#include <string>
#include <chrono>

std::string getDate(){
    char date_str[24];
    std::time_t now = std::time(nullptr)+1;

    std::strftime(date_str, sizeof date_str, "%a %b%d %I:%M:%S %p", std::localtime(&now));

    return date_str;
}
