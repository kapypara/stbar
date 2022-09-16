#include "node.h"

#include <iostream>
#include <cassert>

using namespace comm;

int main(){

    node<int> x;
    node<int> y = 3;
    node<int> z(5);

    x = 4;

    assert(x == 4);
    assert(y == 3);
    assert(z == 5);

    printf("node value is %d\n", x.set_data(32));
    assert(32 == x);

    node<int> *ptr;

    x.set_next(y);
    y.set_next(z);

    ptr = &x;
    std::cout << *ptr << '\n';

    ptr = ptr->get_next(); // pointing to y;
    std::cout << *ptr << '\n';

    ptr = ptr->get_next(); // pointing to z
    std::cout << *ptr << '\n';


    std::cout << "\n\n";

    // int rr = z.set_pervious(y); // pointer 2 is pointing to y
    // std::cout << rr << '\n';

    /* node<int> *ptr2 = ptr->set_pervious(y); // pointer 2 is pointing to y
    std::cout << *ptr2->get_next() << '\n';
    std::cout << *ptr2 << '\n';

    std::cout << *(ptr2 = ptr->set_pervious(x)) << '\n'; */

    return 0;
}
