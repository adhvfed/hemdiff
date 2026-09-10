#include "HemdiffPOSIX.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <spawn.h>
#include <poll.h>
#include <time.h>
#include <signal.h>

extern char **environ;

static void convert(struct stat value, hmd_stat *out) {
    out->device = value.st_dev;
    out->inode = value.st_ino;
    out->size = value.st_size;
    out->blocks = value.st_blocks;
    out->mode = value.st_mode;
    out->uid = value.st_uid;
    out->links = value.st_nlink;
#ifdef __APPLE__
    out->mtime_sec = value.st_mtimespec.tv_sec;
    out->mtime_nsec = value.st_mtimespec.tv_nsec;
    out->ctime_sec = value.st_ctimespec.tv_sec;
    out->ctime_nsec = value.st_ctimespec.tv_nsec;
#else
    out->mtime_sec = value.st_mtim.tv_sec;
    out->mtime_nsec = value.st_mtim.tv_nsec;
    out->ctime_sec = value.st_ctim.tv_sec;
    out->ctime_nsec = value.st_ctim.tv_nsec;
#endif
}

int hmd_stat_fd(int fd, hmd_stat *out) {
    struct stat value;
    if (fstat(fd, &value)) return -1;
    convert(value, out);
    return 0;
}

int hmd_stat_child(int fd, const char *name, hmd_stat *out) {
    struct stat value;
    if (fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW)) return -1;
    convert(value, out);
    return 0;
}

int hmd_open_child(int fd, const char *name) {
    return openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

int hmd_open_regular(int parent, const char *name) {
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat value;
    if (fstat(fd, &value) || !S_ISREG(value.st_mode)) {
        close(fd); errno = EPERM; return -1;
    }
    return fd;
}

// Walk each ancestor independently. O_NOFOLLOW on the final component alone is insufficient.
static int walk(const char *path, int create) {
    if (path[0] != '/') { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    char *copy = strdup(path);
    if (!copy) { close(fd); return -1; }
    char *save = NULL;
    char *component = strtok_r(copy, "/", &save);
    while (component) {
        if (!strcmp(component, ".") || !strcmp(component, "..")) {
            close(fd); free(copy); errno = EINVAL; return -1;
        }
        if (create && mkdirat(fd, component, 0700) && errno != EEXIST) {
            close(fd); free(copy); return -1;
        }
        int next = hmd_open_child(fd, component);
        close(fd);
        if (next < 0) { free(copy); return -1; }
        fd = next;
        component = strtok_r(NULL, "/", &save);
    }
    free(copy);
    return fd;
}

int hmd_open_directory(const char *path) { return walk(path, 0); }

int hmd_private_directory(const char *path) {
    int fd = walk(path, 1);
    if (fd < 0) return -1;
    struct stat value;
    if (fstat(fd, &value) || value.st_uid != getuid() || (value.st_mode & 0777) != 0700) {
        close(fd); errno = EPERM; return -1;
    }
    return fd;
}

char *hmd_names(int fd, size_t *length) {
    // dup(fd) shares its directory offset; openat(".") creates an independent enumeration.
    int copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (copy < 0) return NULL;
    DIR *directory = fdopendir(copy);
    if (!directory) { close(copy); return NULL; }
    size_t used = 0, capacity = 1024;
    char *bytes = malloc(capacity);
    if (!bytes) { closedir(directory); return NULL; }
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        size_t count = strlen(entry->d_name) + 1;
        if (used + count > capacity) {
            capacity = (used + count) * 2;
            char *expanded = realloc(bytes, capacity);
            if (!expanded) { free(bytes); closedir(directory); errno = ENOMEM; return NULL; }
            bytes = expanded;
        }
        memcpy(bytes + used, entry->d_name, count);
        used += count;
        errno = 0;
    }
    int error = errno;
    closedir(directory);
    if (error) { free(bytes); errno = error; return NULL; }
    *length = used;
    return bytes;
}

int hmd_unlink(int fd, const char *name, int directory) {
    return unlinkat(fd, name, directory ? AT_REMOVEDIR : 0);
}
int hmd_close(int fd) { return close(fd); }
void hmd_free(void *pointer) { free(pointer); }

static int secure(int fd) {
    struct stat value;
    return fstat(fd, &value) == 0 && S_ISREG(value.st_mode) && value.st_uid == getuid() &&
        (value.st_mode & 0777) == 0600 && value.st_nlink == 1;
}

int hmd_lock(int directory) {
    int fd = openat(directory, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (!secure(fd) || flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd); errno = EBUSY; return -1;
    }
    return fd;
}

int hmd_write(int directory, const char *name, const void *data, size_t length) {
    char temporary[96];
    snprintf(temporary, sizeof(temporary), ".write-%d-%u", getpid(), arc4random());
    int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, (const char *)data + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); unlinkat(directory, temporary, 0); return -1; }
        written += count;
    }
    int result = fsync(fd);
    close(fd);
    if (!result) result = renameat(directory, temporary, directory, name);
    if (!result) result = fsync(directory);
    if (result) unlinkat(directory, temporary, 0);
    return result;
}

char *hmd_read(int directory, const char *name, size_t *length, size_t limit) {
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat value;
    if (!secure(fd) || fstat(fd, &value) || value.st_size < 0 || (uint64_t)value.st_size > limit) {
        close(fd); errno = EPERM; return NULL;
    }
    size_t count = value.st_size;
    char *bytes = malloc(count + 1);
    if (!bytes) { close(fd); return NULL; }
    size_t used = 0;
    while (used < count) {
        ssize_t readCount = read(fd, bytes + used, count - used);
        if (readCount < 0 && errno == EINTR) continue;
        if (readCount <= 0) { free(bytes); close(fd); errno = EIO; return NULL; }
        used += readCount;
    }
    close(fd);
    bytes[count] = 0;
    *length = count;
    return bytes;
}

int hmd_exists(int directory, const char *name) {
    struct stat value;
    return fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0;
}
uint32_t hmd_uid(void) { return getuid(); }
int hmd_pid(void) { return getpid(); }

// Only bounded regular marker files are read. Never follow a replaced marker link.
char *hmd_read_evidence(int directory, const char *name, size_t *length, size_t limit) {
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat before, after;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_size < 0 ||
        (uint64_t)before.st_size > limit) {
        close(fd);
        errno = EPERM;
        return NULL;
    }
    size_t count = before.st_size;
    char *bytes = malloc(count + 1);
    if (!bytes) { close(fd); return NULL; }
    size_t used = 0;
    while (used < count) {
        ssize_t n = read(fd, bytes + used, count - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { free(bytes); close(fd); errno = EIO; return NULL; }
        used += n;
    }
    int result = fstat(fd, &after);
    close(fd);
    hmd_stat a, b;
    convert(before, &a);
    convert(after, &b);
    if (result || a.size != b.size || a.mtime_sec != b.mtime_sec ||
        a.mtime_nsec != b.mtime_nsec || a.ctime_sec != b.ctime_sec || a.ctime_nsec != b.ctime_nsec) {
        free(bytes); errno = EBUSY; return NULL;
    }
    bytes[count] = 0;
    *length = count;
    return bytes;
}

int hmd_run(const char *const *argv, char **output, size_t *length,
            int seconds, size_t limit, int (*cancelled)(void *), void *context) {
    int descriptors[2];
    if (pipe(descriptors)) return -1;
    fcntl(descriptors[0], F_SETFD, FD_CLOEXEC);
    fcntl(descriptors[1], F_SETFD, FD_CLOEXEC);
    fcntl(descriptors[0], F_SETFL, O_NONBLOCK);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);

    // The caller's repository overrides must not substitute an index/worktree/config.
    size_t envCount = 0;
    while (environ[envCount]) envCount++;
    char **environment = calloc(envCount + 1, sizeof(char *));
    size_t kept = 0;
    for (size_t i = 0; i < envCount; i++) {
        if (!strncmp(environ[i], "GIT_", 4) || !strncmp(environ[i], "LD_", 3) ||
            !strncmp(environ[i], "DYLD_", 5)) continue;
        environment[kept++] = environ[i];
    }
    pid_t pid;
    int error = posix_spawn(&pid, argv[0], &actions, &attributes, (char *const *)argv, environment);
    free(environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (error) { close(descriptors[0]); errno = error; return -1; }

    size_t used = 0;
    char *bytes = malloc(limit + 1);
    if (!bytes) { close(descriptors[0]); kill(-pid, SIGKILL); while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {} return -1; }
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int failed = 0, eof = 0, reaped = 0, status = 0;
    while (!eof || !reaped) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((cancelled && cancelled(context)) || now.tv_sec - start.tv_sec >= seconds) {
            failed = 1;
            break;
        }
        if (!reaped) {
            pid_t result = waitpid(pid, &status, WNOHANG);
            if (result == pid) reaped = 1;
            else if (result < 0 && errno != EINTR) { failed = 1; break; }
        }
        struct pollfd ready = { descriptors[0], POLLIN | POLLHUP, 0 };
        int result = poll(eof ? NULL : &ready, eof ? 0 : 1, 100);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) { failed = 1; break; }
        if (!result || eof) continue;
        ssize_t count = read(descriptors[0], bytes + used, limit - used);
        if (count == 0) eof = 1;
        else if (count < 0 && errno != EAGAIN && errno != EINTR) { failed = 1; break; }
        else if (count > 0) {
            used += count;
            if (used >= limit) { failed = 1; break; }
        }
    }
    close(descriptors[0]);
    if (failed) kill(-pid, SIGKILL);
    if (!reaped) while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (failed) { free(bytes); errno = ETIMEDOUT; return -1; }
    bytes[used] = 0;
    *output = bytes;
    *length = used;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

int hmd_machine_id(char *output, size_t capacity) {
#ifdef __APPLE__
    unsigned char identifier[16];
    struct timespec timeout = { 5, 0 };
    if (capacity < 33 || gethostuuid(identifier, &timeout)) return -1;
    for (size_t index = 0; index < 16; index++) snprintf(output + index * 2, 3, "%02x", identifier[index]);
    return 0;
#else
    int fd = open("/etc/machine-id", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t count = read(fd, output, capacity - 1);
    close(fd);
    if (count < 32) return -1;
    output[count] = 0;
    return 0;
#endif
}
