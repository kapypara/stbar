#pragma once

#include <GL/glew.h>
#include <cassert>

namespace GL{

class array;
class buffer;

class shader;
class program;
class attribute;
class uniform;

class texture;

/* -------------------- */
// TODO: maybe move this some where else
void bindArray(GL::array const&);
void bindBuffer(GL::buffer const&);


inline void unbindArray(){
    glBindVertexArray(0);
}

void bindTexture(GL::texture const&);

inline void unBindTexture(){
    glBindTexture(GL_TEXTURE_2D, 0);
}

void setBuffer(GL::buffer const& buff, GLenum usage,
                      GLuint size, const void *data);

template <typename Container>
inline void setBuffer(GL::buffer const& buffer, GLenum usage, Container data) {

    GLuint size = sizeof(typename Container::value_type) * data.size();
    setBuffer(buffer, usage, size, &data[0]);
}

inline void flush() {
    glFlush();
}

};
