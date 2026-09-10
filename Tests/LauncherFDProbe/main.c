/* Test-only observer. C entry runs before an interpreter can normalize descriptors. */
#include <sys/resource.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct identity { unsigned long long device, inode, mode, rdev; };

static int write_all(int fd, const void *bytes, size_t length) {
    const unsigned char *cursor = bytes;
    while (length) {
        ssize_t n = write(fd, cursor, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        cursor += n;
        length -= (size_t)n;
    }
    return 0;
}

static struct identity identity_of(const struct stat *s) {
    return (struct identity){(unsigned long long)(uint32_t)s->st_dev,
        (unsigned long long)s->st_ino, (unsigned long long)s->st_mode,
        (unsigned long long)(uint32_t)s->st_rdev};
}

static int same_identity(int fd, struct identity expected) {
    struct stat s;
    if (fstat(fd, &s) != 0) return 0;
    struct identity actual = identity_of(&s);
    return actual.device == expected.device && actual.inode == expected.inode &&
        actual.mode == expected.mode && actual.rdev == expected.rdev;
}

static int number(const char *text, unsigned long long *value) {
    if (!text[0] || strspn(text, "0123456789") != strlen(text)) return -1;
    errno = 0;
    char *end;
    *value = strtoull(text, &end, 10);
    return errno == 0 && *end == '\0' ? 0 : -1;
}

static int publish_identities(const char *path) {
    struct stat a, b;
    if (fstat(STDOUT_FILENO, &a) != 0 || fstat(STDERR_FILENO, &b) != 0) return -1;
    struct identity x = identity_of(&a), y = identity_of(&b);
    char buffer[256];
    int n = snprintf(buffer, sizeof(buffer), "%llu %llu %llu %llu\n%llu %llu %llu %llu\n",
        x.device, x.inode, x.mode, x.rdev, y.device, y.inode, y.mode, y.rdev);
    if (n < 0 || (size_t)n >= sizeof(buffer)) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int result = write_all(fd, buffer, (size_t)n);
    if (close(fd) != 0) result = -1;
    return result;
}

static int scan_identities(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    char buffer[257];
    ssize_t length;
    do { length = read(fd, buffer, sizeof(buffer) - 1); } while (length < 0 && errno == EINTR);
    close(fd);
    if (length <= 0 || length == (ssize_t)sizeof(buffer) - 1) return -1;
    buffer[length] = '\0';
    struct identity a, b;
    char extra;
    if (sscanf(buffer, "%llu %llu %llu %llu\n%llu %llu %llu %llu %c",
        &a.device, &a.inode, &a.mode, &a.rdev, &b.device, &b.inode, &b.mode, &b.rdev, &extra) != 8) return -1;
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0 || limit.rlim_cur > 1048576) return -1;
    for (int candidate = 0; candidate < (int)limit.rlim_cur; candidate++) {
        if (same_identity(candidate, a) || same_identity(candidate, b)) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    /* Every observer arms its own expiry before any possible I/O wait. */
    if (signal(SIGALRM, SIG_DFL) == SIG_ERR) return 90;
    sigset_t signals;
    if (sigemptyset(&signals) || sigaddset(&signals, SIGALRM) ||
        sigprocmask(SIG_UNBLOCK, &signals, NULL)) return 90;
    alarm(8);

    if (argc == 7 && strcmp(argv[1], "sentinel") == 0) {
        unsigned long long values[5];
        for (int i = 0; i < 5; i++) if (number(argv[i + 2], &values[i])) return 91;
        if (values[0] > INT_MAX) return 91;
        struct identity expected = {values[1], values[2], values[3], values[4]};
        const char *line = same_identity((int)values[0], expected) ? "sentinel=1\n" : "sentinel=0\n";
        if (write_all(1, line, strlen(line))) return 92;
    } else if (argc == 3 && strcmp(argv[1], "scan") == 0) {
        int inherited = scan_identities(argv[2]);
        if (inherited < 0) return 93;
        const char *line = inherited ? "foreign=1\n" : "foreign=0\n";
        if (write_all(1, line, strlen(line))) return 92;
    } else if (argc == 4 && strcmp(argv[1], "hold") == 0) {
        if (publish_identities(argv[2])) return 94;
        while (access(argv[3], F_OK) != 0) {
            if (errno != ENOENT) return 95;
            usleep(1000);
        }
    } else if (argc != 2 || (strcmp(argv[1], "io") != 0 && strcmp(argv[1], "exit7") != 0)) {
        return 91;
    }

    if (write_all(1, "probe-stdout\n", 13)) return 96;
    unsigned char buffer[4096];
    for (;;) {
        ssize_t n = read(0, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return 97;
        if (n == 0) break;
        if (write_all(1, buffer, (size_t)n)) return 96;
    }
    if (write_all(2, "probe-stderr\n", 13)) return 98;
    return strcmp(argv[1], "exit7") == 0 ? 7 : 0;
}
