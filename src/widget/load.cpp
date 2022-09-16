#include <fstream>
#include "types.h"

u64 getSystemLoad() {

    float load_value;
    std::ifstream load_file("/proc/loadavg");

    if(!load_file.is_open()) [[unlikely]]
        return 0;

    load_file >> load_value;

    return (u64)(load_value*100);
}

