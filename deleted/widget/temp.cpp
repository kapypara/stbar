#include "types.h"
#include <cstdio>
#include <cstring>
#include <dirent.h>

// return the path to the temp file: /sys/bus/platform/devices/coretemp.0/hwmon/hwmon1/temp1_input

static bool get_temp_file_path();
static char temperature_file[128] = "/sys/class/hwmon/hwmon2/temp1_input";
static bool file_found = get_temp_file_path();

static bool get_temp_file_path() {
    DIR* hwmon_dir = opendir("/sys/class/hwmon");
    if (!hwmon_dir) return false;

    struct dirent* entry;
    while ((entry = readdir(hwmon_dir)) != nullptr) {
        // Skip '.' and '..'
        if (entry->d_name[0] == '.') continue;

        char name_path[256];
        snprintf(name_path, sizeof(name_path), "/sys/class/hwmon/%s/name", entry->d_name);
        
        FILE* name_file = fopen(name_path, "r");
        if (name_file) {
            char sensor_name[64];
            if (fgets(sensor_name, sizeof(sensor_name), name_file)) {
                sensor_name[strcspn(sensor_name, "\n")] = 0; // Remove newline
                
                // Check for common CPU temperature drivers: k10temp (AMD) or coretemp (Intel)
                if (strcmp(sensor_name, "k10temp") == 0 || strcmp(sensor_name, "coretemp") == 0) {
                    snprintf(temperature_file, sizeof(temperature_file), "/sys/class/hwmon/%s/temp1_input", entry->d_name);
                    fclose(name_file);
                    closedir(hwmon_dir);
                    return true;
                }
            }
            fclose(name_file);
        }
    }

    closedir(hwmon_dir);
    return false;
}

u64 getSystemTemperature() {

    if (!file_found) [[unlikely]]
        return 0;

    u64 reading;
    FILE* temp = fopen(temperature_file, "r");

    if (!temp) [[unlikely]]
        return 0;

    fscanf(temp, "%2lu", &reading);
    fclose(temp);

    return reading;
}

