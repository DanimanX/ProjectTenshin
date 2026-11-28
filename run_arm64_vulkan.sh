#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ProjectTenshin — Linux ARM64 / Vulkan launcher for Qualcomm Snapdragon + Mesa Freedreno (Turnip).
#
# The v1.0.0-arm64 package and the Steam shortcuts made from it name this file,
# so it stays as the ARM64 entry point. The launcher itself now covers both Linux
# targets; run_linux_vulkan.sh picks the Freedreno/Turnip settings on aarch64.
#
# Usage:
#   ./run_arm64_vulkan.sh [/path/to/default.xbe] [-- extra runner args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${ROOT}/run_linux_vulkan.sh" "$@"
