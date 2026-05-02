#include "uniform.h"

#include "program.h"

using GL::uniform;

void uniform::defineLocation(GLuint program, const GLchar *name){
    location = glGetUniformLocation(program, name);
    assert(location != -1);
}

void uniform::defineLocation(GL::program const& program, const GLchar *name){
    assert(program.getStatus());
    location = glGetUniformLocation(program.getId(), name);
}

uniform::uniform(GLuint program, const GLchar *name){
    defineLocation(program, name);
}

uniform::uniform(GL::program const& program, const GLchar *name){
    defineLocation(program, name);
}

void uniform::setData(GLfloat v0) const {
    glUniform1f(location, v0);
}

void uniform::setData(GLfloat v0, GLfloat v1) const {
    glUniform2f(location, v0, v1);
}

void uniform::setData(GLfloat v0, GLfloat v1, GLfloat v2) const {
    glUniform3f(location, v0, v1, v2);
}

void uniform::setData(GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3) const{
    glUniform4f(location, v0, v1, v2, v3);
}
