# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/steam_shortcut.py: Steam's shortcuts.vdf is edited without disturbing
the shortcuts already in it."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import steam_shortcut as steam


def fixture():
    """A shortcuts.vdf as Steam writes one: root dictionary, one entry with
    Steam's own key spelling, and the closing byte of the file."""
    return (b"\x00shortcuts\x00"
            b"\x000\x00"
            b"\x02appid\x00" + struct.pack("<i", -1234) +
            b"\x01AppName\x00Already Here\x00"
            b"\x01Exe\x00/usr/bin/existing\x00"
            b"\x08"
            b"\x08")


class ShortcutTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "config" / "shortcuts.vdf"

    def write(self, data):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_bytes(data)

    def test_a_steam_file_round_trips_byte_for_byte(self):
        self.write(fixture())
        self.assertEqual(steam.serialize(steam.parse(self.path.read_bytes())), fixture())

    def test_an_added_shortcut_follows_the_existing_ones(self):
        self.write(fixture())
        self.assertEqual(steam.install(self.path, "Dead or Alive 3++", Path("/game/run_game.sh"),
                                       Path("/game"), Path("/game/icon.png")), "added")
        entries = steam.parse(self.path.read_bytes()).entries()
        self.assertEqual([steam.name_of(entry) for entry in entries],
                         ["Already Here", "Dead or Alive 3++"])
        self.assertEqual(entries[1].key, b"1")
        exe = steam.field_of(entries[1], b"Exe")
        self.assertEqual(exe.value, b"/game/run_game.sh")

    def test_adding_twice_replaces_the_same_entry(self):
        self.write(fixture())
        steam.install(self.path, "Dead or Alive 3++", Path("/a/run.sh"), Path("/a"), Path("/a/i.png"))
        steam.install(self.path, "Dead or Alive 3++", Path("/b/run.sh"), Path("/b"), Path("/b/i.png"))
        entries = steam.parse(self.path.read_bytes()).entries()
        self.assertEqual(len(entries), 2)
        self.assertEqual(steam.field_of(entries[1], b"Exe").value, b"/b/run.sh")
        self.assertEqual(steam.field_of(entries[1], b"StartDir").value, b"/b/")

    def test_removing_one_shortcut_renumbers_the_rest(self):
        self.write(fixture())
        steam.install(self.path, "Second", Path("/g/s.sh"), Path("/g"), Path("/g/i.png"))
        self.assertTrue(steam.remove(self.path, "Already Here"))
        entries = steam.parse(self.path.read_bytes()).entries()
        self.assertEqual([(entry.key, steam.name_of(entry)) for entry in entries],
                         [(b"0", "Second")])
        self.assertFalse(steam.remove(self.path, "Already Here"))

    def test_a_new_file_is_a_valid_shortcuts_file(self):
        steam.install(self.path, "Only", Path("/g/run.sh"), Path("/g"), Path("/g/i.png"))
        data = self.path.read_bytes()
        self.assertTrue(data.startswith(b"\x00shortcuts\x00"))
        self.assertTrue(data.endswith(b"\x08\x08"))
        self.assertEqual([name for name, _ in steam.describe(self.path)], ["Only"])

    def test_a_previous_file_is_kept_beside_the_new_one(self):
        self.write(fixture())
        steam.install(self.path, "Added", Path("/g/run.sh"), Path("/g"), Path("/g/i.png"))
        self.assertEqual(self.path.with_name("shortcuts.vdf.bak").read_bytes(), fixture())

    def test_a_path_with_spaces_is_quoted_for_steam(self):
        steam.install(self.path, "Spaced", Path("/my games/run.sh"), Path("/my games"),
                      Path("/my games/i.png"))
        entry = steam.parse(self.path.read_bytes()).entries()[0]
        self.assertEqual(steam.field_of(entry, b"Exe").value, b'"/my games/run.sh"')
        self.assertEqual(steam.field_of(entry, b"StartDir").value, b'"/my games/"')

    def test_a_shortcut_id_sets_the_top_bit(self):
        value = steam.app_id("/a/run.sh", "Dead or Alive 3++")
        self.assertLess(value, 0)
        self.assertEqual(value, steam.app_id("/a/run.sh", "Dead or Alive 3++"))

    def test_a_file_it_cannot_read_is_refused_not_overwritten(self):
        for data in (b"\x01not a root dictionary", b"\x00shortcuts\x00\x02appid\x00\x01\x02\x03",
                      b"\x00shortcuts\x00\x000\x00\x01AppName\x00No end\x00"):
            with self.subTest(data=data):
                self.write(data)
                with self.assertRaises(steam.ShortcutError):
                    steam.install(self.path, "X", Path("/g/run.sh"), Path("/g"), Path("/g/i.png"))
                self.assertEqual(self.path.read_bytes(), data)

    def test_the_keys_are_spelled_as_steam_spells_them(self):
        """Steam looks these up by exact name: a lowercase appname drops the
        shortcut from the library, which is how it silently went missing."""
        steam.install(self.path, "Named", Path("/g/run.sh"), Path("/g"), Path("/g/i.png"))
        entry = steam.parse(self.path.read_bytes()).entries()[0]
        keys = {child.key for child in entry.children}
        self.assertIn(b"AppName", keys)
        self.assertIn(b"Exe", keys)
        self.assertNotIn(b"appname", keys)
        self.assertNotIn(b"exe", keys)

    def test_a_lowercase_entry_written_earlier_is_still_removed(self):
        self.write(fixture().replace(b"AppName", b"appname").replace(b"Exe", b"exe"))
        self.assertEqual([name for name, _ in steam.describe(self.path)], ["Already Here"])
        self.assertTrue(steam.remove(self.path, "Already Here"))


if __name__ == "__main__":
    unittest.main()
