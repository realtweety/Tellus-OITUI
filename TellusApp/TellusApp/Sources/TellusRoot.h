#ifndef TellusRoot_h
#define TellusRoot_h

#include <stddef.h>

#if !defined(__clang__)
#define _Nonnull
#define _Nullable
#endif

// Research helpers for finding out what the Tellus app may do on a jailbroken
// device. Nothing here installs or modifies packages.

/// Tries to create, write and delete a small file in `directory`.
/// Returns 0 on success or the errno of the first step that failed.
int tellus_try_write(const char * _Nonnull directory);

/// Runs `path` (with an optional single argument), captures its output, and
/// waits for it for at most about 5 seconds.
///
/// `use_persona` != 0 asks the system to start the child as root through the
/// persona API (needs the com.apple.private.persona-mgmt entitlement).
///
/// Returns 0 when the process was started and has exited, otherwise the errno
/// or error code of the step that failed. `exit_status` receives the child's
/// exit code, or -1 if it was killed or timed out. `out` always ends with NUL.
int tellus_spawn_capture(const char * _Nonnull path,
                         const char * _Nullable argument,
                         int use_persona,
                         char * _Nonnull out,
                         size_t out_length,
                         int * _Nonnull exit_status);

/// Like `tellus_spawn_capture`, with up to four arguments, a custom timeout, and
/// control over what happens on timeout.
///
/// When the time runs out and `kill_on_timeout` is 0 the child is left running
/// (an install must never be killed half way) and ETIMEDOUT is returned; `out`
/// holds whatever was printed until then.
int tellus_spawn_capture_ex(const char * _Nonnull path,
                            const char * _Nullable argument1,
                            const char * _Nullable argument2,
                            const char * _Nullable argument3,
                            const char * _Nullable argument4,
                            int use_persona,
                            int timeout_milliseconds,
                            int kill_on_timeout,
                            char * _Nonnull out,
                            size_t out_length,
                            int * _Nonnull exit_status);

#endif
