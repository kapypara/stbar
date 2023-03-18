
#pragma once
#include <X11/Xlib.h>
#include <mutex>
#include <string>

#include "types.h"

class windowName {
private:

    Display *dpy;
    Window root;

    locked_string& name;

    u8 * getWindowPropertyByAtom(u64 window, u64 atom, u64 *nitems);
    std::string getWindowName(Window window);
    [[noreturn]] void getActiveWindow();

    void GetCurrentWindow(); // set pramaters and call getActivewindow()

    void setName(std::string const&);
    static std::string sanitizeNmae(std::string);

public:
    windowName(locked_string& str) : name(str) {}

    windowName(Display *dp, locked_string& str)
        : dpy(dp)
        , name(str)
    {}

    void getRootWindow();
    void start(){
        GetCurrentWindow();
    }

    static int ignoreErrors(Display *, XErrorEvent *);
    static void useErrorHandler();

    // std::string getName();

};

