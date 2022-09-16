#pragma once

#include "types.h"

#include <atomic>
#include <string>

std::string getDate();

u64 getFreeMemory();
u64 getCpuUseage();

u64 getSystemTemperature();
u64 getSystemLoad();

u64 getFreeSpace();
u64 getDirtyMemory();
io_t getIoStat();

net_t getNetStat();

[[noreturn]] void setSoundBit(std::atomic_flag* bit);

#include "window.h"

