#pragma once

#include "types.h"
#include <cstdlib>
#include <set>

class font {
    struct glyphs_cords {
        u16 code;
        vec2 cords;

        auto operator<=>(glyphs_cords const& rhs) const {
            return code - rhs.code;
        }

        auto operator<=>(u16 const rhs) const{
            return code - rhs;
        }
    } __attribute__((aligned(16)));

public:
    void load(std::string const&);

    inline const vec2* getGlyphCord(u16 code){

        auto search = glyphs_cache.find(code);

        if (search != glyphs_cache.end()) {
            return &search->cords;
        } 

        return nullptr;
    }

    [[nodiscard]] inline float getRelativeWidth() const {
        return x_incrment;
    }

    [[nodiscard]] inline float getRelativeHeight() const {
        return y_incrment;
    }

    [[nodiscard]] inline u16 getCharHeight() const {
        return char_height;
    }

    [[nodiscard]] inline u16 getCharWidth() const {
        return char_width;
    }

private:
    void addCord(u16, u16);
    void addCord(u16, u16, u16);

    std::set<glyphs_cords, std::less<>> glyphs_cache;

    std::string name;
    std::string bitmap_file;

    u16 bitmap_height;
    u16 bitmap_width;

    u16 char_height;
    u16 char_width;

    u16 columns;
    u16 rows;

    u16 char_count;


    // tools
    float x_incrment;
    float y_incrment;
};
