#!/usr/bin/env python3
"""Isolated ESP-Claw HTTP file & lifecycle manager for /apps/pixel_flight. Never flashes firmware."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
APP = '/apps/pixel_flight'
LOCAL_HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))

MINNA_BRIDGE_CFG = ROOT.parent / 'bridge.local.json'
MINI_BRIDGE_CFG = Path(
    os.environ.get('ESP_AI_MAC_MINI_CFG')
    or (Path.home() / 'LocalProjects' / 'Codex' / 'macmini' / 'ESP32 in macmini' / 'bridge.local.json')
)


def config() -> dict:
    cfg_path = ROOT / 'bridge.local.json'
    if not cfg_path.exists():
        raise FileNotFoundError('Missing bridge.local.json; run python3 host/configure.py first')
    return json.loads(cfg_path.read_text(encoding='utf-8'))


def request(path: str, data=None, method: str = 'GET', timeout: float = 8.0) -> bytes:
    body = None
    headers = {}
    if data is not None:
        if isinstance(data, dict):
            body = json.dumps(data, ensure_ascii=False).encode('utf-8')
            headers['Content-Type'] = 'application/json'
        else:
            body = data
            headers['Content-Type'] = 'application/octet-stream'
    url = 'http://' + config()['device_host'] + path
    req = urllib.request.Request(url, body, headers, method=method)
    with LOCAL_HTTP.open(req, timeout=timeout) as resp:
        return resp.read()


def _route_prefixes() -> tuple[str, ...]:
    mode = config().get('route_mode', 'auto')
    if mode == 'standalone':
        return ('/api/lua/pixel_flight/',)
    if mode == 'shared':
        return ('/api/lua/minna_nihongo/pixel_flight/',)
    return ('/api/lua/pixel_flight/', '/api/lua/minna_nihongo/pixel_flight/')


def detect_status() -> tuple[str | None, dict | None]:
    for prefix in _route_prefixes():
        try:
            data = json.loads(request(prefix + 'status', timeout=3.0))
            if isinstance(data, dict) and data.get('ok'):
                return prefix, data
        except (urllib.error.HTTPError, OSError, ValueError):
            continue
    return None, None


def call(action: str, **data) -> dict:
    payload = {'token': config()['token'], **data}
    last_exc = None
    for prefix in _route_prefixes():
        try:
            return json.loads(request(prefix + action, payload, 'POST', timeout=15.0))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                last_exc = exc
                continue
            raise
    if last_exc:
        raise last_exc
    raise RuntimeError('No pixel_flight receiver route available')


def upload() -> list[dict]:
    _, st = detect_status()
    if st and st.get('ui_running'):
        raise RuntimeError('Exit pixel_flight UI before deploying scripts/assets')

    for sub in ('', '/scripts', '/assets'):
        res = json.loads(request('/api/files/mkdir', {'path': APP + sub, 'recursive': True}, 'POST'))
        assert res.get('ok'), res

    records = []
    for p in sorted((ROOT / 'app').rglob('*')):
        if not p.is_file():
            continue
        target = APP + '/' + p.relative_to(ROOT / 'app').as_posix()
        body = p.read_bytes()
        res = json.loads(request('/api/files/upload?' + urllib.parse.urlencode({'path': target}), body, 'POST', timeout=25.0))
        assert res.get('ok'), f'Upload failed: {target}: {res}'
        readback = request('/files' + target, timeout=25.0)
        assert readback == body, f'Readback mismatch: {target}'
        records.append({'path': target, 'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()})

    (ROOT / 'evidence' / 'upload.json').write_text(json.dumps(records, indent=2), encoding='utf-8')
    return records


def bootstrap() -> dict:
    prompt = (
        '用户已授权安装独立像素飞行应用（pixel_flight）。文件已经上传，文件存在不代表任务运行。只执行以下操作：'
        '用 lua_list_async_jobs 查看 running，仅当运行列表中有 path=/nand/apps/pixel_flight/scripts/receiver.lua 的运行任务才回复已运行；'
        '若 running 已有4个则不执行任何修改，回复槽位满；'
        '否则用 lua_run_script_async 启动 /nand/apps/pixel_flight/scripts/receiver.lua，'
        'name=pixel_flight_receiver，exclusive=pixel_flight_receiver，replace=false，timeout_ms=0，log_bytes=4096。'
        '随后核实该任务 running。不要创建修改文件，不要启动UI，不要停止任何其他任务、服务，不要重启或刷机。'
    )
    reply = json.loads(request('/api/webim/send', {'chat_id': 'pixel-flight-recovery', 'text': prompt}, 'POST'))
    (ROOT / 'evidence' / 'bootstrap-request.json').write_text(json.dumps(reply, ensure_ascii=False), encoding='utf-8')
    deadline = time.monotonic() + 60.0
    while time.monotonic() < deadline:
        _, st = detect_status()
        if st and st.get('ok'):
            return st
        time.sleep(2.0)
    raise RuntimeError('Receiver not started; inspect slots or use shared transport patch')


def ensure_ready() -> dict:
    _, st = detect_status()
    if not st:
        installed = json.loads(request('/files' + APP + '/config.json'))
        if installed.get('token') != config()['token']:
            raise RuntimeError('pixel_flight pairing differs; refusing to overwrite')
        for rel in ('launcher.json', 'scripts/receiver.lua', 'scripts/recovery.lua', 'assets/world128.bin'):
            request('/files' + APP + '/' + rel)
        st = bootstrap()
    if not st.get('ok'):
        raise RuntimeError('pixel_flight receiver unhealthy')
    res = call('recover')
    if not res.get('ok'):
        raise RuntimeError('Recovery incomplete: ' + json.dumps(res, ensure_ascii=False))
    return res


def switch_to_other(target: str) -> dict:
    res = call('stop')
    if not res.get('ok'):
        return res
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        _, st = detect_status()
        if st and not st.get('ui_running'):
            break
        time.sleep(0.1)
    else:
        return {'ok': False, 'error': 'pixel_flight UI did not release screen', 'recoverable': True}

    if target == 'minna':
        tok = json.loads(MINNA_BRIDGE_CFG.read_text(encoding='utf-8'))['token']
        return json.loads(request('/api/lua/minna_nihongo/control', {'token': tok, 'action': 'start'}, 'POST'))
    if target == 'badge':
        tok = json.loads(MINI_BRIDGE_CFG.read_text(encoding='utf-8'))['token']
        return json.loads(request('/api/lua/ai_mac_mini/control', {'token': tok, 'action': 'start'}, 'POST'))
    raise ValueError(f'Unknown target: {target}')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description='Manage pixel_flight on ESP-Mosaico')
    p.add_argument('action', choices=[
        'upload', 'bootstrap', 'recover', 'probe', 'status',
        'start', 'stop', 'publish', 'jobs', 'switch-to-minna', 'switch-to-badge',
    ])
    act = p.parse_args().action
    if act == 'upload':
        out = upload()
    elif act == 'bootstrap':
        out = bootstrap()
    elif act == 'recover':
        out = ensure_ready()
    elif act == 'status':
        _, out = detect_status()
        out = out or {'ok': False, 'error': 'receiver_unreachable'}
    elif act == 'switch-to-minna':
        out = switch_to_other('minna')
    elif act == 'switch-to-badge':
        out = switch_to_other('badge')
    else:
        out = call(act)
    print(json.dumps(out, ensure_ascii=False, indent=2))
