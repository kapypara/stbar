#include <fstream>
#include "types.h"

u64 getDirtyMemory() {

    u64 dirty_mem;

    std::ifstream mem_file("/proc/meminfo");

    if (!mem_file.is_open()) [[unlikely]]
        return 0;

    for (u8 i=0; i<18; i++)
        mem_file.ignore(256, '\n');

    mem_file.ignore(7, ' ');
    mem_file >> dirty_mem;

    return dirty_mem<<10;
}
