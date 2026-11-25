#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ProjectTenshin — BYOD AOT Game Builder for Linux ARM64 Snapdragon + Freedreno Vulkan.
#
# Lifts your own legally obtained Dead or Alive 3 ISO / extracted disc folder
# (Japan 3.1, USA 3.0, or Europe 3.2) via tools/xboxrecomp and cross-compiles
# the full native `doa3.aarch64` Vulkan runner targeting `aarch64-linux-gnu.2.28`
# using Zig 0.17.0. Can run either on an x86_64 Linux PC (cross-compiling for
# your Snapdragon handheld) or natively on an ARM64 Linux device!
#
# Usage:
#   tools/build-arm64-game.sh /path/to/doa3.iso
#   TARGET_CPU=cortex_x3 tools/build-arm64-game.sh /path/to/extracted-disc-folder
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <doa3.iso | extracted-disc-dir> [--no-movies] [--no-costumes]" >&2
    exit 1
fi

ARCH="$(uname -m)"
TARGET_CPU="${TARGET_CPU:-cortex_a77}"
TARGET_CPU="${TARGET_CPU//-/_}"
TARGET_TRIPLE="aarch64-linux-gnu.2.28"

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    echo "[ProjectTenshin] Native ARM64 Linux host detected; building via build_game.sh..."
    exec ./build_game.sh "$@"
fi

echo "[ProjectTenshin] Cross-building Dead or Alive 3++ for $TARGET_TRIPLE ($TARGET_CPU, Vulkan/Freedreno)..."

# Ensure Zig 0.17.0 + SDL3 headers + SDL3 link stub are ready
if [ ! -x "$PWD/deps/zig-linux/zig" ] || [ ! -f "$PWD/build-arm64/libSDL3.so.0" ]; then
    tools/build-arm64.sh
fi

ZIG_BIN="$PWD/deps/zig-linux/zig"
SDL3_INC="$PWD/deps/sdl3-src/SDL3-3.4.12/include"
BDIR="$PWD/build-arm64"
TOOLCHAIN_FILE="$BDIR/zig-aarch64-toolchain.cmake"

cat > "$BDIR/zig-cc-aarch64.sh" <<EOF
#!/usr/bin/env bash
exec "$ZIG_BIN" cc -target $TARGET_TRIPLE -mcpu=$TARGET_CPU "\$@"
EOF
cat > "$BDIR/zig-cxx-aarch64.sh" <<EOF
#!/usr/bin/env bash
exec "$ZIG_BIN" c++ -target $TARGET_TRIPLE -mcpu=$TARGET_CPU "\$@"
EOF
chmod +x "$BDIR/zig-cc-aarch64.sh" "$BDIR/zig-cxx-aarch64.sh"

cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER "$BDIR/zig-cc-aarch64.sh")
set(CMAKE_CXX_COMPILER "$BDIR/zig-cxx-aarch64.sh")
set(CMAKE_ASM_COMPILER "$BDIR/zig-cc-aarch64.sh")
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_CXX_COMPILER_WORKS 1)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

# Create a minimal CMake package config for our cross-compiled SDL3 link stub
mkdir -p "$BDIR/sdl3-cmake"
cat > "$BDIR/sdl3-cmake/SDL3Config.cmake" <<EOF
add_library(SDL3::SDL3 SHARED IMPORTED)
set_target_properties(SDL3::SDL3 PROPERTIES
    IMPORTED_LOCATION "$BDIR/libSDL3.so.0"
    INTERFACE_INCLUDE_DIRECTORIES "$SDL3_INC")
set(SDL3_FOUND TRUE)
EOF

# Lift the disc on the host using tools/xboxrecomp (requires submodule init)
if [ ! -d "tools/xboxrecomp/tools" ]; then
    echo "Initializing tools/xboxrecomp submodule..."
    git submodule update --init tools/xboxrecomp
fi

VENV="$PWD/private/venv"
PYTHON="python3"
if [ ! -f "$VENV/bin/python3" ]; then
    python3 -m venv "$VENV" >/dev/null 2>&1 || rm -rf "$VENV"
fi
[ -f "$VENV/bin/python3" ] && PYTHON="$VENV/bin/python3"
"$PYTHON" -c "import capstone; assert capstone.__version__ == '5.0.7'" 2>/dev/null || \
    "$PYTHON" -m pip install --quiet capstone==5.0.7

# Run lifting via Python helper reusing tools/build_game.py's validated recipe
"$PYTHON" - "$@" "$TOOLCHAIN_FILE" "$BDIR/sdl3-cmake" <<'PYEOF'
import gzip, json, os, shutil, subprocess, sys, uuid
from pathlib import Path

sys.path.insert(0, str(Path("tools").resolve()))
import build_game

args = sys.argv[1:-2]
toolchain = Path(sys.argv[-2]).resolve()
sdl3_dir = Path(sys.argv[-1]).resolve()

source = None
movies = True
for a in args:
    if a == "--no-movies":
        movies = False
    elif not a.startswith("-"):
        source = Path(a)

disc = build_game.find_disc(source, movies=movies)
xbe, version = build_game.disc_version(disc)
play = "play-disc" + version["suffix"]
print(f"Lifting Dead or Alive 3 ({version['name']}) for AArch64 Vulkan...", flush=True)
build_game.prepare_play_disc(disc, movies, play)

work = build_game.ROOT / "private" / ("arm64-program-" + uuid.uuid4().hex[:8])
work.mkdir(parents=True)
generated = work / "generated"
recipe = build_game.ROOT / "tools" / version["recipe"]
functions = work / "functions.json"
functions.write_bytes(gzip.decompress((recipe / "functions.json.gz").read_bytes()))

build_game.run_logged([
    sys.executable, "-u", "-m", "tools.recomp", xbe, "--all", "--split", "1000",
    "--game-name", "Dead or Alive 3",
    "--functions", functions, "--disasm-dir", work / "none",
    "--func-id-dir", work / "none", "--abi-dir", work / "none",
    "--icall-sites", work / "none.json",
    "--manual-functions", recipe / "manual_functions.json",
    "--exclude-manual", build_game.ROOT / "recomp-runtime" / version["forwards"],
    "--gen-dir", generated, "--output-dir", work / "metadata",
], work / "lift.log", build_game.LIFTER)

build_game.use_windows_newlines(generated)
manifest, ebp = build_game.program_manifest(generated)
if (manifest, ebp) != (version["program"], version["ebp"]):
    raise ValueError(f"Generated program {manifest} differs from validated {version['program']}")

build_dir = build_game.ROOT / "build-arm64" / ("recomp-program" + version["suffix"])
cmake_args = [
    "cmake", "-S", str(build_game.ROOT / "recomp-runtime"), "-B", str(build_dir),
    "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
    f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
    f"-DSDL3_DIR={sdl3_dir}",
    f"-DFETCHCONTENT_SOURCE_DIR_IMGUI={(build_game.ROOT / 'extern' / 'imgui').as_posix()}",
    f"-DRECOMP_PROGRAM_DIR={generated.as_posix()}",
    f"-DRECOMP_PROGRAM_MANIFEST_SHA256={manifest}",
    f"-DRECOMP_PROGRAM_EBP_EXPECTED={ebp}",
    f"-DRECOMP_DOA3_JP={'ON' if version['jp'] else 'OFF'}",
    f"-DRECOMP_DOA3_EUR={'ON' if version['eur'] else 'OFF'}",
]
build_game.run_logged(cmake_args, work / "configure.log")
build_game.run_logged([
    "cmake", "--build", str(build_dir),
    "--parallel", str(build_game.build_jobs()),
    "--target", "recomp_program_runner",
], work / "build.log")

runner = build_dir / "recomp_program_runner"
dest_dir = build_game.ROOT / "dist" / "ProjectTenshin-Linux-ARM64-Vulkan"
dest_dir.mkdir(parents=True, exist_ok=True)
dest_bin = dest_dir / ("doa3" + version["suffix"] + ".aarch64")
shutil.copy2(runner, dest_bin)
shutil.copy2(runner, dest_dir / "doa3.aarch64")
print(f"Built ARM64 Vulkan runner: {dest_bin}")
print(f"Copy {dest_dir} and private/{play} onto your Snapdragon Linux ARM64 device!")
PYEOF
