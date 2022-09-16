#include "format.h"

std::string format::cpu_useage(u64 input) {

    char buffer[4];
    std::snprintf(buffer, sizeof buffer, "%02lu", input);
    return buffer;
}

std::string format::memory(u64 input) {

    char buffer[7];
    std::snprintf(buffer, sizeof buffer, "%'06lu", input);
    return buffer;
}

std::string format::system_load(u64 input) {

    char buffer[7];
    std::snprintf(buffer, sizeof buffer, "%.2f", (float)input/100.f);
    return buffer;
}

std::string format::free_space(u64 input) {

    char buffer[9];
    std::snprintf(buffer, sizeof buffer, "%07.3f", (float)(input>>20)/1024.f);
    return buffer;
}

std::string format::generic(u64 num){
    char buffer[7];  // the output will look like "015.6M" so six characters and a null byte.

    if( num < 1e3 )
        std::snprintf(buffer, sizeof buffer, "%05.1fB", (float)num);
    else if( num < 1e6 )
        std::snprintf(buffer, sizeof buffer, "%05.1fK", (float)num/1024.f);
    else if( num < 1e9 )
        std::snprintf(buffer, sizeof buffer, "%05.1fM", (float)(num>>10)/1024.f);
    else if( num < 1e12 )
        std::snprintf(buffer, sizeof buffer, "%05.1fG", (float)(num>>20)/1024.f);
    else if( num < 1e15 )
        std::snprintf(buffer, sizeof buffer, "%05.1fT", (float)(num>>30)/1024.f);
    else if( num < 1e18 )
        std::snprintf(buffer, sizeof buffer, "%05.1fP", (float)(num>>40)/1024.f);
    else
        std::snprintf(buffer, sizeof buffer, "%05.1fE", (float)(num>>50)/1024.f);

    return buffer;
}

std::string format::none(u64 input) {

    return std::to_string(input);
}
