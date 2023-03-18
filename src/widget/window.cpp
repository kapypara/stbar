#include "window.h"
#include <thread>

#include <iostream>

u8 * windowName::getWindowPropertyByAtom(Window window, Atom atom, u64 * nitems) {

    int format;
    u64 bytes_after;
    u8 *prop;

    const i64 mask = (~0L);

    auto result = XGetWindowProperty(dpy, window,
                       atom, 0, mask, False, AnyPropertyType,
                       &atom, &format, nitems, &bytes_after, &prop);

    if (result != 0)
        return nullptr;

    return prop;
}

std::string windowName::getWindowName(Window window) {

    const Atom atom_NET_WM_NAME = XInternAtom(dpy, "_NET_WM_NAME", False);
    // static const Atom atom_WM_NAME = XInternAtom(dpy, "WM_NAME", False);
    // static Atom atom_STRING = XInternAtom(dpy, "STRING", False);
    // static Atom atom_UTF8_STRING = XInternAtom(dpy, "UTF8_STRING", False);

    std::string output;

    u64 nitems;
    char * name_str;

    name_str = reinterpret_cast<char*>(getWindowPropertyByAtom(window, atom_NET_WM_NAME, &nitems));

    if (nitems > 0 && name_str != nullptr) [[likely]]
        output = name_str;

    XFree(name_str);
    return output;
}

void windowName::getActiveWindow() {

    Atom request = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);

    std::string window_name, window_name_old;

    u64 nitems;
    XEvent e;

    Window current_window = root;
    Window * new_window;

    while(true){

        new_window = reinterpret_cast<Window*>(getWindowPropertyByAtom(root, request, &nitems));

        if (nitems > 0 && new_window != nullptr) { [[likely]]

            current_window = *new_window;
            window_name = getWindowName(current_window);

            if(window_name != window_name_old && window_name.length() != 0) { [[likely]]

                setName(window_name);
                window_name_old = window_name;
            }
        }

        XFree(new_window);

        std::this_thread::sleep_for(std::chrono::milliseconds(10));

        XSelectInput(dpy, current_window, PropertyChangeMask);
        XNextEvent(dpy, &e);
    }
}

int windowName::ignoreErrors(Display* /*unused*/, XErrorEvent* /*unused*/){
    return 0;
}


void windowName::useErrorHandler(){
    XSetErrorHandler(ignoreErrors);
}

void windowName::getRootWindow(){

    int s = DefaultScreen(dpy);
    root = XRootWindow(dpy, s);
}

void windowName::GetCurrentWindow() {

    dpy = XOpenDisplay(nullptr);
    if (dpy != nullptr) {

        useErrorHandler();

        getRootWindow();
        getActiveWindow();
    }
}

inline void windowName::setName(std::string const& new_name){

    name.setString(sanitizeNmae(new_name));
    name.not_changed.clear(std::memory_order_release);
}

inline std::string windowName::sanitizeNmae(std::string new_name){

    u16 i, k;

    k = new_name.length();
    i = 0;

    while (i < k){

        if (new_name[i] == '\n'){
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
