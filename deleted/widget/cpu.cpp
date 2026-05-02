#include <fstream>
#include <array>
#include <numeric>

#include "types.h"

template<typename T>
struct cpu_t {
    T idle = 0;
    T total = 0;

    cpu_t<T> operator -(cpu_t<T> const& b) const {
        return {
            .idle = this->idle - b.idle,
            .total = this->total - b.total
        };
    }

    template<typename U>
    operator cpu_t<U>() const {
        return {
            .idle = (U) (this->idle),
            .total = (U) (this->total)
        };
    }
};

u64 getCpuUseage() {

    static cpu_t<u64> cpu_stat_previous;

    cpu_t<u64> cpu_stat;
    cpu_t<float> delta;

    u64 utilization;

    std::array<u64, 10> cpu_ticks;
    std::ifstream proc_stat("/proc/stat");

    if (!proc_stat.is_open()) [[unlikely]]
        return 0;

    proc_stat.ignore(3); // Skip the 'cpu' prefix.

    for(auto& tick: cpu_ticks)
        proc_stat >> tick;

    cpu_stat.idle = cpu_ticks[3];
    cpu_stat.total = std::accumulate(cpu_ticks.begin(), cpu_ticks.end(), (u64)0);

    delta = cpu_stat - cpu_stat_previous;

    if(delta.total == 0)
        return 0;

    utilization = 100 - 100 * (delta.idle / delta.total);

    cpu_stat_previous = cpu_stat;

    return utilization;
}

