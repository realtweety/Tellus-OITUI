// Checks the vendored Monocypher Ed25519 verifier against two published RFC 8032 test vectors (section 7.1, tests 1 and 2),
// and that it rejects a changed message, a changed signature and a changed key. Run by tools/tellus_helper_test.sh.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "monocypher-ed25519.h"

static void unhex(const char *hex, uint8_t *out, size_t length)
{
    for (size_t i = 0; i < length; i++) {
        unsigned value = 0;
        sscanf(hex + 2 * i, "%2x", &value);
        out[i] = (uint8_t)value;
    }
}

static int failures = 0;

static void expectResult(const char *label, int got, int want)
{
    if (got == want) { printf("ok   %s\n", label); return; }
    printf("FAIL %s: got %d, wanted %d\n", label, got, want);
    failures++;
}

int main(void)
{
    const char *keys[2] = {
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
    };
    const char *messages[2] = { "", "72" };
    const char *signatures[2] = {
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
    };
    size_t messageLengths[2] = { 0, 1 };

    for (int i = 0; i < 2; i++) {
        uint8_t key[32], message[8], signature[64];
        unhex(keys[i], key, 32);
        unhex(messages[i], message, messageLengths[i]);
        unhex(signatures[i], signature, 64);

        char label[80];
        snprintf(label, sizeof(label), "RFC 8032 vector %d verifies", i + 1);
        expectResult(label, crypto_ed25519_check(signature, key, message, messageLengths[i]), 0);

        uint8_t changedSignature[64];
        memcpy(changedSignature, signature, 64);
        changedSignature[10] ^= 1;
        snprintf(label, sizeof(label), "vector %d with a changed signature is refused", i + 1);
        expectResult(label, crypto_ed25519_check(changedSignature, key, message, messageLengths[i]) != 0, 1);

        uint8_t changedKey[32];
        memcpy(changedKey, key, 32);
        changedKey[5] ^= 1;
        snprintf(label, sizeof(label), "vector %d with a changed key is refused", i + 1);
        expectResult(label, crypto_ed25519_check(signature, changedKey, message, messageLengths[i]) != 0, 1);

        uint8_t other[2] = { 0x73, 0x00 };
        snprintf(label, sizeof(label), "vector %d with a different message is refused", i + 1);
        expectResult(label, crypto_ed25519_check(signature, key, other, 2) != 0, 1);
    }
    printf("%s\n", failures == 0 ? "all vector checks passed" : "VECTOR CHECKS FAILED");
    return failures == 0 ? 0 : 1;
}
