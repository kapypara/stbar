#include "window.h"
#include <thread>

char* windowName::getWindowPropertyByAtom(Display* dpy, Window window, Atom atom, u64 * nitems) {

    int format;
    u64 bytes_after; /* unused */
    unsigned char *prop;

    try {
        XGetWindowProperty(dpy, window, atom, 0, (~0L), False, AnyPropertyType,
                           &atom, &format, nitems, &bytes_after, &prop);

        return (char*)prop;

    } catch (...){
        return NULL;
    }
}

std::string windowName::getWindowName(Display* dpy, Window window) {

    static const Atom atom_NET_WM_NAME = XInternAtom(dpy, "_NET_WM_NAME", False);
    static const Atom atom_WM_NAME = XInternAtom(dpy, "WM_NAME", False);
    //static Atom atom_STRING = XInternAtom(dpy, "STRING", False);
    //static Atom atom_UTF8_STRING = XInternAtom(dpy, "UTF8_STRING", False);

    std::string output;

    u64 nitems;
    char * name_str;

    name_str = getWindowPropertyByAtom(dpy, window, atom_NET_WM_NAME, &nitems);
    if (nitems == 0)
        name_str = getWindowPropertyByAtom(dpy, window, atom_WM_NAME, &nitems);

    if (name_str != nullptr)
        output = name_str;
    else
        output = "\0";

    free(name_str);
    return output;
}

void windowName::getActiveWindow(Display* dpy, Window *current_window) {

    const Atom request = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    const Window root = *current_window;

    std::string window_name, window_name_old;

    u64 nitems;
    char * new_window;

    XEvent e;

    XSelectInput(dpy, root, FocusChangeMask);

    while(true){

        new_window = getWindowPropertyByAtom(dpy, root, request, &nitems);

        if (nitems) {

            *current_window = * (Window*) new_window;
            window_name = getWindowName(dpy, *current_window);


            if(window_name != window_name_old && window_name[0] != '\0' ) {

                setName(window_name);
                window_name_old = window_name;
            }
        }

        free(new_window);

        std::this_thread::sleep_for(std::chrono::milliseconds(10));

        XSelectInput(dpy, *current_window, PropertyChangeMask);
        XNextEvent(dpy, &e);
    }
}

int windowName::ignoreErrors(Display*, XErrorEvent* ){
    return 0;
}

void windowName::GetCurrentWindow() {

    Display *d;
    Window w;
    int s;

    d = XOpenDisplay(nullptr);
    if (d != nullptr) {

        s = DefaultScreen(d);
        w = XRootWindow(d,s);

        XSetErrorHandler(ignoreErrors);

        getActiveWindow(d, &w);
    }
}

inline void windowName::setName(std::string new_name){

    name.setString(sanitizeNmae(new_name));
    name.not_changed.clear(std::memory_order_release);
}

inline std::string windowName::sanitizeNmae(std::string new_name){

    u16 i, k;

    k = new_name.length();
    i = 0;

    while (i < k){

        if (new_name[i] == '\n' || new_name[i] == '%'){
            new_name.erase(new_name.begin()+i);
            k--;

        } else {
            i++;
        }
    }

    return new_name;
}

/*
std::string windowName::getName(){

    std::lock_guard<std::mutex> lk(lock);

    std::string out = name;
    return name;
}
*/
