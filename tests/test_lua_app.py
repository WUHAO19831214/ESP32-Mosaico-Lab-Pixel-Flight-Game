#!/usr/bin/env python3
"""Offline Lua 5.4 + 480x480 PIL screen verification for pixel-flight-sync/app."""
from __future__ import annotations

import json
from pathlib import Path
import struct
import unittest

from PIL import Image, ImageDraw
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'app'
EVIDENCE = ROOT / 'evidence'


class FakeScreen:
    def __init__(self):
        self.im = Image.new('RGB', (480, 480), (0, 0, 0))
        self.draw = ImageDraw.Draw(self.im)
        self.presents = 0
        self.closed = False
        self.touch_points = []
        self.primitive_count = 0

    @staticmethod
    def _rgb(argb: int) -> tuple[int, int, int]:
        return ((argb >> 16) & 255, (argb >> 8) & 255, argb & 255)

    @staticmethod
    def _chk_int(*vals):
        for v in vals:
            assert isinstance(v, int) and not isinstance(v, bool), f'Non-integer coordinate: {v!r}'

    def begin(self, opts):
        self.primitive_count = 0
        col = self._rgb(int(opts['clear']))
        self.draw.rectangle((0, 0, 479, 479), fill=col)

    def fill_rect(self, x, y, w, h, color):
        self._chk_int(x, y, w, h)
        self.primitive_count += 1
        if w <= 0 or h <= 0:
            return
        self.draw.rectangle((x, y, x + w - 1, y + h - 1), fill=self._rgb(int(color)))

    def fill_round_rect(self, x, y, w, h, r, color):
        self._chk_int(x, y, w, h, r)
        self.primitive_count += 1
        if w <= 0 or h <= 0:
            return
        self.draw.rounded_rectangle((x, y, x + w - 1, y + h - 1), radius=max(0, r), fill=self._rgb(int(color)))

    def fill_circle(self, x, y, r, color):
        self._chk_int(x, y, r)
        self.primitive_count += 1
        r = max(0, r)
        self.draw.ellipse((x - r, y - r, x + r, y + r), fill=self._rgb(int(color)))

    def line(self, x1, y1, x2, y2, color):
        self._chk_int(x1, y1, x2, y2)
        self.primitive_count += 1
        self.draw.line((x1, y1, x2, y2), fill=self._rgb(int(color)), width=1)

    def text(self, x, y, value, opts):
        self._chk_int(x, y)
        self.primitive_count += 1
        col = self._rgb(int(opts['color']))
        self.draw.text((x, y), str(value), fill=col)

    def touch(self, _self=None):
        return self.touch_points

    def present(self):
        self.presents += 1

    def close(self):
        self.closed = True


class FakeBmiDevice:
    def __init__(self, initial_pwr: int = 0x00):
        self.regs = {0x00: 0x24, 0x02: 0x00, 0x21: 0x01 if initial_pwr else 0x00, 0x40: 0xA8, 0x41: 0x00, 0x42: 0xA8, 0x43: 0x02, 0x7C: 0x03, 0x7D: initial_pwr}
        self.writes = []
        self.closed = False
        self.ax, self.ay, self.az = 0, 0, 16384
        self.gx, self.gy, self.gz = 0, 0, 0

    def read_byte(self, reg):
        return self.regs.get(int(reg), 0)

    def write_byte(self, val, reg):
        r, v = int(reg), int(val)
        self.writes.append((r, v))
        self.regs[r] = v
        if r == 0x59 and v == 0x01:
            self.regs[0x21] = 0x01

    def write(self, data_len, reg):
        self.writes.append((int(reg), int(data_len)))

    def read(self, count, reg):
        assert int(reg) == 0x0C and int(count) == 12
        return struct.pack('<hhhhhh', self.ax, self.ay, self.az, self.gx, self.gy, self.gz)

    def close(self):
        self.closed = True


class LuaFlightAppTests(unittest.TestCase):
    def _make_env(self, initial_pwr: int = 0x00):
        lua = LuaRuntime(unpack_returned_tuples=True)
        dev = FakeBmiDevice(initial_pwr=initial_pwr)
        screen = FakeScreen()
        state = {
            'now': 1000,
            'gpio': {8: 1, 10: 1, 11: 1},
            'queues': {},
            'jobs': [
                {'id': 'j1', 'path': '/nand/apps/minna_nihongo/scripts/receiver.lua'},
                {'id': 'j2', 'path': '/nand/apps/ai_mac_mini/scripts/receiver.lua'},
                {'id': 'j3', 'path': '/nand/apps/pixel_flight/scripts/receiver.lua'},
            ],
            'stopped': [],
            'led_closed': False,
        }

        def read_file(path):
            p = str(path).replace('/nand/apps/pixel_flight', str(APP))
            return Path(p).read_bytes()

        def exists(path):
            p = str(path).replace('/nand/apps/pixel_flight', str(APP))
            return Path(p).exists()

        def write_file(path, content):
            pass

        lua.execute("""
            function _make_storage(rf, ex, wf)
              return {
                get_root_dir = function() return '/nand' end,
                join_path = function(...) return table.concat({...}, '/') end,
                read_file = rf,
                exists = ex,
                write_file = wf,
              }
            end
        """)
        storage = lua.globals()._make_storage(read_file, exists, write_file)

        def q_create(name, _opts):
            state['queues'].setdefault(str(name), [])
            return True, None

        def q_send(name, raw, _to):
            q = state['queues'].setdefault(str(name), [])
            if len(q) >= 4:
                return False, 'timeout'
            q.append(str(raw))
            return True, None

        def q_recv(name, _to):
            q = state['queues'].setdefault(str(name), [])
            return q.pop(0) if q else None

        def thread_list(_kind):
            lines = [f"{j['id']} | status=running | path={j['path']}" for j in state['jobs']]
            return True, '\n'.join(lines)

        def thread_get(jid):
            for j in state['jobs']:
                if j['id'] == jid:
                    return True, f"id={jid}\npath={j['path']}\nstatus=running"
            return False, 'not found'

        def thread_stop(jid, _to):
            state['stopped'].append(jid)
            state['jobs'] = [j for j in state['jobs'] if j['id'] != jid]
            return True, 'stopped'

        thread_mod = lua.table_from({
            'sync': lua.table_from({'queue_create': q_create, 'queue_send': q_send, 'queue_recv': q_recv}),
            'list': thread_list,
            'get': thread_get,
            'stop': thread_stop,
            'start': lambda path, args, opts: (True, 'started'),
        })

        def make_screen_proxy():
            touch_fn = lambda: lua.table_from([lua.table_from(pt) for pt in screen.touch_points])
            lua.execute("""
                function _wrap_screen(py_s, touch_fn)
                  local s = {}
                  function s:begin(o) py_s:begin(o) end
                  function s:fill_rect(x,y,w,h,c) py_s:fill_rect(x,y,w,h,c) end
                  function s:fill_round_rect(x,y,w,h,r,c) py_s:fill_round_rect(x,y,w,h,r,c) end
                  function s:fill_circle(x,y,r,c) py_s:fill_circle(x,y,r,c) end
                  function s:line(x1,y1,x2,y2,c) py_s:line(x1,y1,x2,y2,c) end
                  function s:text(x,y,t,o) py_s:text(x,y,t,o) end
                  function s:touch() return {points = touch_fn()} end
                  function s:present() py_s:present() end
                  function s:close() py_s:close() end
                  return s
                end
            """)
            return lua.globals()._wrap_screen(screen, touch_fn)

        def make_i2c_bus(_id, _sda, _scl, _freq):
            lua.execute("""
                function _wrap_i2c(py_d)
                  local bus = {}
                  function bus:device(_addr)
                    local d = {}
                    function d:read_byte(r) return py_d:read_byte(r) end
                    function d:write_byte(v, r) py_d:write_byte(v, r) end
                    function d:write(data, r) py_d:write(#data, r) end
                    function d:read(c, r) return py_d:read(c, r) end
                    function d:close() py_d:close() end
                    return d
                  end
                  function bus:close() end
                  return bus
                end
            """)
            return lua.globals()._wrap_i2c(dev)

        def make_led(_pin, _n):
            lua.execute("""
                function _wrap_led(st)
                  local l = {}
                  function l:clear() end
                  function l:refresh() end
                  function l:close() st['led_closed'] = true end
                  return l
                end
            """)
            return lua.globals()._wrap_led(state)

        modules = {
            'storage': storage,
            'json': lua.table_from({
                'encode': lambda tbl: json.dumps(self._lua_to_py(tbl)),
                'decode': lambda s: lua.table_from(json.loads(str(s))),
            }),
            'thread': thread_mod,
            'system': lua.table_from({'millis': lambda: state['now']}),
            'delay': lua.table_from({'delay_ms': lambda ms: state.__setitem__('now', state['now'] + int(ms))}),
            'display': lua.table_from({'open': make_screen_proxy}),
            'gpio': lua.table_from({
                'set_direction': lambda p, d: None,
                'set_level': lambda p, v: state['gpio'].__setitem__(int(p), int(v)),
                'get_level': lambda p: state['gpio'].get(int(p), 1),
            }),
            'button': lua.table_from({'new': lambda p, m: {'pin': int(p), 'close': lambda _s: None}}),
            'led_strip': lua.table_from({'new': make_led}),
            'i2c': lua.table_from({'new': make_i2c_bus}),
            'capability': lua.table_from({'call': lambda name, args, opts: (True, 'ok', None)}),
        }

        lua.globals()['_PY_MODS'] = modules
        lua.execute("""
            local orig_require = require
            function require(name)
              if _PY_MODS[name] ~= nil then return _PY_MODS[name] end
              return orig_require(name)
            end
            function dofile(path)
              local real = path:gsub('^/nand/apps/pixel_flight', '""" + str(APP).replace('\\', '\\\\') + """')
              local chunk, err = loadfile(real)
              assert(chunk, err)
              return chunk()
            end
        """)
        return lua, dev, screen, state

    @staticmethod
    def _lua_to_py(obj):
        if hasattr(obj, 'items'):
            keys = list(obj.keys())
            if keys and all(isinstance(k, int) for k in keys) and keys == list(range(1, len(keys) + 1)):
                return [LuaFlightAppTests._lua_to_py(obj[k]) for k in keys]
            return {str(k): LuaFlightAppTests._lua_to_py(v) for k, v in obj.items()}
        return obj

    def test_imu_expo_curve_ufo_axes_and_no_stunt_roll(self):
        # 1. Cold boot writes config blob & restores on close
        lua, dev, _, _ = self._make_env(initial_pwr=0x00)
        imu = lua.eval("dofile('/nand/apps/pixel_flight/scripts/imu.lua').open('/nand/apps/pixel_flight')")
        self.assertEqual(imu.mode, 'configured')
        self.assertTrue(any(w == (0x59, 0x01) for w in dev.writes))

        # Neutral holding angle (~24 deg tilted toward user -> ay_raw < 0)
        dev.ax, dev.ay, dev.az = 0, int(-0.407 * 16384), int(0.913 * 16384)
        snap = imu.step(imu, 0.02)
        self.assertTrue(snap.valid)
        self.assertEqual(snap.progress, 100)
        self.assertAlmostEqual(snap.pitch, 0.0, delta=0.5)
        self.assertAlmostEqual(snap.roll, 0.0, delta=0.5)

        # Gentle 10 deg tilt -> non-linear expo yields soft small deflection (< 0.25)
        # Lifting top edge toward flat/up shifts ay toward positive relative to -0.407
        dev.ax, dev.ay, dev.az = 0, int(-0.242 * 16384), int(0.970 * 16384)
        for _ in range(30):
            snap = imu.step(imu, 0.02)
        self.assertGreater(snap.pitch, 6.0)
        self.assertGreater(snap.climb, 0.05)
        self.assertLess(snap.climb, 0.25)

        # Strong 26 deg pull up -> strong climb (> 0.70)
        dev.ax, dev.ay, dev.az = 0, int(0.035 * 16384), int(0.999 * 16384)
        for _ in range(35):
            snap = imu.step(imu, 0.02)
        self.assertGreater(snap.climb, 0.70)

        # Instant 0ms re-zero (center) resets pose immediately
        imu.center(imu)
        snap = imu.step(imu, 0.02)
        self.assertAlmostEqual(snap.pitch, 0.0, delta=0.5)
        self.assertAlmostEqual(snap.turn, 0.0, delta=0.1)

        # Bank right (ufo_remote convention: ax_raw negative relative to zero -> roll > 0, turn > 0)
        dev.ax, dev.ay, dev.az = int(-0.45 * 16384), int(0.035 * 16384), int(0.892 * 16384)
        for _ in range(35):
            snap = imu.step(imu, 0.02)
        self.assertGreater(snap.roll, 18.0)
        self.assertGreater(snap.turn, 0.45)

        imu.close(imu)
        self.assertTrue(dev.closed)
        self.assertEqual(dev.regs[0x7D], 0x00)

        # 2. Borrowed active mode reads without modifying registers
        lua2, dev2, _, _ = self._make_env(initial_pwr=0x0E)
        imu2 = lua2.eval("dofile('/nand/apps/pixel_flight/scripts/imu.lua').open('/nand/apps/pixel_flight')")
        self.assertEqual(imu2.mode, 'borrowed_active')
        self.assertEqual(len(dev2.writes), 0)
        imu2.close(imu2)
        self.assertEqual(len(dev2.writes), 0)

    def test_coordinated_turn_weapons_split_screen_and_main_loop(self):
        lua, dev, screen, state = self._make_env(initial_pwr=0x0E)
        EVIDENCE.mkdir(parents=True, exist_ok=True)

        lua.execute("""
            local sim = dofile('/nand/apps/pixel_flight/scripts/flight_sim.lua').new('/nand/apps/pixel_flight/assets/world128.bin')
            local ren = dofile('/nand/apps/pixel_flight/scripts/render_flight.lua')
            _SIM = sim
            _REN = ren
        """)
        sim = lua.globals()._SIM
        ren = lua.globals()._REN
        imu_snap = lua.table_from({'valid': True, 'progress': 100, 'roll': 18.0, 'pitch': 8.0, 'abs_roll': 18.0, 'abs_pitch': 24.0})

        # Verify default throttle=0.5, weapon=1 (missile), subview=0 (spirit level), zero stunts
        self.assertAlmostEqual(sim.throttle, 0.5, delta=0.01)
        self.assertEqual(sim.weapon, 1)
        self.assertEqual(sim.subview, 0)
        sim.trigger_roll(sim, 1)
        self.assertEqual(sim.stunt, -1.0)

        # Verify bank + pull-up tightens coordinated turn rate (no barrel rolls, bank <= 36 deg)
        for _ in range(25):
            sim.step(sim, 0.02, 0.7, 0.0, False, True, False)
        rate_level = abs(sim.yaw_rate)
        for _ in range(25):
            sim.step(sim, 0.02, 0.7, 0.8, False, True, False)
        rate_pull = abs(sim.yaw_rate)
        self.assertGreater(rate_pull, rate_level * 1.15)
        self.assertLessEqual(abs(sim.froll) * 57.3, 37.0)

        # Render 3 split-screen variants and inspect primitive counts + PNG output
        # 1) Chase + Spirit Level (default) with missile fired
        sim.view = 1
        sim.subview = 0
        sim.weapon = 1
        sim.step(sim, 0.02, 0.45, 0.2, True, True, True)
        ren.draw(screen, sim, imu_snap, True, True)
        self.assertGreater(sim.msl_seq, 0)
        self.assertLess(screen.primitive_count, 420)
        screen.im.save(EVIDENCE / 'preview_chase_level.png')

        # 2) Overhead + Live Island Map with machine gun burst
        sim.view = 0
        sim.subview = 1
        sim.weapon = 0
        sim.step(sim, 0.02, -0.35, 0.1, False, True, True)
        ren.draw(screen, sim, imu_snap, True, False)
        self.assertGreater(sim.gun_seq, 0)
        self.assertLess(screen.primitive_count, 500)
        screen.im.save(EVIDENCE / 'preview_overhead_map.png')

        # 3) Cockpit + Level with boost & firing
        sim.view = 2
        sim.subview = 0
        sim.step(sim, 0.02, 0.25, 0.35, True, True, True)
        ren.draw(screen, sim, imu_snap, True, True)
        self.assertLess(screen.primitive_count, 400)
        screen.im.save(EVIDENCE / 'preview_cockpit_firing.png')

        # Verify touch hitboxes (view, gun, msl, fire, sub_level, sub_map, cal, exit)
        self.assertEqual(ren.hit_test(160, 20), 'view')
        self.assertEqual(ren.hit_test(300, 20), 'cal')
        self.assertEqual(ren.hit_test(410, 20), 'exit')
        self.assertEqual(ren.hit_test(50, 260), 'gun')
        self.assertEqual(ren.hit_test(140, 260), 'msl')
        self.assertEqual(ren.hit_test(240, 260), 'fire')
        self.assertEqual(ren.hit_test(330, 260), 'sub_level')
        self.assertEqual(ren.hit_test(420, 260), 'sub_map')

        # Run full main.lua with GPIO11 boost + GPIO10 weapon fire
        state['gpio'][11] = 0
        state['gpio'][10] = 0
        lua.globals()['args'] = lua.table_from({'smoke_ms': 400})
        lua.execute("dofile('/nand/apps/pixel_flight/scripts/main.lua')")
        # Release keys mid-arm shouldn't prevent clean cleanup when stopped; test armed flow cleanly:
        state2_lua, dev2, screen2, state2 = self._make_env(initial_pwr=0x0E)
        state2_lua.globals()['args'] = state2_lua.table_from({'smoke_ms': 120})
        state2_lua.execute("dofile('/nand/apps/pixel_flight/scripts/main.lua')")
        self.assertEqual(state2['gpio'][8], 0)
        self.assertTrue(state2['led_closed'])
        self.assertTrue(screen2.closed)
        self.assertTrue(dev2.closed)
        samples = state2['queues'].get('pixel_flight_samples', [])
        self.assertGreater(len(samples), 0)
        last = json.loads(samples[-1])
        self.assertEqual(last['v'], 2)
        self.assertLess(len(samples[-1]), 1400)
        self.assertAlmostEqual(last['sync']['throttle'], 0.5, delta=0.05)

    def test_ownership_preserves_receivers(self):
        lua, _, _, state = self._make_env(initial_pwr=0x0E)
        state['jobs'].append({'id': 'ui1', 'path': '/nand/apps/minna_nihongo/scripts/main.lua'})
        lua.execute("dofile('/nand/apps/pixel_flight/scripts/ownership.lua').release_foreground()")
        self.assertEqual(state['stopped'], ['ui1'])
        self.assertEqual(len(state['jobs']), 3)


if __name__ == '__main__':
    unittest.main()
