# Snapdragon & Mesa Freedreno / Turnip Vulkan Guide

**ProjectTenshin** targets Linux ARM64 devices powered by **Qualcomm Snapdragon** SoCs running the open-source **Mesa Freedreno / Turnip** Vulkan driver (`libvulkan_freedreno.so`).

---

## 1. Runtime Prerequisites on the Snapdragon Device

On Debian / Ubuntu ARM64, Arch Linux ARM, PostmarketOS, or ROCKNIX Snapdragon images, make sure the following userspace libraries are installed:

- **Mesa Freedreno / Turnip Vulkan ICD** (`freedreno_icd.aarch64.json` + `libvulkan_freedreno.so`, Mesa 24.0+ recommended for full Vulkan 1.3 + `VK_KHR_maintenance5` support)
- **Vulkan Loader** (`libvulkan.so.1`)
- **SDL3** (`libSDL3.so.0` >= 3.4.0, or built from source and placed into `libs.aarch64/`)
- **shaderc** (`libshaderc_shared.so.1` or `libshaderc.so.1`, used on first run to compile generated GLSL shaders to SPIR-V before caching them to disk)

### Package commands by distribution

**Arch Linux ARM:**
```bash
sudo pacman -S vulkan-freedreno vulkan-icd-loader sdl3 shaderc
```

**Debian / Ubuntu ARM64:**
```bash
sudo apt-get install mesa-vulkan-drivers libvulkan1 libshaderc1
# If your distro does not yet package SDL3, build SDL3 3.4.12 and place libSDL3.so.0 in libs.aarch64/
```

---

## 2. Verifying Your Hardware Before Building the Game

Run the ROM-free Vulkan hardware probe shipped in the release archive:

```bash
./tenshin_vk_probe.aarch64
```

What to look for in the output:
- `[cpu]`: Confirms detected Snapdragon heterogeneous Prime / Gold / Silver core tiers and online CPUs.
- `[soc]`: Confirms Qualcomm Snapdragon detection and `/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json`.
- `[vk] SDL_GPU driver=vulkan spirv=1`: Confirms SDL3 selected Vulkan with SPIR-V shader support.
- `[vk] format BC1_RGBA / BC2_RGBA / BC3_RGBA: OK`: Adreno 6xx/7xx hardware DXT texture decompression.
- `[vk] format D24_UNORM_S8_UINT: OK`: Adreno native tiled depth-stencil format (UBWC + LRZ fast path).
- `[vk] format A8_UNORM`: If `UNSUPPORTED` on older Mesa (< 24.0), ProjectTenshin automatically expands A8 textures to `BGRA8` on upload with zero visual artifacts.
- `[vk] shaderc: OK`: Confirms runtime GLSL→SPIR-V compilation is ready.

You can also run the ROM-free AArch64 runtime self-tests on your device:

```bash
./tenshin_freedreno_test.aarch64
./tenshin_runtime_test.aarch64
```

---

## 3. Freedreno / Turnip Engineering Notes

### Adreno TBDR & Depth-Stencil (`D24_UNORM_S8_UINT`)
Qualcomm Adreno GPUs are Tile-Based Deferred Renderers (TBDR) with hardware **UBWC** (Universal Bandwidth Compression) and **LRZ** (Low-Resolution Z). While desktop x86 GPUs default to `D32_FLOAT_S8_UINT`, Adreno natively accelerates `VK_FORMAT_D24_UNORM_S8_UINT` inside on-chip GMEM tile memory — matching the original Xbox NV2A's native D24S8 depth buffer. ProjectTenshin automatically selects `D24_UNORM_S8_UINT` when Freedreno/Snapdragon is detected (`RECOMP_VK_DEPTH_FORMAT=auto`). Override with `RECOMP_VK_DEPTH_FORMAT=d32s8` if needed.

### Persistent SPIR-V Disk Shader Cache
DOA3 dynamically submits Xbox NV2A vertex programs and fixed-function FVF combinations that `d3d_presenter_sdl_gpu.cpp` translates to GLSL 450 and compiles with `libshaderc`. On mobile ARM64 CPUs, recompiling shaders on every boot causes frame spikes. ProjectTenshin caches validated SPIR-V binaries (`v1_{vs,fs}_<fnv64>.ptspv`) in `$PROJECTTENSHIN_SHADER_CACHE` (default `~/.cache/projecttenshin/spirv`). After the first playthrough of a stage, shaders load in under 1 ms without invoking `shaderc`.

### Modern Water vs. Adreno 6xx Bandwidth (`RECOMP_VK_SIMPLE_WATER`)
`doa3-re`'s SDL_GPU presenter includes a 24-step raymarched screen-space reflection water shader plus an extra single-sample depth pass on water stages. On **Adreno 740 / A32** (Snapdragon 8 Gen 2 / G3x Gen 2), this runs comfortably at 60 FPS. On **Adreno 630 / 650** (Snapdragon 845 / 865) at 2×–3× resolution, set `RECOMP_VK_SIMPLE_WATER=1` in `tenshin.env` to skip the extra depth pass and raymarch for locked 60 FPS.

### Snapdragon big.LITTLE Scheduling (`PROJECTTENSHIN_PIN_PERF`)
`platform/arm64/thread_affinity.h` inspects `/sys/devices/system/cpu/online` and each core's `cpufreq/cpuinfo_max_freq` to separate Prime, Gold, and Silver clusters. Before SDL3/Vulkan initializes, the process mask is explicitly widened to all online cores so Mesa Freedreno/Turnip compiler and submission threads never get trapped on one CPU. When `PROJECTTENSHIN_PIN_PERF=1` (enabled by default in `run_arm64_vulkan.sh`), the Xbox guest thread runs on the Prime/Gold performance cluster while audio and driver workers stay free across all cores.

---

## 4. Supported Disc Revisions & DOA3++

ProjectTenshin inherits `doa3-re`'s authenticated disc recipes:
- **Dead or Alive 3 — Japan 3.1** (XDK 4134, primary target with 3.1 moves, balance, and costumes)
- **Dead or Alive 3 — USA 3.0** (XDK 3925)
- **Dead or Alive 3 — Europe 3.2** (XDK 4134, in bring-up)

When building locally with `tools/build-arm64-game.sh`, the script verifies the generated C manifest SHA-256 against the validated upstream recipe before cross-compiling `doa3.aarch64`.
