// SPDX-License-Identifier: GPL-3.0-or-later
// ProjectTenshin — ROM-free Snapdragon / Freedreno Vulkan hardware probe & self-test.
//
// Run on any Linux ARM64 Snapdragon device (or x86_64 Linux host with Vulkan/Lavapipe)
// to verify before building a user-owned DOA3 disc:
//   1. Snapdragon CPU cluster topology & online cores
//   2. Mesa Freedreno / Turnip Vulkan ICD & SDL3 GPU Vulkan device creation
//   3. Hardware texture/depth format support (BC1/BC2/BC3, BGRA8, A8, D24S8, D32S8, D32F)
//   4. MSAA 2x/4x/8x support & SPIR-V shader cache readiness
#include "thread_affinity.h"
#include "vulkan_freedreno.h"

#include <SDL3/SDL.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

int main(int argc, char **argv) {
    bool headless = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--headless") == 0) headless = true;
    }

    std::printf("=== ProjectTenshin ARM64 / Freedreno Vulkan Probe ===\n");

    const auto topo = projecttenshin::host::detect_topology();
    std::printf("[cpu] online=%zu heterogeneous=%d prime=%zu perf=%zu silver=%zu\n",
        topo.cores.size(), topo.heterogeneous ? 1 : 0,
        topo.prime_cores.size(), topo.gold_cores.size(), topo.silver_cores.size());
    for (const auto &c : topo.cores) {
        std::printf("  cpu%d: max=%lu MHz\n", c.id, c.max_freq_khz / 1000ul);
    }

    const auto fd = projecttenshin::vulkan::probe_freedreno_environment();
    std::printf("[soc] model=%s snapdragon=%d freedreno_icd=%d (%s)\n",
        fd.soc_model.empty() ? "unknown" : fd.soc_model.c_str(),
        fd.is_snapdragon ? 1 : 0,
        fd.freedreno_icd_found ? 1 : 0,
        fd.icd_path.empty() ? "none" : fd.icd_path.c_str());

    const std::string cache_dir = projecttenshin::vulkan::resolve_shader_cache_dir();
    std::printf("[cache] spirv_dir=%s\n", cache_dir.empty() ? "disabled" : cache_dir.c_str());

    if (headless) {
        std::printf("[vk] --headless mode: skipping SDL3 GPU window/device probe.\n");
        return 0;
    }

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        std::fprintf(stderr, "[vk] SDL_Init(SDL_INIT_VIDEO) failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_GPUDevice *device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, false, "vulkan");
    if (!device) {
        device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, false, nullptr);
    }
    if (!device) {
        std::fprintf(stderr, "[vk] SDL_CreateGPUDevice(SPIRV/Vulkan) failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 2;
    }

    const char *driver = SDL_GetGPUDeviceDriver(device);
    std::printf("[vk] SDL_GPU driver=%s spirv=%d\n",
        driver ? driver : "unknown",
        (SDL_GetGPUShaderFormats(device) & SDL_GPU_SHADERFORMAT_SPIRV) ? 1 : 0);

    auto check_fmt = [&](const char *name, SDL_GPUTextureFormat fmt, SDL_GPUTextureUsageFlags usage) {
        bool ok = SDL_GPUTextureSupportsFormat(device, fmt, SDL_GPU_TEXTURETYPE_2D, usage);
        std::printf("[vk] format %-20s: %s\n", name, ok ? "OK" : "UNSUPPORTED");
        return ok;
    };

    check_fmt("BGRA8_UNORM (RT)", SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
        SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);
    check_fmt("BC1_RGBA (DXT1)", SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    check_fmt("BC2_RGBA (DXT3)", SDL_GPU_TEXTUREFORMAT_BC2_RGBA_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    check_fmt("BC3_RGBA (DXT5)", SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    check_fmt("A8_UNORM", SDL_GPU_TEXTUREFORMAT_A8_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    check_fmt("D24_UNORM_S8_UINT", SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT,
        SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET);
    check_fmt("D32_FLOAT_S8_UINT", SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT,
        SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET);
    check_fmt("D32_FLOAT (water)", SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
        SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);

    for (SDL_GPUSampleCount sc : {SDL_GPU_SAMPLECOUNT_2, SDL_GPU_SAMPLECOUNT_4, SDL_GPU_SAMPLECOUNT_8}) {
        const int n = (sc == SDL_GPU_SAMPLECOUNT_2) ? 2 : (sc == SDL_GPU_SAMPLECOUNT_4) ? 4 : 8;
        bool c_ok = SDL_GPUTextureSupportsSampleCount(device, SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM, sc);
        bool d24_ok = SDL_GPUTextureSupportsSampleCount(device, SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT, sc);
        bool d32_ok = SDL_GPUTextureSupportsSampleCount(device, SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT, sc);
        std::printf("[vk] MSAA %dx: color=%d d24s8=%d d32s8=%d\n", n, c_ok, d24_ok, d32_ok);
    }

    // Check runtime shaderc availability
    const char *shaderc_names[] = {
        "libshaderc_shared.so.1", "libshaderc_shared.so", "libshaderc.so.1", "libshaderc.so"
    };
    bool shaderc_ok = false;
    for (const char *lib : shaderc_names) {
        if (SDL_SharedObject *h = SDL_LoadObject(lib)) {
            bool has_fn = SDL_LoadFunction(h, "shaderc_compile_into_spv") != nullptr;
            SDL_UnloadObject(h);
            if (has_fn) {
                std::printf("[vk] shaderc: OK (%s)\n", lib);
                shaderc_ok = true;
                break;
            }
        }
    }
    if (!shaderc_ok) {
        std::printf("[vk] shaderc: NOT FOUND (install libshaderc / bundle libshaderc_shared.so.1 in libs.aarch64/)\n");
    }

    SDL_DestroyGPUDevice(device);
    SDL_Quit();
    std::printf("=== Probe complete ===\n");
    return 0;
}
