/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef HEMDIFF_LINUX_STATX_H
#define HEMDIFF_LINUX_STATX_H

/* Linux statx UAPI layout, retained for static SDKs without Linux kernel headers.
 * Source: https://github.com/torvalds/linux/blob/v5.8/include/uapi/linux/stat.h
 * Unused fields after mount ID stay reserved. The kernel ABI is 256 bytes.
 */
#include <stdint.h>
#include <stddef.h>
#if __has_include(<linux/stat.h>)
#include <linux/stat.h>
typedef struct statx hmd_kernel_statx;
#else
struct hmd_statx_timestamp {
    int64_t tv_sec;
    uint32_t tv_nsec;
    int32_t reserved;
};
typedef struct {
    uint32_t stx_mask, stx_blksize;
    uint64_t stx_attributes;
    uint32_t stx_nlink, stx_uid, stx_gid;
    uint16_t stx_mode, spare0;
    uint64_t stx_ino, stx_size, stx_blocks, stx_attributes_mask;
    struct hmd_statx_timestamp stx_atime, stx_btime, stx_ctime, stx_mtime;
    uint32_t stx_rdev_major, stx_rdev_minor, stx_dev_major, stx_dev_minor;
    uint64_t stx_mnt_id, reserved[13];
} hmd_kernel_statx;
#ifndef STATX_BASIC_STATS
#define STATX_BASIC_STATS 0x000007ffU
#endif
#define STATX_MNT_ID 0x00001000U
#endif
_Static_assert(sizeof(hmd_kernel_statx) == 256, "Unexpected Linux statx ABI size");
_Static_assert(offsetof(hmd_kernel_statx, stx_mnt_id) == 0x90, "Unexpected Linux mount ID offset");
#endif
