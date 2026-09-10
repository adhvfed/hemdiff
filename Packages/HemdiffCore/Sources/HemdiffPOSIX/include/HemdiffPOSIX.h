#ifndef HEMDIFF_POSIX_H
#define HEMDIFF_POSIX_H
#include <stdint.h>
#include <stddef.h>
typedef struct { uint64_t device, mount_id, inode, size, blocks; int64_t mtime_sec, mtime_nsec, ctime_sec, ctime_nsec; uint32_t mode, uid, links; } hmd_stat;
int hmd_open_directory(const char *path);
int hmd_open_child(int parent, const char *name);
int hmd_open_regular(int parent, const char *name);
int hmd_stat_fd(int fd, hmd_stat *out);
int hmd_stat_child(int parent, const char *name, hmd_stat *out);
char *hmd_names(int fd, size_t *length);
int hmd_unlink(int parent, const char *name, int directory);
int hmd_close(int fd);
void hmd_free(void *pointer);
int hmd_private_directory(const char *path);
int hmd_lock(int directory);
int hmd_write(int directory, const char *name, const void *data, size_t length);
char *hmd_read(int directory, const char *name, size_t *length, size_t limit);
int hmd_exists(int directory, const char *name);
int hmd_run(const char *const *argv, char **output, size_t *length, int timeout_seconds, size_t limit, int (*cancelled)(void *), void *context);
char *hmd_read_evidence(int directory, const char *name, size_t *length, size_t limit);
int hmd_machine_id(char *output, size_t capacity);
uint32_t hmd_uid(void);
int hmd_pid(void);
#endif
