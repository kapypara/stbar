#pragma once

#include "forward.h"

namespace GL {

class uniform {

    GLint location = -1;

public:
    void defineLocation(GLuint program, const GLchar *name);
    void defineLocation(GL::program const&, const GLchar *name);

    template <typename Container>
    void defineLocation(program const& program, Container name){
        return defineLocation(program, static_cast<const GLchar*>(name.data()));
    }

    uniform() = default;
    uniform(GLuint program, const GLchar *name);
    uniform(GL::program const&, const GLchar *name);

    template <typename Container>
    uniform(GL::program const& program, Container name){
        defineLocation(program, name.data());
    };

    [[nodiscard]] inline GLint getLocation() const {
        return location;
    }

    void setData(GLfloat) const;
    void setData(GLfloat, GLfloat) const;
    void setData(GLfloat, GLfloat, GLfloat) const;
    void setData(GLfloat, GLfloat, GLfloat, GLfloat) const;

};

}
