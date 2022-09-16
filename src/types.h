#pragma once

#include <cinttypes>
#include <numeric>
#include <utility>
#include <vector>
#include <mutex>
#include <atomic>

#define u8  uint8_t
#define u16 uint16_t
#define u32 uint32_t
#define u64 uint64_t

#define i8  int8_t
#define i16 int16_t
#define i32 int32_t
#define i64 int64_t

inline u32 log2u32(const u32 x){
    return (32 - __builtin_clz (x));
}

struct io_t {
    u64 write = 0;
    u64 read = 0;

    io_t operator -(io_t const& b) const {
        return {
            .write = this->write - b.write,
            .read = this->read - b.read
        };
    }

    io_t operator <<(u8 b) const {
        return {
            .write = this->write << b,
            .read = this->read << b
        };
    }

    operator std::pair<u64, u64>(){
        return {this->read, this->write};
    }
};


struct net_t {
    u64 rx = 0;
    u64 tx = 0;

    net_t operator -(net_t const& b) const {
        return {
            .rx = this->rx - b.rx,
            .tx = this->tx - b.tx
        };
    }

    operator std::pair<u64, u64>(){
        return {this->rx, this->tx};
    }
};

struct locked_string {

    std::mutex lock;
    std::atomic_flag not_changed;
    std::string string;

    void setString(std::string str){

        std::lock_guard<std::mutex> lk(lock);

        string = std::move(str);
    }

    std::string getString(){

        std::lock_guard<std::mutex> lk(lock);

        std::string str = string;
        return str;
    }
};

struct vec4{

    float x, y, z, w;

    vec4(float all) : x(all), y(all), z(all), w(all) {}
    vec4(float a, float b, float c, float d) : x(a), y(b), z(c), w(d) {}
};

struct vec2{

    float x, y;

    vec2(float all) : x(all), y(all) {}
    vec2(float a, float b) : x(a), y(b) {}
} __attribute__((aligned(8)));

struct rect {
    u16 x, y; 
    u16 w, h; 

    rect(u16 a, u16 b, u16 c, u16 d) : x(a), y(b), w(c), h(d) {}
};

struct points_cord {
    vec4 p1 = 0;
    vec4 p2 = 0;
};

