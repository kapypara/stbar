#pragma once

#include <atomic>
#include <cinttypes>
#include <mutex>
#include <numeric>
#include <string>
#include <utility>
#include <vector>

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
            this->rx - b.rx,
            this->tx - b.tx
        };
    }

    net_t operator +(net_t const& b) const {
        return {
            this->rx + b.rx,
            this->tx + b.tx
        };
    }

    net_t operator +=(net_t const& b) {
        this->rx = this->rx + b.rx;
        this->tx = this->tx + b.tx;

        return *this;
    }
    

    constexpr explicit net_t() = default;

    constexpr explicit net_t(u64 i)
        : rx(i)
        , tx(i)
    {}

    constexpr net_t(u64 r, u64 t)
        : rx(r)
        , tx(t)
    {}

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

    constexpr vec4() = default;
    constexpr vec4(float all) : x(all), y(all), z(all), w(all) {}
    constexpr vec4(float a, float b, float c, float d) : x(a), y(b), z(c), w(d) {}
} __attribute__((aligned(16)));

struct vec2{

    float x, y;

    constexpr vec2(const float all) : x(all), y(all) {}
    constexpr vec2(const float a, const float b) : x(a), y(b) {}
} __attribute__((aligned(8)));

struct rect {
    u16 x, y; 
    u16 w, h; 

    constexpr rect(u16 a, u16 b, u16 c, u16 d) : x(a), y(b), w(c), h(d) {}
} __attribute__((aligned(8)));


