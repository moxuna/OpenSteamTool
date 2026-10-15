# Compiles the TOML tables under <repo>/metadata/ into a generated header that
# OpenSteamTool includes, giving every build a metadata fallback that works
# offline and without waiting for the upstream tracker to publish a table for
# the current Steam build.
#
# Why: patterns and IPC tables normally come from OpenSteam001/steam-monitor at
# launch, with <Steam>/opensteamtool/ as the only fallback.  Right after a Steam
# update the tracker has nothing for the new DLL hashes, so both sources miss
# and every hook that needs them is disabled -- even though a table that works
# was known at build time.  Baking the table into the DLL makes a plain release
# zip self-contained.
#
#   opensteamtool_add_builtin_metadata(<out_var>
#       METADATA_DIR <dir>    # default: <repo>/metadata
#       OUTPUT       <file>   # default: <build>/generated/BuiltinMetadata.h
#   )
#
# Sets <out_var> to the generated header path.  Add it to a target's sources so
# the target rebuilds when a table changes.
#
# Regeneration is automatic: the tables are globbed with CONFIGURE_DEPENDS and
# listed as custom-command dependencies, so editing or adding a TOML and
# rebuilding is all it takes.

include_guard(GLOBAL)

function(opensteamtool_add_builtin_metadata out_var)
    cmake_parse_arguments(ARG "" "METADATA_DIR;OUTPUT;SRC_DIR" "" ${ARGN})

    if(NOT ARG_METADATA_DIR)
        get_filename_component(ARG_METADATA_DIR
            "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../metadata" ABSOLUTE)
    endif()

    if(NOT ARG_OUTPUT)
        set(ARG_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/BuiltinMetadata.h")
    endif()

    # Sources to scan for the identifiers the hook code asks PatternLoader for.
    # Optional: without it the generator skips the coverage check.
    if(NOT ARG_SRC_DIR)
        set(ARG_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()

    # A missing tree is not fatal here: the generator reports the empty case
    # with a proper error, and a warning at configure time is friendlier than
    # failing deep inside the build.
    if(NOT IS_DIRECTORY "${ARG_METADATA_DIR}")
        message(WARNING
            "OpenSteamTool: metadata directory '${ARG_METADATA_DIR}' does not exist; "
            "the built-in metadata fallback will be empty and hooks will be disabled "
            "whenever the remote tracker has no table for the installed Steam build.")
    endif()

    file(GLOB_RECURSE _ost_metadata_tables
        CONFIGURE_DEPENDS
        "${ARG_METADATA_DIR}/*.toml")
    list(SORT _ost_metadata_tables)

    set(_ost_generator
        "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/GenerateBuiltinMetadata.cmake")

    add_custom_command(
        OUTPUT "${ARG_OUTPUT}"
        COMMAND ${CMAKE_COMMAND}
                -DMETADATA_DIR=${ARG_METADATA_DIR}
                -DOUTPUT=${ARG_OUTPUT}
                -DSRC_DIR=${ARG_SRC_DIR}
                -DSTRICT=${OPENSTEAMTOOL_STRICT_METADATA}
                -P "${_ost_generator}"
        DEPENDS "${_ost_generator}" ${_ost_metadata_tables}
        COMMENT "Generating BuiltinMetadata.h from ${ARG_METADATA_DIR}"
        VERBATIM
    )

    set(${out_var} "${ARG_OUTPUT}" PARENT_SCOPE)
endfunction()