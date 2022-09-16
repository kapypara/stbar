#include "font.h"
#include "../lib/nlohmann/json.hpp"

#include "iostream"
#include "fstream"

using nlohmann::json;

void font::load(std::string const& conf_name){

    std::ifstream source_file(conf_name, std::ios::binary);

    json conf_file;

    source_file >> conf_file;

    name = conf_file["name"];
    bitmap_file = conf_file["file"];

    bitmap_width = conf_file["width"];
    bitmap_height = conf_file["height"];

    char_width = conf_file["char_width"];
    char_height = conf_file["char_height"];

    columns = conf_file["columns"];
    rows = conf_file["rows"];

    char_count = conf_file["char_count"];

    x_incrment = 1.f / static_cast<float>(columns);
    y_incrment = 1.f / static_cast<float>(rows);

    for (auto const& i: conf_file["char_set"]){

        std::string type = i["type"];

        if(type == "range"){
            addCord(i["index"], i["value"], i["count"]);

        } else if (type == "single"){
            addCord(i["index"], i["value"]);

        } else {
            fputs("[font] an element in char_set have no type\n", stderr);
            exit(1);
        }
    }

    /*
    for(auto const& i: glyphs_cords){

        std::cout << i.first << ": ";
        std::cout << i.second.p1.x << '|';
        std::cout << i.second.p1.y << ' ';
        std::cout << i.second.p1.z << '|';
        std::cout << i.second.p1.w << ", ";

        std::cout << i.second.p2.x << '|';
        std::cout << i.second.p2.y << ' ';
        std::cout << i.second.p2.z << '|';
        std::cout << i.second.p2.w << '\n';
    }
    */
}

void font::addCord(u16 index, u16 glyph_value){

    u8 char_col = index % columns;
    u8 char_row = index / columns;

    glyphs_cords glyph;

    float x, y, w, h;

    x = x_incrment * static_cast<float>(char_col);
    y = y_incrment * static_cast<float>(char_row);

    w = x_incrment * static_cast<float>(char_col+1);
    h = y_incrment * static_cast<float>(char_row+1);

    glyph.code = glyph_value;

    glyph.cords.p1 = {
        x, y,
        x, h,
    };

    glyph.cords.p2 = {
        w, y,
        w, h,
    };

    glyphs_cache.insert(glyph);
}


inline void font::addCord(u16 index, u16 glyph_value, u16 count){

    count += index;
    while(index<count){
        addCord(index++, glyph_value++);
    }
}


