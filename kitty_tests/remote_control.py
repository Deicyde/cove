#!/usr/bin/env python
# License: GPLv3 Copyright: 2026 Kovid Goyal <kovid at kovidgoyal.net>

from types import SimpleNamespace

from kitty.rc.base import MatchError, PayloadGetter, command_for_name

from .base import BaseTest


class Window:
    def __init__(self, id: int):
        self.id = id


class Boss:
    def __init__(self, active: Window, target: Window):
        self.active_window = active
        self.target = target
        self.matches = []
        self.dispatched = None

    def match_windows(self, expr: str, self_window: Window | None = None):
        self.matches.append((expr, self_window))
        if expr == f'id:{self.target.id}':
            yield self.target

    def combine(self, action: str, window: Window, raise_error: bool = False) -> bool:
        self.dispatched = action, window, raise_error
        return True


class TestRemoteControl(BaseTest):
    def test_action_targets_matched_window(self):
        active, target = Window(1), Window(2)
        cmd = command_for_name('action')
        opts = SimpleNamespace(self=False, match='id:2')

        for action in ('copy_to_clipboard', 'paste_from_clipboard'):
            with self.subTest(action=action):
                boss = Boss(active, target)
                payload = cmd.message_to_kitty(None, opts, [action])
                cmd.response_from_kitty(boss, active, PayloadGetter(cmd, payload))
                self.ae(boss.matches, [('id:2', active)])
                self.ae(boss.dispatched, (action, target, True))

        boss = Boss(active, target)
        payload = cmd.message_to_kitty(None, SimpleNamespace(self=False, match='id:99'), ['paste_from_clipboard'])
        with self.assertRaises(MatchError):
            cmd.response_from_kitty(boss, active, PayloadGetter(cmd, payload))
        self.assertIsNone(boss.dispatched)

    def test_action_preserves_existing_target_defaults(self):
        active, target, origin = Window(1), Window(2), Window(3)
        cmd = command_for_name('action')
        cases = (
            ({'action': 'sleep 0', 'self': False}, active),
            ({'action': 'sleep 0', 'self': True}, origin),
            ({'action': 'sleep 0', 'self': False, 'match': 'id:2'}, target),
        )

        for payload, expected in cases:
            with self.subTest(payload=payload):
                boss = Boss(active, target)
                cmd.response_from_kitty(boss, origin, PayloadGetter(cmd, payload))
                self.ae(boss.dispatched, ('sleep 0', expected, True))
