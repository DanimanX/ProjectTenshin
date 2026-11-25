#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Native host build and verification for ProjectTenshin:
#   1. Runs Python tooling & custody unit tests (tools/test_*.py)
#   2. Configures and builds recomp-runtime + ProjectTenshin Freedreno/Snapdragon
#      tests + tenshin_vk_probe on the host
#   3. Runs the full CTest suite (including SDL_GPU Vulkan presenter tests when
#      Vulkan/Lavapipe + shaderc are present)
set -euo pipefail
cd "$(dirname "$0")/.."

BDIR="$PWD/build-host-arm64"
JOBS="${JOBS:-$(nproc)}"

echo "[1/3] Running Python tooling tests..."
python3 -m unittest discover -s tools -p 'test_*.py'

echo "[2/3] Configuring and building recomp-runtime + ProjectTenshin host tests..."
CMAKE_EXTRA=()
if [ -f "$PWD/extern/imgui/imgui.cpp" ]; then
    CMAKE_EXTRA+=("-DFETCHCONTENT_SOURCE_DIR_IMGUI=$PWD/extern/imgui")
fi
if ! pkg-config --exists sdl3 2>/dev/null; then
    CMAKE_EXTRA+=("-DRECOMP_FETCH_SDL3=ON" "-DSDL_UNIX_CONSOLE_BUILD=ON")
fi

cmake -S recomp-runtime -B "$BDIR" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo "${CMAKE_EXTRA[@]}"
cmake --build "$BDIR" --parallel "$JOBS"

echo "[3/3] Running CTest verification suite..."
SDL_VIDEO_DRIVER="${SDL_VIDEO_DRIVER:-offscreen}" \
    ctest --test-dir "$BDIR" --output-on-failure

if [ -x "$BDIR/tenshin_vk_probe" ]; then
    echo "[probe] Running tenshin_vk_probe --headless..."
    "$BDIR/tenshin_vk_probe" --headless
fi

echo "All ProjectTenshin host verification checks passed."
