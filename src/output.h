#ifndef STBAR_V2_OUTPUT_H
#define STBAR_V2_OUTPUT_H

#include "segments.h"
#include "types.h"
#include "widget/widgets.h"

#include <bits/chrono.h>
#include <functional>
#include <string>
#include <thread>

class output_line {

    segment::output bar;

    locked_string window_name;

    bool new_update = false;

    const u8 tick_rate, update_rate;
    const u8 update_interval, update_leftover;
    const std::chrono::microseconds period; 

    std::chrono::time_point<std::chrono::steady_clock> init_time;

    std::thread sound_thread;
    std::thread window_thread;

    // std::atomic_flag sound_state;

    bool error = false; // for debugging

    segment::data<segment::state> data;

    windowName active_window;

    void segmentsInit();
    void sleep();

    void cycle();
    void getData(u8);
    void render(u8);

    void setSegment(std::string&, std::string);
    void testValueAndSetSegment(std::string&, segment::state&, u8, std::function<std::string(u64)>);

public:

    // TODO remove unused var's
    output_line(u8 tick, u8 update)
        : tick_rate(update)
        , update_rate(update)
        , update_interval(update_rate/tick_rate)
        , update_leftover(update_rate%tick_rate)

        , period(std::chrono::milliseconds((int)1e3 / update_rate))
        , active_window(window_name)
    {

        segmentsInit();

        sound_thread = std::thread(setSoundBit, &bar.sound_button);
        sound_thread.detach();

        window_thread = std::thread(&windowName::start, &active_window);
        window_thread.detach();

        init_time = std::chrono::steady_clock::now();
    }

    void output(int count);
    [[noreturn]] void output();
};

#endif //STBAR_V2_OUTPUT_H
