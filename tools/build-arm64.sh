#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile ProjectTenshin (ROM-free distributable ARM64 Vulkan runtime
# library, Freedreno hardware probe, ARM64 runtime self-tests, and SDL3 launcher)
# for Linux ARM64 Qualcomm Snapdragon devices running Mesa Freedreno / Turnip
# Vulkan (glibc <= 2.28), and assemble a clean Linux ARM64 release archive.
#
# Zero copyrighted game binaries, assets, or ROM-derived code ever enter this package.
#
# Usage:
#   tools/build-arm64.sh                       # default CPU: cortex_a77 (Snapdragon 865/870)
#   TARGET_CPU=cortex_x3 tools/build-arm64.sh  # Snapdragon 8 Gen 2 / G3x Gen 2
#   TARGET_CPU=generic tools/build-arm64.sh    # generic ARMv8-A Snapdragon Linux
set -euo pipefail
cd "$(dirname "$0")/.."

DEPS="$PWD/deps"
EXTERN="$PWD/extern"
BDIR="$PWD/build-arm64"
OUT="$PWD/dist/ProjectTenshin-Linux-ARM64-Vulkan"
TAROUT="$PWD/dist/ProjectTenshin-Linux-ARM64-Vulkan.tar.gz"
TARGET_CPU="${TARGET_CPU:-cortex_a77}"
TARGET_CPU="${TARGET_CPU//-/_}"
TARGET_TRIPLE="aarch64-linux-gnu.2.28"
JOBS="${JOBS:-$(nproc)}"

ZIG_VER="0.17.0"
ZIG_SHA="1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026"
SDL3_VER="3.4.12"
SDL3_SHA="f07b958a9ac5020fb7a44cadb957f658b2149c3c8abb4f63145fac9303249db7"
IMGUI_VER="1.91.9"
IMGUI_SHA="3872a5f90df78fced023c1945f4466b654fd74573370b77b17742149763a7a7c"

mkdir -p "$DEPS/dl" "$EXTERN" "$BDIR/obj" "$BDIR/rt" "$BDIR/ui"

fetch_file() {
    local url="$1" name="$2" sha="$3"
    if [ ! -f "$DEPS/dl/$name" ]; then
        curl -fsSL --retry 3 -o "$DEPS/dl/$name.part" "$url"
        mv "$DEPS/dl/$name.part" "$DEPS/dl/$name"
    fi
    echo "$sha  $DEPS/dl/$name" | sha256sum -c --quiet || {
        echo "ERROR: SHA-256 mismatch for $DEPS/dl/$name" >&2
        exit 1
    }
}

# 1. Host Zig compiler (hermetic aarch64-linux-gnu.2.28 C/C++17 cross-compiler)
if [ ! -x "$DEPS/zig-linux/zig" ]; then
    echo "[1/6] Fetching Zig $ZIG_VER..."
    fetch_file "https://ziglang.org/download/$ZIG_VER/zig-x86_64-linux-$ZIG_VER.tar.xz" \
        "zig-x86_64-linux-$ZIG_VER.tar.xz" "$ZIG_SHA"
    tar -C "$DEPS" -xJf "$DEPS/dl/zig-x86_64-linux-$ZIG_VER.tar.xz"
    rm -rf "$DEPS/zig-linux"
    mv "$DEPS/zig-x86_64-linux-$ZIG_VER" "$DEPS/zig-linux"
fi
ZIG_BIN="$DEPS/zig-linux/zig"
export ZIG_GLOBAL_CACHE_DIR="$DEPS/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$DEPS/zig-cache"

# 2. Pinned upstream SDL3 3.4.12 headers & Dear ImGui 1.91.9
echo "[2/6] Checking pinned dependencies (SDL3 $SDL3_VER, Dear ImGui $IMGUI_VER)..."
if [ ! -d "$DEPS/sdl3-src/SDL3-$SDL3_VER/include" ]; then
    fetch_file "https://github.com/libsdl-org/SDL/releases/download/release-$SDL3_VER/SDL3-$SDL3_VER.tar.gz" \
        "SDL3-$SDL3_VER.tar.gz" "$SDL3_SHA"
    rm -rf "$DEPS/sdl3-src" && mkdir -p "$DEPS/sdl3-src"
    tar -C "$DEPS/sdl3-src" -xzf "$DEPS/dl/SDL3-$SDL3_VER.tar.gz"
fi
SDL3_INC="$DEPS/sdl3-src/SDL3-$SDL3_VER/include"

if [ ! -f "$EXTERN/imgui/imgui.cpp" ]; then
    fetch_file "https://github.com/ocornut/imgui/archive/refs/tags/v$IMGUI_VER.tar.gz" \
        "imgui-$IMGUI_VER.tar.gz" "$IMGUI_SHA"
    rm -rf "$EXTERN/imgui"
    tar -C "$EXTERN" -xzf "$DEPS/dl/imgui-$IMGUI_VER.tar.gz"
    mv "$EXTERN/imgui-$IMGUI_VER" "$EXTERN/imgui"
fi

# 3. Cross-compile core recomp-runtime C/C++/ARM64-ASM objects for Snapdragon AArch64
echo "[3/6] Cross-compiling ProjectTenshin runtime for $TARGET_TRIPLE ($TARGET_CPU, Vulkan, -j$JOBS)..."

COMMON_FLAGS="-target $TARGET_TRIPLE -mcpu=$TARGET_CPU -O2 -ffp-contract=off -fno-strict-aliasing -fwrapv \
  -D_GNU_SOURCE -DRECOMP_D3D_FRAME_ENABLED -DRECOMP_DSOUND_TEST_CLOCK -DRECOMP_DOAXBV_BINDINGS -DRECOMP_PUBLIC_LEAF_FIXTURE \
  -Irecomp-runtime -Iplatform/linux -Ixbe -I$SDL3_INC -I$EXTERN/imgui"

RT_C_SRCS=(
    recomp-runtime/runtime.c
    recomp-runtime/recomp_math.c
    recomp-runtime/stop_report.c
    recomp-runtime/runtime_test.c
    recomp-runtime/device_model.c
    recomp-runtime/device_model_test.c
    recomp-runtime/d3d_creation_model.c
    recomp-runtime/d3d_creation_adapter.c
    recomp-runtime/d3d_creation_model_test.c
    recomp-runtime/d3d_draw_model.c
    recomp-runtime/d3d_draw_adapter.c
    recomp-runtime/d3d_draw_model_test.c
    recomp-runtime/d3d_frame_model.c
    recomp-runtime/d3d_frame_model_test.c
    recomp-runtime/d3d_frame_adapter.c
    recomp-runtime/d3d_frame_adapter_test.c
    recomp-runtime/d3d_miniport_adapter.c
    recomp-runtime/d3d_miniport_adapter_test.c
    recomp-runtime/d3d_presenter_memory.c
    recomp-runtime/d3d_presenter_memory_test.c
    recomp-runtime/d3d_render_state_model.c
    recomp-runtime/d3d_render_state_adapter.c
    recomp-runtime/d3d_render_state_model_test.c
    recomp-runtime/d3d_texture_model.c
    recomp-runtime/d3d_texture_adapter.c
    recomp-runtime/d3d_texture_model_test.c
    recomp-runtime/d3d_tile_model.c
    recomp-runtime/d3d_tile_adapter.c
    recomp-runtime/d3d_tile_model_test.c
    recomp-runtime/d3d_vertex_shader_model.c
    recomp-runtime/d3d_vertex_shader_adapter.c
    recomp-runtime/d3d_vertex_shader_model_test.c
    recomp-runtime/xbox_adpcm.c
    recomp-runtime/dsound_service_model.c
    recomp-runtime/dsound_service_adapter.c
    recomp-runtime/dsound_service_adapter_test.c
    recomp-runtime/dsound_api_adapter.c
    recomp-runtime/dsound_api_adapter_test.c
    recomp-runtime/dsound_hrtf.c
    recomp-runtime/dsound_reverb.c
    recomp-runtime/soundtrack_adapter.c
    recomp-runtime/movie_color_model.c
    recomp-runtime/cri_service_model.c
    recomp-runtime/cri_service_model_test.c
    recomp-runtime/cri_service_adapter.c
    recomp-runtime/cri_service_adapter_test.c
    recomp-runtime/cri_adxm_adapter.c
    recomp-runtime/crt_format_model.c
    recomp-runtime/crt_format_adapter.c
    recomp-runtime/crt_format_adapter_test.c
    recomp-runtime/crt_string_adapter.c
    recomp-runtime/crt_string_adapter_test.c
    recomp-runtime/fiber_model.c
    recomp-runtime/fiber_adapter.c
    recomp-runtime/fiber_adapter_test.c
    recomp-runtime/fiber_model_test.c
    recomp-runtime/flag_macro_test.c
    recomp-runtime/sse_semantics_test.c
    recomp-runtime/directory_model.c
    recomp-runtime/directory_model_test.c
    recomp-runtime/input_model.c
    recomp-runtime/input_adapter.c
    recomp-runtime/input_model_test.c
    recomp-runtime/input_pulse_source.c
    recomp-runtime/input_pulse_source_test.c
    recomp-runtime/symbolic_link_model.c
    recomp-runtime/symbolic_link_model_test.c
    recomp-runtime/program_manual.c
    recomp-runtime/save_adapter.c
    recomp-runtime/ohci_model.c
    recomp-runtime/ohci_model_test.c
    recomp-runtime/apu_model.c
    recomp-runtime/apu_model_test.c
    recomp-runtime/kernel_interrupt.c
    recomp-runtime/kernel_memory.c
    recomp-runtime/kernel_memory_test.c
    recomp-runtime/kernel_file.c
    recomp-runtime/kernel_file_save_test.c
    recomp-runtime/kernel_rtl.c
    recomp-runtime/kernel_rtl_test.c
    recomp-runtime/kernel_crypto.c
    recomp-runtime/kernel_crypto_test.c
    recomp-runtime/kernel_thread.c
    recomp-runtime/native_fiber.c
    recomp-runtime/kernel_thread_test.c
    recomp-runtime/thread_scheduler_test.c
    recomp-runtime/kernel_video.c
    recomp-runtime/kernel_video_test.c
    recomp-runtime/kernel_ordinals.c
    recomp-runtime/win32_compat.c
    recomp-runtime/runtime_public_fixture.c
)

RT_CXX_SRCS=(
    recomp-runtime/xapi_clock.cpp
    recomp-runtime/xapi_time_adapter.cpp
    recomp-runtime/xapi_time_adapter_test.cpp
    recomp-runtime/d3d_vblank.cpp
    recomp-runtime/custom_music.cpp
    recomp-runtime/custom_music_test.cpp
    recomp-runtime/save_transaction.cpp
)

printf '%s\n' "${RT_C_SRCS[@]}" | xargs -P "$JOBS" -I{} sh -c '
    src="$1"
    tag=$(echo "$src" | tr "/." "__")
    out="$2/${tag}.o"
    [ -f "$out" ] && [ "$out" -nt "$src" ] && exit 0
    exec "$3" cc -std=c11 -w '"$COMMON_FLAGS"' -c "$src" -o "$out"
' _ {} "$BDIR/rt" "$ZIG_BIN"

printf '%s\n' "${RT_CXX_SRCS[@]}" | xargs -P "$JOBS" -I{} sh -c '
    src="$1"
    tag=$(echo "$src" | tr "/." "__")
    out="$2/${tag}.o"
    [ -f "$out" ] && [ "$out" -nt "$src" ] && exit 0
    exec "$3" c++ -std=c++17 -w '"$COMMON_FLAGS"' -c "$src" -o "$out"
' _ {} "$BDIR/rt" "$ZIG_BIN"

# Native AArch64 fiber context switcher (ELF)
"$ZIG_BIN" cc -target "$TARGET_TRIPLE" -mcpu="$TARGET_CPU" -c \
    recomp-runtime/fiber_switch_arm64.S -o "$BDIR/rt/fiber_switch_arm64.o"

# 4. Cross-compile SDL3 Vulkan presenter, Freedreno probe, Freedreno unit test, and SDL3 launcher
echo "[4/6] Cross-compiling Vulkan SDL_GPU presenter, Freedreno probe, and ARM64 launcher..."

"$ZIG_BIN" c++ -std=c++17 -w $COMMON_FLAGS \
    -c platform/linux/tenshin_vk_probe.cpp -o "$BDIR/obj/tenshin_vk_probe.o"
"$ZIG_BIN" c++ -std=c++17 -w $COMMON_FLAGS \
    -c platform/linux/freedreno_vulkan_test.cpp -o "$BDIR/obj/freedreno_vulkan_test.o"
"$ZIG_BIN" c++ -std=c++17 -w $COMMON_FLAGS \
    -c tools/launcher_sdl.cpp -o "$BDIR/obj/launcher_sdl.o"

# Compile Dear ImGui + SDL_GPU3 backend + Vulkan presenter to validate full ARM64 Vulkan compilation
PRES_SRCS=(
    recomp-runtime/d3d_presenter_sdl_gpu.cpp
    recomp-runtime/overlay_sdl_gpu.cpp
    recomp-runtime/overlay_imgui_panel.cpp
    recomp-runtime/d3d_vertex_program.cpp
    recomp-runtime/audio_output_sdl.cpp
    extern/imgui/imgui.cpp
    extern/imgui/imgui_draw.cpp
    extern/imgui/imgui_tables.cpp
    extern/imgui/imgui_widgets.cpp
    extern/imgui/backends/imgui_impl_sdlgpu3.cpp
)
printf '%s\n' "${PRES_SRCS[@]}" | xargs -P "$JOBS" -I{} sh -c '
    src="$1"
    tag=$(echo "$src" | tr "/." "__")
    out="$2/${tag}.o"
    [ -f "$out" ] && [ "$out" -nt "$src" ] && exit 0
    exec "$3" c++ -std=c++17 -w '"$COMMON_FLAGS"' -c "$src" -o "$out"
' _ {} "$BDIR/ui" "$ZIG_BIN"

rm -f "$BDIR/libtenshin_vulkan.a"
"$ZIG_BIN" ar rcs "$BDIR/libtenshin_vulkan.a" "$BDIR/ui"/*.o

# 5. Generate link-time SDL3 stub (libSDL3.so.0) and link ARM64 binaries
echo "[5/6] Generating SDL3 link stub and linking AArch64 binaries..."
python3 - "$BDIR/sdl3_stub.c" "$BDIR/obj"/*.o "$BDIR/ui"/*.o <<'PYEOF'
import subprocess, sys
out_c = sys.argv[1]
objs = sys.argv[2:]
syms = set()
for o in objs:
    p = subprocess.run(["nm", "-u", o], capture_output=True, text=True, check=True)
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-2] == "U" and parts[-1].startswith("SDL_"):
            syms.add(parts[-1])
with open(out_c, "w") as f:
    f.write("/* Link-time-only stub for system libSDL3.so.0 */\n")
    for s in sorted(syms):
        f.write(f"void {s}(void) {{}}\n")
print(f"  Generated SDL3 stub with {len(syms)} symbols")
PYEOF

"$ZIG_BIN" cc -target "$TARGET_TRIPLE" -shared -Wl,-soname,libSDL3.so.0 \
    -o "$BDIR/libSDL3.so.0" "$BDIR/sdl3_stub.c"

"$ZIG_BIN" c++ -target "$TARGET_TRIPLE" -mcpu="$TARGET_CPU" -O2 \
    -o "$BDIR/tenshin_runtime_test.aarch64" \
    "$BDIR/rt"/*.o -lm -ldl -lpthread

"$ZIG_BIN" c++ -target "$TARGET_TRIPLE" -mcpu="$TARGET_CPU" -O2 \
    -o "$BDIR/tenshin_freedreno_test.aarch64" \
    "$BDIR/obj/freedreno_vulkan_test.o" -lm -lpthread

"$ZIG_BIN" c++ -target "$TARGET_TRIPLE" -mcpu="$TARGET_CPU" -O2 \
    -o "$BDIR/tenshin_vk_probe.aarch64" \
    "$BDIR/obj/tenshin_vk_probe.o" \
    -L"$BDIR" -l:libSDL3.so.0 -lm -ldl -lpthread

"$ZIG_BIN" c++ -target "$TARGET_TRIPLE" -mcpu="$TARGET_CPU" -O2 \
    -o "$BDIR/launcher.aarch64" \
    "$BDIR/obj/launcher_sdl.o" \
    -L"$BDIR" -l:libSDL3.so.0 -lm -ldl -lpthread

# 6. Verify ELF architecture, dynamic deps, glibc <= 2.28
echo "[6/6] Verifying AArch64 ELF binaries and assembling ROM-free Linux ARM64 package..."
for bin in \
    "$BDIR/tenshin_runtime_test.aarch64" \
    "$BDIR/tenshin_freedreno_test.aarch64" \
    "$BDIR/tenshin_vk_probe.aarch64" \
    "$BDIR/launcher.aarch64"; do
    bname=$(basename "$bin")
    FILE_INFO=$(file "$bin")
    echo "$FILE_INFO" | grep -q "ARM aarch64" || { echo "ERROR: $bname is not ARM aarch64 ($FILE_INFO)" >&2; exit 1; }
    MAX_GLIBC=$(objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)
    if [ -n "$MAX_GLIBC" ] && [ "$(printf '%s\n2.28\n' "$MAX_GLIBC" | sort -V | tail -1)" != "2.28" ]; then
        echo "ERROR: $bname requires GLIBC_$MAX_GLIBC (max allowed 2.28)" >&2
        exit 1
    fi
    READELF_D=$(readelf -d "$bin")
    if printf '%s\n' "$READELF_D" | grep -qE "libstdc\+\+"; then
        echo "ERROR: $bname has unexpected libstdc++.so dependency (must be statically linked)" >&2
        exit 1
    fi
    echo "  OK: $bname -> ARM aarch64, max GLIBC_${MAX_GLIBC:-none}, zero libstdc++.so"
done

# Assemble ROM-free Linux ARM64 Snapdragon + Freedreno Vulkan package
rm -rf "$OUT" "$TAROUT"
mkdir -p "$OUT/disc" "$OUT/libs.aarch64" "$OUT/licenses" "$OUT/assets"

cp run_arm64_vulkan.sh "$OUT/"
chmod +x "$OUT/run_arm64_vulkan.sh"
cp assets/projecttenshin-banner.jpg "$OUT/assets/"
cp assets/icon/icon.png "$OUT/assets/"
cp tools/launcher-background.png "$OUT/assets/"

cp "$BDIR/launcher.aarch64" "$OUT/launcher.aarch64"
cp "$BDIR/tenshin_vk_probe.aarch64" "$OUT/tenshin_vk_probe.aarch64"
cp "$BDIR/tenshin_runtime_test.aarch64" "$OUT/tenshin_runtime_test.aarch64"
cp "$BDIR/tenshin_freedreno_test.aarch64" "$OUT/tenshin_freedreno_test.aarch64"
chmod +x "$OUT/"*.aarch64

cp LICENSE "$OUT/licenses/ProjectTenshin-GPL3.txt"
cp NOTICE "$OUT/licenses/NOTICE.txt"
[ -f "$DEPS/sdl3-src/SDL3-$SDL3_VER/LICENSE.txt" ] && cp "$DEPS/sdl3-src/SDL3-$SDL3_VER/LICENSE.txt" "$OUT/licenses/SDL3-LICENSE.txt"
[ -f "$EXTERN/imgui/LICENSE.txt" ] && cp "$EXTERN/imgui/LICENSE.txt" "$OUT/licenses/DearImGui-LICENSE.txt"
cp docs/snapdragon-freedreno.md "$OUT/README-Snapdragon-Freedreno.md"

tar -C "$PWD/dist" -czf "$TAROUT" "$(basename "$OUT")"
echo "Packaged: $TAROUT ($(du -h "$TAROUT" | cut -f1))"
