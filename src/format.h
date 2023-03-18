#pragma once

#include <string>
#include "types.h"

namespace format {

std::u16string cpu_useage(u64);
std::u16string memory(u64);
std::u16string system_load(u64);

std::u16string free_space(u64);
std::u16string generic(u64);
std::u16string none(u64);

u64 toBCD(u64);
constexpr u64 fromBCD(u64);

}
