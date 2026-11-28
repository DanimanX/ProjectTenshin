// SPDX-License-Identifier: GPL-3.0-or-later
// ProjectTenshin — Qualcomm Snapdragon + Mesa Freedreno/Turnip Vulkan support layer.
//
// Provides:
// 1. Freedreno/Turnip ICD & Adreno hardware detection + `[vk]` startup telemetry.
// 2. Persistent on-disk SPIR-V shader cache so runtime GLSL->SPIR-V compilation
//    (via libshaderc) happens only once per shader across launches.
// 3. Adreno TBDR (Tile-Based Deferred Renderer) tuning switches:
//    - RECOMP_VK_DEPTH_FORMAT=auto|d24s8|d32s8 (Adreno native UBWC/LRZ D24S8 path)
//    - RECOMP_VK_SIMPLE_WATER=1 (disables 24-step SSR water raymarch on Adreno 6xx)
//    - RECOMP_FULLSCREEN=1 (forces fullscreen on Linux ARM64 handhelds)
//    - A8_UNORM fallback expansion when VK_KHR_maintenance5 is absent
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace projecttenshin::vulkan {

// Cache format header written to every cached .spv file on disk so truncated or
// mismatched entries from an older shader generator are rejected cleanly.
struct SpirvCacheHeader {
    uint32_t magic;       // 'PTSP' (0x50535450)
    uint32_t version;     // bump when GLSL generator layout changes
    uint64_t source_hash; // FNV-1a 64-bit hash of stage + GLSL source
    uint32_t word_count;  // number of uint32_t SPIR-V words following header
    uint32_t stage;       // 0 = vertex, 1 = fragment
};

constexpr uint32_t kSpirvCacheMagic = 0x50535450u;
constexpr uint32_t kSpirvCacheVersion = 1u;

inline uint64_t fnv1a_64(const void *data, size_t size, uint64_t seed = 0xcbf29ce484222325ull) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    uint64_t h = seed;
    for (size_t i = 0; i < size; ++i) {
        h ^= bytes[i];
        h *= 0x100000001b3ull;
    }
    return h;
}

inline uint64_t spirv_cache_key(const std::string &glsl_source, uint32_t stage) {
    uint64_t h = fnv1a_64(&stage, sizeof(stage));
    return fnv1a_64(glsl_source.data(), glsl_source.size(), h);
}

inline std::string resolve_shader_cache_dir() {
    if (const char *disable = std::getenv("PROJECTTENSHIN_DISABLE_SHADER_CACHE")) {
        if (std::strcmp(disable, "1") == 0) return {};
    }
    if (const char *custom = std::getenv("PROJECTTENSHIN_SHADER_CACHE")) {
        if (custom[0] != '\0') return std::string(custom);
    }
    if (const char *xdg = std::getenv("XDG_CACHE_HOME")) {
        if (xdg[0] != '\0') return std::string(xdg) + "/projecttenshin/spirv-cache";
    }
    if (const char *home = std::getenv("HOME")) {
        if (home[0] != '\0') return std::string(home) + "/.cache/projecttenshin/spirv-cache";
    }
    return {};
}

inline std::filesystem::path spirv_cache_file_path(
    const std::string &cache_dir, uint64_t key, uint32_t stage) {
    char name[64];
    std::snprintf(name, sizeof(name), "v%u_%s_%016llx.ptspv",
        kSpirvCacheVersion, stage == 0u ? "vs" : "fs",
        static_cast<unsigned long long>(key));
    return std::filesystem::path(cache_dir) / name;
}

inline bool spirv_cache_load_from_dir(
    const std::string &cache_dir, const std::string &glsl_source, uint32_t stage,
    std::vector<uint32_t> &out_spv) {
    if (cache_dir.empty()) return false;
    const uint64_t key = spirv_cache_key(glsl_source, stage);
    const auto path = spirv_cache_file_path(cache_dir, key, stage);
    std::ifstream in(path, std::ios::binary);
    if (!in.is_open()) return false;

    SpirvCacheHeader hdr{};
    in.read(reinterpret_cast<char *>(&hdr), sizeof(hdr));
    if (!in || hdr.magic != kSpirvCacheMagic || hdr.version != kSpirvCacheVersion ||
        hdr.source_hash != key || hdr.stage != stage ||
        hdr.word_count == 0u || hdr.word_count > (4u * 1024u * 1024u)) {
        return false;
    }

    std::vector<uint32_t> words(hdr.word_count);
    in.read(reinterpret_cast<char *>(words.data()),
            static_cast<std::streamsize>(hdr.word_count * sizeof(uint32_t)));
    if (!in) return false;
    // Validate SPIR-V magic word (0x07230203)
    if (words[0] != 0x07230203u) return false;

    out_spv = std::move(words);
    return true;
}

inline bool spirv_cache_save_to_dir(
    const std::string &cache_dir, const std::string &glsl_source, uint32_t stage,
    const std::vector<uint32_t> &spv) {
    if (cache_dir.empty() || spv.empty() || spv[0] != 0x07230203u) return false;
    std::error_code ec;
    std::filesystem::create_directories(cache_dir, ec);
    if (ec) return false;

    const uint64_t key = spirv_cache_key(glsl_source, stage);
    const auto final_path = spirv_cache_file_path(cache_dir, key, stage);
    auto tmp_path = final_path;
    tmp_path += ".tmp";

    SpirvCacheHeader hdr{};
    hdr.magic = kSpirvCacheMagic;
    hdr.version = kSpirvCacheVersion;
    hdr.source_hash = key;
    hdr.word_count = static_cast<uint32_t>(spv.size());
    hdr.stage = stage;

    {
        std::ofstream out(tmp_path, std::ios::binary | std::ios::trunc);
        if (!out.is_open()) return false;
        out.write(reinterpret_cast<const char *>(&hdr), sizeof(hdr));
        out.write(reinterpret_cast<const char *>(spv.data()),
                  static_cast<std::streamsize>(spv.size() * sizeof(uint32_t)));
        if (!out.good()) {
            std::filesystem::remove(tmp_path, ec);
            return false;
        }
    }
    std::filesystem::rename(tmp_path, final_path, ec);
    if (ec) {
        std::filesystem::remove(tmp_path, ec);
        return false;
    }
    return true;
}

inline bool spirv_cache_load(
    const std::string &glsl_source, uint32_t stage, std::vector<uint32_t> &out_spv) {
    return spirv_cache_load_from_dir(resolve_shader_cache_dir(), glsl_source, stage, out_spv);
}

inline bool spirv_cache_save(
    const std::string &glsl_source, uint32_t stage, const std::vector<uint32_t> &spv) {
    return spirv_cache_save_to_dir(resolve_shader_cache_dir(), glsl_source, stage, spv);
}

struct FreedrenoInfo {
    bool is_snapdragon = false;
    bool freedreno_icd_found = false;
    std::string icd_path;
    std::string soc_model;
};

inline std::string read_trimmed_file(const char *path) {
    std::ifstream in(path);
    if (!in.is_open()) return {};
    std::string line;
    std::getline(in, line, '\0');
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r' || line.back() == '\0' || line.back() == ' ')) {
        line.pop_back();
    }
    return line;
}

inline FreedrenoInfo probe_freedreno_environment() {
    FreedrenoInfo info;
#if defined(__linux__)
    info.soc_model = read_trimmed_file("/proc/device-tree/model");
    if (info.soc_model.empty()) {
        info.soc_model = read_trimmed_file("/sys/devices/soc0/soc_id");
    }
    std::string compat = read_trimmed_file("/proc/device-tree/compatible");
    auto contains_ci = [](const std::string &hay, const char *needle) {
        if (hay.empty() || !needle) return false;
        std::string h = hay;
        std::string n = needle;
        for (char &c : h) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        for (char &c : n) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        return h.find(n) != std::string::npos;
    };
    if (contains_ci(info.soc_model, "qualcomm") || contains_ci(info.soc_model, "snapdragon") ||
        contains_ci(info.soc_model, "qcom") || contains_ci(info.soc_model, "sm8") ||
        contains_ci(info.soc_model, "sdm8") || contains_ci(info.soc_model, "adreno") ||
        contains_ci(compat, "qcom,")) {
        info.is_snapdragon = true;
    }

    const char *icd_candidates[] = {
        "/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json",
        "/usr/share/vulkan/icd.d/freedreno_icd.json",
        "/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json",
        "/etc/vulkan/icd.d/freedreno_icd.aarch64.json"
    };
    for (const char *cand : icd_candidates) {
        std::error_code ec;
        if (std::filesystem::exists(cand, ec)) {
            info.freedreno_icd_found = true;
            info.icd_path = cand;
            break;
        }
    }
    if (const char *env_icd = std::getenv("VK_DRIVER_FILES")) {
        if (contains_ci(env_icd, "freedreno")) {
            info.freedreno_icd_found = true;
            info.icd_path = env_icd;
        }
    } else if (const char *env_icd2 = std::getenv("VK_ICD_FILENAMES")) {
        if (contains_ci(env_icd2, "freedreno")) {
            info.freedreno_icd_found = true;
            info.icd_path = env_icd2;
        }
    }
#endif
    return info;
}

enum class DepthPreference {
    Auto,
    PreferD24S8,
    PreferD32S8,
};

inline DepthPreference parse_depth_preference(const char *env_val) {
    if (!env_val || env_val[0] == '\0') return DepthPreference::Auto;
    if (std::strcmp(env_val, "d24s8") == 0 || std::strcmp(env_val, "D24S8") == 0) {
        return DepthPreference::PreferD24S8;
    }
    if (std::strcmp(env_val, "d32s8") == 0 || std::strcmp(env_val, "D32S8") == 0) {
        return DepthPreference::PreferD32S8;
    }
    return DepthPreference::Auto;
}

inline bool simple_water_requested() {
    const char *v = std::getenv("RECOMP_VK_SIMPLE_WATER");
    return v != nullptr && std::strcmp(v, "1") == 0;
}

inline bool fullscreen_requested() {
    const char *v = std::getenv("RECOMP_FULLSCREEN");
    return v != nullptr && std::strcmp(v, "1") == 0;
}

} // namespace projecttenshin::vulkan
