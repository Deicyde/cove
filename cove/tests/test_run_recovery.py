#!/usr/bin/env python3

from __future__ import annotations

import fcntl
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class RunRecoveryTest(unittest.TestCase):
    def write_executable(self, path: Path, body: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)

    def run_launcher(
        self, sessions: list[str], *, lock_held: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temp = tempfile.TemporaryDirectory(prefix='cove-run-test-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        repo = root / 'repo'
        runtime = root / 'runtime' / 'cove'
        socket = Path(f'{runtime}-kitty')
        fake_bin = root / 'bin'

        source = (REPO_ROOT / 'cove' / 'run.sh').read_text().replace('/tmp/cove', str(runtime))
        launcher = repo / 'cove' / 'run.sh'
        self.write_executable(launcher, source)
        (repo / 'cove' / '.godot').mkdir(parents=True)
        (repo / 'cove' / '.godot' / 'extension_list.cfg').write_text('')

        self.write_executable(
            repo / 'kitty' / 'launcher' / 'kitty',
            '#!/bin/sh\n'
            'printf "%s\\n" "$@" > "$KITTY_ARGS"\n'
            'mkdir -p "$KITTY_COVE_DIR"\n'
            ': > "$KITTY_COVE_DIR/term-9.rgba"\n'
            ': > "$KITTY_READY"\n'
            'while [ ! -f "$GODOT_DONE" ]; do sleep 0.01; done\n',
        )
        self.write_executable(
            repo / 'kitty' / 'launcher' / 'kitty.app' / 'Contents' / 'MacOS' / 'kitten',
            '#!/bin/sh\n'
            'case "${4:-}" in\n'
            'ls) [ -f "$KITTY_READY" ] || exit 1; printf \'%s\\n\' \'[{"title":"ready"}]\' ;;\n'
            'launch) printf "%s\\n" "$*" >> "$LAUNCH_ARGS" ;;\n'
            'resize-os-window) printf "%s\\n" "$*" >> "$RESIZE_ARGS" ;;\n'
            'esac\n',
        )
        self.write_executable(
            repo / 'cove' / 'bin' / 'abduco',
            '#!/bin/sh\ncat "$ABDUCO_LIST"\n',
        )
        self.write_executable(repo / 'cove' / 'cove-shell.sh', '#!/bin/sh\nexit 0\n')
        self.write_executable(repo / 'cove' / 'cove-remote-start.sh', '#!/bin/sh\nexit 0\n')
        godot = fake_bin / 'godot'
        self.write_executable(godot, '#!/bin/sh\n: > "$GODOT_DONE"\n')

        runtime.mkdir(parents=True)
        (runtime / 'state.json').write_text('saved-layout\n')
        (runtime / 'term-7.rgba').write_text('stale-kitty-frame\n')
        (runtime / 'term-1000000.rgba').write_text('app-frame\n')
        socket.write_text('stale-socket\n')
        listing = ['Active sessions (on host test)']
        listing.extend(f'  Thu 2026-09-24 00:00:00 {session}' for session in sessions)
        listing.append('+ Thu 2026-09-24 00:00:00 cove-333')
        (root / 'abduco-list').write_text('\n'.join(listing) + '\n')

        env = {
            'ABDUCO_LIST': str(root / 'abduco-list'),
            'GODOT': str(godot),
            'GODOT_DONE': str(root / 'godot-done'),
            'HOME': str(root / 'home'),
            'KITTY_ARGS': str(root / 'kitty-args'),
            'KITTY_READY': str(root / 'kitty-ready'),
            'LAUNCH_ARGS': str(root / 'launch-args'),
            'PATH': f'{fake_bin}:/usr/bin:/bin',
            'RESIZE_ARGS': str(root / 'resize-args'),
            'SHELL': '/bin/zsh',
        }
        lock_file = None
        if lock_held:
            lock_file = Path(f'{runtime}-launch.lock').open('w')
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result = subprocess.run(
                ['/bin/bash', str(launcher)], cwd=repo, env=env,
                text=True, capture_output=True, timeout=10, check=False,
            )
        finally:
            if lock_file is not None:
                fcntl.flock(lock_file, fcntl.LOCK_UN)
                lock_file.close()
        return result, root

    def test_concurrent_launcher_is_rejected(self) -> None:
        result, root = self.run_launcher([], lock_held=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another Cove launch is already in progress', result.stderr)
        self.assertFalse((root / 'kitty-args').exists())

    def test_cold_start_keeps_existing_behavior(self) -> None:
        result, root = self.run_launcher([])
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((runtime / 'state.json').exists())
        self.assertEqual((root / 'kitty-args').read_text().splitlines()[-1], str(root / 'repo/cove/cove-shell.sh'))
        self.assertFalse((root / 'launch-args').exists())
        self.assertFalse((root / 'resize-args').exists())

    def test_restart_recovers_sessions_and_repaints(self) -> None:
        result, root = self.run_launcher(['cove-111', 'cove-bad', 'cove-222'])
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((runtime / 'state.json').read_text(), 'saved-layout\n')
        self.assertFalse((runtime / 'term-7.rgba').exists())
        self.assertTrue((runtime / 'term-1000000.rgba').exists())
        self.assertEqual(
            (root / 'kitty-args').read_text().splitlines()[-3:],
            [str(root / 'repo/cove/bin/abduco'), '-a', 'cove-111'],
        )
        self.assertIn('-a cove-222', (root / 'launch-args').read_text())
        self.assertNotIn('cove-333', (root / 'launch-args').read_text())
        self.assertEqual(
            (root / 'resize-args').read_text().splitlines(),
            [
                f'@ --to unix:{root / "runtime/cove-kitty"} resize-os-window --match all --unit cells --incremental --width 1',
                f'@ --to unix:{root / "runtime/cove-kitty"} resize-os-window --match all --unit cells --incremental --width=-1',
            ],
        )


if __name__ == '__main__':
    unittest.main()
