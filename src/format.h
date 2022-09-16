#pragma once

#include <string>
#include "types.h"

namespace format {

std::string cpu_useage(u64);
std::string memory(u64);
std::string generic(u64);
std::string free_space(u64);
std::string system_load(u64);
std::string none(u64);

}
