# Linux x86_64 & Vulkan Guide

ProjectTenshin also targets **Linux x86_64**, where the game runs on **Mesa Intel
ANV**, **Mesa RADV (AMD)** or any other conformant Vulkan 1.3 driver through the
runtime's SDL3 GPU presenter. It is the same lifted program and the same runtime
as the Windows and ARM64 builds; only the host layer differs.

The ARM64 / Snapdragon path (Mesa Freedreno / Turnip) is described in
[snapdragon-freedreno.md](snapdragon-freedreno.md). Everything below applies to
x86_64 handhelds (MSI Claw, ROG Ally, Legion Go), desktops and laptops.

---

## 1. Runtime prerequisites

- **Vulkan 1.3 driver**: `vulkan-intel` (Mesa ANV) or `vulkan-radeon` (Mesa RADV),
  or the vendor driver.
- **Vulkan loader**: `vulkan-icd-loader`.
- **SDL3** (`libSDL3.so.0`, 3.4 or newer).
- **shaderc** (`libshaderc_shared.so.1` or `libshaderc.so.1`). The presenter
  compiles the runtime's own GLSL to SPIR-V on the first run of each shader and
  caches the result, so shaderc is needed only until that cache is warm.

### By distribution

**Arch, CachyOS, SteamOS and other Arch-family systems:**

```bash
sudo pacman -S vulkan-intel vulkan-icd-loader sdl3 shaderc
```

**Debian and Ubuntu:**

```bash
sudo apt-get install mesa-vulkan-drivers libvulkan1 libshaderc1 libsdl3-0
```

Fedora and its derivatives: `vulkan-loader`, `mesa-vulkan-drivers`, `SDL3`,
`shaderc`.

If the distribution has no SDL3 package, `./build_game.sh` builds the pinned
SDL3 3.4.12 itself.

## 2. Building the game

x86_64 Linux needs no cross toolchain: the build uses the host's compiler.

```bash
./install_deps.sh                        # a terminal with a package manager
./build_game.sh /path/to/doa3.iso
```

`build_game.sh` also builds `recomp_launcher` beside the runner, which is the
settings screen `./launcher.sh` opens.

On a read-only or immutable system (SteamOS, Bazzite, CachyOS) with no root
password to give, put CMake and Ninja in the build's own virtual environment
instead: they are Python packages, so `build_game.sh` finds them on `PATH` and
needs no `sudo`.

```bash
python3 -m venv private/venv
private/venv/bin/pip install cmake ninja capstone==5.0.7
./build_game.sh /path/to/doa3.iso
```

### What the build validates

The lifter's output is checked against the recorded program manifest before it
compiles, so a different lifter, recipe or disc stops the build instead of
producing a runner that boots into a different program. USA 3.0 (`8e244632…`),
Japan 3.1 (`310a103c…`) and Europe 3.2 (`6580d45e…`) are supported.

### Compile jobs

Each generated chunk can take about 1 GB to compile, so the build runs one job
per 4 GB of RAM and at least four. Override it with `JOBS` for a CMake build, or
let the default stand on a 16 GB handheld.

## 3. Running

```bash
./launcher.sh        # settings screen, then the game
./run_game.sh        # the game with the saved settings
```

`run_linux_vulkan.sh` is the same launcher path with the Vulkan tuning applied.
It sets the shader cache, the internal resolution scale and the thread pinning,
then starts the runner; `run_arm64_vulkan.sh` remains the ARM64 entry point for
the v1.0.0 package's shortcuts and forwards to it.

### Thread pinning on a hybrid CPU

`PROJECTTENSHIN_PIN_PERF=1` (the default) pins the guest's fiber thread to the
fastest core cluster, measured from `cpufreq/cpuinfo_max_freq`. On an Intel
hybrid part that is the P-cores; on a Snapdragon it is Prime/Gold. The Vulkan
driver and SDL3 worker threads stay unpinned across every online core. Set it
to `0` to leave the scheduler alone.

## 4. Steam Game Mode

Steam's menu shows the games in its library, and a non-Steam game is only in the
library if its entry is in `shortcuts.vdf`. Steam owns that file: it reads it at
startup and rewrites it from its own memory when it exits, so an entry written
while Steam runs is discarded at the next shutdown. The script handles that:

```bash
./tools/steam_shortcut.py add --restart-steam
```

That adds one library entry named *Dead or Alive 3++ (ProjectTenshin)* that runs
`launcher.sh`, stops Steam, writes the file, and starts Steam again in Game Mode
when it was running there. `--direct` adds an entry that skips the settings
screen and runs `run_game.sh`. `list` shows what is registered and `remove`
takes the entry out again.

Stopping Steam takes more than asking it to quit. A Game Mode session supervises
the client (`steam-launcher.service`), so `steam -shutdown` is answered by the
session starting it again within a second — and that new instance reads
`shortcuts.vdf` before the entry is written. The script therefore stops the
supervising unit first, and falls back to signalling the client's own processes,
finishing only when no Steam process is left. It then writes the file and starts
the unit again.

The script backs the previous file up as `shortcuts.vdf.bak` beside it, and
refuses a file it cannot parse rather than overwriting it.

### Checking that Steam took the entry

Steam logs a launch of a shortcut as `GameAction [AppID <id>]` in
`~/.local/share/Steam/logs/console_log.txt`, and `steam://rungameid/` only
accepts the 64-bit *GameID* a shortcut has (the 32-bit appid, shifted up, with
the shortcut type bits). `python3 tools/steam_shortcut.py list` prints the name
and executable Steam recorded; from there the entry is in the library, reachable
with a controller in Game Mode.

Two details worth knowing:

- **The controller**: Steam binds a config to the shortcut
  (`Loaded Config ... for App ID <id>` in that same log), so the pad works in the
  menu. In the game itself, this runtime opens the first SDL gamepad on port 0.
- **Steam Input**: if one controller drives two player ports in the game, turn
  Steam Input off for that shortcut (Properties → Controller). On a handheld
  whose built-in pad is translated by Handheld Daemon (`hhd`), Steam Input adds a
  second, virtual pad on top of hhd's, which is what causes that.
- **Artwork**: Steam names a shortcut's capsule images after its `appid`, so a
  custom grid image is optional; drop it in
  `~/.local/share/Steam/userdata/<id>/config/grid/` named
  `<appid>_hero.png`, `<appid>_logo.png` or `<appid>p.png`.
  `./tools/steam_shortcut.py list` prints the names it registered.

## 5. Verifying the machine

The ROM-free package ships the runtime self-test and a Vulkan probe:

```bash
./tenshin_runtime_test.x86_64          # fibers, math, D3D8/DSound models
./tenshin_vk_probe.x86_64              # CPU clusters and Vulkan formats
```

The probe reports the detected core tiers, the Vulkan device in use, which
render-target, depth and texture formats the driver supports, whether MSAA 2×
and 4× are available, and whether shaderc loaded. A missing format there names
the fallback the presenter will take.

## 6. Differences from the Windows build

The runtime's own notes apply
([building.md](building.md#differences-from-the-windows-build)): no SMAA (that
needs the Direct3D 11 presenter), no `RECOMP_D3D_VRR`, and the SDL audio capture
does not stop after 60 seconds. x86_64 Linux adds no difference of its own: the
guest is the same lifted x86 program, so the CPU-side behaviour matches the
Windows build bit for bit, including `RECOMP_PORTABLE_MATH`.

## 7. Troubleshooting

- **`Vulkan shaders need shaderc`** — install shaderc (section 1) or place
  `libshaderc_shared.so.1` in `libs.x86_64/`.
- **Black window, then exit** — check `private/play-logs/*.log`; the presenter
  logs the driver, resolution, depth format and MSAA it chose.
- **Software rendering** — `vulkaninfo --summary` should name the Intel or AMD
  device. If it reports `llvmpipe`, the ICD for the GPU is not installed.
- **The game starts from a terminal but not from Steam** — Steam starts a
  shortcut in its own environment; a shortcut added with `steam_shortcut.py`
  points at `launcher.sh` inside this checkout, so keep the checkout where it is
  or re-run `steam_shortcut.py add --restart-steam` after moving it.
