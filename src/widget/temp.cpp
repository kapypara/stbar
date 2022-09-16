#include <cstdio>
#include <dirent.h>
#include <cstring>

#include "types.h"

// return the path to the temp file: /sys/bus/platform/devices/coretemp.0/hwmon/hwmon1/temp1_input

bool get_temp_file_path();
static char temperature_file[128] = {};
static bool file_found = get_temp_file_path();

bool get_temp_file_path() {

    const char* base_dir = "/sys/bus/platform/devices/coretemp.0/hwmon";

    DIR* dir = opendir(base_dir);
    struct dirent* entry;

    if(dir)
        entry = readdir(dir);
    else
        entry = nullptr;

    while (entry) {
        if (entry->d_type == DT_DIR)
            if (!strncmp(entry->d_name, "hwmon", 5)) {

                sprintf(temperature_file, "%s/%s/%s", base_dir, entry->d_name, "temp1_input");
                // break;
                return true;
            }

        entry = readdir(dir);
    }

    closedir(dir);
    return false;
}


u64 getSystemTemperature() {

    if (!file_found) [[unlikely]]
        return 0;

    u64 reading;
    std::FILE *temp = std::fopen(temperature_file, "r");

    if (!temp) [[unlikely]]
        return 0;

    std::fscanf(temp, "%2lu", &reading);

    fclose(temp);
    return reading;
}

