#pragma once

#include "forward.h"

namespace GL {

class texture {
    GLint width = 0;
    GLint height = 0; 

    GLuint id = 0;
    GLint loaded = 0;

public:
    void load(const char *image);

    template<typename T>
    inline void load(T const& imge){
        load(imge.data());
    }

    void create();

    inline void bind() const {
        glBindTexture(GL_TEXTURE_2D, id);
    }

    static inline void unbind(){
        glBindTexture(GL_TEXTURE_2D, 0);
    }

    [[nodiscard]] inline GLuint getId() const {
        return id;
    }

};
}
