#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ProjectTenshin — Linux ARM64 / Vulkan launcher for Qualcomm Snapdragon + Mesa Freedreno (Turnip).
#
# Configures Mesa Freedreno/Turnip ICD, persistent SPIR-V shader cache,
# Snapdragon big.LITTLE performance cluster pinning, and optional runtime tuning.
#
# Usage:
#   ./run_arm64_vulkan.sh [/path/to/default.xbe] [-- extra runner args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$ROOT/libs.aarch64:${LD_LIBRARY_PATH:-}"

echo "=== ProjectTenshin (Dead or Alive 3++ — Linux ARM64 / Freedreno Vulkan) ==="
echo "Date: $(date)"
echo "Device: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || uname -n)  Arch: $(uname -m)"

# Read-only hardware & driver telemetry snapshot (never fatal)
{
  printf '[sys]'
  for d in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -d "$d" ] || continue
    f=$(cat "$d/scaling_cur_freq" 2>/dev/null || true)
    [ -n "$f" ] || f=0
    printf ' %s=%sMHz/%s' "$(basename "$(dirname "$d")")" "$((f / 1000))" \
      "$(cat "$d/scaling_governor" 2>/dev/null || echo -)"
  done
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

# Prefer Mesa Freedreno / Turnip Vulkan ICD on Snapdragon Linux if not explicitly set
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

# Vulkan + Freedreno/Turnip runtime defaults
export SDL_GPU_DRIVER="${SDL_GPU_DRIVER:-vulkan}"
export MESA_SHADER_CACHE_DISABLE="${MESA_SHADER_CACHE_DISABLE:-0}"
export PROJECTTENSHIN_SHADER_CACHE="${PROJECTTENSHIN_SHADER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/projecttenshin/spirv}"
export RECOMP_D3D_WIDESCREEN="${RECOMP_D3D_WIDESCREEN:-16:9}"
export RECOMP_D3D_SCALE="${RECOMP_D3D_SCALE:-2}"
export RECOMP_VK_DEPTH_FORMAT="${RECOMP_VK_DEPTH_FORMAT:-auto}"
export PROJECTTENSHIN_PIN_PERF="${PROJECTTENSHIN_PIN_PERF:-1}"

# Optional per-device environment overrides
if [ -f "$ROOT/tenshin.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/tenshin.env"
fi

mkdir -p "$PROJECTTENSHIN_SHADER_CACHE"

# Optional positional XBE path
XBE=""
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
  XBE="$1"
  shift
fi

RUNNER=""
for cand in \
  "$ROOT/doa3.aarch64" \
  "$ROOT/doa3-jp.aarch64" \
  "$ROOT/doa3-eur.aarch64" \
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
  [ -z "$RUNNER" ] && echo "  - Missing doa3.aarch64 (build from your legal DOA3 ISO via tools/build-arm64-game.sh)" >&2
  [ -z "$XBE" ]    && echo "  - Missing extracted disc files (disc/default.xbe or private/play-disc*/default.xbe)" >&2
  if [ -x "$ROOT/tenshin_vk_probe.aarch64" ]; then
    echo "[ProjectTenshin] Running Freedreno Vulkan hardware probe..."
    "$ROOT/tenshin_vk_probe.aarch64" || true
  fi
  exit 1
fi

exec "$RUNNER" --xbe "$XBE" "$@"
