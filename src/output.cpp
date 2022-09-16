#include "output.h"
#include "format.h"

#include <chrono>
#include <iostream>

void output_line::segmentsInit(){

    const u8 update_count = update_interval + update_leftover;

    data.io_read(tick_rate, update_count, segment::type::rate_of_change);
    data.io_write(tick_rate, update_count, segment::type::rate_of_change);

    data.net_rx(tick_rate, update_count, segment::type::rate_of_change);
    data.net_tx(tick_rate, update_count, segment::type::rate_of_change);

    data.mem_dirty(tick_rate, update_count);
    data.mem_free(tick_rate, update_count);
    data.cpu_usage(tick_rate, update_count);

    data.load(tick_rate, update_count);
    data.temp(tick_rate, update_count);
    data.space_free(tick_rate, update_count);

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

inline void output_line::setSegment(std::string& segment, std::string str){

    segment = std::move(str);
    new_update = true;
}

inline void output_line::cycle() {

    setSegment(bar.time, getDate());

    for(u8 i=0; i < tick_rate; ++i){
        getData(i);
        for(u8 k=0; k < update_interval; ++k)
            render(k);
    }

    for(u8 i=0; i < update_leftover; ++i)
        render(i+update_interval);
}

inline void output_line::getData(u8 i){

    data.mem_free.new_tick(i, getFreeMemory());
    data.cpu_usage.new_tick(i, getCpuUseage());

    data.load.new_tick(i, getSystemLoad());
    data.temp.new_tick(i, getSystemTemperature());

    data.space_free.new_tick(i, getFreeSpace());
    data.mem_dirty.new_tick(i, getDirtyMemory());

    const io_t io_tmp = getIoStat();

    data.io_read.new_tick(i, io_tmp.read);
    data.io_write.new_tick(i, io_tmp.write);

    const net_t net_tmp = getNetStat();

    data.net_rx.new_tick(i, net_tmp.rx);
    data.net_tx.new_tick(i, net_tmp.tx);

}

void output_line::testValueAndSetSegment(
    std::string& segment,
    segment::state& data,
    u8 index,
    std::function<std::string(u64)> fn
){

    const u64 old_data = data.last;
    const u64 new_data = data.getTransitionStep(index);

    if(new_data == old_data) { [[likely]]
        // std::cout << "skipping\n";
        return;
    }

    setSegment(segment, fn(new_data));
}

void output_line::render(u8 index) {

    testValueAndSetSegment(bar.mem_free, data.mem_free, index, format::memory);
    testValueAndSetSegment(bar.cpu_usage, data.cpu_usage, index, format::cpu_useage);

    testValueAndSetSegment(bar.net_rx, data.net_rx, index, format::generic);
    testValueAndSetSegment(bar.net_tx, data.net_tx, index, format::generic);

    testValueAndSetSegment(bar.io_write, data.io_write, index, format::generic);
    testValueAndSetSegment(bar.io_read, data.io_read, index, format::generic);

    testValueAndSetSegment(bar.mem_dirty, data.mem_dirty, index, format::generic);
    testValueAndSetSegment(bar.space_free, data.space_free, index, format::free_space);

    testValueAndSetSegment(bar.load, data.load, index, format::system_load);
    testValueAndSetSegment(bar.temp, data.temp, index, format::none);

    if(!window_name.not_changed.test_and_set(std::memory_order_consume)) {
        setSegment(bar.window_title, window_name.getString());
    }


    if (new_update){
        bar.draw();
        new_update = false;
    }

    sleep();
}
