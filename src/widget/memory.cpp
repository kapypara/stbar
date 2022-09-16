#include <fstream>
#include "types.h"

u64 getFreeMemory() {

    u64 free_mem;

    std::ifstream mem_file("/proc/meminfo");

    if(!mem_file.is_open()) [[unlikely]]
        return 0;

    mem_file.ignore(256, '\n');
    mem_file.ignore(256, '\n');
    mem_file.ignore(13, ' ');

    mem_file >> free_mem;

    return free_mem>>10;

}
