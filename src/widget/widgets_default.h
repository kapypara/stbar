#include "../segment.h"

static consteval vec4 c2v(u32 RGBA){

    constexpr auto vec4cTOvec4f = [](u8 x, u8 y, u8 z, u8 w){
        return vec4(
            static_cast<float>(x)/255,
            static_cast<float>(y)/255,
            static_cast<float>(z)/255,
            static_cast<float>(w)/255
        );
    };

    return vec4cTOvec4f(RGBA>>24, RGBA>>16, RGBA>>8, RGBA);
}

struct segment_static_info {
    vec4 color;
    u16 start_offset;
    u16 end_offset;
    u16 draw_offset;

    constexpr segment_static_info(u16 s, u16 e, u16 d, vec4 c)
        : color(c)
        , start_offset(s)
        , end_offset(e)
        , draw_offset(d)
    {}
} __attribute__((packed));

// constexpr u32 x = 0x00000077;

constexpr segment_static_info time_segment(23, 0, 1, c2v(0x595959CC));


constexpr auto add_after_segment = [](segment_static_info const& seg, u16 start, u16 end, u16 draw_offset, vec4 c){

    return segment_static_info (
        seg.start_offset+start,
        seg.start_offset+end,
        draw_offset, c
    );
};

constexpr segment_static_info free_memory_segment = add_after_segment(time_segment, 9, 0, 0, c2v(0x844242CC));
constexpr segment_static_info cpu_usage_segment = add_after_segment(free_memory_segment, 6, 0, 0, c2v(0x844242CC));

constexpr segment_static_info temperature_segment = add_after_segment(cpu_usage_segment, 6, 0, 1, c2v(0x84783CCC));
constexpr segment_static_info system_load_segment = add_after_segment(temperature_segment, 7, 0, 0, c2v(0x84783CCC));

constexpr segment_static_info free_space_segment = add_after_segment(system_load_segment, 13, 0, 1, c2v(0x763C84CC));
constexpr segment_static_info dirty_memory_segment = add_after_segment(free_space_segment, 9, 0, 1, c2v(0x763C84CC));
constexpr segment_static_info io_write_segment = add_after_segment(dirty_memory_segment, 9, 0, 1, c2v(0x763C84CC));
constexpr segment_static_info io_read_segment = add_after_segment(io_write_segment, 9, 0, 1, c2v(0x763C84CC));

constexpr segment_static_info net_tx_segment = add_after_segment(io_read_segment, 10, 0, 1, c2v(0x43843CCC));
constexpr segment_static_info net_rx_segment = add_after_segment(net_tx_segment, 9, 0, 1, c2v(0x43843CCC));

constexpr segment_static_info sound_button_segment = add_after_segment(net_rx_segment, 4, 0, 1, c2v(0x5A938FCC));
constexpr segment_static_info window_title_segment(0, sound_button_segment.start_offset, 1, c2v(0x00000077));

// int ptr = printf("%f%f%f%f\n", xv.x, xv.y, xv.z, xv.w);

