#pragma once

#include "forward.h"

namespace GL {

class attribute {

    GLint location = -1;

public:
    void defineLocation(GLuint program, const GLchar *name);
    void defineLocation(GL::program const&, const GLchar *name);

    template <typename Container>
    void defineLocation(program const& program, Container name){
        defineLocation(program, static_cast<const GLchar*>(name.data()));
    }

    attribute() = default;
    attribute(GLuint program, const GLchar *name);
    attribute(GL::program const&, const GLchar *name);

    template <typename Container>
    attribute(GL::program const& program, Container name){
        defineLocation(program, name.data());
    };

    [[nodiscard]] inline GLint getLocation() const {
        return location;
    }

    // TODO add check for current vao. also enableFor
    inline void enable() const {
        glEnableVertexAttribArray(location);
    }
    inline void disable() const {
        glDisableVertexAttribArray(location);
    }

    void setData(GLint count, GLenum type, GLboolean normalize = GL_FALSE,
                 GLsizei stride = 0, GLulong offset = 0) const;
};

}
