#include <sys/sysinfo.h>
#include "types.h"

u64 getSystemLoad() {

    struct sysinfo info;

    sysinfo(&info);

    return info.loads[0] / ((1 << SI_LOAD_SHIFT) / 100);
}
