/* Source-owned DP06 capability fixture. No SDK headers or executable bodies. */
typedef unsigned long Count;
struct Padded { char head; int value; };
struct __attribute__((packed)) PackedBits { unsigned a:3; unsigned b:31; char tail; };
struct __attribute__((packed)) Barrier { char head; unsigned :0; char tail; };
struct __attribute__((packed)) Aligned { char head; int value __attribute__((aligned(8))); };
union Overlap { char byte; long word; };
struct Anonymous { char prefix; union { int number; float decimal; }; };
struct Flexible { unsigned count; char bytes[]; };
struct Callbacks { int (*callback)(int); };
struct Opaque;
typedef struct Opaque *OpaqueRef;
enum Wide { Zero = 0, Maximum = 18446744073709551615ULL };
/* Independent checks of non-bitfield units; no linking or execution. */
_Static_assert(sizeof(struct Padded) == 8, "Padded size");
_Static_assert(_Alignof(struct Padded) == 4, "Padded alignment");
_Static_assert(__builtin_offsetof(struct Padded, value) == 4, "Padded offset");
_Static_assert(sizeof(struct Aligned) == 16, "Aligned size");
_Static_assert(__builtin_offsetof(struct Aligned, value) == 8, "Aligned offset");
_Static_assert(sizeof(union Overlap) == 8, "Overlap size");
_Static_assert(sizeof(struct Flexible) == 4, "Flexible size");
_Static_assert(__builtin_offsetof(struct Flexible, bytes) == 4, "Flexible offset");
