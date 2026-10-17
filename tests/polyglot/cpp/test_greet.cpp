#include <iostream>
#include "greet.hpp"

int main() {
    if (greet("alissa") != "hello, alissa") {
        std::cerr << "FAIL greet(\"alissa\")\n";
        return 1;
    }
    std::cout << "c++: 1 test passed\n";
    return 0;
}
