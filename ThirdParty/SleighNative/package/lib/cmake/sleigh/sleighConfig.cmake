#
# Copyright (c) 2022-present, Trail of Bits, Inc.
# All rights reserved.
#
# This source code is licensed in accordance with the terms specified in
# the LICENSE file found in the root directory of this source tree.
#

# This file provides access to the installed sleigh targets.
#
# There are optional components that could also be installed:
#   * Specs - Compiled sleigh specification files
#   * Support - Support library for easier use of sleigh
#   * ExtraTools - Extra tools created by Trail of Bits


####### Expanded from @PACKAGE_INIT@ by configure_package_config_file() #######
####### Any changes to this file will be overwritten by the next CMake run ####
####### The input file was install-config.cmake.in                            ########

get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)

macro(set_and_check _var _file)
  set(${_var} "${_file}")
  if(NOT EXISTS "${_file}")
    message(FATAL_ERROR "File or directory ${_file} referenced by variable ${_var} does not exist !")
  endif()
endmacro()

####################################################################################

# Extra version details. Either 'stable' or 'HEAD'
set(sleigh_RELEASE_IS_HEAD "FALSE")

include(CMakeFindDependencyMacro)
find_dependency(ZLIB)

include("${CMAKE_CURRENT_LIST_DIR}/sleighTargets.cmake")

# Helpers exposed by default when finding sleigh
include("${CMAKE_CURRENT_LIST_DIR}/modules/sleighCompile.cmake")

# Find-package component handling for Support library and ExtraTools
set(_sleigh_supported_components Specs Support ExtraTools)

# Specs just sets a variable to the directory of installation
set(_sleigh_Specs_targets "${CMAKE_CURRENT_LIST_DIR}/specfiles.cmake")
set(_sleigh_Support_targets "${CMAKE_CURRENT_LIST_DIR}/sleighSupportTargets.cmake")
set(_sleigh_ExtraTools_targets "${CMAKE_CURRENT_LIST_DIR}/sleighExtraToolsTargets.cmake")

macro(sleigh_load_component comp)
  if(NOT EXISTS "${_sleigh_${comp}_targets}" AND ${sleigh_FIND_REQUIRED_${comp}})
    set(sleigh_NOT_FOUND_MESSAGE
      "sleigh `${comp}` component targets were requested but not found.")
    set(sleigh_FOUND FALSE)
    return()
  endif()
  if(EXISTS "${_sleigh_${comp}_targets}")
    include("${_sleigh_${comp}_targets}")
  endif()
endmacro()

foreach(_comp ${sleigh_FIND_COMPONENTS})
  if (NOT _comp IN_LIST _sleigh_supported_components)
    set(sleigh_FOUND FALSE)
    set(sleigh_NOT_FOUND_MESSAGE "Unsupported component: ${_comp}")
  endif()
  sleigh_load_component("${_comp}")
endforeach()
