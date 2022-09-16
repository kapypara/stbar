#include "attribute.h"
#include "program.h"

using GL::attribute;

GLint attribute::defineLocation(GLuint program, const GLchar *name){

    location = glGetAttribLocation(program, name);

    return location;
}

GLint attribute::defineLocation(GL::program const& program, const GLchar *name){

    assert(program.getStatus());

    return defineLocation(program.getId(), name);
}


attribute::attribute(GLuint program, const GLchar *name){
        defineLocation(program, name);
}
attribute::attribute(GL::program const& program, const GLchar *name){
        defineLocation(program.getId(), name);
}


void attribute::setData(GLint count, GLenum type, GLboolean normalize,
                        GLsizei stride, GLulong offset) const
{
    glVertexAttribPointer(location, count, type, normalize, stride, reinterpret_cast<void*>(offset));
}

