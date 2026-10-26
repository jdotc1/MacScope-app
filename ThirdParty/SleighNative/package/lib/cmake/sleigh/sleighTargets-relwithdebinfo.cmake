#----------------------------------------------------------------
# Generated CMake target import file for configuration "RelWithDebInfo".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "sleigh::sla" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::sla APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::sla PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELWITHDEBINFO "CXX"
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/lib/libsla.a"
  )

list(APPEND _cmake_import_check_targets sleigh::sla )
list(APPEND _cmake_import_check_files_for_sleigh::sla "${_IMPORT_PREFIX}/lib/libsla.a" )

# Import target "sleigh::decomp" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::decomp APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::decomp PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELWITHDEBINFO "CXX"
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/lib/libdecomp.a"
  )

list(APPEND _cmake_import_check_targets sleigh::decomp )
list(APPEND _cmake_import_check_files_for_sleigh::decomp "${_IMPORT_PREFIX}/lib/libdecomp.a" )

# Import target "sleigh::sleigh" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::sleigh APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::sleigh PROPERTIES
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/bin/sleigh"
  )

list(APPEND _cmake_import_check_targets sleigh::sleigh )
list(APPEND _cmake_import_check_files_for_sleigh::sleigh "${_IMPORT_PREFIX}/bin/sleigh" )

# Import target "sleigh::decompiler" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::decompiler APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::decompiler PROPERTIES
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/bin/decomp"
  )

list(APPEND _cmake_import_check_targets sleigh::decompiler )
list(APPEND _cmake_import_check_files_for_sleigh::decompiler "${_IMPORT_PREFIX}/bin/decomp" )

# Import target "sleigh::ghidra" for configuration "RelWithDebInfo"
set_property(TARGET sleigh::ghidra APPEND PROPERTY IMPORTED_CONFIGURATIONS RELWITHDEBINFO)
set_target_properties(sleigh::ghidra PROPERTIES
  IMPORTED_LOCATION_RELWITHDEBINFO "${_IMPORT_PREFIX}/bin/ghidra"
  )

list(APPEND _cmake_import_check_targets sleigh::ghidra )
list(APPEND _cmake_import_check_files_for_sleigh::ghidra "${_IMPORT_PREFIX}/bin/ghidra" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
