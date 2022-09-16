#pragma once

#include <atomic>
#include <string>

#include "types.h"

namespace segment {

template<typename T>
struct data {

    T net_rx;
    T net_tx;
    T io_read;
    T io_write;
    T mem_dirty;
    T space_free;
    T load;
    T temp;
    T cpu_usage;
    T mem_free;
    T time;

};

struct output : data<std::string> {

    std::atomic_flag sound_button;
    std::string window_title;

    void draw();
};

enum type {
    avreage,
    rate_of_change,
};

struct state {

    u8 step_limit = 0;
    u64 last = 0;
    type state_type = avreage;

    std::vector<u64> ticks;
    std::vector<u64> transition_values;

    u64 ticks_sum(){
        return std::reduce(ticks.begin(), ticks.end());
    }

    state() = default;

    // init call
    state& operator ()(u16 vec_size, u16 tran_size, segment::type use = avreage){

        this->state_type = use;
        this->ticks.resize(vec_size, 0);
        this->transition_values.resize(tran_size, 0);

        this->step_limit = log2u32(tran_size) -1; // add +1 to make transition more smoother

        return *this;
    }

    void new_tick(u16, u64);
    void setTransition(u64);

    u64 getTransitionStep(u16 i){
        return last = transition_values[i];
    }
};

}
