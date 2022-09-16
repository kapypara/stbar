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

class draw_program {

    // GL Side
    GL::array program_attributes;
    GL::program program;

    GL::shader vertex, geometry, fragment;
    GL::attribute point, texture_coordinate;

    GL::uniform height, texture_size, background;

    GL::buffer points, coordinates;

    GL::texture *texture;

    // C side
    bool ready = false;

public:

    draw_program();

    void build();
    void draw() const;
    void use() const;

    void drawUntextured() const;
    void drawTextured() const;

    void setTexture(GL::texture*);
    void setPoints(vec2 const&) const;
    void setCoordinates(vec2 const&);

    void setTextureSize(vec2 const&);
    void setBackgroundColor(vec4 const&);
    void setHeight(GLfloat);

    void bindTexture() const;
    void unBindtexture() const;

    [[nodiscard]] inline bool is_ready() const {
        return ready;
    }

};
