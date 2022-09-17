cmake_minimum_required(VERSION 3.20)
project(stbar_v4)

# set(CMAKE_CXX_STANDARD 20)

set(CMAKE_EXPORT_COMPILE_COMMANDS 1)

# for #include serach path 
include_directories(src)

# what object need to compile
# FILE(GLOB widget_src src/widget/*.cpp)
set(widget_src
    src/widget/date.cpp
    src/widget/memory.cpp
    src/widget/io.cpp
    src/widget/net.cpp
    src/widget/dirty.cpp
    src/widget/cpu.cpp
    src/widget/load.cpp
    src/widget/temp.cpp
    src/widget/space.cpp
    src/widget/sound.cpp
    src/widget/window.cpp
    )

add_executable(stbar_v4
    main.cpp

    src/window.cpp
    src/renderer.cpp

    src/static_rect.cpp
    src/font.cpp

    src/gl/attribute.cpp
    src/gl/array.cpp
    src/gl/buffer.cpp
    src/gl/forward.cpp
    src/gl/shader.cpp
    src/gl/program.cpp
    src/gl/texture.cpp
    src/gl/uniform.cpp

    # src/output.cpp 
    # src/segments.cpp
    # src/format.cpp
    # ${widget_src}
    )

set(CMAKE_CXX_FLAGS "\
    -std=c++20 -Wall -march=native -O3 -flto=auto \
    -lpthread -lX11 -lXrender -lGL -lGLEW -lm -lSOIL"
    )
add_definitions(-DUSE_GLX_CREATE_WINDOW -DUSE_GLX_CREATE_CONTEXT_ATTRIB)

# link assests in build dir
file(CREATE_LINK "../assets" "assets" SYMBOLIC)

install(TARGETS stbar_v4 DESTINATION ~/.local/bin/)
