#pragma once

#include <X11/Xlib.h>
#include <mutex>
#include <string>

#include "types.h"

class windowName {
private:

    locked_string& name;

    char * getWindowPropertyByAtom(Display *dpy, u64 window, u64 atom, u64 *nitems);
    std::string getWindowName(Display *dpy, Window window);
    [[noreturn]] void getActiveWindow(Display *dpy, Window *current_window);

    static int ignoreErrors(Display *, XErrorEvent *);

    void GetCurrentWindow(); // set pramaters and call getActivewindow()

    void setName(std::string);
    static std::string sanitizeNmae(std::string);

public:
    windowName(locked_string& str) : name(str) {};

    void start(){
        GetCurrentWindow();
    }

    // std::string getName();

};

