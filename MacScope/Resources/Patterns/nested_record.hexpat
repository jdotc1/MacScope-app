// MacScope-owned fixture: 12 bytes; little-endian unless a field says otherwise.
enum RecordKind : u8 {
    small = 1,
    large = 2
};
struct Header {
    u8 magic[2];
    RecordKind kind;
    u8 version;
};
bitfield Flags {
    enabled : 1;
    mode : 3;
    reserved : 4;
};
struct Sample {
    u16 value;
    Flags flags;
};
struct Packet {
    Header header;
    Sample samples[2];
    u16 trailer;
};
Packet packet @ 0;

