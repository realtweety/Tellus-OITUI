#ifndef TellusRoot_h
#define TellusRoot_h

#include <stddef.h>

#if !defined(__clang__)
#define _Nonnull
#define _Nullable
#endif

// Starts the Tellus root helper as root and captures its output. Nothing here installs or modifies packages by itself.

/// Runs `path` with up to four arguments and captures its output (stdout and stderr), waiting for it for at most
/// `timeout_milliseconds`.
///
/// `use_persona` != 0 asks the system to start the child as root through the persona API (needs the
/// com.apple.private.persona-mgmt entitlement). Returns 0 when the process was started and has exited, otherwise the errno or
/// error code of the step that failed. `exit_status` receives the child's exit code, or -1 if it was killed or timed out. `out`
/// always ends with NUL.
///
/// What happens on timeout is up to the caller:
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
