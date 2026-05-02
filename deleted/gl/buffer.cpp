#include "buffer.h"

using GL::buffer;

void buffer::resize(GLushort new_size){

    GLushort old_size = id.size();

    if(new_size > old_size){

        id.resize(new_size);
        glGenBuffers(new_size - old_size, &id[old_size]);
    } else {

        glDeleteBuffers(old_size - new_size, &id[new_size]);
        id.resize(new_size);
    }

    id_type.resize(new_size);

}
