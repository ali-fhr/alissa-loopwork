#include <stdio.h>
#include "add.h"

int main(void) {
    if (add(2, 3) != 5) {
        fprintf(stderr, "FAIL add(2, 3) != 5\n");
        return 1;
    }
    printf("c: 1 test passed\n");
    return 0;
}
