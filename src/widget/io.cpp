#include <fstream>

#include "types.h"

// a line in /proc/diskstats would look like:
// [   8       0 sda 655739 70745 87981947 952130 262646 11755 40000104 323883 0 623150 1288910 0 0 0 0 14508 12896 ]
// we need these fields           --^^^--                      --^^^--
// Field  3 -- # of sectors read 
// Field  7 -- # of sectors written 
// example names of block Storage devices: sra loop1 sdf mmcblk
// this code target none partation sd* and sr* block devices

// refer to Documentation/iostats.txt for more information

io_t getIoStat(){

    static struct io_t io_stat_previous;

    struct io_t io_stat, output_stat;

    std::ifstream stat_file("/proc/diskstats");

    if (!stat_file.is_open()) [[unlikely]]
        return output_stat;

    u64 temp;

    // assuming line beginning is fixed
    while (stat_file.ignore(13)) {

        std::string devices_name;
        stat_file >> devices_name;

        // TODO add sda support to this update
        if (devices_name.compare(0, 6, "mmcblk") == 0) { [[likely]]

            // checking if devices_name is not a volume parathion
            if (devices_name[devices_name.length()-2] != 'p') { [[unlikely]]

                stat_file.ignore(20, ' '); // skip feild 1
                stat_file.ignore(20, ' '); // skip feild 2

                stat_file >> temp ;
                io_stat.read += temp;

                stat_file.ignore(20, ' '); // skip feild 3
                stat_file.ignore(20, ' '); // skip feild 4
                stat_file.ignore(20, ' '); // skip feild 5
                stat_file.ignore(20, ' '); // skip feild 6

                stat_file >> temp ;
                io_stat.write += temp;
            }
        }

        stat_file.ignore(1024, '\n');
    }

    output_stat = io_stat - io_stat_previous;

    io_stat_previous = io_stat;

    return output_stat << 9;
}

