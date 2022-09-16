#pragma once

#include <gl/forward.h>

#include <iostream>
#define assertm(exp, msg) assert(exp && msg)

#include "shader.h"

namespace GL {

class program {

    GLuint id = 0;
    GLint status = 0;

    void link();

public:
    program();
    program(shader vertex, shader fragment);
    program(shader vertex, shader geometry, shader fragment);

    void build(shader vertex, shader fragment);
    void build(shader vertex, shader geometry, shader fragment);

    [[nodiscard]] inline GLuint getId() const {
        return id;
    };

    [[nodiscard]] inline GLint getStatus() const {
        return status;
    };

    inline void use() const {
        assertm(status == 1, "program is not link");
        glUseProgram(id);
    };
};
}
