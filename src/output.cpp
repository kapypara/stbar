#include "output.h"
#include "format.h"

#include "widget/widgets_default.h"

#include <chrono>
#include <iostream>
#include <locale>
#include <codecvt>
#include <future>

template<typename segment_generic>
void output_line::drawSegment(segment_generic const& seg, std::string const& str){
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    std::u16string u16str = converter.from_bytes(str);

    drawSegment(seg, u16str);
}

template<typename segment_generic>
void output_line::drawSegment(segment_generic const& seg, std::u16string const& str){

    if(str.empty())
        return;

    std::vector<float> characters;
    std::vector<GLfloat> slots;

    characters.reserve(seg.getMaxCharacters()*2);
    slots.reserve(seg.getMaxCharacters()*2);

    u16 limit = seg.getMaxCharacters() - seg.getOffset();

    if(limit>str.size())
        limit = str.size();

    u16 k = 0;
    for (u16 i=0; i<limit; ++i) {

        auto const& c = str[i];

        if(c == u'\n'){
            continue;
        }

        const auto *x = font_cache.getGlyphCord(c);

        if(x != nullptr) {
            characters.push_back(x->x);
            characters.push_back(x->y);

#ifdef IGNORE_UNKNOWN_GLYPHS
            slots.push_back(seg.getSlot(seg.getOffset()+i-k));
#else
            slots.push_back(seg.getSlot(seg.getOffset()+i));
#endif
            slots.push_back(seg.getYpos());
        } else {
            k++;
        }

    }

    rect.setBackgroundColor(seg.getColor());
    rect.setTextureCoordinates(characters);
    rect.setRectPoints(slots);

    rect.draw(slots.size()/2);

};

template<typename segment_generic>
void output_line::clearSegment(segment_generic const& seg){

    rect.setRectSize(
            {
                seg.getMaxCharacters()*2*static_cast<GLfloat>(font_cache.getCharWidth())/static_cast<GLfloat>(screen.get_width()),
                2
            });

    rect.setBackgroundColor(seg.getColor());

    const auto *cord = font_cache.getGlyphCord(' ');
    rect.setTextureCoordinates({cord->x, cord->y});

    rect.setRectPoints({seg.getSlot(0), 1});


    rect.draw(1);

    rect.setRectSize(
            {
                2*static_cast<GLfloat>(font_cache.getCharWidth())/static_cast<float>(screen.get_width()),
                2*static_cast<GLfloat>(font_cache.getCharHeight())/static_cast<GLfloat>(screen.get_height()),
            });
};

// sizes

void output_line::segmentsInit(){

    const u8 update_count = update_interval + update_leftover;

    const int screen_width = screen.get_width();
    const int char_count = screen_width / font_cache.getCharWidth();

    //
    GLfloat y_pos = .9f - static_cast<float>(font_cache.getCharWidth()) / static_cast<float>(screen_width);
    //

    std::vector<GLfloat> slots;

    for(int i=0; i<char_count+1; i++){

        // cord in opengl
        // -1 -------------- 0 -------------- 1

        // cord here
        //  0 -------------- 1 -------------- 2

        GLfloat cord = static_cast<float>(font_cache.getCharWidth()*i) / static_cast<float>(screen_width/2) - 1.f;

        slots.push_back(cord);
    }

    time = {
        { slots.end()-time_segment.start_offset, slots.end()-time_segment.end_offset},
        y_pos, time_segment.draw_offset,
        time_segment.color
    };
    clearSegment(time);


    free_memory = {
        {slots.end()-free_memory_segment.start_offset, slots.end()-free_memory_segment.end_offset},
        y_pos, free_memory_segment.draw_offset,
        free_memory_segment.color
    };
    clearSegment(free_memory);
    drawSegment(free_memory, u"\n\n,\n\n\n");


    cpu_usage = {
        {slots.end()-cpu_usage_segment.start_offset, slots.end()-cpu_usage_segment.end_offset},
        y_pos, cpu_usage_segment.draw_offset,
        cpu_usage_segment.color
    };
    clearSegment(cpu_usage);
    drawSegment(cpu_usage, u"\n\n\n");


    temperature = {
        {slots.end()-temperature_segment.start_offset, slots.end()-temperature_segment.end_offset},
        y_pos, temperature_segment.draw_offset,
        temperature_segment.color
    };
    clearSegment(temperature);
    drawSegment(temperature, u"\n\n");


    system_load = {
        {slots.end()-system_load_segment.start_offset, slots.end()-system_load_segment.end_offset},
        y_pos, system_load_segment.draw_offset,
        system_load_segment.color
    };
    clearSegment(system_load);
    drawSegment(system_load, u"\n\n.\n\n");


    free_space = {
        {slots.end()-free_space_segment.start_offset, slots.end()-free_space_segment.end_offset},
        y_pos, free_space_segment.draw_offset,
        free_space_segment.color
    };
    clearSegment(free_space);
    drawSegment(free_space, u"\n\n\n\n.\n\n\nG");


    dirty_memory = {
        {slots.end()-dirty_memory_segment.start_offset, slots.end()-dirty_memory_segment.end_offset},
        y_pos, dirty_memory_segment.draw_offset,
        dirty_memory_segment.color
    };
    clearSegment(dirty_memory);
    drawSegment(dirty_memory, u"\n\n\n.\n\n");


    io_write = {
        {slots.end()-io_write_segment.start_offset, slots.end()-io_write_segment.end_offset},
        y_pos, io_write_segment.draw_offset,
        io_write_segment.color
    };
    clearSegment(io_write);
    drawSegment(io_write, u"\n\n\n.\n\n");


    io_read = {
        {slots.end()-io_read_segment.start_offset, slots.end()-io_read_segment.end_offset},
        y_pos, io_read_segment.draw_offset,
        io_read_segment.color
    };
    clearSegment(io_read);
    drawSegment(io_read, u"\n\n\n.\n\n");

    net_tx = {
        {slots.end()-net_tx_segment.start_offset, slots.end()-net_tx_segment.end_offset},
        y_pos, net_tx_segment.draw_offset,
        net_tx_segment.color
    };
    clearSegment(net_tx);
    drawSegment(net_tx, u"\n\n\n.\n\n");

    net_rx = {
        {slots.end()-net_rx_segment.start_offset, slots.end()-net_rx_segment.end_offset},
        y_pos, net_rx_segment.draw_offset,
        net_rx_segment.color
    };
    clearSegment(net_rx);
    drawSegment(net_rx, u"\n\n\n.\n\n");


    sound_button = {
        {slots.end()-sound_button_segment.start_offset, slots.end()-sound_button_segment.end_offset},
        y_pos, sound_button_segment.draw_offset,
        sound_button_segment.color
    };
    clearSegment(sound_button);
    drawSegment(sound_button, u"");


    window_title = {
        {slots.begin(), slots.end()-window_title_segment.end_offset},
        y_pos, window_title_segment.draw_offset,
        window_title_segment.color
    };
    clearSegment(window_title);


    // initing data
    free_memory(tick_rate, update_count);
    cpu_usage(tick_rate, update_count);

    temperature(tick_rate, update_count);
    system_load(tick_rate, update_count);

    free_space(tick_rate, update_count);
    dirty_memory(tick_rate, update_count);

    io_write(tick_rate, update_count, segment::type::rate_of_change);
    io_read(tick_rate, update_count, segment::type::rate_of_change);

    net_rx(tick_rate, update_count, segment::type::rate_of_change);
    net_tx(tick_rate, update_count, segment::type::rate_of_change);

}

inline void output_line::sleep(){

    const auto time_point_now = std::chrono::steady_clock::now();
    const auto duration = time_point_now - init_time;

    const auto sleep_length = period - (duration%period);

    // std::cout << std::setw(8) << std::chrono::duration_cast<std::chrono::microseconds>(period - sleep_length) << '\n';

    std::this_thread::sleep_for(sleep_length);
}

void output_line::output(int count) {

    for(int i = 0 ; i < count; ++i){

        cycle();
    }
}

void output_line::output() {
    while(1) cycle();
}

/*
inline void output_line::setSegment(std::string& segment, std::string str){

    segment = std::move(str);
    new_update = true;
}
*/

inline void output_line::cycle() {

    drawSegment(time, getDate());
    // setSegment(bar.time, getDate());

    for(u8 i=0; i < tick_rate; ++i){
        getData(i);
        for(u8 k=0; k < update_interval; ++k)
            render(k);
    }

    for(u8 i=0; i < update_leftover; ++i)
        render(i+update_interval);
}

inline void output_line::getData(u8 i){

    screen.handleEvents();
    // screen.update();
    if (screen.is_ButtonClicked()){
        handleClick(screen.getClick_x(), screen.getClick_button());
        screen.clearClick();
    }

    // free_space.new_tick(i, getFreeMemory());
    auto a1 = std::async(&segment::new_tick, &free_memory, i, getFreeMemory());
    auto a2 = std::async(&segment::new_tick, &cpu_usage, i, getCpuUseage());

    auto a3 = std::async(&segment::new_tick, &temperature, i, getSystemTemperature());
    auto a4 = std::async(&segment::new_tick, &system_load, i, getSystemLoad());

    auto a5 = std::async(&segment::new_tick, &free_space, i, getFreeSpace());
    auto a6 = std::async(&segment::new_tick, &dirty_memory, i, getDirtyMemory());

    auto a7 = std::async(
            [&](){
                const io_t io_tmp = getIoStat();

                io_write.new_tick(i, io_tmp.write);
                io_read.new_tick(i, io_tmp.read);
            });

    auto a8 = std::async(
            [&](){
                const net_t net_tmp = getNetStat();

                net_rx.new_tick(i, net_tmp.rx);
                net_tx.new_tick(i, net_tmp.tx);
            });

    a1.wait();
    a2.wait();
    a3.wait();
    a4.wait();
    a5.wait();
    a6.wait();
    a7.wait();
    a8.wait();

}

void output_line::handleClick(const u16 x_pos, const u8 button){

    // clicked slot is from right
    u16 clicked_slot = 1+ (screen.get_width() - x_pos) / static_cast<u16>(font_cache.getCharWidth());

    switch(clicked_slot){
        case 0 ... time_segment.start_offset:

            std::cout << "cclip -i $(date +%s)" << std::endl;

        break;

        case free_memory_segment.end_offset+1 ... cpu_usage_segment.start_offset:

            std::cout << "konsole -e htop &" << std::endl;

        break;

        case temperature_segment.end_offset+1 ... system_load_segment.start_offset:

            std::cout << "screenfix &" << std::endl;

        break;

        case free_space_segment.end_offset+1 ... io_write_segment.start_offset:

            std::cout << "dolphin &" << std::endl;

        break;

        case net_tx_segment.end_offset+1 ... net_rx_segment.start_offset:

            std::cout << "usb-restart &" << std::endl;

        break;

        case sound_button_segment.end_offset+1 ... sound_button_segment.start_offset:

            sound_button_state = !sound_button_state;
            if(sound_button_state){
                drawSegment(sound_button, u"\n");
                std::cout << "line_out -s 1" << std::endl;

            } else {
                drawSegment(sound_button, u"\n");
                std::cout << "line_out -s 0" << std::endl;

            }

        break;

        default: // window title

            std::cout << "cclip -i \"$(xdotool getwindowname `xdotool getactivewindow` | tr -d '\\n')\" &" << std::endl;

        break;

    }

}

void output_line::updateSegment(
    segment& seg,
    u8 index,
    std::function<std::string(u64)> const& fn
){
    const u64 old_data = seg.getLast();
    const u64 new_data = seg.getTransitionStep(index);

    if(new_data == old_data) { [[likely]]
        // std::cout << "skipping\n";
        return;
    }

    drawSegment(seg, fn(new_data));
}

void output_line::updateSegment(
    segment& seg,
    u8 index,
    std::function<std::u16string(u64)> const& fn
){

    const u64 old_data = seg.getLast();
    const u64 new_data = seg.getTransitionStep(index);

    if(new_data == old_data) { [[likely]]
        // std::cout << "skipping\n";
        return;
    }

    drawSegment(seg, fn(new_data));
}


void output_line::render(u8 index) {


    updateSegment(free_memory, index, format::memory);
    updateSegment(cpu_usage, index, format::cpu_useage);

    updateSegment(temperature, index, format::none);
    updateSegment(system_load, index, format::system_load);

    updateSegment(free_space, index, format::free_space);
    updateSegment(dirty_memory, index, format::generic);

    updateSegment(io_write, index, format::generic);
    updateSegment(io_read, index, format::generic);

    updateSegment(net_tx, index, format::generic);
    updateSegment(net_rx, index, format::generic);

    if(!window_title_string.not_changed.test_and_set(std::memory_order_consume)) {

        clearSegment(window_title);

        std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
        window_title_u16string = converter.from_bytes(window_title_string.getString());

        // a hack to remove undrawable charaters from string
        {
            auto& new_name = window_title_u16string;

            u16 i, k;

            k = new_name.length();
            i = 0;

            while (i < k){

                if (font_cache.getGlyphCord(new_name[i]) == nullptr){
                    new_name.erase(new_name.begin()+i);
                    k--;

                } else {
                    i++;
                }
            }
        }


        if(window_title_u16string.size() > window_title.getMaxCharacters()){
            window_title_u16string.push_back(' ');
            window_title_u16string.push_back(2);
            window_title_u16string.push_back(' ');
        }

        window_fetch_time = program_counter;
        window_name_rotation = 0;

        drawSegment(window_title, window_title_u16string);

    } else if (program_counter - window_fetch_time > static_cast<i64>(update_rate) &&
        !((program_counter - window_fetch_time)%(update_interval))){

        if(window_title_u16string.length() > window_title.getMaxCharacters()){

            std::rotate(window_title_u16string.begin(), window_title_u16string.begin()+1, window_title_u16string.end());

            drawSegment(window_title, window_title_u16string);

            if(++window_name_rotation == window_title_u16string.size()*2){
                window_fetch_time = program_counter + 60*update_rate;
                window_name_rotation = 0;
            }
        }
    }


    glFlush();

    program_counter++;
    sleep();
}
