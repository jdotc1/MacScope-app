// Shared bridge entry points.
#include "MacScopeParserEngines.h"

#include "ParserEnginesIdentity.h"

#include <cstdlib>

extern "C" void macscope_parser_engines_free(char *document) { std::free(document); }

extern "C" const char *macscope_parser_engines_identity(void) { return MACSCOPE_PARSER_ENGINES_IDENTITY; }
