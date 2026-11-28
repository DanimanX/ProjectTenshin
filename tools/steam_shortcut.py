#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Register ProjectTenshin in Steam's library, so Steam Game Mode starts it.

Steam keeps non-Steam shortcuts in <steam>/userdata/<id>/config/shortcuts.vdf,
a binary VDF file it rewrites whenever it changes. It reads that file at startup
and writes it when it exits, so a change made while Steam runs is lost: this
script stops with an explanation instead, unless --restart-steam stopped Steam,
made the change and started it again.

    ./tools/steam_shortcut.py list
    ./tools/steam_shortcut.py add                  # settings launcher entry
    ./tools/steam_shortcut.py add --direct         # straight into the game
    ./tools/steam_shortcut.py remove
"""
import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NAME = "Dead or Alive 3++ (ProjectTenshin)"
# The binary VDF types Steam writes in shortcuts.vdf.
TYPE_DICT = 0x00
TYPE_STRING = 0x01
TYPE_INT32 = 0x02
TYPE_UINT64 = 0x07
TYPE_END = 0x08
# A new file's trailing byte: Steam closes the root dictionary and the file.
NEW_TRAILING = b"\x08"


class ShortcutError(RuntimeError):
    pass


@dataclass
class Entry:
    """One VDF node: its key, its type tag, and the raw value bytes, or its
    children when it is a dictionary. Keeping the raw bytes is what lets an
    untouched shortcut round-trip byte for byte."""
    key: bytes
    kind: int
    value: bytes = b""
    children: list = field(default_factory=list)


@dataclass
class Shortcuts:
    """A parsed shortcuts.vdf: the entries of its root dictionary, and the bytes
    that follow that dictionary (Steam ends the file with a second 0x08)."""
    children: list = field(default_factory=list)
    trailing: bytes = NEW_TRAILING

    def entries(self):
        """The shortcut dictionaries, in file order."""
        return [child for child in self.children if child.kind == TYPE_DICT]


def _read_key(data, start):
    end = data.find(b"\x00", start)
    if end < 0:
        raise ShortcutError("unterminated key or string value")
    return data[start:end], end + 1


def parse(data):
    """Parse a shortcuts.vdf's bytes, refusing anything it did not write."""
    if not data:
        return Shortcuts()
    if data[0] != TYPE_DICT:
        raise ShortcutError("not a shortcuts.vdf file: no root dictionary")
    _, position = _read_key(data, 1)
    shortcuts = Shortcuts()
    shortcuts.children, position = _parse_children(data, position)
    rest = data[position:]
    if rest.strip(b"\x08"):
        raise ShortcutError("trailing bytes after the root dictionary")
    shortcuts.trailing = rest
    return shortcuts


def _parse_children(data, position):
    children = []
    while position < len(data):
        kind = data[position]
        position += 1
        if kind == TYPE_END:
            return children, position
        key, position = _read_key(data, position)
        if kind == TYPE_DICT:
            nested, position = _parse_children(data, position)
            children.append(Entry(key, TYPE_DICT, children=nested))
        elif kind == TYPE_STRING:
            value, position = _read_key(data, position)
            children.append(Entry(key, TYPE_STRING, value))
        elif kind in (TYPE_INT32, TYPE_UINT64):
            width = 4 if kind == TYPE_INT32 else 8
            if position + width > len(data):
                raise ShortcutError(f"truncated value for {key!r}")
            children.append(Entry(key, kind, data[position:position + width]))
            position += width
        else:
            raise ShortcutError(f"unsupported VDF type 0x{kind:02x} for {key!r}")
    raise ShortcutError("unterminated dictionary")


def serialize(shortcuts):
    """The file bytes for a Shortcuts, in Steam's own layout: the root
    dictionary's end marker, then whatever closed the file."""
    return (b"\x00shortcuts\x00" + _serialize_children(shortcuts.children)
            + b"\x08" + shortcuts.trailing)


def _serialize_children(children):
    out = bytearray()
    for child in children:
        if child.kind == TYPE_DICT:
            out += b"\x00" + child.key + b"\x00" + _serialize_children(child.children) + b"\x08"
        elif child.kind == TYPE_STRING:
            out += b"\x01" + child.key + b"\x00" + child.value + b"\x00"
        elif child.kind in (TYPE_INT32, TYPE_UINT64):
            out += bytes([child.kind]) + child.key + b"\x00" + child.value
        else:
            raise ShortcutError(f"cannot write VDF type 0x{child.kind:02x}")
    return bytes(out)


def app_id(exe, name):
    """Steam's id for a non-Steam shortcut: CRC-32 of the executable then the
    name, with the top bit set so it cannot collide with a store id."""
    digest = zlib.crc32(f"{exe}{name}".encode("utf-8")) & 0xFFFFFFFF
    return (digest | 0x80000000) - 0x100000000


def text(entry):
    return entry.value.decode("utf-8", "surrogateescape")


def field_of(entry, key):
    return next((child for child in entry.children if child.key == key), None)


def name_of(entry):
    """The shortcut's name. Steam writes some of these keys capitalized, so read
    either spelling: a file this script wrote before that was learned has them
    lowercase, and must still be removable."""
    for key in (b"AppName", b"appname"):
        value = field_of(entry, key)
        if value is not None:
            return text(value)
    return ""


def exe_of(entry):
    for key in (b"Exe", b"exe"):
        value = field_of(entry, key)
        if value is not None:
            return text(value)
    return ""


def shortcut_entry(name, exe, start_dir, icon, launch_options=""):
    """A shortcut dictionary with the fields and the key spelling Steam itself
    writes: AppName, Exe and StartDir are capitalized, the rest are not. Steam
    looks these up by exact name, so a lowercase appname makes it drop the
    shortcut from the library."""
    exe, start_dir, icon = str(exe), str(start_dir), str(icon)
    quoted_exe = f'"{exe}"' if " " in exe else exe
    directory = start_dir.rstrip("/") + "/"
    quoted_dir = f'"{directory}"' if " " in directory else directory
    return [
        Entry(b"appid", TYPE_INT32, struct.pack("<i", app_id(quoted_exe, name))),
        Entry(b"AppName", TYPE_STRING, name.encode("utf-8")),
        Entry(b"Exe", TYPE_STRING, quoted_exe.encode("utf-8")),
        Entry(b"StartDir", TYPE_STRING, quoted_dir.encode("utf-8")),
        Entry(b"icon", TYPE_STRING, icon.encode("utf-8")),
        Entry(b"ShortcutPath", TYPE_STRING, b""),
        Entry(b"LaunchOptions", TYPE_STRING, launch_options.encode("utf-8")),
        Entry(b"IsHidden", TYPE_INT32, struct.pack("<i", 0)),
        Entry(b"AllowDesktopConfig", TYPE_INT32, struct.pack("<i", 1)),
        Entry(b"AllowOverlay", TYPE_INT32, struct.pack("<i", 1)),
        Entry(b"OpenVR", TYPE_INT32, struct.pack("<i", 0)),
        Entry(b"Devkit", TYPE_INT32, struct.pack("<i", 0)),
        Entry(b"DevkitGameID", TYPE_STRING, b""),
        Entry(b"DevkitOverrideAppID", TYPE_INT32, struct.pack("<i", 0)),
        Entry(b"LastPlayTime", TYPE_INT32, struct.pack("<i", 0)),
        Entry(b"FlatpakAppID", TYPE_STRING, b""),
        Entry(b"tags", TYPE_DICT, children=[Entry(b"0", TYPE_STRING, b"")]),
    ]


def _write(path, shortcuts):
    """Replace the file atomically, keeping the previous one beside it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        path.with_name(path.name + ".bak").write_bytes(path.read_bytes())
    partial = path.with_name(path.name + ".tmp")
    partial.write_bytes(serialize(shortcuts))
    os.replace(partial, path)


def install(path, name, exe, start_dir, icon, launch_options=""):
    """Add the shortcut, or replace the one of the same name: "added" or
    "replaced"."""
    path = Path(path)
    shortcuts = parse(path.read_bytes()) if path.is_file() else Shortcuts()
    wanted = shortcut_entry(name, exe, start_dir, icon, launch_options)
    for entry in shortcuts.entries():
        if name_of(entry) == name:
            entry.children = wanted
            action = "replaced"
            break
    else:
        used = {int(entry.key) for entry in shortcuts.entries() if entry.key.isdigit()}
        index = max(used) + 1 if used else 0
        shortcuts.children.append(Entry(str(index).encode("ascii"), TYPE_DICT, children=wanted))
        action = "added"
    _write(path, shortcuts)
    return action


def remove(path, name):
    """Drop the shortcut of that name; True when one was removed. Steam numbers
    the entries itself, so the rest are renumbered without a gap."""
    path = Path(path)
    if not path.is_file():
        return False
    shortcuts = parse(path.read_bytes())
    kept = [entry for entry in shortcuts.entries() if name_of(entry) != name]
    if len(kept) == len(shortcuts.entries()):
        return False
    shortcuts.children = [Entry(str(index).encode("ascii"), TYPE_DICT, children=entry.children)
                          for index, entry in enumerate(kept)]
    _write(path, shortcuts)
    return True


def describe(path):
    """The (name, executable) pairs of one file, for `list`."""
    if not Path(path).is_file():
        return []
    described = []
    for entry in parse(Path(path).read_bytes()).entries():
        described.append((name_of(entry), exe_of(entry)))
    return described


def steam_roots():
    """Steam's install folders that hold userdata, most likely first."""
    candidates = [os.environ.get("STEAM_ROOT"), os.environ.get("STEAM_DIR"),
                  "~/.local/share/Steam", "~/.steam/steam", "~/.steam/root",
                  "~/.var/app/com.valvesoftware.Steam/data/Steam"]
    roots, seen = [], set()
    for candidate in candidates:
        if not candidate:
            continue
        try:
            path = Path(candidate).expanduser().resolve()
        except OSError:
            continue
        if path in seen or not (path / "userdata").is_dir():
            continue
        seen.add(path)
        roots.append(path)
    return roots


def user_ids(steam_root):
    """The numeric userdata folders, preferring the ones Steam set up."""
    users = [path for path in sorted((Path(steam_root) / "userdata").iterdir()) if path.name.isdigit()]
    with_config = [path for path in users if (path / "config").is_dir()]
    return with_config or users


def shortcuts_path(steam_root, user):
    return Path(steam_root) / "userdata" / str(user) / "config" / "shortcuts.vdf"


def steam_running():
    """Whether this user's Steam client is running, without needing a display."""
    if not Path("/proc").is_dir():
        return False
    uid = os.getuid()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            name = (entry / "comm").read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if name == "steam":
            return True
    return False


def steam_pids():
    """This user's Steam client processes."""
    if not Path("/proc").is_dir():
        return []
    uid = os.getuid()
    pids = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            name = (entry / "comm").read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if name == "steam":
            pids.append(int(entry.name))
    return pids


def _supervisor_unit():
    """The user unit that starts (and restarts) Steam in a Game Mode session.
    Where it exists, stopping it is what actually stops Steam: asking the client
    to quit only makes the session start it again a second later."""
    if shutil.which("systemctl") is None:
        return None
    for unit in ("steam-launcher.service", "steam.service"):
        probe = subprocess.run(["systemctl", "--user", "cat", unit], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode == 0:
            return unit
    return None


def stop_steam(timeout=45):
    """Stop Steam, so it cannot rewrite shortcuts.vdf from its own memory when it
    exits. Returns True only when no Steam process is left.

    Order matters: the client's own quit request first, then the supervising unit
    that would restart it, then the processes themselves. A Steam that is merely
    asked to quit comes back within a second in Game Mode, which is why an entry
    written after that request is silently discarded on the next shutdown."""
    unit = _supervisor_unit()
    if unit is not None:
        subprocess.run(["systemctl", "--user", "stop", unit], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    steam = shutil.which("steam")
    if steam is not None:
        subprocess.run([steam, "-shutdown"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if _wait_for_exit(timeout / 3):
        return True
    for signal_number in (signal.SIGTERM, signal.SIGKILL):
        for pid in steam_pids():
            try:
                os.kill(pid, signal_number)
            except OSError:
                pass
        if _wait_for_exit(timeout / 3):
            return True
    return not steam_running()


def _wait_for_exit(seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if not steam_running():
            return True
        time.sleep(0.5)
    return not steam_running()


def start_steam():
    """Start Steam again, through its supervising unit when the session has one
    (that is how Game Mode starts it), else directly and in Game Mode if the
    gamescope session is the one that was running."""
    unit = _supervisor_unit()
    if unit is not None:
        if subprocess.run(["systemctl", "--user", "start", unit], check=False,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return True
    steam = shutil.which("steam")
    if steam is None:
        return False
    game_mode = os.environ.get("SteamGamepadUI") or \
        Path(f"/run/user/{os.getuid()}/gamescope-0").exists()
    subprocess.Popen([steam, *(["-gamepadui"] if game_mode else [])],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("add", "remove", "list"))
    parser.add_argument("--name", default=DEFAULT_NAME, help="the library entry's name")
    parser.add_argument("--direct", action="store_true",
                        help="start the game straight away instead of the settings screen")
    parser.add_argument("--steam", help="Steam's install folder (default: find it)")
    parser.add_argument("--user", help="the userdata folder number (default: all of them)")
    parser.add_argument("--restart-steam", action="store_true",
                        help="stop Steam, change the file, then start it again")
    args = parser.parse_args()

    roots = [Path(args.steam).expanduser()] if args.steam else steam_roots()
    if not roots:
        print("Steam's folder was not found. Install Steam, or pass --steam.", file=sys.stderr)
        return 1
    targets = [shortcuts_path(root, user.name)
               for root in roots for user in user_ids(root)
               if not args.user or user.name == args.user]
    if not targets:
        print(f"{roots[0]} has no userdata folder for a Steam user yet. "
              "Sign in to Steam once, then run this again.", file=sys.stderr)
        return 1

    if args.action == "list":
        for path in targets:
            for name, exe in describe(path):
                print(f"{path.parent.parent.name}\t{name}\t{exe}")
        return 0

    script = ROOT / ("run_game.sh" if args.direct else "launcher.sh")
    if not script.is_file():
        print(f"{script} is missing; run this from the checkout.", file=sys.stderr)
        return 1

    if steam_running():
        if not args.restart_steam:
            print("Steam is running, and it rewrites shortcuts.vdf when it exits, which\n"
                  "would discard the change. Close Steam first, or pass --restart-steam.",
                  file=sys.stderr)
            return 3
        print("Stopping Steam...")
        if not stop_steam():
            print("Steam did not exit; the shortcut was not changed.", file=sys.stderr)
            return 3

    failures = 0
    for path in targets:
        try:
            if args.action == "add":
                result = install(path, args.name, script, ROOT, ROOT / "assets/icon/icon.png")
            else:
                result = "removed" if remove(path, args.name) else "absent"
        except (ShortcutError, OSError) as error:
            print(f"{path}: {error}", file=sys.stderr)
            failures += 1
            continue
        print(f"{path}: {result}")

    if args.restart_steam:
        start_steam()
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
