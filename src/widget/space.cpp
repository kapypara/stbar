#include <cstdio>
#include <cstring>
#include <set>

#include <mntent.h>
#include <sys/stat.h>
#include <sys/statvfs.h>

#include "types.h"

u64 getPathFreeSpace(const char *path);

u64 getFreeSpace() {
    FILE* mount_file = setmntent("/proc/mounts", "r");
    if (mount_file == nullptr) [[unlikely]]
        return 0;

    struct mntent* ent;
    u64 total_bytes = 0;

    std::set<std::string> seen_devices;

    while ((ent = getmntent(mount_file)) != nullptr) {
        const char* dev_name = ent->mnt_fsname;

        // Support: /dev/sd* (SATA), /dev/nvme* (NVMe), /dev/mmcblk* (SD/eMMC)
        bool is_storage = (strncmp(dev_name, "/dev/sd", 7) == 0 || 
                           strncmp(dev_name, "/dev/nvme", 9) == 0 || 
                           strncmp(dev_name, "/dev/mmcblk", 11) == 0);

        if (is_storage) {
            // .insert().second is true only if the element was newly added
            if (seen_devices.insert(ent->mnt_fsname).second) {
                total_bytes += getPathFreeSpace(ent->mnt_dir);
            }
        }
    }

    endmntent(mount_file);
    return total_bytes;
}

inline u64 getPathFreeSpace(const char *path) {

    struct statvfs fiData;

    if (!statvfs(path, &fiData)) [[likely]]
        return fiData.f_bavail * fiData.f_bsize;

    return 0;
}

