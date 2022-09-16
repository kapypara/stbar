#include "renderer.h"

#include "gl/uniform.h"
#include "gl/array.h"
#include "gl/attribute.h"
#include "gl/buffer.h"
#include "gl/program.h"
#include "gl/shader.h"
#include "gl/texture.h"

#include "font.h"

#include <locale>
// #include "output.h"
#include "src/draw_program.h"
#include "src/gl/forward.h"
#include "types.h"

#include <thread>


int main() {

    // std::locale::global(std::locale ("en_US.UTF8"));

    renderer ren;

    ren.setWindow(0, 17, 1280, 14+6);
    // ren.setWindow(0, 1024-14, 1280, 14);

    ren.setDockMode();

    ren.init();


    GL::array vertex_array(2);

    GL::bindArray(vertex_array);

    std::vector<GLfloat> vertices = {
        -1.f,  1.f,
        -1.f, -1.f,
         1.f,  1.f,
         1.f, -1.f,

    };

    std::vector<GLuint> vertex_elements = {
        0, 1, 2,
        1, 2, 3,
    };


    using buffer_type = GL::buffer::type;

    GL::buffer vertex_buffer(2);
    GL::buffer element_buffer;

    vertex_buffer.setType(buffer_type::array);
    GL::bindBuffer(vertex_buffer);

    GL::setBuffer(vertex_buffer, GL_STATIC_DRAW, vertices);


    element_buffer.setType(buffer_type::element_array);
    GL::bindBuffer(element_buffer);
    GL::setBuffer(element_buffer, GL_STATIC_DRAW, vertex_elements);


    //

    const char* vertexSource = R"glsl(
        #version 150 core

        in vec2 position;
        in vec2 texcord;

        out vec2 texcoord_frag;

        void main() {
            texcoord_frag = texcord;

            gl_Position = vec4(position, 0.0, 1.0);
        }

        )glsl";

    using shader_type = GL::shader::type;

    GL::shader vertex;
    GL::shader fragment;

    vertex.create(shader_type::vertex, vertexSource);
    if (vertex.getStatus() == 0)
        return 1;


    // fragment Shader source
    const char* fragmentSource = R"glsl(
        #version 150 core

        in vec2 texcoord_frag;

        uniform sampler2D tex;

        void main() {
            vec4 bg = vec4(.0, .0, .0, .1417);
            vec4 fg = texture(tex, texcoord_frag);

            gl_FragColor = mix(bg, fg, fg.a);
       // mix equivalent: (1.0 - fg.a) * bg + fg.a * fg
        }

        )glsl";

    fragment.create(shader_type::fragment, fragmentSource);
    if (fragment.getStatus() == 0)
        return 1;


    GL::program program;

    program.build(vertex, fragment);
    program.use();

    if (program.getStatus() == 0)
        return 31;



    // attribute
    GL::attribute position(program, "position");

    position.setData(2, GL_FLOAT);
    position.enable();

    // texture in
    GL::texture dog;

    dog.create();
    dog.load("assets/active.png");

    const std::vector<float> texcord = {
        0.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        1.0f, 1.0f,
    };

    // GL::buffer tex_buffer;

    vertex_buffer[1].setType(buffer_type::array);

    GL::bindBuffer(vertex_buffer);
    GL::setBuffer(vertex_buffer, GL_STATIC_DRAW, texcord);


    GL::attribute tex_pos(program, "texcord");

    tex_pos.setData(2, GL_FLOAT);
    tex_pos.enable();


/* ------------ Text on screen ------------ */

    draw_program dp;

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

    dp.setHeight(1);

    dp.setPoints({-1, 1});
    dp.setCoordinates({0, 0});
    dp.setTextureSize({0,0});
    dp.drawTextured();

    dp.setTextureSize(tex_char_size);
    dp.setHeight(14.f/static_cast<float>(ren.get_height()));

    // std::cout << 15.f/static_cast<float>(ren.get_height()) << '\n';
    // exit(1);

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

    dp.setPoints({char_array[0], char_array[char_array.size()/2]});


    // points_cord x = cord(rect(63, 28, 7, 14));
    const vec2* x = font_glyphs.getGlyphCord(0);

    dp.setCoordinates({x->x, x->y});
    dp.bindTexture();

    u16 i = 0;
    u16 a = 0;

    glClearColor(0, 0, 0, 0);

	while (ren.is_running()) {

        ren.handleEvents();
        ren.update();
        // glClear(GL_COLOR_BUFFER_BIT);
        
        /*
        GL::bindArray(vertex_array[0]);
        program.use();
        dog.bind();
        glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, nullptr);
        */

        x = font_glyphs.getGlyphCord(i=((++i)>255)? 0: i );

        if(x != nullptr){

            // dp.setPoints({char_array[a], char_array[a+1]});
            dp.setPoints({char_array[a], char_array[a+1]});
            a = ++a>char_array.size()-2? 0: a;

            dp.setCoordinates({x->x, x->y});
            dp.draw();

            glFlush();

            std::this_thread::sleep_for(std::chrono::milliseconds(13));
        }


	}


    // output_line bar(1,1);
    //
    // bar.output();

    return 0;
}
