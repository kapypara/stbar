#include "static_rect.h"

#include "gl/texture.h"
#include <cstring>

static_rect::static_rect(){

    points.setType(GL::buffer::type::array);
    coordinates.setType(GL::buffer::type::array);
}

void static_rect::build(){

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

            uniform vec2 rect_size;
            uniform vec2 tex_size;

            out vec2 texcoord_frag;

            void main() {

                gl_Position = vec4(0, 0, 0, 1);


                gl_Position.xy = vs_in[0].point;
                texcoord_frag = vs_in[0].texcoord;
                EmitVertex();


                gl_Position.y = vs_in[0].point.y - rect_size.y;
                texcoord_frag.y = vs_in[0].texcoord.y + tex_size.y;
                EmitVertex();


                gl_Position.xy = vec2(vs_in[0].point.x + rect_size.x, vs_in[0].point.y);
                texcoord_frag = vec2(vs_in[0].texcoord.x + tex_size.x, vs_in[0].texcoord.y);
                EmitVertex();


                gl_Position.y = vs_in[0].point.y - rect_size.y;
                texcoord_frag.y = vs_in[0].texcoord.y + tex_size.y;
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

    rect_size.defineLocation(program, "rect_size");
    texture_size.defineLocation(program, "tex_size");
    background.defineLocation(program, "bg");

    // rect_size.setData(1.f, -1.f);

    ready = true;
}

void static_rect::use() const {
    GL::bindArray(program_attributes);
    program.use();
}

void static_rect::draw(u16 count) const {

    glDrawArrays(GL_POINTS, 0, count);
}

void static_rect::setTexture(GL::texture* new_texture){
    texture = new_texture;
}

void static_rect::setRectPoints(std::vector<GLfloat> const& points_vector) const {

    GL::bindBuffer(points);
    GL::setBuffer(points, GL_DYNAMIC_DRAW, points_vector);

    point.setData(2, GL_FLOAT);
    point.enable();
}


void static_rect::setTextureCoordinates(std::vector<GLfloat> const& coordinates_vec) const{

    GL::bindBuffer(coordinates);
    GL::setBuffer(coordinates, GL_DYNAMIC_DRAW, coordinates_vec);

    texture_coordinate.setData(2, GL_FLOAT);
    texture_coordinate.enable();
}

void static_rect::setTextureSize(vec2 const& size){
    texture_size.setData(size.x, size.y);
}

void static_rect::setBackgroundColor(vec4 const& color){
    background.setData(color.x, color.y, color.z, color.w);
}

void static_rect::setRectSize(vec2 const& size){
    rect_size.setData(size.x, size.y);
}


void static_rect::bindTexture() const {
    GL::bindTexture(*texture);
}

void static_rect::unBindtexture() const {
    GL::unBindTexture();
}

