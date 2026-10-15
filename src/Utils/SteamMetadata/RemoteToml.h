#pragma once
#include <string>

namespace RemoteToml {

    struct Request {
        std::string channel;    // "pattern" or "ipc"
        std::string component;  // "steamclient" or "steamui"
        std::string dllPath;
    };

    struct Result {
        bool        ok           = false;   // body is usable
        bool        fromCache    = false;   // body came from the on-disk cache
        bool        fromBuiltin  = false;   // body came from BuiltinMetadata
        std::string body;
        std::string sha256;
    };

    // Resolve a channel/component/sha256 table to its TOML body.
    //
    // Lookup order, stopping at the first hit:
    //   1. the remote tracker (and its mirrors) -- authoritative
    //   2. the exact-match local cache under <Steam>/opensteamtool/
    //   3. the table compiled into this DLL, if one was generated for this sha
    //
    // The remote result is still cached to disk when it succeeds, so the local
    // cache keeps working for the next offline launch.
    Result Fetch(const Request& request);

    // Same, but skipping the network entirely -- used by tools and tests that
    // only want to know whether this DLL can resolve a table on its own.
    Result FetchLocalOnly(const Request& request);

    // Human-readable name of the tier a Result was resolved from, for logs.
    // "remote", "cache", "builtin" or "none".
    const char* SourceName(const Result& result);

} // namespace RemoteToml
