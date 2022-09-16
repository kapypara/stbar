#pragma once

#include <gl/forward.h>

#include <vector>

namespace GL {

class buffer {
public:
    enum type {
        array = GL_ARRAY_BUFFER,                            // Vertex attributes
        atomic_counter = GL_ATOMIC_COUNTER_BUFFER, 	        // Atomic counter storage
        copy_read = GL_COPY_READ_BUFFER, 	                // Buffer copy source
        copy_write = GL_COPY_WRITE_BUFFER, 	                // Buffer copy destination
        dispatch_indirect = GL_DISPATCH_INDIRECT_BUFFER,    // Indirect compute dispatch commands
        draw_indirect = GL_DRAW_INDIRECT_BUFFER,            // Indirect command arguments
        element_array = GL_ELEMENT_ARRAY_BUFFER, 	        // Vertex array indices
        pxiel_pack = GL_PIXEL_PACK_BUFFER, 	                // Pixel read target
        pixel_upack = GL_PIXEL_UNPACK_BUFFER, 	            // Texture data source
        query_buffer = GL_QUERY_BUFFER, 	                // Query result buffer
        shader_storage = GL_SHADER_STORAGE_BUFFER, 	        // Read-write storage for shaders
        texture_buffer = GL_TEXTURE_BUFFER, 	            // Texture data buffer
        transform_feedback = GL_TRANSFORM_FEEDBACK_BUFFER,  // Transform feedback buffer
        uniform_buffer = GL_UNIFORM_BUFFER 	                // Uniform block storage
    };
    
    buffer() {
        resize(1);
    }

    explicit buffer(GLushort count) {
        resize(count);
    }

    void resize(GLushort);

    [[nodiscard]] inline GLuint getId() const {
        return id.at(index);
    };

    [[nodiscard]] inline GLenum getType() const {
        return id_type.at(index);
    };

    inline void setIndex(GLushort new_index) {
        index = new_index;
    };

    inline void setType(type new_type) {
        id_type.at(index) = new_type;
    };


    buffer& at(GLushort index){

        setIndex(index);

        return *this;
    }

    buffer& operator[](GLushort index){

        return this->at(index);
    }

private:

    std::vector<GLuint> id;
    std::vector<type> id_type;

    GLushort index = 0;

};
}
