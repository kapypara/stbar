#include "program.h"
#include "shader.h"

using GL::program;

program::program() : id(glCreateProgram()) {}

program::program(shader vertex, shader fragment) : id(glCreateProgram()) {
    build(vertex, fragment);
}

program::program(shader vertex, shader geometry, shader fragment) : id(glCreateProgram()) {
    build(vertex, geometry, fragment);
}

void program::build(shader vertex, shader geometry, shader fragment){

    assertm(status == 0, "program is already linked");
    
    assertm(vertex.getType() == shader::type::vertex, "vertex shader dont have the correct type");
    assertm(geometry.getType() == shader::type::geometry, "geometry shader dont have the correct type");
    assertm(fragment.getType() == shader::type::fragment, "fragment shader dont have the correct type");

    assertm(vertex.getStatus() && geometry.getStatus() && fragment.getStatus(), "one or more shaders are not compiled");

    glAttachShader(id, vertex.getId());
    glAttachShader(id, geometry.getId());
    glAttachShader(id, fragment.getId());

    link();
}

void program::build(shader vertex, shader fragment){

    assertm(status == 0, "program is already linked");
    
    assertm(vertex.getType() == shader::type::vertex, "vertex shader dont have the correct type");
    assertm(fragment.getType() == shader::type::fragment, "fragment shader dont have the correct type");
    assertm(vertex.getStatus() && fragment.getStatus(), "one or more shaders are not compiled");

    glAttachShader(id, vertex.getId());
    glAttachShader(id, fragment.getId());

    link();
}

inline void program::link(){
    glLinkProgram(id);

    if (glGetError() == 0)
        status = 1;
}
