// MacScope-owned two-byte fixture; bit 0 denotes the first MSB in this record.
bitfield CrossBits {
    a : 3;
    b : 10;
    c : 3;
};
be CrossBits cross @ 0;

