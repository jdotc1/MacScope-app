typedef unsigned int uint32_t;
uint32_t reconstructed(uint32_t value) { return value == 4294967295U ? value : value + 1U; }
