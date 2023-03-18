#include "renderer.h"

#include "font.h"
#include "gl/texture.h"
#include "output.h"
#include "segment.h"
#include "static_rect.h"
#include "types.h"

#include <locale>
#include <thread>

int main() {

    // std::locale::global(std::locale ("en_US.UTF8"));

    renderer ren;

    ren.setWindow(0, 0, 1280, 14+3);
    // ren.setWindow(0, 1024-14, 1280, 14);

    ren.setDockMode();

    ren.init();
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);

/* ------------ Text on screen ------------ */

    static_rect dp;

    dp.build();
    if(!dp.is_ready())
        return 22;

    // background
    dp.setBackgroundColor(vec4(.0f, .0f, .0f, .4666f));

    // texture
    GL::texture font_texture;

    font_texture.create();
    font_texture.load("assets/font/tamzen.png");

    dp.setTexture(&font_texture);
    dp.bindTexture();

    //
    font font_glyphs;

    font_glyphs.load("assets/font/tamzen.json");

    vec2 tex_char_size = {
        font_glyphs.getRelativeWidth(),
        font_glyphs.getRelativeHeight()
    };

    dp.setTextureSize(tex_char_size);

    // output
    output_line bar(ren, dp, font_glyphs, 8, 60);

    bar.output();

    /*
	while (ren.is_running()) {

        ren.handleEvents();
        ren.update();

        glClear(GL_COLOR_BUFFER_BIT);
        glFlush();
	}
    */



    return 0;
}
