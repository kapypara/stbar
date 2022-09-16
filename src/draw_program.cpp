#include "draw_program.h"

#include "gl/texture.h"
#include <cstring>

draw_program::draw_program(){

    points.setType(GL::buffer::type::array);
    coordinates.setType(GL::buffer::type::array);
}

void draw_program::build(){

    vertex.create(GL::shader::type::vertex, R"glsl(

            #version 150 core

            in vec2 point;
            in vec2 texcoord;

            out VS_OUT {
                vec2 point;
                vec2 texcoord;
            } vs_out;

            void main() {
                vs_out.point = point;
                vs_out.texcoord = texcoord;
            }
            )glsl");

    geometry.create(GL::shader::type::geometry, R"glsl(

            #version 150 core

            layout(points) in;
            layout(triangle_strip, max_vertices = 4) out;

            in VS_OUT {
                vec2 point;
                vec2 texcoord;
            } vs_in[];

            uniform float height;
            uniform vec2 tex_size;

            out vec2 texcoord_frag;

            void main() {

                texcoord_frag = vs_in[0].texcoord;
                gl_Position = vec4(vs_in[0].point.x, height, 0, 1);
                EmitVertex();

                texcoord_frag = vec2(vs_in[0].texcoord.x, vs_in[0].texcoord.y+tex_size.y);
                gl_Position = vec4(vs_in[0].point.x, -height, 0, 1);
                EmitVertex();

                texcoord_frag = vec2(vs_in[0].texcoord.x+tex_size.x, vs_in[0].texcoord.y);
                gl_Position = vec4(vs_in[0].point.y, height, 0, 1);
                EmitVertex();

                texcoord_frag = vec2(vs_in[0].texcoord.x+tex_size.x, vs_in[0].texcoord.y+tex_size.y);
                gl_Position = vec4(vs_in[0].point.y, -height, 0, 1);
                EmitVertex();

                EndPrimitive();
            }
        )glsl");

    fragment.create(GL::shader::type::fragment, R"glsl(

            #version 150 core

            in vec2 texcoord_frag;

            uniform vec4 bg;
            uniform sampler2D tex;

            void main() {

                vec4 fg = texture(tex, texcoord_frag);
                gl_FragColor = mix(bg, fg, fg.a);
            }

        )glsl");

    if (vertex.getStatus() == 0 || geometry.getStatus() == 0 || fragment.getStatus() == 0){
        return;
    }

    program.build(vertex, geometry, fragment);

    use();

    if (program.getStatus() == 0)
        return;

    point.defineLocation(program, "point");
    texture_coordinate.defineLocation(program, "texcoord");

    height.defineLocation(program, "height");
    texture_size.defineLocation(program, "tex_size");
    background.defineLocation(program, "bg");

    height.setData(1.f);

    ready = true;
}

void draw_program::use() const {
    GL::bindArray(program_attributes);
    program.use();
}

void draw_program::draw() const {

    glDrawArrays(GL_POINTS, 0, 1);
}

void draw_program::drawUntextured() const {
    GL::unBindTexture();
    draw();
}

void draw_program::drawTextured() const {
    bindTexture();
    draw();
}

void draw_program::setTexture(GL::texture* new_texture){
    texture = new_texture;
}

void draw_program::setPoints(vec2 const& points_vec) const {

    GL::bindBuffer(points);
    GL::setBuffer(points, GL_DYNAMIC_DRAW, sizeof(points_vec), &points_vec.x);

    point.setData(2, GL_FLOAT);
    point.enable();
}


void draw_program::setCoordinates(vec2 const& coordinates_vec){

    GL::bindBuffer(coordinates);
    GL::setBuffer(coordinates, GL_DYNAMIC_DRAW, sizeof(coordinates_vec), &coordinates_vec.x);

    texture_coordinate.setData(2, GL_FLOAT);
    texture_coordinate.enable();
}

void draw_program::setTextureSize(vec2 const& size){
    texture_size.setData(size.x, size.y);
}

void draw_program::setBackgroundColor(vec4 const& color){
    background.setData(color.x, color.y, color.z, color.w);
}

void draw_program::setHeight(GLfloat height_in){
    height.setData(height_in);
}


void draw_program::bindTexture() const {
    GL::bindTexture(*texture);
}

void draw_program::unBindtexture() const {
    GL::unBindTexture();
}

