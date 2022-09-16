#include "texture.h"
#include "SOIL/SOIL.h"

void GL::texture::create(){
    glGenTextures(1, &id);

    bind();

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
}

void GL::texture::load(const char *image){

    unsigned char* tex = SOIL_load_image(image, &width, &height, nullptr, SOIL_LOAD_RGBA);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, tex);

    SOIL_free_image_data(tex);
}
