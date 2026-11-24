/* Self-test payload for the wine bundle build.
 *
 * Compiled to a Windows PE with mingw on the x86_64 runner and executed there
 * under wine, so the exact Windows layer about to be shipped is proven to work
 * before it reaches the device. The arithmetic keeps the result non-trivial and
 * printable, which distinguishes "ran" from "linked". */
#include <stdio.h>

int main(void)
{
    unsigned long acc = 0;
    for (unsigned long i = 0; i < 1000000UL; i++)
        acc += i ^ (acc >> 3);
    printf("hello from a Windows PE, acc=%lu\n", acc);
    return 0;
}
