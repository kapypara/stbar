#include "shader.h"

using GL::shader;

shader::shader(type type, const GLchar *source){

    create(type, source);
}

void shader::create(GLenum type, GLsizei count,
                    const GLchar *strings[], const GLint lengths[]){

    id = glCreateShader(type);
    glShaderSource(id, count, strings, lengths);


    glCompileShader(id);

    // set status to ture if compilation was successful
    glGetShaderiv(id, GL_COMPILE_STATUS, &status);

    if(status == 0)
        checkLog();
}

void GL::shader::create(type in_type, GLint length, const GLchar *source){

    used_type = in_type;

    create(type_value[in_type], 1, &source, &length);
}

void GL::shader::create(type in_type, const GLchar *source){

    used_type = in_type;

    create(type_value[in_type], 1, &source, NULL);
}


void GL::shader::checkLog() const {

    GLint length;

    glGetShaderiv(id, GL_INFO_LOG_LENGTH, &length);

    std::string log;

    log.resize(++length);

    glGetShaderInfoLog(id, log.length(), nullptr, log.data());

    if (status == 0)
        std::cerr << "[Shader]: " << type_name[used_type] << " Shader compiling failed:\n";

    if (length > 0)
        std::cerr << log.c_str() << '\n';

}
