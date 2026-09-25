#!/usr/bin/env python3

from __future__ import annotations

import json
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
            # If the handoff ever regresses, dev.sh falls through to stopping
            # "the" Cove: keep that away from the real one running this test.
            stopped = root / 'stop-attempted'
            for tool in ('pkill', 'ps'):
                self.write_executable(fake_bin / tool, f'#!/bin/sh\n: > "{stopped}"\nexit 1\n')
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
            self.assertFalse(stopped.exists())
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

    def exercise_reload(
        self, *, launch_times_out: bool = False, stays_attached: bool = False,
        kitty_broken: bool = False, first_session_dead: bool = False,
        stale_pid_file: bool = False, listing_fails_after_stop: bool = False,
        ls_blinks: bool = False, launch_lands_late: bool = False,
    ) -> None:
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
            landed = root / 'landed'   # one file per session with a window
            landed.mkdir()
            godot_started = root / 'godot-started'
            kitty_ready = root / 'kitty-ready'
            kitty_exited = root / 'kitty-exited'
            kitty_args = root / 'kitty-args'
            launch_args = root / 'launch-args'
            old_ls = root / 'old-ls.json'
            ls_count = root / 'ls-count'

            self.write_executable(
                abduco,
                '#!/bin/sh\n'
                'if [ "$#" -ne 0 ]; then exit 0; fi\n'
                'count=$(cat "$ABDUCO_COUNT" 2>/dev/null || echo 0)\n'
                'count=$((count + 1)); printf "%s\\n" "$count" > "$ABDUCO_COUNT"\n'
                'if [ "$ABDUCO_FAIL_AFTER" -ne 0 ] && [ "$count" -gt "$ABDUCO_FAIL_AFTER" ]; then exit 1; fi\n'
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

args = Path(os.environ['KITTY_ARGS'])
args.write_text('\\n'.join(sys.argv[1:]) + '\\n')
if os.environ['NEW_KITTY_BROKEN'] != '1':
    Path(os.environ['KITTY_READY']).touch()
    # Its first window: the session's, unless that died (abduco -a fails).
    if os.environ['FIRST_SESSION_DEAD'] != '1':
        (Path(os.environ['LANDED']) / sys.argv[-1]).write_text('pre-exec')
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
# Never outlive the test, even if the script under test was SIGKILLed
# before it could stop us.
deadline = time.monotonic() + 30
while not Path(os.environ['GODOT_STARTED']).exists():
    if time.monotonic() > deadline or not args.parent.exists():
        sys.exit(1)
    time.sleep(0.01)
Path(os.environ['KITTY_EXITED']).touch()
''',
            )
            # kitty's ls: indented JSON, one cmdline element per line, and a
            # window's cmdline is its live argv. A landed window shows
            # `cove-reattach.sh cove-N` until the script execs, then
            # `abduco -a cove-N`. The first window (kitty's own) is caught
            # before the exec, the launched ones after it. A decoy first: its
            # title, user vars and foreground process (someone ran abduco in
            # its shell) name cove-111, so it mustn't count as that window.
            fake_ls = root / 'fake-ls.py'
            fake_ls.write_text(f'''import json, os
from pathlib import Path
abduco, reattach = {str(abduco)!r}, {str(reattach)!r}
windows = [{{"cmdline": ["/bin/zsh"], "title": "cove-111", "user_vars": {{"s": "cove-111"}},
            "foreground_processes": [{{"cmdline": [abduco, "-a", "cove-111"]}}]}}]
for s in sorted(os.listdir(os.environ["LANDED"])):
    if (Path(os.environ["LANDED"]) / s).read_text() == "pre-exec":
        cmd = ["/bin/sh", reattach, s]
    else:
        cmd = [abduco, "-a", s]
    windows.append({{"cmdline": cmd, "title": "zsh", "foreground_processes": [{{"cmdline": [abduco, "-a", s]}}]}})
print(json.dumps([{{"tabs": [{{"windows": windows}}]}}], indent=2, sort_keys=True))
''')
            self.write_executable(
                kitten,
                '#!/bin/sh\n'
                'case "${4:-}" in\n'
                'ls)\n'
                '    if kill -0 "$OLD_KITTY_PID" 2>/dev/null; then cat "$OLD_LS"; exit 0; fi\n'
                '    [ -f "$KITTY_READY" ] || exit 1\n'
                '    n=$(cat "$LS_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); printf "%s\\n" "$n" > "$LS_COUNT"\n'
                '    if [ -f "$LATE" ] && [ "$n" -ge "$(cut -d" " -f1 "$LATE")" ]; then : > "$LANDED/$(cut -d" " -f2 "$LATE")"; fi\n'
                # Under load, right after the ready check (call 1), ls can fail
                # or come back without the reattach windows yet.
                '    if [ "$LS_BLINKS" = 1 ]; then case "$n" in 2) exit 1 ;; 3) echo "[]"; exit 0 ;; esac; fi\n'
                f'    exec "{sys.executable}" "{fake_ls}"\n'
                '    ;;\n'
                'get-text) printf "screen of %s\\n" "$6" ;;\n'
                'launch)\n'
                '    printf "%s\\n" "$*" >> "$LAUNCH_ARGS"\n'
                '    eval "s=\\${$#}"\n'
                '    if [ "$s" = cove-111 ] && [ "$FIRST_SESSION_DEAD" = 1 ]; then exit 1; fi\n'
                # A launch that times out under load can still open its window,
                # at once or (LAUNCH_LANDS_LATE) 30 ls polls after it gave up:
                # counted in polls, not seconds, as each poll's time varies.
                '    if [ "$LAUNCH_LANDS_LATE" = 1 ]; then\n'
                '        n=$(cat "$LS_COUNT" 2>/dev/null || echo 0); printf "%s %s\\n" $((n + 30)) "$s" > "$LATE"\n'
                '        echo "Timed out waiting for a response from kitty" >&2; exit 1\n'
                '    fi\n'
                '    : > "$LANDED/$s"; [ "$LAUNCH_TIMES_OUT" != 1 ] ;;\n'
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
                '    if [ "$2" = "$OLD_KITTY_PID" ]; then echo "/fake/launcher/kitty --title cove"; else echo "/bin/sleep 30"; fi\n'
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
            # A crash can leave kitty.pid naming a pid that's since been reused
            # by something else, which must survive the reload.
            bystander = None
            if stale_pid_file:
                bystander = subprocess.Popen(['/bin/sleep', '30'])
                self.addCleanup(bystander.wait)
                self.addCleanup(bystander.kill)
            (runtime / 'kitty.pid').write_text(f'{(bystander or old_kitty).pid}\n')
            (runtime / 'dev-env').write_text(
                f'COVE_KITTEN={kitten}\nCOVE_KITTY_SOCKET=unix:{socket}\n'
                f'APP={repo / "cove"}\nGODOT={godot}\nCOVE_KITTY_PID={old_kitty.pid}\n'
            )
            # The old kitty's windows: a first-run session (-A), a reattached one
            # (-a), and a window with no session, whose screen isn't saved.
            old_ls.write_text(json.dumps([{'tabs': [{'windows': [
                {'id': 1, 'foreground_processes': [{'cmdline': [str(abduco), '-A', 'cove-111', '/bin/zsh']}]},
                {'id': 2, 'foreground_processes': [{'cmdline': [str(abduco), '-a', 'cove-222']}]},
                {'id': 3, 'foreground_processes': [{'cmdline': ['/bin/zsh']}]},
            ]}]}]))
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
                # The first listing is the up-front check, before kitty stops.
                'ABDUCO_FAIL_AFTER': '1' if listing_fails_after_stop else '0',
                'FIRST_SESSION_DEAD': '1' if first_session_dead else '0',
                'GODOT_ARGS': str(root / 'godot-args'),
                'GODOT_STARTED': str(godot_started),
                'HOME': str(root / 'home'),
                'KITTY_ARGS': str(kitty_args),
                'KITTY_EXITED': str(kitty_exited),
                'KITTY_READY': str(kitty_ready),
                'LANDED': str(landed),
                'LAUNCH_ARGS': str(launch_args),
                'LS_BLINKS': '1' if ls_blinks else '0',
                'LS_COUNT': str(ls_count),
                'OLD_KITTY_PID': str(old_kitty.pid),
                'PATH': f'{fake_bin}:/usr/bin:/bin',
                'LAUNCH_TIMES_OUT': '1' if launch_times_out else '0',
                'LAUNCH_LANDS_LATE': '1' if launch_lands_late else '0',
                'LATE': str(root / 'late-launch'),
                'NEW_KITTY_BROKEN': '1' if kitty_broken else '0',
                'OLD_LS': str(old_ls),
                'REATTACH': str(reattach),
                'SHELL': '/bin/zsh',
            }
            try:
                result = subprocess.run(
                    ['/bin/bash', str(launcher)], cwd=repo, env=env,
                    text=True, capture_output=True, timeout=60, check=False,
                )
            finally:
                if reaper.is_alive():
                    old_kitty.terminate()
                reaper.join(timeout=2)
                if reaper.is_alive():
                    old_kitty.kill()
                    reaper.join(timeout=2)

            # Generous: the fake kitty is a python process, slow to notice
            # Godot under heavy load.
            deadline = time.monotonic() + 15
            while not kitty_exited.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            # Screens are saved from the old kitty before it's stopped.
            scroll = runtime / 'scroll'
            self.assertEqual(sorted(f.name for f in scroll.iterdir()), ['cove-111.ansi', 'cove-222.ansi'])
            self.assertEqual((scroll / 'cove-111.ansi').read_text(), 'screen of id:1\n')
            self.assertEqual((scroll / 'cove-222.ansi').read_text(), 'screen of id:2\n')
            if bystander is not None:
                self.assertIsNone(bystander.poll(), 'killed the process a stale kitty.pid named')
            if kitty_broken or listing_fails_after_stop:
                # A failed reload keeps dev-env (reload.sh needs it) minus the
                # dead kitty's pid, and doesn't start Godot.
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('failed to list abduco sessions after stopping kitty'
                              if listing_fails_after_stop else 'kitty did not become ready',
                              result.stderr)
                self.assertEqual(
                    (runtime / 'dev-env').read_text().splitlines(),
                    [f'COVE_KITTEN={kitten}', f'COVE_KITTY_SOCKET=unix:{socket}',
                     f'APP={repo / "cove"}', f'GODOT={godot}'],
                )
                self.assertFalse((runtime / 'kitty.pid').exists())
                self.assertFalse(godot_started.exists())
                self.assertEqual(state.read_text(), 'saved-layout\n')
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(counter.read_text(), '51\n' if stays_attached else '4\n')
            self.assertEqual(state.read_text(), 'saved-layout\n')
            self.assertFalse(stale_frame.exists())
            self.assertTrue(app_frame.exists())
            self.assertFalse(socket.exists())
            self.assertEqual(kitty_args.read_text().splitlines()[-2:], [str(reattach), 'cove-111'])
            launch = f'@ --to unix:{socket} launch --type=os-window {reattach}'
            if first_session_dead:
                # Its window never came: the others are reattached anyway, it
                # is retried, then reported, and Godot still starts.
                self.assertEqual(launch_args.read_text().splitlines(),
                                 [f'{launch} cove-222', f'{launch} cove-111', f'{launch} cove-111'])
                self.assertIn("couldn't reattach cove-111", result.stderr)
            else:
                # Exactly one launch: the window that landed isn't opened twice.
                self.assertEqual(launch_args.read_text().strip(), f'{launch} cove-222')
                self.assertNotIn("couldn't reattach", result.stderr)
            if stays_attached:
                self.assertIn('still attached elsewhere, reattaching anyway: cove-111 cove-222', result.stderr)
            self.assertTrue((runtime / 'kitty.pid').read_text().strip().isdigit())
            self.assertNotEqual((runtime / 'kitty.pid').read_text().strip(), str(old_kitty.pid))
            self.assertIn(f'COVE_KITTY_SOCKET=unix:{socket}\n', (runtime / 'dev-env').read_text())
            self.assertIn(f'COVE_KITTY_PID={(runtime / "kitty.pid").read_text().strip()}\n',
                          (runtime / 'dev-env').read_text())
            self.assertEqual((root / 'godot-args').read_text().strip(), f'--path {repo / "cove"}')
            self.assertTrue(kitty_exited.exists())

    def test_reload_recovers_after_old_kitty_detaches(self) -> None:
        self.exercise_reload()

    def test_reload_keeps_sessions_that_stay_attached(self) -> None:
        self.exercise_reload(stays_attached=True)

    def test_failed_reload_keeps_dev_env(self) -> None:
        self.exercise_reload(kitty_broken=True)

    def test_listing_failure_after_stop_drops_the_dead_pid(self) -> None:
        self.exercise_reload(listing_fails_after_stop=True)

    def test_dead_first_session_does_not_sink_the_reload(self) -> None:
        self.exercise_reload(first_session_dead=True)

    def test_ls_failing_or_empty_for_a_moment_does_not_sink_the_reload(self) -> None:
        self.exercise_reload(ls_blinks=True)

    def test_stale_pid_file_does_not_kill_a_bystander(self) -> None:
        self.exercise_reload(stale_pid_file=True)

    def test_reload_sh_restarts_a_dead_kitty(self) -> None:
        with tempfile.TemporaryDirectory(prefix='cove-reload-sh-test-') as tdir:
            root = Path(tdir)
            repo = root / 'repo'
            runtime = root / 'runtime' / 'cove'
            fake_bin = root / 'bin'
            launcher = self.copy_script('reload.sh', repo, runtime)
            called = root / 'reload-kitty-called'
            self.write_executable(repo / 'cove' / 'reload-kitty.sh', f'#!/bin/sh\n: > "{called}"\n')
            self.write_executable(fake_bin / 'ps', '#!/bin/sh\nexit 0\n')
            godot = fake_bin / 'godot'
            self.write_executable(godot, f'#!/bin/sh\n: > "{root / "godot-started"}"\n')
            runtime.mkdir(parents=True)
            (runtime / 'dev-env').write_text(
                f'COVE_KITTEN=/nonexistent\nCOVE_KITTY_SOCKET=unix:{runtime}-kitty\n'
                f'APP={repo / "cove"}\nGODOT={godot}\n'
            )
            result = subprocess.run(
                ['/bin/bash', str(launcher)], cwd=repo,
                env={'HOME': str(root / 'home'), 'PATH': f'{fake_bin}:/usr/bin:/bin'},
                text=True, capture_output=True, timeout=10, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(called.exists())
            self.assertFalse((root / 'godot-started').exists())

    def test_reload_does_not_relaunch_a_window_that_landed(self) -> None:
        self.exercise_reload(launch_times_out=True)

    def test_reload_waits_for_a_timed_out_launch_that_lands_late(self) -> None:
        self.exercise_reload(launch_lands_late=True)


class ReattachTest(unittest.TestCase):
    def run_reattach(self, *, saved: str | None, patched: bool) -> tuple[subprocess.CompletedProcess[str], Path]:
        temp = tempfile.TemporaryDirectory(prefix='cove-reattach-test-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        runtime = root / 'runtime'
        script = root / 'repo' / 'cove' / 'cove-reattach.sh'
        script.parent.mkdir(parents=True)
        script.write_text((REPO_ROOT / 'cove' / 'cove-reattach.sh').read_text())
        script.chmod(0o755)
        # The patched abduco when built, else the one on PATH.
        fake = (root / 'repo' / 'cove' / 'bin' / 'abduco') if patched else (root / 'bin' / 'abduco')
        fake.parent.mkdir(parents=True)
        fake.write_text(f'#!/bin/sh\nprintf "exec %s:" "{"patched" if patched else "path"}"; printf " %s" "$@"; echo\n')
        fake.chmod(0o755)
        (runtime / 'scroll').mkdir(parents=True)
        if saved is not None:
            (runtime / 'scroll' / 'cove-111.ansi').write_text(saved)
        result = subprocess.run(
            ['/bin/sh', str(script), 'cove-111'],
            env={'KITTY_COVE_DIR': str(runtime), 'PATH': f'{root / "bin"}:/usr/bin:/bin'},
            text=True, capture_output=True, timeout=10, check=False,
        )
        return result, runtime / 'scroll' / 'cove-111.ansi'

    def test_prints_saved_screen_then_attaches_existing_session(self) -> None:
        result, saved = self.run_reattach(saved='\x1b[31mold screen\x1b[0m\n', patched=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '\x1b[31mold screen\x1b[0m\nexec patched: -a cove-111\n')
        self.assertFalse(saved.exists())

    def test_attaches_without_a_saved_screen(self) -> None:
        result, _ = self.run_reattach(saved=None, patched=True)
        self.assertEqual(result.stdout, 'exec patched: -a cove-111\n')

    def test_falls_back_to_abduco_on_path(self) -> None:
        result, _ = self.run_reattach(saved='', patched=False)
        self.assertEqual(result.stdout, 'exec path: -a cove-111\n')


if __name__ == '__main__':
    unittest.main()
