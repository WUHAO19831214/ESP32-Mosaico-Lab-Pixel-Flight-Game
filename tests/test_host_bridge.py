#!/usr/bin/env python3
"""Mock ESP-Mosaico HTTP integration tests for host/server.py & host/device.py."""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'host'))

import device  # noqa: E402
import server  # noqa: E402


class MockMosaicoState:
    def __init__(self):
        self.token = 'test-token-123'
        self.ui_running = False
        self.seq = 0
        self.sample_age_ms = 20
        self.last_cmd_ack = ''
        self.received_cmds = []
        self.received_keys = []
        self.jobs = [
            {'id': 'j1', 'path': '/nand/apps/minna_nihongo/scripts/receiver.lua'},
            {'id': 'j2', 'path': '/nand/apps/ai_mac_mini/scripts/receiver.lua'},
            {'id': 'j3', 'path': '/nand/apps/pixel_flight/scripts/receiver.lua'},
        ]
        self.slots_full = False


def make_mock_handler(mock_state: MockMosaicoState):
    class MockHandler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _json(self, d, code=200):
            raw = json.dumps(d).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _status_payload(self):
            sample = None
            if mock_state.ui_running:
                sample = {
                    'v': 2, 'seq': mock_state.seq, 'roll': -8.5, 'pitch': 4.0, 'yaw': 12.0,
                    'abs_roll': -8.0, 'abs_pitch': 24.0,
                    'valid': True, 'progress': 100, 'imu_mode': 'configured',
                    'keys': {'left': False, 'right': False},
                    'sync': {'x': 710.0, 'y': 345.0, 'z': 112.0, 'vx': 40.0, 'vy': -82.0,
                             'fyaw': 0.9, 'froll': -0.2, 'fpitch': 0.05, 'yaw_rate': -0.3,
                             'boost': 0.0, 'throttle': 0.5, 'stunt': -1.0, 'stunt_dir': 1,
                             'view': 1, 'subview': 0, 'weapon': 1, 'firing': False,
                             'gun_seq': 0, 'msl_seq': 1, 'day': 0, 'wingmen': 0,
                             'cmd_ack': mock_state.last_cmd_ack},
                }
            return {
                'ok': True, 'ui_running': mock_state.ui_running,
                'sample': sample, 'sample_age_ms': mock_state.sample_age_ms,
                'cmd_ack': mock_state.last_cmd_ack,
            }

        def do_GET(self):
            if self.path == '/api/lua/pixel_flight/status':
                return self._json(self._status_payload())
            return self._json({'ok': False}, 404)

        def do_POST(self):
            length = int(self.headers.get('Content-Length', '0'))
            body = json.loads(self.rfile.read(length))
            if body.get('token') != mock_state.token:
                return self._json({'ok': False}, 403)
            if self.path == '/api/lua/pixel_flight/recover':
                return self._json({'ok': True, 'published': True})
            if self.path == '/api/lua/pixel_flight/start':
                if mock_state.slots_full:
                    return self._json({'ok': False, 'recoverable': True, 'result': 'No Lua slot available'})
                mock_state.ui_running = True
                mock_state.seq += 1
                return self._json({'ok': True})
            if self.path == '/api/lua/pixel_flight/stop':
                mock_state.ui_running = False
                return self._json({'ok': True})
            if self.path == '/api/lua/pixel_flight/exchange':
                if 'keys' in body:
                    mock_state.received_keys.append(body['keys'])
                cmd = body.get('cmd')
                if isinstance(cmd, dict) and cmd.get('id'):
                    mock_state.received_cmds.append(cmd)
                    mock_state.last_cmd_ack = cmd['id']
                mock_state.seq += 1
                return self._json(self._status_payload())
            return self._json({'ok': False}, 404)

    return MockHandler


class HostBridgeTests(unittest.TestCase):
    def setUp(self):
        self.mock_state = MockMosaicoState()
        self.mock_srv = ThreadingHTTPServer(('127.0.0.1', 0), make_mock_handler(self.mock_state))
        self.mock_thread = threading.Thread(target=self.mock_srv.serve_forever, daemon=True)
        self.mock_thread.start()
        mock_port = self.mock_srv.server_port

        self._orig_config_device = device.config
        self._orig_config_server = server.config
        cfg = {'device_host': f'127.0.0.1:{mock_port}', 'token': self.mock_state.token, 'port': 0, 'route_mode': 'standalone'}
        device.config = lambda: cfg
        server.config = lambda: cfg

    def tearDown(self):
        device.config = self._orig_config_device
        server.config = self._orig_config_server
        self.mock_srv.shutdown()
        self.mock_srv.server_close()

    def test_passive_startup_explicit_start_cmd_ack_and_weapons_tune(self):
        b = server.Bridge(poll_interval_s=0.015)
        b.thread.start()
        try:
            time.sleep(0.08)
            self.assertFalse(self.mock_state.ui_running)
            self.assertFalse(b.snapshot()['connected'])

            self.mock_state.slots_full = True
            fail_res = b.control('start')
            self.assertFalse(fail_res['ok'])
            self.assertTrue(fail_res['recoverable'])

            self.mock_state.slots_full = False
            ok_res = b.control('start')
            self.assertTrue(ok_res['ok'])
            self.assertTrue(self.mock_state.ui_running)

            # Send feedback + weapon / subview / tune / fire commands
            b.update({
                'client': 'c1',
                'active': True,
                'keys': {'turn': 0.4, 'climb': -0.2, 'boost': True, 'fire': True, 'manual': True},
                'cmd': {'action': 'tune', 'inv_pitch': True, 'swap_xy': False, 'gain': 1.2, 'client_cmd_id': 'c1-1'},
            })
            time.sleep(0.08)
            b.update({
                'client': 'c1',
                'active': True,
                'keys': {'turn': 0.0, 'climb': 0.0, 'boost': False, 'fire': True, 'manual': False},
                'cmd': {'action': 'weapon', 'val': 0, 'client_cmd_id': 'c1-2'},
            })
            time.sleep(0.08)

            snap = b.snapshot()
            self.assertTrue(snap['connected'])
            self.assertEqual(len(self.mock_state.received_cmds), 2)
            self.assertEqual(self.mock_state.received_cmds[0]['action'], 'tune')
            self.assertTrue(self.mock_state.received_cmds[0]['inv_pitch'])
            self.assertAlmostEqual(self.mock_state.received_cmds[0]['gain'], 1.2)
            self.assertEqual(self.mock_state.received_cmds[1]['action'], 'weapon')
            self.assertTrue(any(k.get('fire') is True for k in self.mock_state.received_keys))
            self.assertEqual(len(b.cmds), 0)

            self.mock_state.sample_age_ms = 900
            time.sleep(0.06)
            self.assertFalse(b.snapshot()['connected'])

            stop_res = b.control('stop')
            self.assertTrue(stop_res['ok'])
            self.assertFalse(self.mock_state.ui_running)
        finally:
            b.stop_event.set()


if __name__ == '__main__':
    unittest.main()
