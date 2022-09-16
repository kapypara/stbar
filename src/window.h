#pragma once

#include <GL/glew.h>

#include <GL/gl.h>
#include <GL/glx.h>
#include <GL/glxext.h>

#include <X11/Xatom.h>
#include <X11/extensions/Xrender.h>
#include <X11/Xutil.h>

#define USE_CHOOSE_FBCONFIG

class window {

public:
    [[nodiscard]] inline bool is_running() const {
        return running;
    }

    [[nodiscard]] inline int get_width() const {
        return width;
    }

    [[nodiscard]] inline int get_height() const {
        return height;
    }

    inline void setDockMode(){
        docked = true;
    }

protected:
    void createTheWindow();
    void createTheRenderContext();

    void updateTheMessageQueue();

    window() = default;
    ~window();

    int Xscreen;
    Atom del_atom;
    Colormap cmap;
    Display *Xdisplay;
    XVisualInfo *visual;
    XRenderPictFormat *pict_format;
    GLXFBConfig *fbconfigs, fbconfig;
    int numfbconfigs;
    GLXContext render_context;
    Window Xroot, window_handle;
    GLXWindow glX_window_handle;
    int width = 100, height = 100;
    int x = 100, y =100;

    bool running = true;
    bool docked = false;

    static void fatalError(const char *why);
    static int ctxErrorHandler(Display *dpy, XErrorEvent *ev);

private:
    const int VisData[17] = {
        GLX_RENDER_TYPE, GLX_RGBA_BIT,
        GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
        GLX_DOUBLEBUFFER, False,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_ALPHA_SIZE, 8,
        GLX_DEPTH_SIZE, 16,
        None
    };

    static int isExtensionSupported(const char *extList, const char *extension);
    static Bool WaitForMapNotify(Display *d, XEvent *e, char *arg);
    static void describe_fbconfig(Display* dpy, GLXFBConfig fbconfig);
};
