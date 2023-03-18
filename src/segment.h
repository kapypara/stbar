#pragma once

#include "static_rect.h"
#include "font.h"
#include "types.h"

#include <functional>
#include <string>

class segment_draw {

    // for drawing
    std::vector<float> slots;
    float y_offset;
    u16 char_offset;
    u16 limit;
    vec4 color;


public:
    segment_draw() = default;
    segment_draw(std::span<float> const& x_poistion, float y_poistion,
            u16 offset, vec4 const& new_color) 
        : slots(x_poistion.begin(), x_poistion.end())
        , y_offset(y_poistion)
        , char_offset(offset)
        , limit(slots.size())
        , color(new_color)
    {
    }

    // draw stuff
    void setSlots(std::span<float> const& x_poistion);

    inline void setYpos(float y_position){
        y_offset = y_position;
    }

    inline void setCharOffset(u16 offset){
        char_offset = offset;
    }

    inline void setColor(vec4 const& new_color){
        color = new_color;
    };

    [[nodiscard]] inline u64 getMaxCharacters() const {
        return limit;
    }

    [[nodiscard]] inline u64 getOffset() const {
        return char_offset;
    }

    [[nodiscard]] inline float getSlot(u16 index) const {
        return slots[index];
    }

    [[nodiscard]] inline float getYpos() const {
        return y_offset;
    }

    [[nodiscard]] inline vec4 getColor() const {
        return color;
    }
};

class segment : public segment_draw {
public:
    enum type {
        avreage,
        rate_of_change,
    };
private:

    u64 last = 0;
    type state_type = avreage;
    u8 step_limit = 0;

    std::vector<u64> ticks;
    std::vector<u64> transition_values;


public:
    using segment_draw::segment_draw;

    // math stuff
    [[nodiscard]] inline u64 ticks_sum() const {
        return std::reduce(ticks.begin(), ticks.end());
    }

    void operator ()(u16 memory_size, u16 transition_size, segment::type use = avreage);

    void new_tick(u16, u64);
    void setTransition(u64);

    [[nodiscard]] inline u64 getLast() const {
        return last;
    }

    inline u64 getTransitionStep(u16 i){
        return last = transition_values[i];
    }

};
