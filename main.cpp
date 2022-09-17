#include "renderer.h"

#include "static_rect.h"
#include "font.h"
#include "gl/texture.h"
#include "types.h"

// #include "output.h"

#include <locale>
#include <thread>


int main() {

    // std::locale::global(std::locale ("en_US.UTF8"));

    renderer ren;

    ren.setWindow(0, 17, 1280, 14+3);
    // ren.setWindow(0, 1024-14, 1280, 14);

    ren.setDockMode();

    ren.init();

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

    //
    font font_glyphs;

    font_glyphs.load("assets/font/tamzen.json");

    vec2 tex_char_size = {
        font_glyphs.getRelativeWidth(),
        font_glyphs.getRelativeHeight()
    };

    dp.setRectSize({2, 2});

    dp.setRectPoints({-1, 1});

    dp.draw(1);

    dp.setTextureCoordinates({0, 0});
    dp.setTextureSize({0,0});

    dp.setTextureSize(tex_char_size);

    dp.setRectSize(
            {
                2*static_cast<GLfloat>(font_glyphs.getCharWidth())/static_cast<float>(ren.get_width()),
                2*static_cast<GLfloat>(font_glyphs.getCharHeight())/static_cast<GLfloat>(ren.get_height()),
            }
        );


    // points
    std::vector<GLfloat> char_array;

    const int local_width = ren.get_width();
    const int char_count = local_width / static_cast<int>(font_glyphs.getCharWidth());

    for(int i=0; i<char_count+2; i++){

        // cord in opengl
        // -1 -------------- 0 -------------- 1

        // cord here
        //  0 -------------- 1 -------------- 2

        GLfloat cord = static_cast<float>(7*i) / static_cast<float>(local_width/2) - 1.f;

        char_array.push_back(cord);
    }

    // dp.setRectSize({char_array[0], char_array[char_array.size()/2]});


    // points_cord x = cord(rect(63, 28, 7, 14));
    const vec2* x = font_glyphs.getGlyphCord(0);

    dp.setTextureCoordinates({x->x, x->y});
    dp.bindTexture();

    GLfloat y_pos = .9f - static_cast<GLfloat>(font_glyphs.getCharWidth()) / static_cast<float>(ren.get_width());

    u16 i = 0;
    u16 a = 0;

    glClearColor(0, 0, 0, 0);

	while (ren.is_running()) {

        ren.handleEvents();
        ren.update();
        // glClear(GL_COLOR_BUFFER_BIT);
        
        x = font_glyphs.getGlyphCord(i=(++i % 255));
        const vec2* y = font_glyphs.getGlyphCord(i+1);

        if(x != nullptr && y != nullptr){

            // dp.setPoints({char_array[a], char_array[a+1]});
            dp.setRectPoints(
                    {
                        char_array[a], y_pos,
                        char_array[a+1], y_pos,
                    });

            a = ++a>char_array.size()-2? 0: a;

            dp.setTextureCoordinates(
                    {
                        x->x, x->y,
                        y->x, y->y,
                    });

            dp.draw(2);

            glFlush();

            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }


	}


    // output_line bar(1,1);
    //
    // bar.output();

    return 0;
}
