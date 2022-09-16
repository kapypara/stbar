#include "forward.h"

#include "array.h"
#include "buffer.h"
#include "texture.h"

void GL::bindArray(GL::array const& array){
    glBindVertexArray(array.getId());

}

void GL::bindBuffer(GL::buffer const& buffer){
    glBindBuffer(buffer.getType(), buffer.getId());

}

void GL::bindTexture(GL::texture const& texture){
    glBindTexture(GL_TEXTURE_2D, texture.getId());
}

void GL::setBuffer(buffer const& buffer, GLenum usage,
                               GLuint size, const void *data){

    glBufferData(buffer.getType(), size, data, usage);
}
