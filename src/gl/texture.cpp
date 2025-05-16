#include "texture.h"
#include <vector>
#include "../lib/lodepng.h"

void GL::texture::create(){
    glGenTextures(1, &id);

    bind();

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
}

void GL::texture::load(const char *image){

    unsigned int width, height;

    std::vector<unsigned char> tex;
    lodepng::decode(tex, width, height, image, LCT_RGBA, 8);

    this->width = width;
    this->height = height;

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, tex.data());
}
