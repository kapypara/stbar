#include "types.h"

#include <fstream>
#include <filesystem>

#include <string>
#include <vector>

#include <iostream>

namespace fs = std::filesystem;
std::vector<fs::directory_entry> fetch_target_interfaces_paths() {

    fs::path dir_path = "/sys/class/net/";

    std::vector<fs::directory_entry> output;
    output.reserve(4);

    try {
        for (const auto& entry : fs::directory_iterator(dir_path)){

            const auto& name = entry.path().filename();

            if(std::string(name).starts_with("en"))
                output.push_back(entry);

            if(std::string(name).starts_with("wlan"))
                output.push_back(entry);
        }

        return output;

    } catch(fs::filesystem_error const& ex) {
        std::cerr << "[net] " << ex.what() << '\n';
        return {};
    }

}


net_t getInterfacesSum() {

    static auto target_interfaces = fetch_target_interfaces_paths();
    static u8 cycles = 0;

    if(++cycles == 0u) [[unlikely]]
        target_interfaces = fetch_target_interfaces_paths();

    net_t sum(0);

    for(auto const& e : target_interfaces){

        // std::cout << e.path() << '\n';

        net_t temp;

        std::ifstream rx_file(e.path() / "statistics/rx_bytes");
        std::ifstream tx_file(e.path() / "statistics/tx_bytes");

        if(!rx_file.is_open() || !tx_file.is_open()) [[unlikely]]
            continue;

        rx_file >> temp.rx;
        tx_file >> temp.tx;

        sum += temp;
    }

    return sum;
}
 
net_t getNetStat(){

    static net_t net_stat_previous(0);

    net_t net_stat, output_stat;

    net_stat = getInterfacesSum();

    output_stat = net_stat - net_stat_previous;

    net_stat_previous = net_stat;

    return output_stat;
}

