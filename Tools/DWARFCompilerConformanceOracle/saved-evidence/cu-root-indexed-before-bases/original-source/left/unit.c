typedef unsigned long word; typedef const volatile int cvint;
struct Pair { int first; long second; }; union Choice { int integer; double real; };
enum Color { RED=-2, GREEN=3, BLUE=19 }; volatile int sink;
int target(int x, long y) { int local=x+(int)y; sink=local; return local; }
/* deterministic seed member 20261013 */
