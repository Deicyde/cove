#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class DevRestartRecoveryTest(unittest.TestCase):
    def write_executable(self, path: Path, body: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)

    def copy_script(self, name: str, repo: Path, runtime: Path) -> Path:
        source = (REPO_ROOT / 'cove' / name).read_text()
        self.assertIn('/tmp/cove', source)
        source = source.replace('/tmp/cove', str(runtime))
        self.assertNotIn('/tmp/cove', source)
        target = repo / 'cove' / name
        self.write_executable(target, source)
        return target

    def test_dev_delegates_existing_sessions_to_warm_restart(self) -> None:
        with tempfile.TemporaryDirectory(prefix='cove-dev-test-') as tdir:
            root = Path(tdir)
            repo = root / 'repo'
            runtime = root / 'runtime' / 'cove'
            fake_bin = root / 'bin'
            launcher = self.copy_script('dev.sh', repo, runtime)

            kitty = repo / 'kitty' / 'launcher' / 'kitty'
            kitten = repo / 'kitty' / 'launcher' / 'kitty.app' / 'Contents' / 'MacOS' / 'kitten'
            godot = fake_bin / 'godot'
            unexpected = root / 'unexpected-start'
            for executable in (kitty, kitten, godot):
                self.write_executable(executable, f'#!/bin/sh\n: > "{unexpected}"\n')
            self.write_executable(
                repo / 'cove' / 'bin' / 'abduco',
                '#!/bin/sh\nprintf \'%s\\n\' \'Active sessions (on host test)\' \'* Thu 2026-09-24 00:00:00 cove-111\'\n',
            )
            reload_called = root / 'reload-called'
            remote_called = root / 'remote-called'
            self.write_executable(
                repo / 'cove' / 'reload-kitty.sh',
                f'#!/bin/sh\nprintf "%s\\n" "$COVE_LAUNCH_LOCK_HELD" > "{reload_called}"\n',
            )
            self.write_executable(repo / 'cove' / 'cove-remote-start.sh', f'#!/bin/sh\n: > "{remote_called}"\n')
            (repo / 'cove' / '.godot').mkdir(parents=True)
            (repo / 'cove' / '.godot' / 'extension_list.cfg').write_text('')

            runtime.mkdir(parents=True)
            state = runtime / 'state.json'
            state.write_text('saved-layout\n')
            result = subprocess.run(
                ['/bin/bash', str(launcher)],
                cwd=repo,
                env={
                    'GODOT': str(godot),
                    'HOME': str(root / 'home'),
                    'PATH': f'{fake_bin}:/usr/bin:/bin',
                    'SHELL': '/bin/zsh',
                },
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(reload_called.read_text(), '1\n')
            self.assertTrue(remote_called.exists())
            self.assertFalse(unexpected.exists())
            self.assertEqual(state.read_text(), 'saved-layout\n')
            self.assertEqual(
                (runtime / 'dev-env').read_text().splitlines(),
                [
                    f'COVE_KITTEN={kitten}',
                    f'COVE_KITTY_SOCKET=unix:{runtime}-kitty',
                    f'APP={repo / "cove"}',
                    f'GODOT={godot}',
                ],
            )

    def exercise_reload(self, *, launch_times_out: bool = False, stays_attached: bool = False) -> None:
        with tempfile.TemporaryDirectory(prefix='cove-reload-test-') as tdir:
            root = Path(tdir)
            repo = root / 'repo'
            runtime = root / 'runtime' / 'cove'
            socket = Path(f'{runtime}-kitty')
            fake_bin = root / 'bin'
            launcher = self.copy_script('reload-kitty.sh', repo, runtime)

            kitty = repo / 'kitty' / 'launcher' / 'kitty'
            kitten = repo / 'kitty' / 'launcher' / 'kitty.app' / 'Contents' / 'MacOS' / 'kitten'
            abduco = repo / 'cove' / 'bin' / 'abduco'
            wrapper = repo / 'cove' / 'cove-shell.sh'
            reattach = repo / 'cove' / 'cove-reattach.sh'
            godot = fake_bin / 'godot'
            counter = root / 'abduco-count'
            attached = root / 'abduco-attached'
            detached = root / 'abduco-detached'
            second_attached = root / 'second-attached'
            godot_started = root / 'godot-started'
            kitty_ready = root / 'kitty-ready'
            kitty_exited = root / 'kitty-exited'
            kitty_args = root / 'kitty-args'
            launch_args = root / 'launch-args'

            self.write_executable(
                abduco,
                '#!/bin/sh\n'
                'if [ "$#" -ne 0 ]; then exit 0; fi\n'
                'count=$(cat "$ABDUCO_COUNT" 2>/dev/null || echo 0)\n'
                'count=$((count + 1)); printf "%s\\n" "$count" > "$ABDUCO_COUNT"\n'
                'if [ "$count" -le 3 ]; then cat "$ABDUCO_ATTACHED"; else cat "$ABDUCO_DETACHED"; fi\n',
            )
            self.write_executable(
                kitty,
                f'''#!{sys.executable}
import os
import signal
import sys
import time
from pathlib import Path

Path(os.environ['KITTY_ARGS']).write_text('\\n'.join(sys.argv[1:]) + '\\n')
Path(os.environ['KITTY_READY']).touch()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while not Path(os.environ['GODOT_STARTED']).exists():
    time.sleep(0.01)
Path(os.environ['KITTY_EXITED']).touch()
''',
            )
            self.write_executable(
                kitten,
                '#!/bin/sh\n'
                'case "${4:-}" in\n'
                'ls)\n'
                '    [ -f "$KITTY_READY" ] || exit 1\n'
                '    if [ -f "$SECOND_ATTACHED" ]; then\n'
                '        printf \'%s\\n\' \'[{"title":"cove-111"},{"title":"cove-222"}]\'\n'
                '    else\n'
                '        printf \'%s\\n\' \'[{"title":"cove-111"}]\'\n'
                '    fi\n'
                '    ;;\n'
                # A launch that times out under load can still open its window.
                'launch) printf "%s\\n" "$*" >> "$LAUNCH_ARGS"; : > "$SECOND_ATTACHED"; [ "$LAUNCH_TIMES_OUT" != 1 ] ;;\n'
                'esac\n',
            )
            self.write_executable(wrapper, '#!/bin/sh\nexit 0\n')
            self.write_executable(
                godot,
                '#!/bin/sh\nprintf "%s\\n" "$*" > "$GODOT_ARGS"\n: > "$GODOT_STARTED"\n',
            )
            self.write_executable(fake_bin / 'pkill', '#!/bin/sh\nexit 1\n')
            self.write_executable(
                fake_bin / 'ps',
                '#!/bin/sh\n'
                'if [ "${1:-}" = -p ]; then\n'
                '    printf \'%s\\n\' \'/fake/launcher/kitty --title cove\'\n'
                'else\n'
                '    printf "%s %s\\n" "$OLD_KITTY_PID" "/fake/launcher/kitty --title cove"\n'
                'fi\n',
            )

            old_kitty = subprocess.Popen(['/bin/sleep', '30'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            reaper = threading.Thread(target=old_kitty.wait, daemon=True)
            reaper.start()
            runtime.mkdir(parents=True)
            state = runtime / 'state.json'
            stale_frame = runtime / 'term-7.rgba'
            app_frame = runtime / 'term-1000000.rgba'
            state.write_text('saved-layout\n')
            stale_frame.write_text('stale\n')
            app_frame.write_text('app\n')
            socket.write_text('stale socket\n')
            (runtime / 'kitty.pid').write_text(f'{old_kitty.pid}\n')
            (runtime / 'dev-env').write_text(
                f'COVE_KITTEN={kitten}\nCOVE_KITTY_SOCKET=unix:{socket}\n'
                f'APP={repo / "cove"}\nGODOT={godot}\nCOVE_KITTY_PID={old_kitty.pid}\n'
            )
            attached.write_text(
                'Active sessions (on host test)\n'
                '* Thu 2026-09-24 00:00:00 cove-111\n'
                '* Thu 2026-09-24 00:00:00 cove-222\n'
            )
            detached.write_text(attached.read_text() if stays_attached else
                'Active sessions (on host test)\n'
                '  Thu 2026-09-24 00:00:00 cove-111\n'
                '  Thu 2026-09-24 00:00:00 cove-222\n'
            )
            env = {
                'ABDUCO_ATTACHED': str(attached),
                'ABDUCO_COUNT': str(counter),
                'ABDUCO_DETACHED': str(detached),
                'GODOT_ARGS': str(root / 'godot-args'),
                'GODOT_STARTED': str(godot_started),
                'HOME': str(root / 'home'),
                'KITTY_ARGS': str(kitty_args),
                'KITTY_EXITED': str(kitty_exited),
                'KITTY_READY': str(kitty_ready),
                'LAUNCH_ARGS': str(launch_args),
                'OLD_KITTY_PID': str(old_kitty.pid),
                'PATH': f'{fake_bin}:/usr/bin:/bin',
                'LAUNCH_TIMES_OUT': '1' if launch_times_out else '0',
                'SECOND_ATTACHED': str(second_attached),
                'SHELL': '/bin/zsh',
            }
            try:
                result = subprocess.run(
                    ['/bin/bash', str(launcher)], cwd=repo, env=env,
                    text=True, capture_output=True, timeout=20, check=False,
                )
            finally:
                if reaper.is_alive():
                    old_kitty.terminate()
                reaper.join(timeout=2)
                if reaper.is_alive():
                    old_kitty.kill()
                    reaper.join(timeout=2)

            deadline = time.monotonic() + 2
            while not kitty_exited.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(counter.read_text(), '51\n' if stays_attached else '4\n')
            self.assertEqual(state.read_text(), 'saved-layout\n')
            self.assertFalse(stale_frame.exists())
            self.assertTrue(app_frame.exists())
            self.assertFalse(socket.exists())
            self.assertEqual(kitty_args.read_text().splitlines()[-2:], [str(reattach), 'cove-111'])
            # Exactly one launch: the window that landed isn't opened twice.
            self.assertEqual(
                launch_args.read_text().strip(),
                f'@ --to unix:{socket} launch --type=os-window {reattach} cove-222',
            )
            self.assertNotIn("couldn't reattach", result.stderr)
            if stays_attached:
                self.assertIn('still attached elsewhere, reattaching anyway: cove-111 cove-222', result.stderr)
            self.assertTrue((runtime / 'kitty.pid').read_text().strip().isdigit())
            self.assertNotEqual((runtime / 'kitty.pid').read_text().strip(), str(old_kitty.pid))
            self.assertIn(f'COVE_KITTY_SOCKET=unix:{socket}\n', (runtime / 'dev-env').read_text())
            self.assertEqual((root / 'godot-args').read_text().strip(), f'--path {repo / "cove"}')
            self.assertTrue(kitty_exited.exists())

    def test_reload_recovers_after_old_kitty_detaches(self) -> None:
        self.exercise_reload()

    def test_reload_keeps_sessions_that_stay_attached(self) -> None:
        self.exercise_reload(stays_attached=True)

    def test_reload_does_not_relaunch_a_window_that_landed(self) -> None:
        self.exercise_reload(launch_times_out=True)


if __name__ == '__main__':
    unittest.main()
