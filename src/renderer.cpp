#include "renderer.h"

#include "gl/array.h"
#include "gl/buffer.h"

void renderer::init(){

	createTheWindow();
	createTheRenderContext(); // what define the rendering stuff

    glewExperimental = GL_TRUE; // force new openGL features
    glewInit();
}

void renderer::handleEvents(){

    updateTheMessageQueue();
}

void renderer::update(){

    // set the dimention for the window image
    glViewport (0, 0, width, height);

}

void renderer::swap(){
 	glXSwapBuffers(Xdisplay, glX_window_handle);
}


#if 0
void renderer::loadAssets(){

     SDL_Surface *temp = IMG_Load("assets/dog.png");
     struct image image1;

    if(temp == NULL){
        printf("Image was not returned from loadTexture\n");
        exit(0);
    }

    image1.data = temp->pixels;

    image1.width = temp->w;
    image1.height = temp->h;

    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, 3, image1->width, image1->height, 0,
                 GL_RGB, GL_UNSIGNED_BYTE, image1->data);
    glBindTexture(GL_TEXTURE_2D, tex);

    return;

    // makeCheckImage();
    // glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    // Create Texture
    glGenTextures(2, texture);
    glBindTexture(GL_TEXTURE_2D, texture[0]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);

    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA,
                 image1.width, image1.height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                 image1.data);

    free(temp);

    // glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_DECAL);
    // glBindTexture(GL_TEXTURE_2D, texture[1]);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    // glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_DECAL);
    // glTexImage2D(GL_TEXTURE_2D, 0, 3, checkImageWidth,
    // checkImageHeight, 0, GL_RGB, GL_UNSIGNED_BYTE,&checkImage[0][0][0]);
    // glEnable(GL_TEXTURE_2D);

}
#endif

void renderer::render(){

#if 0
	// struct timespec Ta, Tb;

	// clock_gettime(CLOCK_MONOTONIC_RAW, &Ta);

    glViewport (0, 0, width, height); // set the dimention for the inital image

    glMatrixMode(GL_PROJECTION); // selecting the wanted matrix
    glLoadIdentity(); // resetting it
    glOrtho(0, width-1, height-1, 0, 0, 1); // left, right, botoom, top, near, far

    glMatrixMode(GL_TEXTURE);
    glLoadIdentity();
    glOrtho(0, 190*2-1, 0, 180*2-1, 0, 1); // left, right, botoom, top, near, far
    // glOrtho(-0.5, (width - 1) + 0.5, (height - 1) + 0.5, -0.5, 0.0, 1.0);
    // printf("w:%d, h:%d\n", width, height);

    glClearColor(0.0f, 0.0f, 0.0f, 0.0f); // Set background color to black and opaque
    glClear(GL_COLOR_BUFFER_BIT);         // Clear the color buffer (background)
 
    // Draw a Red 1x1 Square centered at origin
    // glBegin(GL_TRIANGLES);

    glBindTexture(GL_TEXTURE_2D, texture[0]);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    // glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    // glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_DECAL);
    // glTexImage2D(GL_TEXTURE_2D, 0, 3, checkImageWidth,
    // checkImageHeight, 0, GL_RGB, GL_UNSIGNED_BYTE,&checkImage[0][0][0]);
    glEnable(GL_TEXTURE_2D);

    glBegin(GL_QUADS);              // Each set of 4 vertices form a quad
        glColor4f(1.0f, 1.0f, 1.0f, 1.0f); // Red
    glTexCoord2i(0, 0);
        glVertex2i(50, 50);

    glTexCoord2i(0, 180);
        glVertex2i(50, height -50);

    glTexCoord2i(190, 180);
        glVertex2i(width - 50, height -50);

    glTexCoord2i(190, 0);
        glVertex2i(width - 50, 50);

    glEnd();


    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);  

    glBegin(GL_QUADS);              // Each set of 4 vertices form a quad
        glColor4f(1.0f, 1.0f, 1.0f, 1.0f); // Red

    glTexCoord2i(0, 0);
        glVertex2i(100, 100);

    glTexCoord2i(0, 180);
        glVertex2i(100, height -100);

    glTexCoord2i(190, 180);
        glVertex2i(width - 100, height -100);

    glTexCoord2i(190, 0);
        glVertex2i(width - 100, 100);

    glEnd();

    glDisable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, 0);
 
    glFlush();  // Render now
 	// glXSwapBuffers(Xdisplay, glX_window_handle);
	
	// clock_gettime(CLOCK_MONOTONIC_RAW, &Tb);
    // usleep(20000);


    // in micro seconds
    double time_delta = (1e6*(double)Tb.tv_sec + 1e-3*(double)Tb.tv_nsec) -
                        (1e6*(double)Ta.tv_sec + 1e-3*(double)Ta.tv_nsec);

    fprintf(stderr, "glXSwapBuffers returned after %04.3f ms\n", time_delta/1000);	
#endif
   
}


