#pragma once

#include "types.h"
#include <cstdlib>
#include <set>

class font {
    struct glyphs_cords {
        u16 code;
        vec2 cords;

        auto operator<=>(glyphs_cords const& lhs) const {
            if (code < lhs.code) return -1;
            if (lhs.code < code) return 1;
            return 0;
        }

        auto operator<=>(u16 const lhs) const{
            if (code < lhs) return -1;
            if (lhs < code) return 1;
            return 0;
        }
    };

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

    [[nodiscard]] inline float getCharHeight() const {
        return char_height;
    }

    [[nodiscard]] inline float getCharWidth() const {
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
