#include <fstream>
#include "types.h"


net_t getNetStat(){

    static net_t net_stat_previous;

    net_t net_stat, output_stat;

    std::ifstream rx_file("/sys/class/net/eno1/statistics/rx_bytes");
    std::ifstream tx_file("/sys/class/net/eno1/statistics/tx_bytes");

    if(!rx_file.is_open() || !tx_file.is_open()) [[unlikely]]
        return output_stat;

    rx_file >> net_stat.rx;
    tx_file >> net_stat.tx;

    output_stat = net_stat - net_stat_previous;

    net_stat_previous = net_stat;

    return output_stat;
}

