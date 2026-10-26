/* Public-header parser fixture; ABI8 configuration from the supplied layout.c. */
typedef __SIZE_TYPE__ size_t;
typedef struct opaque_FILE FILE;
#define JCONFIG_INCLUDED 1
#define JPEG_LIB_VERSION 80

/* Internal import opts in before jmorecfg.h selects its capabilities.
 * jconfig.h.in:13-34 and the 3.2.0 installed jconfig.h supply these values.
 * CMakeLists.txt:298-299 defaults WITH_PROFILE off; jconfigint.h.in:80
 * leaves it undefined (defining it as zero would still enable the fields).
 */
#ifdef JPEG_INTERNAL_OPTIONS
#define C_ARITH_CODING_SUPPORTED 1
#define D_ARITH_CODING_SUPPORTED 1
#define MEM_SRCDST_SUPPORTED 1
#define WITH_SIMD 1
#define BITS_IN_JSAMPLE 8
#undef WITH_PROFILE
#endif
#include "jpeglib.h"

/* jmorecfg.h:218-225 allows JPEG_INTERNAL_OPTIONS independently of
 * JPEG_INTERNALS.  Set the latter only after the public include so that
 * jpeglib.h:1212-1214 does not also include jpegint.h and absent jerror.h.
 * The importing test includes jpegint.h exactly once after this fixture.
 */
#ifdef JPEG_INTERNAL_OPTIONS
#define JPEG_INTERNALS
#endif
