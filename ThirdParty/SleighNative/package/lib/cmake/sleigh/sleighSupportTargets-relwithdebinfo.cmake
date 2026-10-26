#----------------------------------------------------------------
# Generated CMake target import file for configuration "RelWithDebInfo".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "sleigh::support" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::support APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::support PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELWITHDEBINFO "CXX"
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/lib/libslaSupport.a"
  )

list(APPEND _cmake_import_check_targets sleigh::support )
list(APPEND _cmake_import_check_files_for_sleigh::support "${_IMPORT_PREFIX}/lib/libslaSupport.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
