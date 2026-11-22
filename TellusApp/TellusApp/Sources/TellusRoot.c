#include "TellusRoot.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

// Private persona API, declared here the same way TrollStore does. The
// symbols live in libSystem; using them requires the persona-mgmt entitlement.
#define TELLUS_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, gid_t);

static long long millisecondsNow(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int spawnCapture(const char *path,
                        char *const argv[],
                        int use_persona,
                        int timeout_milliseconds,
                        int kill_on_timeout,
                        char *out,
                        size_t out_length,
                        int *exit_status)
{
    if (out == NULL || out_length == 0 || exit_status == NULL || path == NULL) return EINVAL;
    out[0] = '\0';
    *exit_status = -1;

    int pipefd[2];
    if (pipe(pipefd) != 0) return errno;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);

    if (use_persona) {
        int result = posix_spawnattr_set_persona_np(&attributes, 99, TELLUS_PERSONA_FLAGS_OVERRIDE);
        if (result == 0) result = posix_spawnattr_set_persona_uid_np(&attributes, 0);
        if (result == 0) result = posix_spawnattr_set_persona_gid_np(&attributes, 0);
        if (result != 0) {
            posix_spawnattr_destroy(&attributes);
            posix_spawn_file_actions_destroy(&actions);
            close(pipefd[0]);
            close(pipefd[1]);
            return result;
        }
    }

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, path, &actions, &attributes, argv, environ);

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (spawnResult != 0) {
        close(pipefd[0]);
        return spawnResult;
    }

    size_t used = 0;
    long long deadline = millisecondsNow() + timeout_milliseconds;
    int timedOut = 0;

    for (;;) {
        long long remaining = deadline - millisecondsNow();
        if (remaining <= 0) { timedOut = 1; break; }

        struct pollfd descriptor = { .fd = pipefd[0], .events = POLLIN, .revents = 0 };
        int ready = poll(&descriptor, 1, (int)remaining);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) { timedOut = 1; break; }

        char chunk[512];
        ssize_t count = read(pipefd[0], chunk, sizeof(chunk));
        if (count <= 0) break; // EOF: the child closed its output

        size_t room = out_length - 1 - used;
        size_t take = (size_t)count < room ? (size_t)count : room;
        memcpy(out + used, chunk, take);
        used += take;
        out[used] = '\0';
    }
    close(pipefd[0]);

    if (timedOut && !kill_on_timeout) {
        // Leave the child alone; it keeps running without us.
        return ETIMEDOUT;
    }
    if (timedOut) kill(pid, SIGKILL);

    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);

    if (waited >= 0 && !timedOut && WIFEXITED(status)) {
        *exit_status = WEXITSTATUS(status);
    }
    return 0;
}

int tellus_spawn_capture_ex(const char *path,
                            const char *argument1,
                            const char *argument2,
                            const char *argument3,
                            const char *argument4,
                            int use_persona,
                            int timeout_milliseconds,
                            int kill_on_timeout,
                            char *out,
                            size_t out_length,
                            int *exit_status)
{
    char *argv[7];
    int count = 0;
    argv[count++] = (char *)path;
    if (argument1 != NULL) argv[count++] = (char *)argument1;
    if (argument2 != NULL) argv[count++] = (char *)argument2;
    if (argument3 != NULL) argv[count++] = (char *)argument3;
    if (argument4 != NULL) argv[count++] = (char *)argument4;
    argv[count] = NULL;
    return spawnCapture(path, argv, use_persona, timeout_milliseconds, kill_on_timeout, out, out_length, exit_status);
}
