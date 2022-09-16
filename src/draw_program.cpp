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

            in float point;
            in vec4 texcoord;

            out VS_OUT {
                vec4 texcoord;
            } vs_out;

            void main() {
                gl_Position = vec4(point, 0.0, 0.0, 1.0);
                vs_out.texcoord = texcoord;
            }
            )glsl");

    geometry.create(GL::shader::type::geometry, R"glsl(

            #version 150 core

            layout(lines) in;
            layout(triangle_strip, max_vertices = 4) out;

            in VS_OUT {
                vec4 texcoord;
            } vs_in[];

            out vec2 texcoord_frag;

            void main() {

                texcoord_frag = vs_in[0].texcoord.xy;
                gl_Position = vec4(gl_in[0].gl_Position.x, 1, 0, 1);
                EmitVertex();

                texcoord_frag = vs_in[0].texcoord.zw;
                gl_Position = vec4(gl_in[0].gl_Position.x, -1, 0, 1);
                EmitVertex();

                texcoord_frag = vs_in[1].texcoord.xy;
                gl_Position = vec4(gl_in[1].gl_Position.x, 1, 0, 1);
                EmitVertex();

                texcoord_frag = vs_in[1].texcoord.zw;
                gl_Position = vec4(gl_in[1].gl_Position.x, -1, 0, 1);
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
    texture_cordnate.defineLocation(program, "texcoord");
    background.defineLocation(program, "bg");

    ready = true;
}

void draw_program::use() const {
    GL::bindArray(program_attributes);
    program.use();
}

void draw_program::draw() const {

    GL::bindArray(program_attributes);
    program.use();

    glDrawArrays(GL_LINES, 0, 2);
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

void draw_program::setPoints(GLfloat p1, GLfloat p2) const {

    std::array<GLfloat, 2> points_array {
        p1,
        p2,
    };

    GL::bindBuffer(points);
    GL::setBuffer(points, GL_DYNAMIC_DRAW, points_array);
    point.setData(1, GL_FLOAT);
    point.enable();
}


void draw_program::setCoordinates(vec4 const& side1, vec4 const& side2){

    std::array<GLfloat, 2*4> coord_array {
        side1.x,
        side1.y,
        side1.z,
        side1.w,

        side2.x,
        side2.y,
        side2.z,
        side2.w,
    };

    GL::bindBuffer(coordinates);
    GL::setBuffer(coordinates, GL_DYNAMIC_DRAW, coord_array);

    texture_cordnate.setData(4, GL_FLOAT);
    texture_cordnate.enable();
}

void draw_program::setBackground(vec4 const& color){
    background.setData(color.x, color.y, color.z, color.w);
}


void draw_program::bindTexture() const {
    GL::bindTexture(*texture);
}

void draw_program::unBindtexture() const {
    GL::unBindTexture();
}

