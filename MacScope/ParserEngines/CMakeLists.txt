# MacScope parser-engine bridge (RX-03). Built only by
# Scripts/dependencies/build_parser_engines.py into the shared, content-addressed
# dependency cache, against the cached LIEF, pe-parse and go-macho payloads named
# by LIEF_ROOT, PEPARSE_ROOT and GOMACHO_ROOT. Never a compile source of an Xcode
# target; Xcode links the staged static archives. No downloads happen here.
cmake_minimum_required(VERSION 3.24)
project(macscope_parser_engines CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

foreach(root LIEF_ROOT PEPARSE_ROOT GOMACHO_ROOT)
  if(NOT ${root} OR NOT IS_DIRECTORY "${${root}}")
    message(FATAL_ERROR "${root} must name a staged parser-engine payload")
  endif()
endforeach()
if(NOT MACSCOPE_PARSER_ENGINES_IDENTITY_FILE OR NOT EXISTS "${MACSCOPE_PARSER_ENGINES_IDENTITY_FILE}")
  message(FATAL_ERROR "MACSCOPE_PARSER_ENGINES_IDENTITY_FILE must name the engine identity JSON")
endif()
file(READ "${MACSCOPE_PARSER_ENGINES_IDENTITY_FILE}" identity_json)
string(STRIP "${identity_json}" identity_json)
string(REPLACE "\\" "\\\\" identity_json "${identity_json}")
string(REPLACE "\"" "\\\"" identity_json "${identity_json}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/generated/ParserEnginesIdentity.h"
  "#define MACSCOPE_PARSER_ENGINES_IDENTITY \"${identity_json}\"\n")

find_package(LIEF CONFIG REQUIRED PATHS "${LIEF_ROOT}" NO_DEFAULT_PATH)

add_library(macscope_parser_engines STATIC
  src/LIEFFacts.cpp
  src/PEParseFacts.cpp
  src/ParserEngines.cpp)
target_include_directories(macscope_parser_engines PRIVATE include src "${PEPARSE_ROOT}/include"
  "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(macscope_parser_engines PRIVATE LIEF::LIEF)

add_executable(macscope-parser-dump tools/macscope_parser_dump.cpp)
target_include_directories(macscope-parser-dump PRIVATE include)
target_link_libraries(macscope-parser-dump PRIVATE
  macscope_parser_engines
  LIEF::LIEF
  "${PEPARSE_ROOT}/lib/libpe-parse.a"
  "${GOMACHO_ROOT}/lib/libmacscope_gomacho.a"
  "-framework CoreFoundation"
  "-framework Security"
  resolv)
