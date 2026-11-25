// SPDX-License-Identifier: GPL-3.0-or-later
// Unit tests for ProjectTenshin's Snapdragon CPU topology classifier and
// Freedreno/Turnip Vulkan persistent SPIR-V shader cache.
#include "thread_affinity.h"
#include "vulkan_freedreno.h"

#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

static void test_cpulist_parsing() {
    auto a = projecttenshin::arm64::parse_cpulist("0-7\n");
    assert(a.size() == 8 && a.front() == 0 && a.back() == 7);

    auto b = projecttenshin::arm64::parse_cpulist("0,3,5-7");
    assert(b.size() == 5);
    assert(b[0] == 0 && b[1] == 3 && b[2] == 5 && b[3] == 6 && b[4] == 7);

    auto c = projecttenshin::arm64::parse_cpulist("");
    assert(c.empty());
}

static void test_snapdragon_cluster_classification() {
    // Snapdragon 865 (Retroid Pocket 5): 4x A55 @ 1.8GHz, 3x A77 @ 2.42GHz, 1x A77 @ 2.84GHz
    std::vector<projecttenshin::arm64::CpuCoreInfo> sd865 = {
        {0, 1804800, true}, {1, 1804800, true}, {2, 1804800, true}, {3, 1804800, true},
        {4, 2419200, true}, {5, 2419200, true}, {6, 2419200, true},
        {7, 2841600, true},
    };
    auto t865 = projecttenshin::arm64::classify_topology(sd865);
    assert(t865.heterogeneous);
    assert(t865.prime_cores.size() == 1 && t865.prime_cores[0] == 7);
    assert(t865.gold_cores.size() == 4); // cores 4, 5, 6, 7
    assert(t865.silver_cores.size() == 4); // cores 0, 1, 2, 3

    // Snapdragon 8 Gen 2 (AYN Odin 2): 3x A510 @ 2.02GHz, 4x Gold @ 2.8GHz, 1x X3 @ 3.19GHz
    std::vector<projecttenshin::arm64::CpuCoreInfo> sd8g2 = {
        {0, 2016000, true}, {1, 2016000, true}, {2, 2016000, true},
        {3, 2803200, true}, {4, 2803200, true}, {5, 2803200, true}, {6, 2803200, true},
        {7, 3187200, true},
    };
    auto t8g2 = projecttenshin::arm64::classify_topology(sd8g2);
    assert(t8g2.heterogeneous);
    assert(t8g2.prime_cores.size() == 1 && t8g2.prime_cores[0] == 7);
    assert(t8g2.gold_cores.size() == 5);
    assert(t8g2.silver_cores.size() == 3);

    // Homogeneous 4-core CPU
    std::vector<projecttenshin::arm64::CpuCoreInfo> uniform = {
        {0, 1512000, true}, {1, 1512000, true}, {2, 1512000, true}, {3, 1512000, true},
    };
    auto tuni = projecttenshin::arm64::classify_topology(uniform);
    assert(!tuni.heterogeneous);
    assert(tuni.prime_cores.size() == 4);
}

static void test_spirv_disk_cache() {
    namespace pv = projecttenshin::vulkan;
    const auto dir = (std::filesystem::temp_directory_path() / "projecttenshin_spv_cache_test").string();
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);

    const std::string glsl = "#version 450\nvoid main() { gl_Position = vec4(0.0); }\n";
    const std::vector<uint32_t> fake_spv = {0x07230203u, 0x00010000u, 0x0008000au, 0x00000005u, 0x00000000u};

    std::vector<uint32_t> loaded;
    assert(!pv::spirv_cache_load_from_dir(dir, glsl, 0u, loaded));
    assert(pv::spirv_cache_save_to_dir(dir, glsl, 0u, fake_spv));
    assert(pv::spirv_cache_load_from_dir(dir, glsl, 0u, loaded));
    assert(loaded == fake_spv);

    // Different stage must not collide
    loaded.clear();
    assert(!pv::spirv_cache_load_from_dir(dir, glsl, 1u, loaded));

    // Reject invalid SPIR-V magic on save
    const std::vector<uint32_t> bad_spv = {0xdeadbeefu, 1u, 2u};
    assert(!pv::spirv_cache_save_to_dir(dir, glsl, 1u, bad_spv));

    // Reject corrupted cache file on load
    const auto key = pv::spirv_cache_key(glsl, 0u);
    const auto path = pv::spirv_cache_file_path(dir, key, 0u);
    {
        std::ofstream corrupt(path, std::ios::binary | std::ios::trunc);
        corrupt << "corrupted-bytes";
    }
    loaded.clear();
    assert(!pv::spirv_cache_load_from_dir(dir, glsl, 0u, loaded));

    std::filesystem::remove_all(dir, ec);
}

static void test_depth_preference() {
    using projecttenshin::vulkan::DepthPreference;
    using projecttenshin::vulkan::parse_depth_preference;
    assert(parse_depth_preference(nullptr) == DepthPreference::Auto);
    assert(parse_depth_preference("") == DepthPreference::Auto);
    assert(parse_depth_preference("d24s8") == DepthPreference::PreferD24S8);
    assert(parse_depth_preference("D24S8") == DepthPreference::PreferD24S8);
    assert(parse_depth_preference("d32s8") == DepthPreference::PreferD32S8);
    assert(parse_depth_preference("unknown") == DepthPreference::Auto);
}

int main() {
    test_cpulist_parsing();
    test_snapdragon_cluster_classification();
    test_spirv_disk_cache();
    test_depth_preference();
    std::printf("ProjectTenshin Freedreno/Snapdragon ARM64 tests passed.\n");
    return 0;
}
