#include <cstdio>
#include <cstring>

#include <sys/statvfs.h>
#include <mntent.h>

#include "types.h"

u64 getPathFreeSpace(const char *path);

u64 getFreeSpace() {

    std::FILE* mount_point = std::fopen("/proc/mounts", "r");
    mntent* line;

    u64 bytes = 0;

    if(!mount_point) [[unlikely]]
        return 0;

    if (mount_point) {

        while((line=getmntent(mount_point))) {

            if(!strncmp(line->mnt_fsname, "/dev/sd", 7)) {

                bytes += getPathFreeSpace(line->mnt_dir);
            }
        }
    }

    fclose(mount_point);
    return bytes;
}

inline u64 getPathFreeSpace(const char *path) {

    struct statvfs fiData;

    if (!statvfs(path, &fiData)) [[likely]]
        return fiData.f_bavail * fiData.f_bsize;
    else
        return 0;
}

