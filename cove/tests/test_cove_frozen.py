#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / 'cove-frozen.py'


def load():
    spec = importlib.util.spec_from_file_location('cove_frozen', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VerdictTest(unittest.TestCase):
    def test_each_stage(self) -> None:
        v = load().verdict
        self.assertIn('kitty stopped drawing', v(True, 0, 300, [0.0], 0))
        self.assertIn("the Cove (Godot) isn't showing", v(True, 4, 300, [0.0], 0))
        self.assertIn('session is gone', v(False, 0, None, [], 0))
        self.assertIn('spinning', v(False, 0, 300, [97.0], 0))
        self.assertIn('deadlocked', v(False, 0, 300, [0.0], 512))
        self.assertIn('printed nothing', v(False, 0, 300, [0.0], 0))
        self.assertIn('sudo sample 2901', v(False, 0, 300, [0.0], 0, kitty_answers=False, kitty_pid=2901))


if __name__ == '__main__':
    unittest.main()
