#pragma once

#include "forward.h"
#include <iostream>


namespace GL {
// TODO add set sources and seprate compiling
class shader {

public:
    enum type {
        compute,
        fragment,
        geometry,
        tess_contorl,
        tess_evaluation,
        vertex,
    };

private:
    static constexpr GLenum type_value[] = {
        [compute] = GL_COMPUTE_SHADER,
        [fragment] = GL_FRAGMENT_SHADER,
        [geometry] = GL_GEOMETRY_SHADER,
        [tess_contorl] = GL_TESS_CONTROL_SHADER,
        [tess_evaluation] = GL_TESS_EVALUATION_SHADER,
        [vertex] = GL_VERTEX_SHADER
    };

    static constexpr const char* type_name[] = {
        [compute] = "compute",
        [fragment] = "fragment",
        [geometry] = "geometry",
        [tess_contorl] = "tess_contorl",
        [tess_evaluation] = "tess_evaluation",
        [vertex] = "vertex"
    };



    // TODO remove the array bound
    GLuint id = 0;

    GLint status = 0;
    type used_type;


public:
    shader() = default;
    shader(type type, const GLchar *source);

    void checkLog() const;

    void create(GLenum type, GLsizei count, const GLchar *strings[], const GLint lengths[]);

    void create(type, GLint length, const GLchar *source);
    void create(type, const GLchar *source);

    template <typename Container>
    void create(type in_type, Container const& source){

        used_type = in_type;
        GLuint length = sizeof(typename Container::value_type) * source.size();

        create(type_value[in_type], 1, source.data(), length);
    }

    inline GLuint getId() const {
        return id;
    };

    inline GLint getStatus() const {
        return status;
    };

    inline constexpr GLint getType(){
        return used_type;
    };
};
} // namespace GL
