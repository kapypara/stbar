#pragma once

#include "gl/forward.h"
#include "gl/array.h"
#include "gl/attribute.h"
#include "gl/buffer.h"
#include "gl/program.h"
#include "gl/uniform.h"

#include "types.h"
#include <span>
#include <string>
#include <vector>

class static_rect {

    // GL Side
    GL::array program_attributes;
    GL::program program;

    GL::shader vertex, geometry, fragment;
    GL::attribute point, texture_coordinate;

    GL::uniform rect_size, texture_size, background;

    GL::buffer points, coordinates;

    GL::texture *texture;

    // C side
    bool ready = false;

public:

    static_rect();

    void build();
    void draw(u16) const;
    void use() const;

    void setTexture(GL::texture*);
    void setRectPoints(std::vector<GLfloat> const&) const;
    void setTextureCoordinates(std::vector<GLfloat> const&) const;

    void setRectSize(vec2 const&);
    void setTextureSize(vec2 const&);
    void setBackgroundColor(vec4 const&);

    void bindTexture() const;
    void unBindtexture() const;

    [[nodiscard]] inline bool is_ready() const {
        return ready;
    }

};
