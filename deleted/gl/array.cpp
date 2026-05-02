#include "array.h"

void GL::array::resize(GLushort new_size){

    GLushort old_size = id.size();

    if(new_size > old_size){

        id.resize(new_size);
        glGenVertexArrays(new_size - old_size, &id[old_size]);
    } else {

        glDeleteVertexArrays(old_size - new_size, &id[new_size]);
        id.resize(new_size);
    }
}
