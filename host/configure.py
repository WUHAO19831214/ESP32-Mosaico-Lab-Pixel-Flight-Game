#!/usr/bin/env python3
"""Initialize isolated local pairing credentials (bridge.local.json + app/config.json)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[1]
MINNA_BRIDGE_CFG = ROOT.parent / 'bridge.local.json'


def detect_default_host() -> str:
    if MINNA_BRIDGE_CFG.exists():
        try:
            data = json.loads(MINNA_BRIDGE_CFG.read_text(encoding='utf-8'))
            host = str(data.get('device_host') or '').strip()
            if host:
                return host
        except Exception:
            pass
    return '192.168.1.100'


def configure(device_host: str | None = None, port: int = 8780, force: bool = False) -> dict:
    bridge_path = ROOT / 'bridge.local.json'
    app_cfg_path = ROOT / 'app' / 'config.json'

    existing_token = None
    existing_host = None
    if bridge_path.exists() and not force:
        try:
            cur = json.loads(bridge_path.read_text(encoding='utf-8'))
            existing_token = cur.get('token')
            existing_host = cur.get('device_host')
        except Exception:
            pass

    token = existing_token or secrets.token_hex(32)
    host = (device_host or existing_host or detect_default_host()).strip()

    bridge_cfg = {
        'device_host': host,
        'token': token,
        'port': port,
        'route_mode': 'auto',
    }
    app_cfg = {
        'token': token,
        'stability_profile': 'safe',
    }

    bridge_path.write_text(json.dumps(bridge_cfg, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    app_cfg_path.write_text(json.dumps(app_cfg, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    os.chmod(bridge_path, 0o600)
    os.chmod(app_cfg_path, 0o600)
    return {'bridge_path': str(bridge_path), 'app_cfg_path': str(app_cfg_path), 'device_host': host, 'port': port}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description='Configure isolated pixel_flight pairing')
    p.add_argument('host', nargs='?', help='ESP-Mosaico LAN IP (optional)')
    p.add_argument('--port', type=int, default=8780)
    p.add_argument('--force', action='store_true', help='Regenerate token')
    args = p.parse_args()
    res = configure(args.host, args.port, args.force)
    print(json.dumps(res, indent=2, ensure_ascii=False))
