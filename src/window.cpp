#include "window.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>


inline void window::fatalError(const char *why){
    fputs(why, stderr);
    exit(1);
}

inline int window::ctxErrorHandler(Display *dpy, XErrorEvent *ev){
    fputs("Error at context creation\n", stderr);
    return 0;
}

int window::isExtensionSupported(const char *extList, const char *extension){

    const char *start;
    const char *where, *terminator;

    /* Extension names should not have spaces. */
    where = strchr(extension, ' ');
    if ( where || *extension == '\0' )
        return 0;

    /* It takes a bit of care to be fool-proof about parsing the
         OpenGL extensions string. Don't be fooled by sub-strings,
         etc. */
    for ( start = extList; ; ) {
        where = strstr( start, extension );

        if ( !where )
            break;

        terminator = where + strlen( extension );

        if ( where == start || *(where - 1) == ' ' )
            if ( *terminator == ' ' || *terminator == '\0' )
                return 1;

        start = terminator;
    }
    return 0;
}

Bool window::WaitForMapNotify(Display *d, XEvent *e, char *arg){
    return d && e && arg && (e->type == MapNotify) && (e->xmap.window == *(Window*)arg);
}

void window::describe_fbconfig(Display* dpy, GLXFBConfig fbconfig){
    int doublebuffer;
    int red_bits, green_bits, blue_bits, alpha_bits, depth_bits;

    glXGetFBConfigAttrib(dpy, fbconfig, GLX_DOUBLEBUFFER, &doublebuffer);
    glXGetFBConfigAttrib(dpy, fbconfig, GLX_RED_SIZE, &red_bits);
    glXGetFBConfigAttrib(dpy, fbconfig, GLX_GREEN_SIZE, &green_bits);
    glXGetFBConfigAttrib(dpy, fbconfig, GLX_BLUE_SIZE, &blue_bits);
    glXGetFBConfigAttrib(dpy, fbconfig, GLX_ALPHA_SIZE, &alpha_bits);
    glXGetFBConfigAttrib(dpy, fbconfig, GLX_DEPTH_SIZE, &depth_bits);

/*
    fprintf(stderr, "FBConfig selected:\n"
            "Doublebuffer: %s\n"
            "Red Bits: %d, Green Bits: %d, Blue Bits: %d, Alpha Bits: %d, Depth Bits: %d\n",
            doublebuffer == True ? "Yes" : "No", 
            red_bits, green_bits, blue_bits, alpha_bits, depth_bits);
*/
}

void window::createTheWindow(){

    XEvent event;
    int attr_mask;
    XSizeHints hints;
    XWMHints *startup_state;
    XTextProperty textprop;
    XSetWindowAttributes attr = {};
    const char title[] = "X11 with OpenGL with ARGB extension";

    Xdisplay = XOpenDisplay(NULL); // connect to x11
    if (!Xdisplay) {
        fatalError("Couldn't connect to X server\n");
    }

    Xscreen = DefaultScreen(Xdisplay); // get dispaly
    Xroot = RootWindow(Xdisplay, Xscreen); // get parent

    fbconfigs = glXChooseFBConfig(Xdisplay, Xscreen, VisData, &numfbconfigs);
    fbconfig = 0;
    for(int i = 0; i<numfbconfigs; i++) {
        visual = (XVisualInfo*) glXGetVisualFromFBConfig(Xdisplay, fbconfigs[i]);
        if(!visual)
            continue;

        pict_format = XRenderFindVisualFormat(Xdisplay, visual->visual);
        if(!pict_format)
            continue;

        fbconfig = fbconfigs[i];
        if(pict_format->direct.alphaMask > 0) {
            break;
        }
        XFree(visual);
    }

    if(!fbconfig) {
        fatalError("No matching FB config found");
    }

    describe_fbconfig(Xdisplay, fbconfig);

    /* Create a colormap - only needed on some X clients, eg. IRIX */
    cmap = XCreateColormap(Xdisplay, Xroot, visual->visual, AllocNone);

    attr.colormap = cmap;
    attr.background_pixmap = None;
    attr.border_pixmap = None;
    attr.border_pixel = 0;
    attr.event_mask =
        StructureNotifyMask |
        EnterWindowMask |
        LeaveWindowMask |
        ExposureMask |
        ButtonPressMask |
        ButtonReleaseMask |
        OwnerGrabButtonMask |
        KeyPressMask |
        KeyReleaseMask;

    attr_mask = 
        //	CWBackPixmap|
        CWColormap|
        CWBorderPixel|
        CWEventMask;

        /*
    width = DisplayWidth(Xdisplay, DefaultScreen(Xdisplay))/2;
    height = DisplayHeight(Xdisplay, DefaultScreen(Xdisplay))/2;
    x=width/2, y=height/2;
        */

    window_handle = XCreateWindow(Xdisplay,
                                  Xroot,
                                  x, y, width, height,
                                  0,
                                  visual->depth,
                                  InputOutput,
                                  visual->visual,
                                  attr_mask, &attr);

    if(!window_handle) {
        fatalError("Couldn't create the window\n");
    }

#if USE_GLX_CREATE_WINDOW
    // fputs("glXCreateWindow\n", stderr);
    int glXattr[] = { None };
    glX_window_handle = glXCreateWindow(Xdisplay, fbconfig, window_handle, glXattr);
    if(!glX_window_handle) {
        fatalError("Couldn't create the GLX window\n");
    }
#else
    glX_window_handle = window_handle;
#endif

    textprop.value = (unsigned char*)title;
    textprop.encoding = XA_STRING;
    textprop.format = 8;
    textprop.nitems = strlen(title);

    hints.x = x;
    hints.y = y;
    hints.width = width;
    hints.height = height;
    hints.flags = USPosition|USSize;

    startup_state = XAllocWMHints();
    startup_state->initial_state = NormalState;
    startup_state->flags = StateHint;

    XSetWMProperties(Xdisplay, window_handle,&textprop, &textprop,
                     NULL, 0,
                     &hints,
                     startup_state,
                     NULL);

    XFree(startup_state);


    // docked mode
    constexpr int only_if_exists = 1;

    if(docked){

        // dock mode

        Atom dock_type = XInternAtom(Xdisplay, "_NET_WM_WINDOW_TYPE_DOCK", only_if_exists);
        Atom window_type = XInternAtom(Xdisplay, "_NET_WM_WINDOW_TYPE", only_if_exists);

        XChangeProperty(Xdisplay, window_handle,
                        window_type, XA_ATOM,
                        32, PropModeReplace,
                        reinterpret_cast<const unsigned char*>(&dock_type), 1);

        // appending window states 
        Atom sticky_state = XInternAtom(Xdisplay, "_NET_WM_STATE_STICKY", only_if_exists);
        Atom ontop_state = XInternAtom(Xdisplay, "_NET_WM_STATE_STAYS_ON_TOP", only_if_exists);
        Atom above_state = XInternAtom(Xdisplay, "_NET_WM_STATE_ABOVE", only_if_exists);

        Atom window_state = XInternAtom(Xdisplay, "_NET_WM_STATE", only_if_exists);

        XChangeProperty(Xdisplay, window_handle,
                        window_state, XA_ATOM,
                        32, PropModeAppend,
                        reinterpret_cast<const unsigned char*>(&sticky_state), 1);

        XChangeProperty(Xdisplay, window_handle,
                        window_state, XA_ATOM,
                        32, PropModeAppend,
                        reinterpret_cast<const unsigned char*>(&above_state), 1);

        XChangeProperty(Xdisplay, window_handle,
                        window_state, XA_ATOM,
                        32, PropModeAppend,
                        reinterpret_cast<const unsigned char*>(&ontop_state), 1);

        // all desktops
        Atom wm_desktop = XInternAtom(Xdisplay, "_NET_WM_DESKTOP", only_if_exists);

        constexpr long all_desktop = 0xFFFFFFFF;

        XChangeProperty(Xdisplay, window_handle,
                        wm_desktop, XA_CARDINAL,
                        32, PropModeReplace,
                        (unsigned char*)&all_desktop, 1);


        // strut

        Atom wm_strut = XInternAtom(Xdisplay, "_NET_WM_STRUT", only_if_exists);
        Atom wm_strut_partial = XInternAtom(Xdisplay, "_NET_WM_STRUT_PARTIAL", only_if_exists);

        int strut[12] = {};
        strut[2+2] = height+17; //bh;
        // strut[8] = 0; //mon->x;
        // strut[9] = 0; //mon->x + mon->width - 1;

        XChangeProperty(Xdisplay, window_handle,
                        wm_strut, XA_CARDINAL,
                        32, PropModeReplace,
                        (unsigned char*)&strut, 12);

        XChangeProperty(Xdisplay, window_handle,
                        wm_strut_partial, XA_CARDINAL,
                        32, PropModeReplace,
                        (unsigned char*)&strut, 4);
    }
    //////////////

    XMapWindow(Xdisplay, window_handle);
    XIfEvent(Xdisplay, &event, WaitForMapNotify, (char*)&window_handle);

    if ((del_atom = XInternAtom(Xdisplay, "WM_DELETE_WINDOW", 0)) != None) {
        XSetWMProtocols(Xdisplay, window_handle, &del_atom, 1);
    }
}

void window::createTheRenderContext(){

    int dummy;
    if (!glXQueryExtension(Xdisplay, &dummy, &dummy)) {
        fatalError("OpenGL not supported by X server\n");
    }

    render_context = NULL;

#if USE_GLX_CREATE_CONTEXT_ATTRIB
#define GLX_CONTEXT_MAJOR_VERSION_ARB       0x2091
#define GLX_CONTEXT_MINOR_VERSION_ARB       0x2092

    if(isExtensionSupported(glXQueryExtensionsString(Xdisplay, DefaultScreen(Xdisplay)), "GLX_ARB_create_context")){

        typedef GLXContext (*glXCreateContextAttribsARBProc)(Display*, GLXFBConfig, GLXContext, Bool, const int*);
        glXCreateContextAttribsARBProc glXCreateContextAttribsARB = (glXCreateContextAttribsARBProc) glXGetProcAddressARB((GLubyte*)"glXCreateContextAttribsARB"); // gives a fucntion call

        if(glXCreateContextAttribsARB){
            int context_attribs[] = {
                GLX_CONTEXT_MAJOR_VERSION_ARB, 2,
                GLX_CONTEXT_MINOR_VERSION_ARB, 1,
                //GLX_CONTEXT_FLAGS_ARB        , GLX_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB,
                None
            };

            int (*oldHandler)(Display*, XErrorEvent*) = XSetErrorHandler(&ctxErrorHandler);

            render_context = glXCreateContextAttribsARB(Xdisplay, fbconfig, 0, True, context_attribs);

            XSync( Xdisplay, False );
            XSetErrorHandler( oldHandler );
        } else {
            fputs("glXCreateContextAttribsARB could not be retrieved\n", stderr);
        }
    } else {
        fputs("glXCreateContextAttribsARB not supported\n", stderr);
    }

#endif
    if(!render_context){
        fputs("using fallback\n", stderr);
        render_context = glXCreateNewContext(Xdisplay, fbconfig, GLX_RGBA_TYPE, 0, True);
        if (!render_context){
            fatalError("Failed to create a GL context\n");
        }
    }

    if (!glXMakeContextCurrent(Xdisplay, glX_window_handle, glX_window_handle, render_context)){
        fatalError("glXMakeCurrent failed for window\n");
    }
}

void window::updateTheMessageQueue(){

    XEvent event;
    XConfigureEvent *xc;

    while (XPending(Xdisplay)){

        XNextEvent(Xdisplay, &event);

        switch (event.type){
            case ClientMessage:
                if (event.xclient.data.l[0] == del_atom)
                    running = false;

            case ConfigureNotify:
                xc = &(event.xconfigure);
                width = xc->width;
                height = xc->height;
                break;
        }
    }
}

window::~window(){

    glXMakeCurrent(Xdisplay, None, NULL);
    glXDestroyContext(Xdisplay, render_context);
    XDestroyWindow(Xdisplay, window_handle);
    XCloseDisplay(Xdisplay);
}
