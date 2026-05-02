#ifndef STBAR_V2_OUTPUT_H
#define STBAR_V2_OUTPUT_H

#include "segment.h"
#include "renderer.h"
#include "types.h"
#include "widget/widgets.h"

#include <bits/chrono.h>
#include <functional>
#include <string>
#include <thread>

class output_line {

    segment_draw time; // draw only
    segment free_memory;
    segment cpu_usage;
    segment temperature;
    segment system_load;

    segment free_space;
    segment dirty_memory;
    segment io_write;
    segment io_read;

    segment net_tx;
    segment net_rx;

    segment_draw sound_button;
    segment_draw window_title;

    bool sound_button_state = false;

    locked_string window_title_string;
    std::u16string window_title_u16string;

    bool new_update = false;

    renderer& screen;
    static_rect& rect;
    font& font_cache;

    const u8 tick_rate, update_rate;
    const u8 update_interval, update_leftover;
    const std::chrono::microseconds period; 

    std::chrono::time_point<std::chrono::steady_clock> init_time;

    std::thread window_thread;

    i64 program_counter;

    bool error = false; // for debugging

    windowName active_window;
    i64 window_fetch_time;
    u64 window_name_rotation;

    void segmentsInit();
    void sleep();

    void cycle();
    void handleClick(u16 x_pos, u8 button = 1);
    void getData(u8);
    void render(u8);

    template<typename segment_generic>
    void drawSegment(segment_generic const& seg, std::string const& str);

    template<typename segment_generic>
    void drawSegment(segment_generic const& seg, std::u16string const& str);

    template<typename segment_generic>
    void clearSegment(segment_generic const& seg);

    void updateSegment(segment&, u8, std::function<std::string(u64)> const&);
    void updateSegment(segment&, u8, std::function<std::u16string(u64)> const&);
    // void setSegment(std::string&, std::string);
    // void testValueAndSetSegment(std::string&, segment::state&, u8, std::function<std::string(u64)>);

public:

    // TODO remove unused var's
    output_line(renderer &scrn, static_rect& prepeard_rect, font& font_cache,
                u8 tick, u8 update)
        : screen(scrn)
        , rect(prepeard_rect)
        , font_cache(font_cache)
        , tick_rate(tick)
        , update_rate( (update>tick)?update:tick )
        , update_interval(update_rate/tick_rate)
        , update_leftover(update_rate%tick_rate)

        , period(std::chrono::milliseconds((int)1e3 / update_rate))
        , active_window(window_title_string)
    {

        // std::cout << (long)update_interval << '\n';
        segmentsInit();

        // sound_thread = std::thread(setSoundBit, &sound_button_flag);
        // sound_thread.detach();

        window_thread = std::thread(&windowName::start, &active_window);
        window_thread.detach();

        init_time = std::chrono::steady_clock::now();
    }

    void output(int count);
    [[noreturn]] void output();
};

#endif //STBAR_V2_OUTPUT_H
