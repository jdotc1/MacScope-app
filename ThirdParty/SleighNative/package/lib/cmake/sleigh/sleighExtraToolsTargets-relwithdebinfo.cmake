#----------------------------------------------------------------
# Generated CMake target import file for configuration "RelWithDebInfo".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "sleigh::lift" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::lift APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::lift PROPERTIES
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/bin/sleigh-lift"
  )

list(APPEND _cmake_import_check_targets sleigh::lift )
list(APPEND _cmake_import_check_files_for_sleigh::lift "${_IMPORT_PREFIX}/bin/sleigh-lift" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
