#pragma once

#include <gl/forward.h>

#include <vector>

namespace GL {

class array {
public:
    array() {
        resize(1);
    }

    explicit array(GLushort count) {
        resize(count);
    }

    void resize(GLushort);

    [[nodiscard]] inline GLuint getId() const {
        return id.at(index);
    };

    inline void setIndex(GLushort new_index) {
        index = new_index;
    };


    array& at(GLushort index){

        setIndex(index);

        return *this;
    }

    array& operator[](GLushort index){

        return this->at(index);
    }

private:

    std::vector<GLuint> id;

    GLushort index = 0;
};
}
