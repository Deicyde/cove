#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
import unittest
from pathlib import Path


WATCHDOG = Path(os.environ.get('COVE_WATCHDOG', Path(__file__).resolve().parents[1] / 'cove-watchdog.py'))


def load_watchdog():
    spec = importlib.util.spec_from_file_location('cove_watchdog', WATCHDOG)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def proc(ppid: int, tty: str, cpu: float, cmd: str) -> dict:
    return {'ppid': ppid, 'tty': tty, 'cpu': cpu, 'time': '0:01.00', 'cmd': cmd}


class ClassifyTest(unittest.TestCase):
    def test_only_abduco_processes_are_attach_clients(self) -> None:
        sess = 'cove-839365273'
        procs = {
            # run.sh starts kitty with the first session as its command, from a
            # terminal, and under load kitty sits above the spin threshold.
            100: proc(1, 'ttys000', 54.0,
                      '/Users/u/cove/kitty/launcher/kitty --title cove --listen-on unix:/tmp/cove-kitty '
                      f'-o shell=/Users/u/cove/cove/cove-shell.sh /Users/u/cove/cove/bin/abduco -a {sess}'),
            200: proc(100, 'ttys012', 0.0, f'/Users/u/cove/cove/bin/abduco -a {sess}'),
            300: proc(1, '??', 0.1, f'/Users/u/cove/cove/bin/abduco -A {sess} /bin/zsh'),
            301: proc(300, 'ttys013', 0.0, '-zsh'),
            # Godot ending a session mentions it too.
            400: proc(1, 'ttys000', 0.0, f'/usr/bin/pkill -f abduco -A {sess} '),
        }

        masters, clients = load_watchdog().classify(procs)

        self.assertEqual(clients, [(200, sess)])
        self.assertEqual(masters, {sess: 300})


if __name__ == '__main__':
    unittest.main()
