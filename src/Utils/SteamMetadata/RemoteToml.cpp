#include "RemoteToml.h"
#include "BuiltinMetadata.h"
#include "OSTPlatform/include/Http.h"
#include "Utils/Config/Config.h"
#include "Utils/Logging/Log.h"
#include "Utils/SteamMetadata/SteamDiagnostics.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string_view>
#include <vector>

namespace RemoteToml {

namespace {
    constexpr const char* kGithubTemplate =
        "https://raw.githubusercontent.com/OpenSteam001/steam-monitor/"
        "{channel}/{component}/{sha256}.toml";
    constexpr const char* kJsdelivrTemplate =
        "https://cdn.jsdelivr.net/gh/OpenSteam001/steam-monitor@"
        "{channel}/{component}/{sha256}.toml";

    static bool HasPlaceholder(std::string_view text, std::string_view placeholder)
    {
        return text.find(placeholder) != std::string_view::npos;
    }

    static bool IsValidTemplate(std::string_view urlTemplate)
    {
        return HasPlaceholder(urlTemplate, "{channel}") &&
               HasPlaceholder(urlTemplate, "{component}") &&
               HasPlaceholder(urlTemplate, "{sha256}");
    }

    static void ReplaceAll(std::string& text,
                           std::string_view from,
                           std::string_view to)
    {
        size_t pos = 0;
        while ((pos = text.find(from, pos)) != std::string::npos) {
            text.replace(pos, from.size(), to);
            pos += to.size();
        }
    }

    static std::string ExpandTemplate(std::string urlTemplate,
                                      const Request& request,
                                      std::string_view sha256)
    {
        ReplaceAll(urlTemplate, "{channel}", request.channel);
        ReplaceAll(urlTemplate, "{component}", request.component);
        ReplaceAll(urlTemplate, "{sha256}", sha256);
        return urlTemplate;
    }

    static std::vector<std::string> BuildUrlTemplates()
    {
        const std::string remoteUrlTemplate = Config::GetRemoteUrlTemplate();
        if (remoteUrlTemplate.empty())
            return { kGithubTemplate, kJsdelivrTemplate };

        if (!IsValidTemplate(remoteUrlTemplate)) {
            LOG_WARN("RemoteToml: remote.url_template must contain "
                     "{channel}, {component}, and {sha256}; remote fetch disabled");
            return {};
        }

        return { remoteUrlTemplate };
    }
    // ── fallback tiers ─────────────────────────────────────────────────
    // Both helpers return true when they filled `out` with a usable body.

    // Tier 2: the exact-match entry in <Steam>/opensteamtool/<channel>/...
    static bool TryCache(const std::filesystem::path& cachePath,
                         const std::string& cachePathText,
                         const Request& request,
                         const std::string& lastUrl,
                         long lastStatus,
                         Result& out)
    {
        namespace fs = std::filesystem;
        if (!fs::exists(cachePath)) return false;

        std::ifstream ifs(cachePath, std::ios::binary);
        if (!ifs) {
            LOG_WARN("RemoteToml({}/{}): could not open cache file: {}",
                     request.channel, request.component, cachePathText);
            return false;
        }

        std::string buf((std::istreambuf_iterator<char>(ifs)),
                         std::istreambuf_iterator<char>());
        if (buf.empty()) {
            LOG_WARN("RemoteToml({}/{}): cache file empty: {}",
                     request.channel, request.component, cachePathText);
            return false;
        }

        LOG_WARN("RemoteToml({}/{}): remote failed (last URL {} HTTP {}); "
                 "falling back to local cache {}",
                 request.channel, request.component,
                 lastUrl.empty() ? "<none>" : lastUrl, lastStatus, cachePathText);

        out.body      = std::move(buf);
        out.ok        = true;
        out.fromCache = true;
        return true;
    }

    // Tier 3: the table baked into this DLL.  Only matches the exact Steam DLL
    // sha256 the table was generated from, so it goes inert by itself once
    // Steam ships a new client and the user updates OpenSteamTool.
    static bool TryBuiltin(const Request& request, Result& out)
    {
        const BuiltinMetadata::Table* t =
            BuiltinMetadata::Find(request.channel, request.component, out.sha256);
        if (!t) return false;

        LOG_INFO("RemoteToml({}/{}): using built-in table for {} ({} sections)",
                 request.channel, request.component, out.sha256, t->sections);

        out.body       = std::string(t->body);
        out.ok         = true;
        out.fromBuiltin = true;
        return true;
    }
} // namespace

Result Fetch(const Request& request)
{
    namespace fs = std::filesystem;
    Result out;

    // 1. SHA-256 of the DLL.
    const auto hashStart = std::chrono::steady_clock::now();
    out.sha256 = SteamDiagnostics::Sha256Of(request.dllPath);
    const auto hashMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - hashStart).count();

    if (out.sha256.empty()) {
        LOG_WARN("RemoteToml({}/{}): Sha256OfFile failed for {} ({} ms)",
                 request.channel, request.component, request.dllPath, hashMs);
        return out;
    }
    LOG_INFO("RemoteToml({}/{}): sha256 = {} ({} ms)",
             request.channel, request.component, out.sha256, hashMs);

    // 2. Cache path & dir.
    fs::path steamRoot = fs::path(request.dllPath).parent_path();
    fs::path cacheDir  = steamRoot / "opensteamtool" / request.channel / request.component;
    fs::path cachePath = cacheDir / (out.sha256 + ".toml");
    const std::string cachePathText = cachePath.string();

    std::error_code mkdirEc;
    fs::create_directories(cacheDir, mkdirEc);
    if (mkdirEc) {
        LOG_WARN("RemoteToml({}/{}): could not create cache dir {} ({})",
                 request.channel, request.component, cacheDir.string(), mkdirEc.message());
    }

    // 3. Try remote (mirror chain with early-out on 404).
    const std::vector<std::string> urlTemplates = BuildUrlTemplates();
    OSTPlatform::Http::Result http;
    std::string lastUrl;

    for (size_t i = 0; i < urlTemplates.size(); ++i) {
        lastUrl = ExpandTemplate(urlTemplates[i], request, out.sha256);
        LOG_INFO("RemoteToml({}/{}): downloading {}",
                 request.channel, request.component, lastUrl);

        http = OSTPlatform::Http::Execute(L"GET", lastUrl.c_str(),
                                          nullptr, 0, nullptr);

        if (http.ok && http.status == 200) break;

        if (http.ok && http.status == 404) {
            LOG_WARN("RemoteToml({}/{}): mirror has no such file (HTTP 404): {}",
                     request.channel, request.component, lastUrl);
            break;   // all mirrors serve same data
        }

        if (i + 1 < urlTemplates.size()) {
            LOG_WARN("RemoteToml({}/{}): mirror failed ({} ok={} HTTP={}), falling back",
                     request.channel, request.component, lastUrl, http.ok, http.status);
        }
    }

    // 4. Remote OK → write cache, return body.
    if (http.ok && http.status == 200 && !http.body.empty()) {
        std::ofstream ofs(cachePath, std::ios::binary);
        if (ofs) {
            ofs.write(http.body.data(),
                      static_cast<std::streamsize>(http.body.size()));
            LOG_INFO("RemoteToml({}/{}): cached to {}",
                     request.channel, request.component, cachePathText);
        } else {
            LOG_WARN("RemoteToml({}/{}): could not open {} for writing",
                     request.channel, request.component, cachePathText);
        }
        out.body = std::move(http.body);
        out.ok = true;
        return out;
    }

    // 5. Remote failed → fall back to whatever is cached for this exact SHA.
    if (TryCache(cachePath, cachePathText, request, lastUrl, http.status, out)) {
        return out;
    }

    // 6. Still nothing → the table compiled into this DLL, if the build shipped
    //    one for this exact Steam DLL.  This is what makes a plain release zip
    //    work with no network and no cache: the metadata travels with the DLL.
    if (TryBuiltin(request, out)) {
        return out;
    }

    // 7. Total failure — caller handles popup / degraded mode.
    LOG_WARN("RemoteToml({}/{}): no source available (last URL: {} HTTP {}; "
             "no local cache, no built-in table for {})",
             request.channel, request.component,
             lastUrl.empty() ? "<none>" : lastUrl, http.status, out.sha256);
    return out;
}
Result FetchLocalOnly(const Request& request)
{
    namespace fs = std::filesystem;
    Result out;

    out.sha256 = SteamDiagnostics::Sha256Of(request.dllPath);
    if (out.sha256.empty()) {
        LOG_WARN("RemoteToml({}/{}): Sha256OfFile failed for {}",
                 request.channel, request.component, request.dllPath);
        return out;
    }

    const fs::path steamRoot = fs::path(request.dllPath).parent_path();
    const fs::path cachePath = steamRoot / "opensteamtool" / request.channel
                             / request.component / (out.sha256 + ".toml");

    if (TryCache(cachePath, cachePath.string(), request, {}, 0, out))
        return out;

    TryBuiltin(request, out);
    return out;
}

const char* SourceName(const Result& result)
{
    if (!result.ok)         return "none";
    if (result.fromBuiltin) return "builtin";
    if (result.fromCache)   return "cache";
    return "remote";
}

} // namespace RemoteToml
