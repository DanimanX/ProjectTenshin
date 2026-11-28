#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ProjectTenshin — Linux / Vulkan launcher for both Linux targets:
#   * x86_64: Mesa Intel ANV or RADV (AMD) through the SDL3 GPU Vulkan backend.
#   * ARM64:  Qualcomm Snapdragon with Mesa Freedreno / Turnip.
#
# Sets the Vulkan driver hints, the persistent SPIR-V shader cache and the
# optional runtime tuning each architecture needs, then starts the runner.
#
# Usage:
#   ./run_linux_vulkan.sh [--extra runner args...]
#   RECOMP_D3D_SCALE=3 ./run_linux_vulkan.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The two Linux targets differ in the ICD to prefer and in the binary suffix.
ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64 | arm64)
    HOST=arm64
    SUFFIX=".aarch64"
    LIBDIR="libs.aarch64"
    ;;
  x86_64 | amd64)
    HOST=x86_64
    SUFFIX=".x86_64"
    LIBDIR="libs.x86_64"
    ;;
  *)
    echo "[ProjectTenshin] Unsupported CPU: ${ARCH}. This package targets Linux x86_64 and ARM64 (aarch64)." >&2
    exit 1
    ;;
esac

export LD_LIBRARY_PATH="$ROOT/${LIBDIR}:${LD_LIBRARY_PATH:-}"

echo "=== ProjectTenshin (Dead or Alive 3++ — Linux ${HOST} / Vulkan) ==="
echo "Date: $(date)"
echo "Host: $(uname -n)  Arch: ${ARCH}"

# Read-only hardware and driver telemetry snapshot (never fatal).
{
  printf '[sys]'
  for d in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -d "$d" ] || continue
    f=$(cat "$d/scaling_cur_freq" 2>/dev/null || true)
    [ -n "$f" ] || f=0
    printf ' %s=%sMHz/%s' "$(basename "$(dirname "$d")")" "$((f / 1000))" \
      "$(cat "$d/scaling_governor" 2>/dev/null || echo -)"
  done
  # devfreq describes the Snapdragon GPU (kgsl/msm); x86_64 iGPUs report through
  # their DRM driver instead, so an empty list is expected there.
  for d in /sys/class/devfreq/*gpu* /sys/class/devfreq/*kgsl* /sys/class/devfreq/*msm*; do
    [ -d "$d" ] || continue
    f=$(cat "$d/cur_freq" 2>/dev/null || true)
    [ -n "$f" ] || f=0
    printf ' devfreq:%s=%sMHz/%s' "$(basename "$d")" "$((f / 1000000))" \
      "$(cat "$d/governor" 2>/dev/null || echo -)"
  done
  printf ' mem=%sMB cores=%s online=%s\n' \
    "$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)" \
    "$(nproc 2>/dev/null || echo ?)" \
    "$(cat /sys/devices/system/cpu/online 2>/dev/null || echo ?)"
}

# Snapdragon Linux usually ships several ICDs; name Freedreno so the loader does
# not pick a software one. x86_64 distributions name theirs by vendor, and the
# loader's default order is already the hardware driver, so only report them.
if [ "${HOST}" = arm64 ]; then
  if [ -z "${VK_DRIVER_FILES:-}" ] && [ -z "${VK_ICD_FILENAMES:-}" ]; then
    for icd in \
      /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
      /usr/share/vulkan/icd.d/freedreno_icd.json \
      /usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json; do
      if [ -f "$icd" ]; then
        export VK_DRIVER_FILES="$icd"
        echo "[vk] Freedreno/Turnip ICD: $icd"
        break
      fi
    done
  fi
else
  for icd in /usr/share/vulkan/icd.d/*.json; do
    [ -f "$icd" ] || continue
    echo "[vk] ICD available: $(basename "$icd")"
  done
fi

# Vulkan and driver runtime defaults, shared by both targets.
export SDL_GPU_DRIVER="${SDL_GPU_DRIVER:-vulkan}"
export MESA_SHADER_CACHE_DISABLE="${MESA_SHADER_CACHE_DISABLE:-0}"
export PROJECTTENSHIN_SHADER_CACHE="${PROJECTTENSHIN_SHADER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/projecttenshin/spirv}"
export RECOMP_D3D_WIDESCREEN="${RECOMP_D3D_WIDESCREEN:-16:9}"
export RECOMP_D3D_SCALE="${RECOMP_D3D_SCALE:-2}"
export RECOMP_VK_DEPTH_FORMAT="${RECOMP_VK_DEPTH_FORMAT:-auto}"
# Pin the guest's fiber thread to the fastest cores: the Snapdragon Prime/Gold
# cluster, or the P-cores of a hybrid Intel/AMD part.
export PROJECTTENSHIN_PIN_PERF="${PROJECTTENSHIN_PIN_PERF:-1}"

# Optional per-device environment overrides.
if [ -f "$ROOT/tenshin.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/tenshin.env"
fi

mkdir -p "$PROJECTTENSHIN_SHADER_CACHE"

# Optional positional XBE path.
XBE=""
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
  XBE="$1"
  shift
fi

RUNNER=""
for cand in \
  "$ROOT/doa3${SUFFIX}" \
  "$ROOT/doa3.aarch64" \
  "$ROOT/doa3.x86_64" \
  "$ROOT/doa3-jp${SUFFIX}" \
  "$ROOT/doa3-eur${SUFFIX}" \
  "$ROOT/build/recomp-program-jp/recomp_program_runner" \
  "$ROOT/build/recomp-program/recomp_program_runner" \
  "$ROOT/build/recomp-program-eur/recomp_program_runner"; do
  if [ -x "$cand" ]; then
    RUNNER="$cand"
    break
  fi
done

if [ -z "$XBE" ]; then
  for cand in \
    "$ROOT/disc/default.xbe" \
    "$ROOT/disc/DEFAULT.XBE" \
    "$ROOT/private/play-disc-jp/default.xbe" \
    "$ROOT/private/play-disc/default.xbe" \
    "$ROOT/private/play-disc-eur/default.xbe"; do
    if [ -f "$cand" ]; then
      XBE="$cand"
      break
    fi
  done
fi

if [ -z "$RUNNER" ] || [ -z "$XBE" ]; then
  echo "[ProjectTenshin] BYOD setup incomplete:" >&2
  [ -z "$RUNNER" ] && echo "  - Missing doa3${SUFFIX} (build from your legal DOA3 ISO with ./build_game.sh)" >&2
  [ -z "$XBE" ]    && echo "  - Missing extracted disc files (disc/default.xbe or private/play-disc*/default.xbe)" >&2
  if [ -x "$ROOT/tenshin_vk_probe${SUFFIX}" ]; then
    echo "[ProjectTenshin] Running the Vulkan hardware probe..."
    "$ROOT/tenshin_vk_probe${SUFFIX}" || true
  fi
  exit 1
fi

exec "$RUNNER" --xbe "$XBE" "$@"
