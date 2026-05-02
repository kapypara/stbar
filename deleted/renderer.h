#pragma once

#include "gl/forward.h"
#include "window.h"

class renderer : public window {

    bool initialized = false;

public:

    inline void setWindow(int x, int y, int width, int height){

        this->x = x;
        this->y = y;

        this->width = width;
        this->height = height;
    }

    void init();

    void handleEvents();
    void update();

    void swap();
    void render();

};
