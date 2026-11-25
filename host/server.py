#!/usr/bin/env python3
"""Loopback-only HTTP/SSE bridge & web server for ESP-Mosaico Pixel Flight Sync.
Startup and reconnect are strictly passive: never activates ESP32 UI unless user clicks Connect.
"""
from __future__ import annotations

import argparse
from collections import deque
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import secrets
import threading
import time
import urllib.parse

try:
    from .device import ROOT, call, config, detect_status, ensure_ready, switch_to_other
except ImportError:
    from device import ROOT, call, config, detect_status, ensure_ready, switch_to_other


class Bridge:
    def __init__(self, poll_interval_s: float = 0.032):
        self.poll_interval_s = poll_interval_s
        self.lock = threading.Condition()
        self.latest = {'connected': False, 'ui_running': False, 'error': '未连接 ESP-Mosaico（可点击左上角连接，或直接用键盘/鼠标试玩）'}
        self.version = 0
        self.client = None
        self.last_browser = -100.0
        self.keys = {'turn': 0.0, 'climb': 0.0, 'boost': False, 'fire': False, 'manual': False}
        self.cmds = deque(maxlen=32)
        self.seen_cmds = deque(maxlen=128)
        self.next_cmd = 0
        self.cmd_session = secrets.token_hex(6)
        self.stop_event = threading.Event()
        self._wake = threading.Event()
        self.device_lock = threading.RLock()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self._last_seq = None
        self._last_seq_at = 0.0

    def update(self, d: dict):
        client = str(d.get('client', ''))[:80]
        if not client:
            raise ValueError('Missing client ID')
        now = time.monotonic()
        with self.lock:
            if self.client not in (None, client) and (now - self.last_browser) < 1.0:
                raise ValueError('另一个浏览器标签页正在同步 ESP-Mosaico')
            self.client = client
            self.last_browser = now if d.get('active') is True else -100.0

            k = d.get('keys') or {}
            turn = float(k.get('turn', 0.0))
            climb = float(k.get('climb', 0.0))
            if not (math.isfinite(turn) and math.isfinite(climb)):
                raise ValueError('Invalid axis value')
            self.keys = {
                'turn': max(-1.0, min(1.0, turn)),
                'climb': max(-1.0, min(1.0, climb)),
                'boost': bool(k.get('boost', False)),
                'fire': bool(k.get('fire', False)),
                'manual': bool(k.get('manual', False)),
            }

            cmd = d.get('cmd')
            if isinstance(cmd, dict) and d.get('active') is True:
                action = str(cmd.get('action', ''))
                if action not in ('center', 'view', 'subview', 'weapon', 'fire', 'day', 'wingmen', 'roll', 'reset', 'tune'):
                    raise ValueError('Unsupported command action')
                cid = str(cmd.get('client_cmd_id', ''))
                key = (client, cid)
                if not cid or key not in self.seen_cmds:
                    if cid:
                        self.seen_cmds.append(key)
                    self.next_cmd += 1
                    item = {
                        'id': f'{self.cmd_session}:{self.next_cmd}',
                        'action': action,
                        'at': now,
                    }
                    if 'val' in cmd and isinstance(cmd['val'], (int, float)):
                        item['val'] = int(cmd['val'])
                    if 'dir' in cmd and isinstance(cmd['dir'], (int, float)):
                        item['dir'] = int(cmd['dir'])
                    if action == 'tune':
                        if 'inv_pitch' in cmd and isinstance(cmd['inv_pitch'], bool):
                            item['inv_pitch'] = cmd['inv_pitch']
                        if 'inv_roll' in cmd and isinstance(cmd['inv_roll'], bool):
                            item['inv_roll'] = cmd['inv_roll']
                        if 'swap_xy' in cmd and isinstance(cmd['swap_xy'], bool):
                            item['swap_xy'] = cmd['swap_xy']
                        if 'gain' in cmd and isinstance(cmd['gain'], (int, float)) and math.isfinite(float(cmd['gain'])):
                            item['gain'] = max(0.4, min(2.5, float(cmd['gain'])))
                    self.cmds.append(item)
        self._wake.set()

    def snapshot(self) -> dict:
        with self.lock:
            return {'app_id': 'pixel_flight', **self.latest}

    def run(self):
        while not self.stop_event.is_set():
            began = time.monotonic()
            with self.lock:
                active = (began - self.last_browser) < 0.9
                while self.cmds and (not active or (began - self.cmds[0]['at']) > 2.5):
                    self.cmds.popleft()
                cmd = {k: v for k, v in self.cmds[0].items() if k != 'at'} if self.cmds else None
                keys = dict(self.keys) if active else {'turn': 0.0, 'climb': 0.0, 'boost': False, 'fire': False, 'manual': False}

            if not active:
                # Idle polling when browser is not connected/active
                try:
                    with self.device_lock:
                        _, st = detect_status()
                    if st and st.get('ok'):
                        latest = {
                            'connected': False,
                            'ui_running': bool(st.get('ui_running')),
                            'sample': None,
                            'error': None if st.get('ui_running') else 'ESP-Mosaico 待命中，点击连接开启双端同步',
                        }
                    else:
                        latest = {'connected': False, 'ui_running': False, 'sample': None, 'error': '未检测到 ESP-Mosaico（可点击连接重试）'}
                except Exception:
                    latest = {'connected': False, 'ui_running': False, 'sample': None, 'error': '设备离线或未配置'}
                with self.lock:
                    self.latest = latest
                    self.version += 1
                    self.lock.notify_all()
                self._wake.wait(0.45)
                self._wake.clear()
                continue

            try:
                with self.device_lock:
                    data = call('exchange', active=True, keys=keys, cmd=cmd)
                sample = data.get('sample')
                seq = sample.get('seq') if isinstance(sample, dict) else None
                age_ms = data.get('sample_age_ms')
                if seq is not None and seq != self._last_seq:
                    self._last_seq = seq
                    self._last_seq_at = began
                fresh = bool(
                    data.get('ui_running')
                    and sample
                    and (age_ms is None or age_ms < 500)
                    and ((began - self._last_seq_at) < 0.8 or seq is None)
                )
                latest = {
                    'connected': fresh,
                    'ui_running': bool(data.get('ui_running')),
                    'sample': sample if fresh else None,
                    'sample_age_ms': age_ms,
                    'rtt_ms': round((time.monotonic() - began) * 1000.0, 2),
                    'error': None if fresh else '飞行端尚未激活，点击“连接 ESP-Mosaico”启动',
                }
                ack = data.get('cmd_ack', '')
                with self.lock:
                    if self.cmds and self.cmds[0]['id'] == ack:
                        self.cmds.popleft()
            except Exception:
                latest = {
                    'connected': False,
                    'ui_running': False,
                    'sample': None,
                    'error': 'ESP-Mosaico 连接中断，请确认同一局域网后重试',
                }
            with self.lock:
                self.latest = latest
                self.version += 1
                self.lock.notify_all()
            self.stop_event.wait(max(0.004, self.poll_interval_s - (time.monotonic() - began)))

    def control(self, action: str) -> dict:
        with self.device_lock:
            if action == 'start':
                ensure_ready()
                res = call('start')
                if not res.get('ok'):
                    return res
                deadline = time.monotonic() + 6.0
                while time.monotonic() < deadline:
                    _, st = detect_status()
                    if st and st.get('ui_running') and st.get('sample') and (st.get('sample_age_ms') or 0) < 500:
                        return {'ok': True}
                    time.sleep(0.1)
                return {'ok': False, 'error': 'ESP-Mosaico 未在预期时间内推流', 'recoverable': True}
            if action == 'stop':
                res = call('stop')
                if not res.get('ok'):
                    return res
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    _, st = detect_status()
                    if st and not st.get('ui_running'):
                        with self.lock:
                            self.last_browser = -100.0
                            self.cmds.clear()
                        return {'ok': True}
                    time.sleep(0.1)
                return {'ok': False, 'error': '设备尚未释放屏幕', 'recoverable': True}
            if action in ('minna', 'badge'):
                res = switch_to_other(action)
                with self.lock:
                    self.last_browser = -100.0
                    self.cmds.clear()
                return res
            raise ValueError(f'Unknown control action: {action}')


class Handler(SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def valid_host(self) -> bool:
        port = self.server.server_port
        return self.headers.get('Host') in (f'127.0.0.1:{port}', f'localhost:{port}')

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def json_resp(self, d: dict, status: int = 200):
        body = json.dumps(d, ensure_ascii=False, allow_nan=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.valid_host():
            return self.json_resp({'ok': False}, 403)
        path = urllib.parse.urlsplit(self.path).path
        if path == '/api/status':
            return self.json_resp(self.server.bridge.snapshot())
        if path == '/api/stream':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            version = -1
            try:
                while not self.server.bridge.stop_event.is_set():
                    with self.server.bridge.lock:
                        self.server.bridge.lock.wait_for(lambda: self.server.bridge.version != version, timeout=1.0)
                        version = self.server.bridge.version
                        data = dict(self.server.bridge.latest)
                    self.wfile.write(('data: ' + json.dumps(data, ensure_ascii=False) + '\n\n').encode('utf-8'))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            return
        return super().do_GET()

    def do_POST(self):
        port = self.server.server_port
        origin = self.headers.get('Origin')
        valid_origins = (f'http://127.0.0.1:{port}', f'http://localhost:{port}')
        if not self.valid_host() or (origin and origin not in valid_origins):
            return self.json_resp({'ok': False}, 403)
        length = int(self.headers.get('Content-Length', '0'))
        if not (0 < length <= 8192):
            return self.json_resp({'ok': False}, 413)
        if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
            return self.json_resp({'ok': False}, 415)
        try:
            data = json.loads(self.rfile.read(length))
            if self.path == '/api/feedback':
                self.server.bridge.update(data)
                return self.json_resp({'ok': True})
            if self.path == '/api/control':
                return self.json_resp(self.server.bridge.control(data.get('action', '')))
            return self.json_resp({'ok': False}, 404)
        except (ValueError, KeyError, TypeError) as exc:
            return self.json_resp({'ok': False, 'error': str(exc)}, 400)
        except Exception as exc:
            return self.json_resp({'ok': False, 'error': f'设备未响应: {exc}'}, 503)


def main():
    default_port = 8780
    try:
        default_port = int(config().get('port', 8780))
    except Exception:
        pass
    p = argparse.ArgumentParser(description='Pixel Flight ESP-Mosaico host bridge')
    p.add_argument('--port', type=int, default=default_port)
    args = p.parse_args()

    bridge = Bridge()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(ROOT / 'web')))
    server.daemon_threads = True
    server.bridge = bridge
    bridge.thread.start()
    print(f'Pixel Flight Sync: http://127.0.0.1:{args.port} (passive mode; click Connect to start ESP32)', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop_event.set()
        server.server_close()


if __name__ == '__main__':
    main()
