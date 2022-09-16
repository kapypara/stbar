#include <fstream>
#include <atomic>

void setSoundBit(std::atomic_flag* bit) {

    // TODO reomve this string duplicate
    const std::string filePath = "/tmp/status_bar/sound";

    std::fstream file(filePath);

    if(!file.is_open()) [[unlikely]]
        return;

    while(true){

        if (bit->test(std::memory_order_acquire)) {

            bit->clear(std::memory_order_release);

        } else {

            bit->test_and_set(std::memory_order_release);

        }

        file.ignore(); // sleep (block) until file written
        file.clear();
    }
}
