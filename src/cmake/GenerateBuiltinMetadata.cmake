# Generates BuiltinMetadata.h from the TOML tables under <repo>/metadata/.
#
# Run in CMake script mode (cmake -P) by opensteamtool_add_builtin_metadata();
# see src/cmake/BuiltinMetadata.cmake for the configure-time entry point.
#
# Inputs (pass with -D):
#   METADATA_DIR   root of the table tree
#   OUTPUT         the header to write
#   SRC_DIR        optional; enables the coverage check described below
#   STRICT         optional; "ON" turns coverage gaps into a fatal error
#
# Layout expected under METADATA_DIR:
#   <channel>/<component>/<sha256>.toml
# with <channel> in {pattern, ipc} and <component> in {steamclient, steamui}.
# Everything is keyed by the lower-case sha256 of the Steam DLL the table was
# derived from, which is the same key the runtime cache uses -- so a built-in
# table can only ever be applied to the DLL it was made for.
#
# Coverage check (needs SRC_DIR): a pattern table is keyed by FNV-1a(function
# name), and that name must be exactly the identifier the hook code passes to
# FindPattern(). An entry whose name matches no identifier is dead -- the hook
# reports "missing" and stays off, with no error anywhere. That is how the
# tracker's tables ended up carrying "KeyValues_ReadAsBinary" while the code
# asked for "ReadAsBinary", silently disabling KeyValues hooking.
#
# So the required identifiers are scanned out of the sources and compared with
# the union of names across all shipped pattern tables per component. Gaps are
# reported, and are fatal only when STRICT is ON (CI), because a contributor
# adding a hook cannot know the RVA for a Steam build they do not have.
#
# Implemented in CMake on purpose: this project builds with nothing but CMake
# and MSVC, and adding a scripting-language dependency for a code generator
# would be a poor trade.

if(NOT DEFINED METADATA_DIR)
    message(FATAL_ERROR "GenerateBuiltinMetadata: METADATA_DIR is not set")
endif()
if(NOT DEFINED OUTPUT)
    message(FATAL_ERROR "GenerateBuiltinMetadata: OUTPUT is not set")
endif()
if(NOT IS_DIRECTORY "${METADATA_DIR}")
    message(FATAL_ERROR "GenerateBuiltinMetadata: '${METADATA_DIR}' is not a directory")
endif()

set(_channels pattern ipc)
set(_components steamclient steamui)

set(_entries "")
set(_summary "")
set(_table_count 0)

# component -> union of every "name" seen in that component's pattern tables
set(_known_steamclient "")
set(_known_steamui "")

foreach(_channel IN LISTS _channels)
    foreach(_component IN LISTS _components)

        set(_dir "${METADATA_DIR}/${_channel}/${_component}")
        if(NOT IS_DIRECTORY "${_dir}")
            continue()
        endif()

        # No CONFIGURE_DEPENDS here: this runs in script mode, where it is not
        # supported.  The configure-time wrapper globs the tree itself.
        file(GLOB _tables "${_dir}/*.toml")
        list(SORT _tables)

        foreach(_table IN LISTS _tables)
            get_filename_component(_filename "${_table}" NAME)
            string(REGEX REPLACE "\\.toml$" "" _sha "${_filename}")

            # CMake's regex engine has no {n} interval quantifier, so check the
            # length and the alphabet separately.
            string(LENGTH "${_sha}" _sha_len)
            if(NOT _sha_len EQUAL 64 OR NOT _sha MATCHES "^[0-9a-f]+$")
                message(FATAL_ERROR
                    "GenerateBuiltinMetadata: ${_table}\n"
                    "  expected <lower-case-sha256>.toml, got '${_filename}'")
            endif()

            file(READ "${_table}" _body)

            # Normalise line endings; the repo stores LF and the TOML parser
            # does not care either way, but it keeps the generated file stable.
            string(REPLACE "\r\n" "\n" _body "${_body}")
            string(REPLACE "\r" "\n" _body "${_body}")
            string(STRIP "${_body}" _body)
            if(_body STREQUAL "")
                message(FATAL_ERROR "GenerateBuiltinMetadata: ${_table} is empty")
            endif()

            # Count section headers ([...] at the start of a line) so the
            # generated table carries a cheap sanity figure for logs.
            string(REPLACE "\n" ";" _lines "${_body}")
            set(_sections 0)
            foreach(_line IN LISTS _lines)
                if(_line MATCHES "^\\[")
                    math(EXPR _sections "${_sections} + 1")
                endif()
            endforeach()
            if(_sections EQUAL 0)
                message(FATAL_ERROR "GenerateBuiltinMetadata: ${_table} has no [section] headers")
            endif()

            # Collect the identifiers this table provides (pattern tables only).
            if(_channel STREQUAL "pattern")
                string(REGEX MATCHALL "name = \"[^\"]+\"" _name_entries "${_body}")
                foreach(_entry IN LISTS _name_entries)
                    string(REGEX REPLACE "^name = \"" "" _entry_name "${_entry}")
                    string(REGEX REPLACE "\"$" "" _entry_name "${_entry_name}")
                    list(APPEND _known_${_component} "${_entry_name}")
                endforeach()
            endif()

            # Escape for a C++ string literal. Order matters: backslashes first.
            string(REPLACE "\\" "\\\\" _escaped "${_body}")
            string(REPLACE "\"" "\\\"" _escaped "${_escaped}")
            string(REPLACE "\n" "\\n" _escaped "${_escaped}")
            string(REPLACE "\t" "\\t" _escaped "${_escaped}")

            string(APPEND _entries
                "        Table{\n"
                "            \"${_channel}\",\n"
                "            \"${_component}\",\n"
                "            \"${_sha}\",\n"
                "            ${_sections},\n"
                "            \"${_escaped}\",\n"
                "        },\n")

            math(EXPR _table_count "${_table_count} + 1")
            string(APPEND _summary "//   ${_channel}/${_component}/${_sha} (${_sections} sections)\n")

            message(STATUS
                "GenerateBuiltinMetadata: ${_channel}/${_component} ${_sha} (${_sections} sections)")
        endforeach()

    endforeach()
endforeach()

if(_table_count EQUAL 0)
    message(FATAL_ERROR
        "GenerateBuiltinMetadata: no tables found under '${METADATA_DIR}'.\n"
        "  A build with no built-in metadata silently disables every hook after a\n"
        "  Steam update, which is exactly what this fallback exists to prevent.")
endif()

# ---- coverage check -------------------------------------------------------

if(DEFINED SRC_DIR AND IS_DIRECTORY "${SRC_DIR}")

    set(_required_steamclient "")
    set(_required_steamui "")

    file(GLOB_RECURSE _sources "${SRC_DIR}/*.cpp" "${SRC_DIR}/*.h")

    foreach(_source IN LISTS _sources)
        file(READ "${_source}" _text)

        # Reduce the file to plain code before scanning, because both the macro
        # *definitions* and the prose that documents them look like call sites:
        # "#define RESOLVE_C(name) ...", the "ARM_INT3_C(name, ...)" on its
        # continuation line, and comments such as
        # "lets ARM_CAPTURE_C(name) pick up the ...".  All three would otherwise
        # contribute a bogus identifier called "name".
        string(REGEX REPLACE "//[^\n]*" "" _text "${_text}")

        # Drop preprocessor directives including every backslash continuation.
        string(REPLACE "\n" ";" _source_lines "${_text}")
        set(_code "")
        set(_in_directive FALSE)
        foreach(_line IN LISTS _source_lines)
            if(_line MATCHES "^[ \t]*#")
                set(_in_directive TRUE)
            endif()
            if(_in_directive)
                # A trailing backslash means the directive continues.
                if(NOT _line MATCHES "\\\\[ \t]*$")
                    set(_in_directive FALSE)
                endif()
                continue()
            endif()
            string(APPEND _code "${_line}\n")
        endforeach()
        set(_text "${_code}")

        # The _C suffix means steamclient64.dll, _U means steamui.dll.  These are
        # the macro families that reach PatternLoader::FindPattern; see
        # Hook/HookMacros.h and Utils/HookSupport/VehCommon.h.
        foreach(_suffix IN ITEMS C U)
            if(_suffix STREQUAL "C")
                set(_list_name _required_steamclient)
            else()
                set(_list_name _required_steamui)
            endif()

            string(REGEX MATCHALL
                "(INSTALL_HOOK_${_suffix}|RESOLVE_${_suffix}|ARM_CAPTURE_${_suffix}|ARM_INT3_${_suffix})[ \t]*\\([ \t]*[A-Za-z_][A-Za-z_0-9]*"
                _hits "${_text}")

            foreach(_hit IN LISTS _hits)
                # MATCHALL returns whole matches, so strip up to and including '('.
                string(REGEX REPLACE "^.*\\(" "" _name "${_hit}")
                string(STRIP "${_name}" _name)
                if(NOT _name STREQUAL "")
                    list(APPEND ${_list_name} "${_name}")
                endif()
            endforeach()
        endforeach()
    endforeach()

    list(REMOVE_DUPLICATES _required_steamclient)
    list(SORT _required_steamclient)
    list(REMOVE_DUPLICATES _required_steamui)
    list(SORT _required_steamui)
    list(REMOVE_DUPLICATES _known_steamclient)
    list(REMOVE_DUPLICATES _known_steamui)

    set(_gaps "")

    foreach(_component IN LISTS _components)
        foreach(_name IN LISTS _required_${_component})
            if(NOT _name IN_LIST _known_${_component})
                list(APPEND _gaps "${_component}: ${_name}")
            endif()
        endforeach()
    endforeach()

    # Entries no identifier asks for: not harmful, but they are dead weight and
    # usually mean the code was renamed without updating the table.
    set(_unused "")
    foreach(_component IN LISTS _components)
        foreach(_name IN LISTS _known_${_component})
            if(NOT _name IN_LIST _required_${_component})
                list(APPEND _unused "${_component}: ${_name}")
            endif()
        endforeach()
    endforeach()

    list(LENGTH _required_steamclient _req_client_count)
    list(LENGTH _required_steamui _req_ui_count)
    message(STATUS
        "GenerateBuiltinMetadata: coverage check against ${_req_client_count} steamclient "
        "and ${_req_ui_count} steamui identifiers")

    if(_unused)
        list(JOIN _unused "\n    " _unused_text)
        message(STATUS
            "GenerateBuiltinMetadata: table entries no hook asks for (dead entries):\n    ${_unused_text}")
    endif()

    if(_gaps)
        list(JOIN _gaps "\n    " _gaps_text)
        string(CONCAT _gaps_header
            "GenerateBuiltinMetadata: no shipped table provides these identifiers, so the\n"
            "  hooks that need them can never install:")
        if(STRICT)
            message(FATAL_ERROR "${_gaps_header}\n    ${_gaps_text}")
        else()
            message(WARNING
                "${_gaps_header}\n    ${_gaps_text}\n"
                "  Add them to a table under ${METADATA_DIR}, or configure with\n"
                "  -DOPENSTEAMTOOL_STRICT_METADATA=ON to make this fatal.")
        endif()
    else()
        message(STATUS "GenerateBuiltinMetadata: every required identifier is covered")
    endif()

endif()

# ---- emit -----------------------------------------------------------------

get_filename_component(_output_dir "${OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${_output_dir}")

set(_generated
"// Generated by src/cmake/GenerateBuiltinMetadata.cmake -- do not edit.
//
// Built-in Steam metadata tables, compiled into OpenSteamTool.dll so that a
// release works without contacting the upstream tracker and without a local
// cache.  Consulted only after the remote tracker and the on-disk cache both
// miss, and only for the exact Steam DLL sha256 the table was generated from.
//
// Tables in this build:
${_summary}
#pragma once

#include <cstddef>
#include <string_view>

namespace BuiltinMetadata {

    struct Table {
        std::string_view channel;    // \"pattern\" | \"ipc\"
        std::string_view component;  // \"steamclient\" | \"steamui\"
        std::string_view sha256;     // sha256 of the Steam DLL, lower-case hex
        std::size_t      sections;   // number of [section] headers, for diagnostics
        std::string_view body;       // the TOML document itself
    };

    inline constexpr Table kTables[] = {
${_entries}    };

    inline constexpr std::size_t kTableCount = sizeof(kTables) / sizeof(kTables[0]);

    // Returns nullptr when no built-in table matches, which is the expected case
    // for any Steam build newer than this DLL.
    inline const Table* Find(std::string_view channel,
                             std::string_view component,
                             std::string_view sha256)
    {
        for (std::size_t i = 0; i < kTableCount; ++i) {
            const Table& t = kTables[i];
            if (t.channel == channel && t.component == component && t.sha256 == sha256)
                return &t;
        }
        return nullptr;
    }

} // namespace BuiltinMetadata
")

file(WRITE "${OUTPUT}" "${_generated}")
message(STATUS "GenerateBuiltinMetadata: wrote ${OUTPUT} (${_table_count} tables)")