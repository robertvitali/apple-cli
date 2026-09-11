/* Fixed observation-only ABI for qualified capability process sessions.
 * This module never installs dispositions, signals, spawns, or reaps.
 * Native compilation and profile admission require separate qualification.
 */
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

_Static_assert(sizeof(pid_t) == sizeof(int32_t), "unsupported pid_t width");
_Static_assert((pid_t)-1 < 0, "unsupported pid_t signedness");
_Static_assert(sizeof(((struct sigaction *)0)->sa_flags) == sizeof(uint32_t),
               "unsupported sigaction flags width");
_Static_assert(NSIG == 32, "unsupported signal range");

uint32_t capability_process_abi_version(void) {
    return UINT32_C(1);
}

int32_t capability_process_sigchld_snapshot(int32_t *handler_kind,
                                           uint32_t *flags) {
    if (handler_kind != NULL) {
        *handler_kind = 0;
    }
    if (flags != NULL) {
        *flags = 0;
    }
    if (handler_kind == NULL || flags == NULL) {
        return EINVAL;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    if (sigaction(SIGCHLD, NULL, &action) == -1) {
        const int saved_errno = errno;
        return saved_errno;
    }
    *handler_kind = action.sa_handler == SIG_DFL ? 0 :
        (action.sa_handler == SIG_IGN ? 1 : 2);
    *flags = (uint32_t)action.sa_flags;
    return 0;
}

int32_t capability_process_observe_child(int32_t child, int32_t *state,
                                         int32_t *observed_pid,
                                         int32_t *status_kind,
                                         int32_t *status_code) {
    if (state != NULL) {
        *state = 0;
    }
    if (observed_pid != NULL) {
        *observed_pid = 0;
    }
    if (status_kind != NULL) {
        *status_kind = 0;
    }
    if (status_code != NULL) {
        *status_code = 0;
    }
    if (child <= 0 || state == NULL || observed_pid == NULL ||
        status_kind == NULL || status_code == NULL) {
        return EINVAL;
    }

    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)child, &info,
               WNOWAIT | WNOHANG | WEXITED) == -1) {
        const int saved_errno = errno;
        return saved_errno;
    }
    if (info.si_pid == 0) {
        return 0;
    }
    if (info.si_pid != (pid_t)child) {
        return EPROTO;
    }

    int32_t kind;
    switch (info.si_code) {
    case CLD_EXITED:
        if (info.si_status < 0 || info.si_status > 255) {
            return EPROTO;
        }
        kind = 1;
        break;
    case CLD_KILLED:
    case CLD_DUMPED:
        if (info.si_status <= 0 || info.si_status >= NSIG) {
            return EPROTO;
        }
        kind = info.si_code == CLD_KILLED ? 2 : 3;
        break;
    default:
        return EPROTO;
    }

    *state = 1;
    *observed_pid = (int32_t)info.si_pid;
    *status_kind = kind;
    *status_code = (int32_t)info.si_status;
    return 0;
}
