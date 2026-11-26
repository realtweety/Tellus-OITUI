// Tellus root helper.
//
// Tellus starts this program as root (through the persona API) to install one
// of its own packages. The helper does not trust its caller: it re-checks the
// package itself before running dpkg.
//
//   tellus-helper --install <package> <manifest> <signature> <package-id>
//   tellus-helper --probe
//
// --install refuses to run unless it is really root, only accepts the packages
// in the allowlist below, only reads files from Tellus's update folder, checks
// that the manifest (SHA256SUMS) carries a valid Ed25519 signature from one of
// the built-in public keys, takes the package's expected SHA-256 from that
// signed manifest (never from its caller), hashes the package itself, copies it
// into a root-only folder, confirms the package name inside the .deb, refuses a
// version lower than the installed one, and only then runs dpkg on the private
// copy.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "monocypher-ed25519.h"

// Paths can be overridden at compile time for tests; the shipped build uses the defaults.
#ifndef TELLUS_DPKG_PATH
#define TELLUS_DPKG_PATH "/var/jb/usr/bin/dpkg"
#endif
#ifndef TELLUS_DPKG_DEB_PATH
#define TELLUS_DPKG_DEB_PATH "/var/jb/usr/bin/dpkg-deb"
#endif
#ifndef TELLUS_DPKG_QUERY_PATH
#define TELLUS_DPKG_QUERY_PATH "/var/jb/usr/bin/dpkg-query"
#endif
#ifndef TELLUS_PRIVATE_DIR
#define TELLUS_PRIVATE_DIR "/var/jb/var/tmp/tellus-install"
#endif
#ifndef TELLUS_STAGING_DIR_1
#define TELLUS_STAGING_DIR_1 "/var/mobile/Library/Caches/TellusUpdates"
#endif
#ifndef TELLUS_STAGING_DIR_2
#define TELLUS_STAGING_DIR_2 "/var/jb/var/mobile/Library/Caches/TellusUpdates"
#endif

#define MAX_PACKAGE_BYTES (50u * 1024u * 1024u)
#define MAX_MANIFEST_BYTES (64u * 1024u)
#define SIGNATURE_BYTES 64u

// The Ed25519 public keys (32 bytes, as 64 lowercase hex characters) whose signatures the helper accepts. A signature
// from either one is enough. KEY_1 is the primary release key and KEY_2 the backup key (kept offline). The private keys are
// never in this repository. Tests override these at compile time with their own keys; the shipped build uses the defaults.
#ifndef TELLUS_TRUSTED_KEY_1
#define TELLUS_TRUSTED_KEY_1 "ee5637ae091ca8d079f8385a7b74186f80045bc0ed01aa254c95157a929442f9"
#endif
#ifndef TELLUS_TRUSTED_KEY_2
#define TELLUS_TRUSTED_KEY_2 "7f6176d77eb31a9b56916e3507895e8cd6f094c8bca0a1c51fc89293f604afab"
#endif

#define MANIFEST_FILE_NAME "SHA256SUMS"
#define SIGNATURE_FILE_NAME "SHA256SUMS.sig"

extern char **environ;

static const char *const kAllowedPackages[] = {
    "com.wilburt.oitcore",
    "com.wilburt.oiti",
    "com.wilburt.tellus",
    NULL
};

// ---------------------------------------------------------------- SHA-256

typedef struct {
    uint32_t state[8];
    uint64_t bitCount;
    uint8_t buffer[64];
    size_t bufferLength;
} Sha256;

static const uint32_t kRound[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256Block(Sha256 *context, const uint8_t *block)
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = context->state[0], b = context->state[1], c = context->state[2], d = context->state[3];
    uint32_t e = context->state[4], f = context->state[5], g = context->state[6], h = context->state[7];

    for (int i = 0; i < 64; i++) {
        uint32_t s1 = ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
        uint32_t choose = (e & f) ^ (~e & g);
        uint32_t temp1 = h + s1 + choose + kRound[i] + w[i];
        uint32_t s0 = ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = s0 + majority;
        h = g; g = f; f = e; e = d + temp1; d = c; c = b; b = a; a = temp1 + temp2;
    }

    context->state[0] += a; context->state[1] += b; context->state[2] += c; context->state[3] += d;
    context->state[4] += e; context->state[5] += f; context->state[6] += g; context->state[7] += h;
}

static void sha256Init(Sha256 *context)
{
    static const uint32_t initial[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    memcpy(context->state, initial, sizeof(initial));
    context->bitCount = 0;
    context->bufferLength = 0;
}

static void sha256Update(Sha256 *context, const uint8_t *data, size_t length)
{
    context->bitCount += (uint64_t)length * 8;
    while (length > 0) {
        size_t room = 64 - context->bufferLength;
        size_t take = length < room ? length : room;
        memcpy(context->buffer + context->bufferLength, data, take);
        context->bufferLength += take;
        data += take;
        length -= take;
        if (context->bufferLength == 64) {
            sha256Block(context, context->buffer);
            context->bufferLength = 0;
        }
    }
}

static void sha256Hex(Sha256 *context, char out[65])
{
    uint64_t totalBits = context->bitCount;
    uint8_t padding[72];
    size_t paddingLength = (context->bufferLength < 56) ? (56 - context->bufferLength) : (120 - context->bufferLength);
    memset(padding, 0, sizeof(padding));
    padding[0] = 0x80;
    sha256Update(context, padding, paddingLength);

    uint8_t lengthBytes[8];
    for (int i = 0; i < 8; i++) lengthBytes[i] = (uint8_t)(totalBits >> (56 - 8 * i));
    sha256Update(context, lengthBytes, 8);

    for (int i = 0; i < 8; i++) snprintf(out + i * 8, 9, "%08x", context->state[i]);
    out[64] = '\0';
}

// ---------------------------------------------------------------- helpers

static int fail(int code, const char *message)
{
    printf("ERROR: %s\n", message);
    fflush(stdout);
    return code;
}

static int isAllowedPackage(const char *packageID)
{
    for (int i = 0; kAllowedPackages[i] != NULL; i++) {
        if (strcmp(kAllowedPackages[i], packageID) == 0) return 1;
    }
    return 0;
}

/// Is `resolvedDirectory` the real path of one of the allowed staging folders?
static int isStagingDirectory(const char *resolvedDirectory)
{
    const char *allowed[] = { TELLUS_STAGING_DIR_1, TELLUS_STAGING_DIR_2 };
    for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
        char resolved[PATH_MAX];
        if (realpath(allowed[i], resolved) != NULL && strcmp(resolved, resolvedDirectory) == 0) return 1;
    }
    return 0;
}

static int writeAll(int fd, const uint8_t *data, size_t length)
{
    size_t done = 0;
    while (done < length) {
        ssize_t count = write(fd, data + done, length - done);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        done += (size_t)count;
    }
    return 0;
}

/// Runs a program and optionally captures its output (up to `capacity - 1` bytes).
/// Returns the exit code, or -1 if the program could not be run or did not exit normally.
static int runProgram(const char *path, char *const argv[], char *capture, size_t capacity)
{
    int pipefd[2] = { -1, -1 };
    if (capture != NULL) {
        capture[0] = '\0';
        if (pipe(pipefd) != 0) return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (capture != NULL) {
        posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, pipefd[0]);
        posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    }

    char *environment[] = {
        "PATH=/var/jb/usr/local/sbin:/var/jb/usr/local/bin:/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "DEBIAN_FRONTEND=noninteractive",
        "DPKG_COLORS=never",
        NULL
    };

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, path, &actions, NULL, argv, environment);
    posix_spawn_file_actions_destroy(&actions);
    if (capture != NULL) close(pipefd[1]);

    if (spawnResult != 0) {
        if (capture != NULL) close(pipefd[0]);
        printf("ERROR: could not start %s (%s)\n", path, strerror(spawnResult));
        return -1;
    }

    if (capture != NULL) {
        size_t used = 0;
        for (;;) {
            char chunk[256];
            ssize_t count = read(pipefd[0], chunk, sizeof(chunk));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            size_t room = capacity - 1 - used;
            size_t take = (size_t)count < room ? (size_t)count : room;
            memcpy(capture + used, chunk, take);
            used += take;
            capture[used] = '\0';
        }
        close(pipefd[0]);
    }

    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);

    if (waited < 0 || !WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

static void reportFile(const char *label, const char *path)
{
    struct stat info;
    if (stat(path, &info) != 0) {
        printf("%s: stat failed (%s)\n", label, strerror(errno));
        return;
    }
    int fd = open(path, O_RDONLY);
    int openError = fd < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    printf("%s: size=%lld mode=%o owner=%d readable=%s\n", label, (long long)info.st_size,
           (unsigned)(info.st_mode & 07777), (int)info.st_uid, fd >= 0 ? "yes" : strerror(openError));
}

// ---------------------------------------------------------------- files, signature, manifest

typedef struct {
    uint8_t *data;
    size_t length;
    char directory[PATH_MAX];
    char name[256];
} StagedFile;

static void releaseStagedFile(StagedFile *file)
{
    free(file->data);
    file->data = NULL;
    file->length = 0;
}

/// Reads one regular file from an allowed staging folder completely into memory. Everything that is checked afterwards is
/// checked on these bytes, so the file cannot be swapped between the check and the install. Returns 0, or the exit code to
/// fail with (and sets *message).
static int loadStagedFile(const char *requestedPath, size_t maximumBytes, StagedFile *file, const char **message)
{
    memset(file, 0, sizeof(*file));

    char resolved[PATH_MAX];
    if (realpath(requestedPath, resolved) == NULL) { *message = "the file does not exist"; return 13; }

    char *lastSlash = strrchr(resolved, '/');
    if (lastSlash == NULL || lastSlash == resolved) { *message = "the file path is not valid"; return 14; }
    size_t directoryLength = (size_t)(lastSlash - resolved);
    memcpy(file->directory, resolved, directoryLength);
    file->directory[directoryLength] = '\0';
    const char *fileName = lastSlash + 1;
    if (strlen(fileName) == 0 || strlen(fileName) >= sizeof(file->name)) { *message = "the file name is not valid"; return 14; }
    strcpy(file->name, fileName);

    if (!isStagingDirectory(file->directory)) { *message = "the file is not in Tellus's update folder"; return 14; }

    int input = open(resolved, O_RDONLY | O_NOFOLLOW);
    if (input < 0) { *message = "the file could not be opened"; return 13; }

    struct stat info;
    if (fstat(input, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || (uint64_t)info.st_size > maximumBytes) {
        close(input);
        *message = "the file is not a regular file of a sensible size";
        return 16;
    }

    size_t length = (size_t)info.st_size;
    uint8_t *data = malloc(length);
    if (data == NULL) { close(input); *message = "out of memory"; return 17; }
    size_t received = 0;
    while (received < length) {
        ssize_t count = read(input, data + received, length - received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        received += (size_t)count;
    }
    close(input);
    if (received != length) { free(data); *message = "the file could not be read completely"; return 17; }

    file->data = data;
    file->length = length;
    return 0;
}

static int hexValue(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/// Decodes 64 lowercase hex characters into 32 bytes. Returns 1 on success.
static int decodePublicKey(const char *hex, uint8_t out[32])
{
    if (strlen(hex) != 64) return 0;
    for (int i = 0; i < 32; i++) {
        int high = hexValue(hex[2 * i]);
        int low = hexValue(hex[2 * i + 1]);
        if (high < 0 || low < 0) return 0;
        out[i] = (uint8_t)((high << 4) | low);
    }
    return 1;
}

/// How many of the built-in keys are usable (a key that is not valid hex is ignored, never trusted).
static int trustedKeyCount(void)
{
    const char *keys[] = { TELLUS_TRUSTED_KEY_1, TELLUS_TRUSTED_KEY_2 };
    uint8_t key[32];
    int count = 0;
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (decodePublicKey(keys[i], key)) count++;
    }
    return count;
}

/// Is `signature` a valid Ed25519 signature of exactly `manifest` by one of the built-in keys?
static int manifestSignatureIsValid(const uint8_t *manifest, size_t manifestLength, const uint8_t signature[SIGNATURE_BYTES])
{
    const char *keys[] = { TELLUS_TRUSTED_KEY_1, TELLUS_TRUSTED_KEY_2 };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        uint8_t key[32];
        if (!decodePublicKey(keys[i], key)) continue;
        if (crypto_ed25519_check(signature, key, manifest, manifestLength) == 0) return 1;
    }
    return 0;
}

/// Finds `fileName` in the (already verified) manifest. Lines look like "<64 lowercase hex>  <name>" (sha256sum text mode) or
/// "<64 hex> *<name>" (binary mode). Returns 1 and the hash if exactly one distinct hash is listed for that name; 0 if the
/// name is missing or listed with different hashes.
static int manifestHashFor(const uint8_t *manifest, size_t length, const char *fileName, char hash[65])
{
    size_t nameLength = strlen(fileName);
    int found = 0;
    size_t position = 0;
    while (position < length) {
        size_t end = position;
        while (end < length && manifest[end] != '\n') end++;
        size_t lineLength = end - position;
        if (lineLength > 0 && manifest[position + lineLength - 1] == '\r') lineLength--;
        const uint8_t *line = manifest + position;
        position = end + 1;

        if (lineLength != 64 + 2 + nameLength) continue;
        if (line[64] != ' ' || (line[65] != ' ' && line[65] != '*')) continue;
        if (memcmp(line + 66, fileName, nameLength) != 0) continue;

        char candidate[65];
        int valid = 1;
        for (int i = 0; i < 64; i++) {
            if (hexValue((char)line[i]) < 0) { valid = 0; break; }
            candidate[i] = (char)line[i];
        }
        if (!valid) continue;
        candidate[64] = '\0';

        if (found && strcmp(candidate, hash) != 0) return 0;
        memcpy(hash, candidate, 65);
        found = 1;
    }
    return found;
}

static void trimLineEnd(char *text)
{
    size_t length = strlen(text);
    while (length > 0 && (text[length - 1] == '\n' || text[length - 1] == '\r')) text[--length] = '\0';
}

/// Refuses a package whose version is lower than the installed one. Returns 0 to go on, or the exit code to fail with.
/// An equal version is allowed (a release candidate carries the final version number). A package that is not installed yet is
/// allowed. Anything that cannot be decided is refused.
static int checkNotADowngrade(const char *privatePath, const char *packageID)
{
    char newVersion[256];
    char *newArguments[] = { TELLUS_DPKG_DEB_PATH, "-f", (char *)privatePath, "Version", NULL };
    int newResult = runProgram(TELLUS_DPKG_DEB_PATH, newArguments, newVersion, sizeof(newVersion));
    trimLineEnd(newVersion);
    if (newResult != 0 || newVersion[0] == '\0') return fail(25, "the version of the package could not be read");

    char installedVersion[256];
    char *queryArguments[] = { TELLUS_DPKG_QUERY_PATH, "-W", "--showformat=${Version}", (char *)packageID, NULL };
    int queryResult = runProgram(TELLUS_DPKG_QUERY_PATH, queryArguments, installedVersion, sizeof(installedVersion));
    trimLineEnd(installedVersion);
    if (queryResult == 1 || (queryResult == 0 && installedVersion[0] == '\0')) return 0;   // not installed
    if (queryResult != 0) return fail(25, "the installed version could not be read");

    char *compareArguments[] = { TELLUS_DPKG_PATH, "--compare-versions", newVersion, "lt", installedVersion, NULL };
    int compareResult = runProgram(TELLUS_DPKG_PATH, compareArguments, NULL, 0);
    if (compareResult == 0) return fail(24, "that package is older than the installed version, and Tellus does not downgrade");
    if (compareResult != 1) return fail(25, "the versions could not be compared");
    return 0;
}

// ---------------------------------------------------------------- install

static int installPackage(const char *packagePath, const char *manifestPath, const char *signaturePath, const char *packageID)
{
    if (getuid() != 0 || geteuid() != 0) return fail(10, "the helper is not running as root");
    if (!isAllowedPackage(packageID)) return fail(11, "that package is not allowed to be installed from Tellus");

    printf("STEP: checking the package file\n");
    fflush(stdout);

    StagedFile package, manifest, signature;
    const char *message = NULL;
    int code = loadStagedFile(packagePath, MAX_PACKAGE_BYTES, &package, &message);
    if (code != 0) return fail(code, message);

    const char *fileName = package.name;
    size_t prefixLength = strlen(packageID);
    size_t nameLength = strlen(fileName);
    if (nameLength <= prefixLength + 5 || strncmp(fileName, packageID, prefixLength) != 0 ||
        fileName[prefixLength] != '_' || strcmp(fileName + nameLength - 4, ".deb") != 0) {
        releaseStagedFile(&package);
        return fail(15, "the file name does not match the package");
    }

    // The manifest and its signature: same folder as the package, fixed names, nothing else.
    code = loadStagedFile(manifestPath, MAX_MANIFEST_BYTES, &manifest, &message);
    if (code == 0 && (strcmp(manifest.name, MANIFEST_FILE_NAME) != 0 || strcmp(manifest.directory, package.directory) != 0)) {
        releaseStagedFile(&manifest);
        code = 21;
    }
    if (code != 0) {
        releaseStagedFile(&package);
        return fail(21, "the signed checksum list is missing or not usable");
    }
    code = loadStagedFile(signaturePath, SIGNATURE_BYTES, &signature, &message);
    if (code == 0 && (signature.length != SIGNATURE_BYTES || strcmp(signature.name, SIGNATURE_FILE_NAME) != 0 ||
                      strcmp(signature.directory, package.directory) != 0)) {
        releaseStagedFile(&signature);
        code = 21;
    }
    if (code != 0) {
        releaseStagedFile(&package);
        releaseStagedFile(&manifest);
        return fail(21, "the signature of the checksum list is missing or not usable");
    }

    if (trustedKeyCount() == 0 || !manifestSignatureIsValid(manifest.data, manifest.length, signature.data)) {
        releaseStagedFile(&package);
        releaseStagedFile(&manifest);
        releaseStagedFile(&signature);
        return fail(22, "the checksum list is not signed by a trusted key");
    }
    printf("STEP: signature verified\n");

    char expectedHash[65];
    int listed = manifestHashFor(manifest.data, manifest.length, fileName, expectedHash);
    releaseStagedFile(&manifest);
    releaseStagedFile(&signature);
    if (!listed) {
        releaseStagedFile(&package);
        return fail(23, "the signed checksum list does not list this package exactly once");
    }

    // Hash what we actually read; this is the data that will be installed.
    Sha256 hasher;
    char actualHash[65];
    sha256Init(&hasher);
    sha256Update(&hasher, package.data, package.length);
    sha256Hex(&hasher, actualHash);
    if (strcmp(actualHash, expectedHash) != 0) {
        releaseStagedFile(&package);
        return fail(18, "the package does not match its signed checksum");
    }
    printf("STEP: checksum verified\n");

    // A root-only folder, so nobody can swap the file between the check and the install.
    char privateDirectory[] = TELLUS_PRIVATE_DIR;
    mkdir(privateDirectory, 0700);
    struct stat directoryInfo;
    if (lstat(privateDirectory, &directoryInfo) != 0 || !S_ISDIR(directoryInfo.st_mode) || directoryInfo.st_uid != 0) {
        releaseStagedFile(&package);
        return fail(19, "the private install folder is not usable");
    }
    chmod(privateDirectory, 0700);

    char privatePath[PATH_MAX];
    snprintf(privatePath, sizeof(privatePath), "%s/%s", privateDirectory, fileName);
    unlink(privatePath);
    int output = open(privatePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (output < 0) {
        releaseStagedFile(&package);
        return fail(19, "the private copy could not be created");
    }
    int writeResult = writeAll(output, package.data, package.length);
    fsync(output);
    close(output);
    releaseStagedFile(&package);
    if (writeResult != 0) {
        unlink(privatePath);
        return fail(19, "the private copy could not be written");
    }

    // The package name inside the .deb must be the one that was asked for.
    char nameOutput[256];
    char *queryArguments[] = { TELLUS_DPKG_DEB_PATH, "-f", privatePath, "Package", NULL };
    int queryResult = runProgram(TELLUS_DPKG_DEB_PATH, queryArguments, nameOutput, sizeof(nameOutput));
    trimLineEnd(nameOutput);
    if (queryResult != 0 || strcmp(nameOutput, packageID) != 0) {
        unlink(privatePath);
        return fail(20, "the package inside the file is not the expected one");
    }
    printf("STEP: package name confirmed (%s)\n", packageID);

    int versionCode = checkNotADowngrade(privatePath, packageID);
    if (versionCode != 0) {
        unlink(privatePath);
        return versionCode;
    }
    printf("STEP: version checked\n");
    printf("STEP: running dpkg\n");
    fflush(stdout);

    // Keep going even if Tellus closes (for example while it updates itself).
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    char *installArguments[] = { TELLUS_DPKG_PATH, "-i", "--force-confold", privatePath, NULL };
    int installResult = runProgram(TELLUS_DPKG_PATH, installArguments, NULL, 0);
    unlink(privatePath);

    if (installResult != 0) {
        printf("ERROR: dpkg failed (exit %d)\n", installResult);
        fflush(stdout);
        return 30;
    }
    printf("RESULT: installed %s\n", packageID);
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 6 && strcmp(argv[1], "--install") == 0) {
        return installPackage(argv[2], argv[3], argv[4], argv[5]);
    }

    if (argc >= 2 && strcmp(argv[1], "--probe") == 0) {
        printf("uid=%d euid=%d gid=%d egid=%d pid=%d\n", (int)getuid(), (int)geteuid(),
               (int)getgid(), (int)getegid(), (int)getpid());
        reportFile("dpkg status", "/var/jb/var/lib/dpkg/status");
        reportFile("dpkg binary", TELLUS_DPKG_PATH);
        printf("trusted signing keys: %d\n", trustedKeyCount());
        return 0;
    }

    fprintf(stderr, "usage: tellus-helper --install <package> <manifest> <signature> <package-id> | --probe\n");
    return 2;
}
