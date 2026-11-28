#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the ROM-free Linux x86_64 / Vulkan package: the runtime self-tests, the
# Vulkan/Freedreno helper test and the hardware probe, plus the launcher script,
# assembled as dist/ProjectTenshin-Linux-x86_64-Vulkan.tar.gz.
#
# This is the x86_64 counterpart of tools/build-arm64.sh. It builds with the host
# compiler (there is no cross toolchain: x86_64 Linux is native), so the glibc
# floor is the build host's. Run it on the oldest distribution you support.
#
# The game binary is not in the package: it comes from your own disc through
# ./build_game.sh, which also builds the settings launcher beside the runner.
#
# Usage:
#   tools/build-linux-x86_64.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="ProjectTenshin-Linux-x86_64-Vulkan"
OUT="$PWD/dist/$NAME"
TAROUT="$PWD/dist/$NAME.tar.gz"
BDIR="$PWD/build-x86_64"
JOBS="${JOBS:-$(nproc)}"

if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: this builds a Linux x86_64 package; run it on Linux." >&2
    exit 1
fi
if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: this builds the x86_64 package and needs an x86_64 Linux host (found $(uname -m))." >&2
    exit 1
fi
for tool in cmake ninja file objdump; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool is missing." >&2; exit 1; }
done

# Netplay pairs runners of one release; the package ships no runner, but configure
# still asks for a version and a tarball has neither VERSION nor a useful commit.
if [ -z "${RECOMP_NETPLAY_VERSION:-}" ]; then
    RECOMP_NETPLAY_VERSION="$(git describe --tags --always 2>/dev/null || echo 0.0.0-local)"
fi

echo "[1/4] Configuring the x86_64 runtime (SDL3 from the system, else fetched)..."
CMAKE_EXTRA=()
if ! pkg-config --exists sdl3 2>/dev/null; then
    CMAKE_EXTRA+=("-DRECOMP_FETCH_SDL3=ON" "-DSDL_UNIX_CONSOLE_BUILD=ON")
fi
if [ -f "$PWD/extern/imgui/imgui.cpp" ]; then
    CMAKE_EXTRA+=("-DFETCHCONTENT_SOURCE_DIR_IMGUI=$PWD/extern/imgui")
fi
cmake -S recomp-runtime -B "$BDIR" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DRECOMP_NETPLAY_VERSION="$RECOMP_NETPLAY_VERSION" \
    "${CMAKE_EXTRA[@]}"

echo "[2/4] Building the self-tests and the hardware probe (-j$JOBS)..."
cmake --build "$BDIR" --parallel "$JOBS" \
    --target recomp_runtime_test recomp_freedreno_vulkan_test tenshin_vk_probe

echo "[3/4] Verifying the x86_64 ELF binaries..."
rm -rf "$OUT" "$TAROUT"
mkdir -p "$OUT/libs.x86_64" "$OUT/licenses" "$OUT/assets" "$OUT/disc"
for pair in \
    "recomp_runtime_test:tenshin_runtime_test.x86_64" \
    "recomp_freedreno_vulkan_test:tenshin_freedreno_test.x86_64" \
    "tenshin_vk_probe:tenshin_vk_probe.x86_64"; do
    built="${pair%%:*}"
    shipped="${pair##*:}"
    bin="$BDIR/$built"
    if [ ! -x "$bin" ]; then
        echo "ERROR: $built was not built" >&2
        exit 1
    fi
    info="$(file -b "$bin")"
    case "$info" in
        *"ELF 64-bit"*"x86-64"*) ;;
        *) echo "ERROR: $shipped is not an x86-64 ELF ($info)" >&2; exit 1 ;;
    esac
    needs_libstdcxx="$(objdump -p "$bin" | awk '$1 == "NEEDED" {print $2}' | grep -c '^libstdc++' || true)"
    [ "$needs_libstdcxx" = 0 ] || echo "  note: $shipped links libstdc++ (the game build ships its own)"
    cp "$bin" "$OUT/$shipped"
    chmod +x "$OUT/$shipped"
    echo "  OK: $shipped"
done

echo "[4/4] Assembling $TAROUT..."
cp run_linux_vulkan.sh "$OUT/"
chmod +x "$OUT/run_linux_vulkan.sh"
cp LICENSE "$OUT/licenses/ProjectTenshin-GPL3.txt"
cp NOTICE "$OUT/licenses/NOTICE.txt"
# The probe links the system SDL3, so its zlib licence travels with it, as the
# ARM64 package already does. The header comes from the distribution when SDL3
# is a package, and from CMake's own fetch when the pin was built instead.
for sdl_license in \
    /usr/share/licenses/sdl3/LICENSE \
    /usr/share/licenses/sdl3/LICENSE.txt \
    /usr/share/doc/sdl3/copyright \
    /usr/share/doc/libsdl3-dev/copyright \
    "$BDIR/_deps/sdl3-src/LICENSE.txt"; do
    if [ -f "$sdl_license" ]; then
        cp "$sdl_license" "$OUT/licenses/SDL3-LICENSE.txt"
        echo "  bundled SDL3 licence from $sdl_license"
        break
    fi
done
[ -f "$OUT/licenses/SDL3-LICENSE.txt" ] ||
    echo "  WARNING: no SDL3 licence found; the probe links SDL3 and its licence is required" >&2
cp assets/projecttenshin-banner.jpg "$OUT/assets/" 2>/dev/null || true
# The guide is written for a checkout, so say what this archive itself holds
# before quoting it: everything below that names launcher.sh or build_game.sh
# needs the checkout the guide tells you to make.
if [ -f docs/x86_64-linux.md ]; then
    {
        echo "<!-- Prefixed by tools/build-linux-x86_64.sh; the guide follows. -->"
        echo ""
        echo "# ProjectTenshin — Linux x86_64 / Vulkan package"
        echo ""
        echo "This archive holds the ROM-free diagnostics for x86_64 Linux: the runtime"
        echo "self-test (\`tenshin_runtime_test.x86_64\`), the Linux host-layer test"
        echo "(\`tenshin_freedreno_test.x86_64\`), the Vulkan probe"
        echo "(\`tenshin_vk_probe.x86_64\`) and \`run_linux_vulkan.sh\`."
        echo ""
        echo "It holds **no game and no settings screen**. The game binary comes from your"
        echo "own disc, and \`launcher.sh\` and \`build_game.sh\` live in the repository; clone"
        echo "or download the source, then build there. The guide below describes that"
        echo "checkout."
        echo ""
        echo "---"
        echo ""
        cat docs/x86_64-linux.md
    } > "$OUT/README-x86_64-Linux.md"
fi
tar -C "$PWD/dist" -czf "$TAROUT" "$NAME"
echo "Packaged: $TAROUT ($(du -h "$TAROUT" | cut -f1))"
echo "Copy the folder onto the x86_64 machine, build your own doa3 runner with ./build_game.sh, then run ./run_linux_vulkan.sh"
