cmake_minimum_required(VERSION 3.20)

project(MacScopeNativeDecompilerBridge LANGUAGES CXX)

option(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS "Treat bridge warnings as errors" ON)
set(
    MACSCOPE_NATIVE_DECOMPILER_SANITIZER
    "none"
    CACHE STRING
    "Native bridge test instrumentation: none, address, or undefined"
)
set_property(
    CACHE MACSCOPE_NATIVE_DECOMPILER_SANITIZER
    PROPERTY STRINGS none address undefined
)
if(NOT MACSCOPE_NATIVE_DECOMPILER_SANITIZER MATCHES "^(none|address|undefined)$")
    message(FATAL_ERROR
        "MACSCOPE_NATIVE_DECOMPILER_SANITIZER must be none, address, or undefined"
    )
endif()
add_compile_definitions(
    MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE="${MACSCOPE_NATIVE_DECOMPILER_SANITIZER}"
)
if(NOT MACSCOPE_NATIVE_DECOMPILER_SANITIZER STREQUAL "none")
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "native sanitizer qualification requires Clang")
    endif()
    if(MACSCOPE_NATIVE_DECOMPILER_SANITIZER STREQUAL "address")
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
        add_link_options(-fsanitize=address)
    else()
        add_compile_options(-fsanitize=undefined -fno-sanitize-recover=all)
        add_link_options(-fsanitize=undefined -fno-sanitize-recover=all)
    endif()
endif()

option(
    MACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE
    "Compile and execute the explicitly materialized native SLEIGH/Ghidra API probe"
    OFF
)
option(
    MACSCOPE_ENABLE_GHIDRA_PROVIDER
    "Build the developer-only direct native structured provider"
    OFF
)
option(
    MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION
    "Derive the attested native package location from explicit runtime configuration"
    OFF
)
set(
    MACSCOPE_SLEIGH_MATERIALIZATION_ROOT
    ""
    CACHE PATH
    "Path to the explicit sleigh-native-dcp03b4 materialization root"
)
set(
    MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION
    ""
    CACHE STRING
    "Explicit lowercase 40- or 64-digit wrapper Git revision"
)

set(_macscope_requires_sleigh OFF)
if(MACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE OR MACSCOPE_ENABLE_GHIDRA_PROVIDER)
    set(_macscope_requires_sleigh ON)
endif()

if(
    MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION
    AND NOT MACSCOPE_ENABLE_GHIDRA_PROVIDER
)
    message(FATAL_ERROR
        "MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION requires "
        "MACSCOPE_ENABLE_GHIDRA_PROVIDER=ON"
    )
endif()

if(MACSCOPE_ENABLE_GHIDRA_PROVIDER)
    string(LENGTH
        "${MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION}"
        _macscope_wrapper_revision_length
    )
    if(
        NOT (
            _macscope_wrapper_revision_length EQUAL 40
            OR _macscope_wrapper_revision_length EQUAL 64
        )
        OR NOT MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION MATCHES "^[0-9a-f]+$"
    )
        message(FATAL_ERROR
            "MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION must be an "
            "explicit lowercase 40- or 64-digit Git revision"
        )
    endif()
    if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
        message(FATAL_ERROR
            "DCP-03B5 provider qualification supports native arm64 macOS only"
        )
    endif()
    if(CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
        message(FATAL_ERROR "DCP-03B5 provider builds must target arm64 only")
    endif()
    if(NOT CMAKE_OSX_SYSROOT)
        message(FATAL_ERROR "DCP-03B5 provider builds require an explicit Xcode macOS SDK")
    endif()
endif()

function(
    _macscope_require_real_path_within
    output_variable
    trusted_root
    candidate
    label
)
    if(NOT EXISTS "${candidate}")
        message(FATAL_ERROR "${label} is missing")
    endif()
    get_filename_component(_trusted_root "${trusted_root}" REALPATH)
    get_filename_component(_candidate "${candidate}" REALPATH)
    file(RELATIVE_PATH _relative "${_trusted_root}" "${_candidate}")
    if(_relative STREQUAL ".." OR _relative MATCHES "^\\.\\./" OR IS_ABSOLUTE "${_relative}")
        message(FATAL_ERROR "${label} escapes its attested root")
    endif()
    set("${output_variable}" "${_candidate}" PARENT_SCOPE)
endfunction()

function(_macscope_require_imported_archive target expected_archive expected_include_root)
    if(NOT TARGET "${target}")
        message(FATAL_ERROR "required imported target ${target} is missing")
    endif()
    get_target_property(_imported "${target}" IMPORTED)
    get_target_property(_type "${target}" TYPE)
    if(NOT _imported OR NOT _type STREQUAL "STATIC_LIBRARY")
        message(FATAL_ERROR "${target} is not the attested static imported archive")
    endif()

    get_filename_component(_expected_archive "${expected_archive}" REALPATH)
    set(_locations)
    get_target_property(_base_location "${target}" IMPORTED_LOCATION)
    if(_base_location AND NOT _base_location MATCHES "-NOTFOUND$")
        list(APPEND _locations "${_base_location}")
    endif()
    get_target_property(_configurations "${target}" IMPORTED_CONFIGURATIONS)
    foreach(_configuration IN LISTS _configurations)
        string(TOUPPER "${_configuration}" _configuration_upper)
        get_target_property(
            _configured_location
            "${target}"
            "IMPORTED_LOCATION_${_configuration_upper}"
        )
        if(_configured_location AND NOT _configured_location MATCHES "-NOTFOUND$")
            list(APPEND _locations "${_configured_location}")
        endif()
    endforeach()
    if(NOT _locations)
        message(FATAL_ERROR "${target} has no imported archive location")
    endif()
    foreach(_location IN LISTS _locations)
        get_filename_component(_location_real "${_location}" REALPATH)
        if(NOT _location_real STREQUAL _expected_archive)
            message(FATAL_ERROR "${target} does not resolve to its attested archive")
        endif()
    endforeach()

    get_filename_component(_expected_include_root "${expected_include_root}" REALPATH)
    get_target_property(_include_roots "${target}" INTERFACE_INCLUDE_DIRECTORIES)
    if(NOT _include_roots)
        message(FATAL_ERROR "${target} has no imported include root")
    endif()
    foreach(_include_root IN LISTS _include_roots)
        get_filename_component(_include_root_real "${_include_root}" REALPATH)
        if(NOT _include_root_real STREQUAL _expected_include_root)
            message(FATAL_ERROR "${target} exposes an unattested include root")
        endif()
    endforeach()
    get_target_property(_link_libraries "${target}" INTERFACE_LINK_LIBRARIES)
    if(NOT _link_libraries STREQUAL "ZLIB::ZLIB")
        message(FATAL_ERROR "${target} exposes an unexpected transitive dependency")
    endif()
endfunction()

function(_macscope_escape_cxx_string output_variable value label)
    if("${value}" MATCHES "[\n\r\t]" OR "${value}" MATCHES ";")
        message(FATAL_ERROR "${label} contains unsupported characters")
    endif()
    string(REPLACE "\\" "\\\\" _escaped "${value}")
    string(REPLACE "\"" "\\\"" _escaped "${_escaped}")
    set("${output_variable}" "${_escaped}" PARENT_SCOPE)
endfunction()
add_library(macscope_native_decompiler_contract STATIC
    src/Backend.cpp
    src/CanonicalRequest.cpp
    src/InputModel.cpp
    src/OutputModel.cpp
    src/BlockPartition.cpp
)
add_library(MacScope::NativeDecompilerContract ALIAS macscope_native_decompiler_contract)

target_include_directories(macscope_native_decompiler_contract
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
)
target_compile_features(macscope_native_decompiler_contract PUBLIC cxx_std_20)
set_target_properties(macscope_native_decompiler_contract PROPERTIES
    CXX_EXTENSIONS OFF
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

if(MSVC)
    target_compile_options(macscope_native_decompiler_contract PRIVATE /W4)
    if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
        target_compile_options(macscope_native_decompiler_contract PRIVATE /WX)
    endif()
else()
    target_compile_options(macscope_native_decompiler_contract PRIVATE -Wall -Wextra -Wpedantic)
    if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
        target_compile_options(macscope_native_decompiler_contract PRIVATE -Werror)
    endif()
endif()

include(CTest)
if(BUILD_TESTING)
    find_package(Threads REQUIRED)
    add_executable(macscope_native_decompiler_contract_tests tests/ContractTests.cpp)
    target_link_libraries(macscope_native_decompiler_contract_tests PRIVATE MacScope::NativeDecompilerContract)
    add_test(NAME macscope_native_decompiler_contract_tests COMMAND macscope_native_decompiler_contract_tests)

    add_executable(
        macscope_native_decompiler_canonical_request_tests
        tests/CanonicalRequestTests.cpp
    )
    target_include_directories(
        macscope_native_decompiler_canonical_request_tests
        PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src"
    )
    target_link_libraries(
        macscope_native_decompiler_canonical_request_tests
        PRIVATE MacScope::NativeDecompilerContract
    )
    add_test(
        NAME macscope_native_decompiler_canonical_request_tests
        COMMAND macscope_native_decompiler_canonical_request_tests
    )

    add_executable(macscope_native_decompiler_definition_identity_tests tests/DefinitionIdentityTests.cpp)
    target_include_directories(macscope_native_decompiler_definition_identity_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_link_libraries(macscope_native_decompiler_definition_identity_tests PRIVATE MacScope::NativeDecompilerContract)
    add_test(NAME macscope_native_decompiler_definition_identity_tests COMMAND macscope_native_decompiler_definition_identity_tests)


    add_executable(macscope_native_decompiler_provider_tests tests/ProviderBackendTests.cpp)
    target_link_libraries(macscope_native_decompiler_provider_tests PRIVATE MacScope::NativeDecompilerContract Threads::Threads)
    add_test(NAME macscope_native_decompiler_provider_tests COMMAND macscope_native_decompiler_provider_tests)
endif()


if(_macscope_requires_sleigh)
    if(NOT MACSCOPE_SLEIGH_MATERIALIZATION_ROOT)
        message(FATAL_ERROR
            "The enabled native SLEIGH feature requires MACSCOPE_SLEIGH_MATERIALIZATION_ROOT"
        )
    endif()
    get_filename_component(
        _macscope_sleigh_materialization_input
        "${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT}"
        ABSOLUTE
    )
    if(NOT EXISTS "${_macscope_sleigh_materialization_input}/MATERIALIZATION.json")
        message(FATAL_ERROR "DCP-03B4 MATERIALIZATION.json is missing")
    endif()

    # A CMake package configuration is executable code. Verify the complete
    # materialization before allowing find_package() to evaluate any upstream
    # CMake file. This probe is developer-only and is never enabled by an
    # ordinary MacScope configure/build/test path.
    find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)
    set(
        _macscope_sleigh_verifier
        "${CMAKE_CURRENT_SOURCE_DIR}/../../Scripts/native-decompiler-direct/verify_sleigh_package.py"
    )
    if(NOT EXISTS "${_macscope_sleigh_verifier}")
        message(FATAL_ERROR "DCP-03B4 package verifier is unavailable")
    endif()
    set(_macscope_sleigh_verification_command
        "${Python3_EXECUTABLE}" -B "${_macscope_sleigh_verifier}" verify
        --materialization-root "${_macscope_sleigh_materialization_input}"
        --expected-sanitizer "${MACSCOPE_NATIVE_DECOMPILER_SANITIZER}")
    if("$ENV{MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE}" STREQUAL "shared-view")
        set(_macscope_sleigh_verification_command
            "${Python3_EXECUTABLE}" -B
            "${CMAKE_CURRENT_SOURCE_DIR}/../../Scripts/qualification/dev_dependency_cache.py"
            reuse-sleigh --repository-root "${CMAKE_CURRENT_SOURCE_DIR}/../.."
            --materialization-root "${_macscope_sleigh_materialization_input}"
            --expected-sanitizer "${MACSCOPE_NATIVE_DECOMPILER_SANITIZER}")
        set(_macscope_sleigh_receipt_output --output-json)
    elseif(NOT "$ENV{MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE}" STREQUAL "")
        message(FATAL_ERROR "unsupported native verification receipt mode")
    endif()
    execute_process(
        COMMAND ${_macscope_sleigh_verification_command} ${_macscope_sleigh_receipt_output}
        RESULT_VARIABLE _macscope_sleigh_verification_status
        OUTPUT_VARIABLE _macscope_sleigh_verified_json
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
        TIMEOUT 30
    )
    if(NOT _macscope_sleigh_verification_status EQUAL 0)
        message(FATAL_ERROR "DCP-03B4 native package verification failed")
    endif()
    get_filename_component(
        _macscope_sleigh_materialization_root
        "${_macscope_sleigh_materialization_input}"
        REALPATH
    )
    set(
        _macscope_sleigh_manifest
        "${_macscope_sleigh_materialization_root}/MATERIALIZATION.json"
    )
    if(_macscope_sleigh_receipt_output)
        string(JSON _macscope_sleigh_manifest_sha256 GET "${_macscope_sleigh_verified_json}" manifest_sha256)
        string(JSON _macscope_sleigh_verified_json GET "${_macscope_sleigh_verified_json}" identity)
    else()
        file(SHA256 "${_macscope_sleigh_manifest}" _macscope_sleigh_manifest_sha256)
    endif()
    set_property(
        DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${_macscope_sleigh_manifest}"
    )

    string(JSON
        _macscope_sleigh_package_relative_root
        GET "${_macscope_sleigh_verified_json}" package relativeRoot
    )
    string(JSON
        _macscope_sleigh_config_relative_path
        GET "${_macscope_sleigh_verified_json}" package cmakeConfigRelativePath
    )
    string(JSON
        _macscope_sleigh_processor_relative_root
        GET "${_macscope_sleigh_verified_json}" package processorSpecRelativeRoot
    )
    string(JSON
        _macscope_sleigh_decomp_relative_path
        GET "${_macscope_sleigh_verified_json}" package decompilerLibraryRelativePath
    )
    string(JSON
        _macscope_sleigh_sla_relative_path
        GET "${_macscope_sleigh_verified_json}" package sleighLibraryRelativePath
    )
    string(JSON
        _macscope_sleigh_tree_sha256
        GET "${_macscope_sleigh_verified_json}" package treeSha256
    )
    string(JSON
        _macscope_sleigh_version
        GET "${_macscope_sleigh_verified_json}" sleighVersion
    )
    string(JSON
        _macscope_ghidra_version
        GET "${_macscope_sleigh_verified_json}" ghidraVersion
    )
    string(JSON
        _macscope_ghidra_revision
        GET "${_macscope_sleigh_verified_json}" ghidraGitRevision
    )
    if(
        NOT _macscope_sleigh_version STREQUAL "12.1.2"
        OR NOT _macscope_ghidra_version STREQUAL "12.1.2"
        OR NOT _macscope_ghidra_revision STREQUAL "c0f584bf229fffba61b36431f3ce30c0c3e4e682"
    )
        message(FATAL_ERROR "verified package identity does not match the frozen DCP-03B5 contract")
    endif()

    _macscope_require_real_path_within(
        _macscope_sleigh_package_root
        "${_macscope_sleigh_materialization_root}"
        "${_macscope_sleigh_materialization_root}/${_macscope_sleigh_package_relative_root}"
        "attested package root"
    )
    get_filename_component(
        _macscope_sleigh_config_relative_directory
        "${_macscope_sleigh_config_relative_path}"
        DIRECTORY
    )
    _macscope_require_real_path_within(
        _macscope_sleigh_config_directory
        "${_macscope_sleigh_package_root}"
        "${_macscope_sleigh_package_root}/${_macscope_sleigh_config_relative_directory}"
        "attested CMake package directory"
    )
    foreach(_macscope_forbidden_sleigh_target IN ITEMS
        sleigh::sla
        sleigh::decomp
        sleigh::sleigh
        sleigh::decompiler
        sleigh::ghidra
    )
        if(TARGET "${_macscope_forbidden_sleigh_target}")
            message(FATAL_ERROR "a native SLEIGH target existed before attested package evaluation")
        endif()
    endforeach()
    if(CMAKE_FIND_PACKAGE_REDIRECTS_DIR)
        foreach(_macscope_redirect_name IN ITEMS
            sleigh-config.cmake
            sleighConfig.cmake
            sleigh-config-version.cmake
            sleighConfigVersion.cmake
        )
            if(EXISTS "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/${_macscope_redirect_name}")
                message(FATAL_ERROR "CMake package redirection for SLEIGH is not permitted")
            endif()
        endforeach()
    endif()
    set(
        sleigh_DIR
        "${_macscope_sleigh_config_directory}"
        CACHE PATH
        "Attested SLEIGH package configuration directory"
        FORCE
    )

    find_package(
        sleigh 12.1.2 EXACT CONFIG REQUIRED COMPONENTS Specs
        PATHS "${_macscope_sleigh_config_directory}"
        NO_DEFAULT_PATH
    )
    set(
        _macscope_expected_sleigh_config
        "${_macscope_sleigh_package_root}/${_macscope_sleigh_config_relative_path}"
    )
    if(NOT DEFINED sleigh_CONFIG OR NOT EXISTS "${sleigh_CONFIG}")
        message(FATAL_ERROR "CMake did not report the evaluated SLEIGH package configuration")
    endif()
    get_filename_component(_macscope_sleigh_config_after_find "${sleigh_CONFIG}" REALPATH)
    get_filename_component(_macscope_expected_sleigh_config "${_macscope_expected_sleigh_config}" REALPATH)
    if(NOT _macscope_sleigh_config_after_find STREQUAL _macscope_expected_sleigh_config)
        message(FATAL_ERROR "CMake evaluated an unattested SLEIGH package configuration")
    endif()
    get_filename_component(_macscope_sleigh_dir_after_find "${sleigh_DIR}" REALPATH)
    if(NOT _macscope_sleigh_dir_after_find STREQUAL _macscope_sleigh_config_directory)
        message(FATAL_ERROR "SLEIGH package resolution escaped the attested configuration directory")
    endif()

    set(_macscope_sleigh_include_root "${_macscope_sleigh_package_root}/include/sleigh")
    _macscope_require_imported_archive(
        sleigh::decomp
        "${_macscope_sleigh_package_root}/${_macscope_sleigh_decomp_relative_path}"
        "${_macscope_sleigh_include_root}"
    )
    _macscope_require_imported_archive(
        sleigh::sla
        "${_macscope_sleigh_package_root}/${_macscope_sleigh_sla_relative_path}"
        "${_macscope_sleigh_include_root}"
    )
    if(NOT DEFINED sleigh_INSTALL_SPECDIR OR NOT IS_DIRECTORY "${sleigh_INSTALL_SPECDIR}")
        message(FATAL_ERROR "materialized SLEIGH package lacks compiled processor specifications")
    endif()
    _macscope_require_real_path_within(
        _macscope_sleigh_global_spec_root
        "${_macscope_sleigh_package_root}"
        "${_macscope_sleigh_package_root}/share/sleigh/specfiles"
        "global processor specification root"
    )
    get_filename_component(_macscope_sleigh_configured_spec_root "${sleigh_INSTALL_SPECDIR}" REALPATH)
    if(NOT _macscope_sleigh_configured_spec_root STREQUAL _macscope_sleigh_global_spec_root)
        message(FATAL_ERROR "upstream package exposes an unexpected processor specification root")
    endif()
    _macscope_require_real_path_within(
        _macscope_sleigh_processor_spec_root
        "${_macscope_sleigh_package_root}"
        "${_macscope_sleigh_package_root}/${_macscope_sleigh_processor_relative_root}"
        "AArch64 processor specification root"
    )

    if(MACSCOPE_ENABLE_GHIDRA_PROVIDER)
        get_filename_component(_macscope_sdk_root "${CMAKE_OSX_SYSROOT}" REALPATH)
        if(NOT IS_DIRECTORY "${_macscope_sdk_root}")
            message(FATAL_ERROR "configured macOS SDK is unavailable")
        endif()
        if(NOT TARGET ZLIB::ZLIB)
            message(FATAL_ERROR "attested native targets did not resolve SDK zlib")
        endif()
        get_target_property(_macscope_zlib_imported ZLIB::ZLIB IMPORTED)
        if(NOT _macscope_zlib_imported)
            message(FATAL_ERROR "zlib is not an imported SDK target")
        endif()
        set(_macscope_zlib_locations)
        get_target_property(_macscope_zlib_location ZLIB::ZLIB IMPORTED_LOCATION)
        if(_macscope_zlib_location AND NOT _macscope_zlib_location MATCHES "-NOTFOUND$")
            list(APPEND _macscope_zlib_locations "${_macscope_zlib_location}")
        endif()
        get_target_property(_macscope_zlib_configurations ZLIB::ZLIB IMPORTED_CONFIGURATIONS)
        foreach(_macscope_zlib_configuration IN LISTS _macscope_zlib_configurations)
            string(TOUPPER "${_macscope_zlib_configuration}" _macscope_zlib_configuration_upper)
            get_target_property(
                _macscope_zlib_configured_location
                ZLIB::ZLIB
                "IMPORTED_LOCATION_${_macscope_zlib_configuration_upper}"
            )
            if(
                _macscope_zlib_configured_location
                AND NOT _macscope_zlib_configured_location MATCHES "-NOTFOUND$"
            )
                list(APPEND _macscope_zlib_locations "${_macscope_zlib_configured_location}")
            endif()
        endforeach()
        if(NOT _macscope_zlib_locations)
            message(FATAL_ERROR "SDK zlib has no imported library location")
        endif()
        foreach(_macscope_zlib_candidate IN LISTS _macscope_zlib_locations)
            _macscope_require_real_path_within(
                _macscope_zlib_location_real
                "${_macscope_sdk_root}"
                "${_macscope_zlib_candidate}"
                "zlib imported library"
            )
        endforeach()
        get_target_property(_macscope_zlib_includes ZLIB::ZLIB INTERFACE_INCLUDE_DIRECTORIES)
        foreach(_macscope_zlib_include IN LISTS _macscope_zlib_includes)
            if(_macscope_zlib_include AND NOT _macscope_zlib_include MATCHES "-NOTFOUND$")
                _macscope_require_real_path_within(
                    _macscope_zlib_include_real
                    "${_macscope_sdk_root}"
                    "${_macscope_zlib_include}"
                    "zlib imported include directory"
                )
            endif()
        endforeach()
        foreach(_macscope_zlib_property IN ITEMS
            INTERFACE_LINK_LIBRARIES
            INTERFACE_LINK_OPTIONS
            INTERFACE_COMPILE_DEFINITIONS
            INTERFACE_COMPILE_OPTIONS
        )
            get_target_property(_macscope_zlib_property_value ZLIB::ZLIB "${_macscope_zlib_property}")
            if(
                _macscope_zlib_property_value
                AND NOT _macscope_zlib_property_value MATCHES "-NOTFOUND$"
            )
                message(FATAL_ERROR "SDK zlib exposes an unexpected interface property")
            endif()
        endforeach()
    endif()

    add_custom_target(
        macscope_verify_sleigh_materialization
        COMMAND ${_macscope_sleigh_verification_command}
        COMMENT "Revalidating the closed native SLEIGH materialization"
        VERBATIM
    )
endif()

if(MACSCOPE_ENABLE_GHIDRA_PROVIDER)
    if(MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION)
        set(MACSCOPE_ATTESTED_RELOCATABLE_MATERIALIZATION true)
        set(MACSCOPE_ATTESTED_MATERIALIZATION_ROOT "")
        set(MACSCOPE_ATTESTED_PACKAGE_ROOT "")
        set(MACSCOPE_ATTESTED_GLOBAL_SPEC_ROOT "")
        set(MACSCOPE_ATTESTED_PROCESSOR_SPEC_ROOT "")
    else()
        set(MACSCOPE_ATTESTED_RELOCATABLE_MATERIALIZATION false)
        _macscope_escape_cxx_string(
            MACSCOPE_ATTESTED_MATERIALIZATION_ROOT
            "${_macscope_sleigh_materialization_root}"
            "materialization root"
        )
        _macscope_escape_cxx_string(
            MACSCOPE_ATTESTED_PACKAGE_ROOT
            "${_macscope_sleigh_package_root}"
            "package root"
        )
        _macscope_escape_cxx_string(
            MACSCOPE_ATTESTED_GLOBAL_SPEC_ROOT
            "${_macscope_sleigh_global_spec_root}"
            "global specification root"
        )
        _macscope_escape_cxx_string(
            MACSCOPE_ATTESTED_PROCESSOR_SPEC_ROOT
            "${_macscope_sleigh_processor_spec_root}"
            "processor specification root"
        )
    endif()
    _macscope_escape_cxx_string(
        MACSCOPE_ATTESTED_PACKAGE_RELATIVE_ROOT
        "${_macscope_sleigh_package_relative_root}"
        "package relative root"
    )
    _macscope_escape_cxx_string(
        MACSCOPE_ATTESTED_GLOBAL_SPEC_RELATIVE_ROOT
        "share/sleigh/specfiles"
        "global specification relative root"
    )
    _macscope_escape_cxx_string(
        MACSCOPE_ATTESTED_PROCESSOR_SPEC_RELATIVE_ROOT
        "${_macscope_sleigh_processor_relative_root}"
        "processor specification relative root"
    )
    set(MACSCOPE_ATTESTED_MANIFEST_SHA256 "${_macscope_sleigh_manifest_sha256}")
    set(MACSCOPE_ATTESTED_TREE_SHA256 "${_macscope_sleigh_tree_sha256}")
    set(MACSCOPE_ATTESTED_SLEIGH_VERSION "${_macscope_sleigh_version}")
    set(MACSCOPE_ATTESTED_GHIDRA_VERSION "${_macscope_ghidra_version}")
    set(MACSCOPE_ATTESTED_GHIDRA_REVISION "${_macscope_ghidra_revision}")
    set(MACSCOPE_ATTESTED_WRAPPER_VERSION "dcp05c-v1")
    set(
        MACSCOPE_ATTESTED_WRAPPER_REVISION
        "${MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION}"
    )
    set(_macscope_attestation_generated_root "${CMAKE_CURRENT_BINARY_DIR}/generated")
    file(MAKE_DIRECTORY "${_macscope_attestation_generated_root}/MacScopeNativeDecompiler")
    configure_file(
        src/GhidraBuildIdentity.hpp.in
        "${_macscope_attestation_generated_root}/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"
        @ONLY
    )

    target_sources(macscope_native_decompiler_contract PRIVATE
        src/BoundedUTF8StreamBuffer.cpp
        src/GhidraPackageAttestation.cpp
        src/GhidraRuntime.cpp
        src/GhidraArchitecture.cpp
        src/GhidraLoadImage.cpp
        src/GhidraProvider.cpp
        src/GhidraBlockPartition.cpp
    )
    target_include_directories(
        macscope_native_decompiler_contract
        SYSTEM PRIVATE
            "${_macscope_sleigh_include_root}"
    )
    target_include_directories(
        macscope_native_decompiler_contract
        PRIVATE "${_macscope_attestation_generated_root}"
    )
    target_compile_definitions(
        macscope_native_decompiler_contract
        PRIVATE MACSCOPE_ENABLE_GHIDRA_PROVIDER=1
    )
    target_link_libraries(
        macscope_native_decompiler_contract
        PRIVATE sleigh::decomp sleigh::sla
    )
    add_dependencies(
        macscope_native_decompiler_contract
        macscope_verify_sleigh_materialization
    )

    if(MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION)
        add_executable(
            macscope_native_decompiler_relocatable_link_probe
            probes/RelocatableProviderLinkProbe.cpp
        )
        target_compile_features(
            macscope_native_decompiler_relocatable_link_probe
            PRIVATE cxx_std_20
        )
        set_target_properties(
            macscope_native_decompiler_relocatable_link_probe
            PROPERTIES
                CXX_EXTENSIONS OFF
                CXX_VISIBILITY_PRESET hidden
                VISIBILITY_INLINES_HIDDEN YES
        )
        target_link_libraries(
            macscope_native_decompiler_relocatable_link_probe
            PRIVATE MacScope::NativeDecompilerContract
        )
        if(MSVC)
            target_compile_options(
                macscope_native_decompiler_relocatable_link_probe PRIVATE /W4
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_relocatable_link_probe PRIVATE /WX
                )
            endif()
        else()
            target_compile_options(
                macscope_native_decompiler_relocatable_link_probe
                PRIVATE -Wall -Wextra -Wpedantic
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_relocatable_link_probe PRIVATE -Werror
                )
            endif()
        endif()
    endif()

    if(BUILD_TESTING)
        add_executable(
            macscope_native_decompiler_ghidra_package_identity_tests
            tests/GhidraPackageIdentityTests.cpp
        )
        target_compile_features(
            macscope_native_decompiler_ghidra_package_identity_tests
            PRIVATE cxx_std_20
        )
        set_target_properties(
            macscope_native_decompiler_ghidra_package_identity_tests
            PROPERTIES CXX_EXTENSIONS OFF
        )
        target_include_directories(
            macscope_native_decompiler_ghidra_package_identity_tests
            PRIVATE src
        )
        target_link_libraries(
            macscope_native_decompiler_ghidra_package_identity_tests
            PRIVATE MacScope::NativeDecompilerContract
        )
        if(MSVC)
            target_compile_options(
                macscope_native_decompiler_ghidra_package_identity_tests
                PRIVATE /W4
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_ghidra_package_identity_tests
                    PRIVATE /WX
                )
            endif()
        else()
            target_compile_options(
                macscope_native_decompiler_ghidra_package_identity_tests
                PRIVATE -Wall -Wextra -Wpedantic
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_ghidra_package_identity_tests
                    PRIVATE -Werror
                )
            endif()
        endif()
        add_test(
            NAME macscope_native_decompiler_ghidra_package_identity_tests
            COMMAND macscope_native_decompiler_ghidra_package_identity_tests
        )

        add_executable(
            macscope_native_decompiler_opcode_vocabulary_binding_tests
            tests/PcodeOpcodeVocabularyBindingTests.cpp
        )
        target_compile_features(
            macscope_native_decompiler_opcode_vocabulary_binding_tests
            PRIVATE cxx_std_20
        )
        target_include_directories(
            macscope_native_decompiler_opcode_vocabulary_binding_tests
            PRIVATE
                "${CMAKE_CURRENT_SOURCE_DIR}/src"
                "${CMAKE_CURRENT_SOURCE_DIR}/include"
        )
        target_include_directories(
            macscope_native_decompiler_opcode_vocabulary_binding_tests
            SYSTEM PRIVATE "${_macscope_sleigh_include_root}"
        )
        set_target_properties(
            macscope_native_decompiler_opcode_vocabulary_binding_tests
            PROPERTIES CXX_EXTENSIONS OFF
        )
        target_link_libraries(
            macscope_native_decompiler_opcode_vocabulary_binding_tests
            PRIVATE sleigh::decomp sleigh::sla
        )
        if(MSVC)
            target_compile_options(
                macscope_native_decompiler_opcode_vocabulary_binding_tests PRIVATE /W4
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_opcode_vocabulary_binding_tests PRIVATE /WX
                )
            endif()
        else()
            target_compile_options(
                macscope_native_decompiler_opcode_vocabulary_binding_tests
                PRIVATE -Wall -Wextra -Wpedantic
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_opcode_vocabulary_binding_tests PRIVATE -Werror
                )
            endif()
        endif()
        add_test(
            NAME macscope_native_decompiler_opcode_vocabulary_binding_tests
            COMMAND macscope_native_decompiler_opcode_vocabulary_binding_tests
        )

        add_executable(
            macscope_native_decompiler_ghidra_provider_tests
            tests/GhidraProviderTests.cpp
            tests/GhidraPacQualificationSupport.cpp
        )
        target_compile_features(
            macscope_native_decompiler_ghidra_provider_tests
            PRIVATE cxx_std_20
        )
        target_include_directories(
            macscope_native_decompiler_ghidra_provider_tests
            PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src"
        )
        target_include_directories(
            macscope_native_decompiler_ghidra_provider_tests
            SYSTEM PRIVATE "${_macscope_sleigh_include_root}"
        )
        set_target_properties(
            macscope_native_decompiler_ghidra_provider_tests
            PROPERTIES CXX_EXTENSIONS OFF
        )
        target_compile_definitions(
            macscope_native_decompiler_ghidra_provider_tests
            PRIVATE
                MACSCOPE_TEST_SLEIGH_PACKAGE_ROOT="${_macscope_sleigh_package_root}"
                MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256="${MACSCOPE_ATTESTED_MANIFEST_SHA256}"
                MACSCOPE_TEST_SLEIGH_TREE_SHA256="${MACSCOPE_ATTESTED_TREE_SHA256}"
                MACSCOPE_TEST_SLEIGH_PROCESSOR_SPEC_ROOT="${_macscope_sleigh_processor_spec_root}"
        )
        target_compile_definitions(
            macscope_native_decompiler_contract_tests
            PRIVATE MACSCOPE_ENABLE_GHIDRA_PROVIDER=1
        )
        target_link_libraries(
            macscope_native_decompiler_ghidra_provider_tests
            PRIVATE
                MacScope::NativeDecompilerContract
                Threads::Threads
                sleigh::decomp
                sleigh::sla
        )
        add_test(
            NAME macscope_native_decompiler_ghidra_provider_tests
            COMMAND macscope_native_decompiler_ghidra_provider_tests
                    --scenario-group core
        )
        add_test(
            NAME macscope_native_decompiler_ghidra_provider_apple_profile_readiness_tests
            COMMAND macscope_native_decompiler_ghidra_provider_tests
                    --scenario apple-profile-readiness
        )
        add_test(
            NAME macscope_native_decompiler_ghidra_provider_target_normalization_tests
            COMMAND macscope_native_decompiler_ghidra_provider_tests
                    --scenario target-normalization
        )
        foreach(_macscope_partition_scenario IN ITEMS
            cp4-contract-corpus
            rewritten-zero-op
            rewritten-multi-owner
            standalone-autibsp
            ordinary-vim-bodies
        )
            string(REPLACE "-" "_" _macscope_partition_test_suffix "${_macscope_partition_scenario}")
            add_test(
                NAME "macscope_native_decompiler_ghidra_provider_${_macscope_partition_test_suffix}_tests"
                COMMAND macscope_native_decompiler_ghidra_provider_tests
                        --scenario "${_macscope_partition_scenario}"
            )
        endforeach()

        foreach(_macscope_pac_scenario IN ITEMS
            pac-output
            pac-memory
            pac-control
            hidden-pac-contrast
            pac-bounds
            pac-cancellation
        )
            string(REPLACE "-" "_" _macscope_pac_test_suffix "${_macscope_pac_scenario}")
            add_test(
                NAME "macscope_native_decompiler_ghidra_provider_${_macscope_pac_test_suffix}_tests"
                COMMAND macscope_native_decompiler_ghidra_provider_tests
                        --scenario "${_macscope_pac_scenario}"
            )
        endforeach()

        foreach(_macscope_authored_scenario IN ITEMS
            authored-names-and-direct-calls
            authored-complete-type-catalog
            authored-signature-merge-matrix
            authored-parameter-storage
            authored-applied-noncode-objects
            authored-atomic-unsupported
            authored-application-cancellation
        )
            string(REPLACE "-" "_" _macscope_authored_test_suffix "${_macscope_authored_scenario}")
            add_test(
                NAME "macscope_native_decompiler_ghidra_provider_${_macscope_authored_test_suffix}_tests"
                COMMAND macscope_native_decompiler_ghidra_provider_tests
                        --scenario "${_macscope_authored_scenario}"
            )
        endforeach()

        add_executable(
            macscope_native_decompiler_ghidra_provider_location_tests
            tests/GhidraProviderLocationTests.cpp
        )
        target_compile_features(
            macscope_native_decompiler_ghidra_provider_location_tests
            PRIVATE cxx_std_20
        )
        set_target_properties(
            macscope_native_decompiler_ghidra_provider_location_tests
            PROPERTIES CXX_EXTENSIONS OFF
        )
        target_compile_definitions(
            macscope_native_decompiler_ghidra_provider_location_tests
            PRIVATE
                MACSCOPE_TEST_SLEIGH_MATERIALIZATION_ROOT="${_macscope_sleigh_materialization_root}"
                MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256="${MACSCOPE_ATTESTED_MANIFEST_SHA256}"
                MACSCOPE_TEST_SLEIGH_TREE_SHA256="${MACSCOPE_ATTESTED_TREE_SHA256}"
        )
        target_link_libraries(
            macscope_native_decompiler_ghidra_provider_location_tests
            PRIVATE MacScope::NativeDecompilerContract
        )
        if(MSVC)
            target_compile_options(
                macscope_native_decompiler_ghidra_provider_location_tests PRIVATE /W4
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_ghidra_provider_location_tests PRIVATE /WX
                )
            endif()
        else()
            target_compile_options(
                macscope_native_decompiler_ghidra_provider_location_tests
                PRIVATE -Wall -Wextra -Wpedantic
            )
            if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
                target_compile_options(
                    macscope_native_decompiler_ghidra_provider_location_tests PRIVATE -Werror
                )
            endif()
        endif()
        add_test(
            NAME macscope_native_decompiler_ghidra_provider_location_tests
            COMMAND macscope_native_decompiler_ghidra_provider_location_tests
        )
    endif()
endif()

if(MACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE)

    add_executable(
        macscope_sleigh_decomp_api_probe
        probes/SleighDecompApiProbe.cpp
    )
    target_compile_features(macscope_sleigh_decomp_api_probe PRIVATE cxx_std_20)
    set_target_properties(macscope_sleigh_decomp_api_probe PROPERTIES CXX_EXTENSIONS OFF)
    target_link_libraries(
        macscope_sleigh_decomp_api_probe
        PRIVATE
            sleigh::decomp
            sleigh::sla
    )
    add_dependencies(
        macscope_sleigh_decomp_api_probe
        macscope_verify_sleigh_materialization
    )
    if(MSVC)
        target_compile_options(macscope_sleigh_decomp_api_probe PRIVATE /W4)
        if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
            target_compile_options(macscope_sleigh_decomp_api_probe PRIVATE /WX)
        endif()
    else()
        target_compile_options(macscope_sleigh_decomp_api_probe PRIVATE -Wall -Wextra -Wpedantic)
        if(MACSCOPE_NATIVE_DECOMPILER_WARNINGS_AS_ERRORS)
            target_compile_options(macscope_sleigh_decomp_api_probe PRIVATE -Werror)
        endif()
    endif()
    if(BUILD_TESTING)
        add_test(
            NAME macscope_sleigh_decomp_api_probe
            COMMAND macscope_sleigh_decomp_api_probe "${_macscope_sleigh_global_spec_root}"
        )
    endif()
endif()
