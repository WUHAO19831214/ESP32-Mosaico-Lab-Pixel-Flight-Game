#!/usr/bin/env python3
"""Generate crisp showcase PNGs in docs/images/ for the project README."""
from __future__ import annotations

import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'app'
RUNTIME = ROOT / '.runtime'
OUT = ROOT / 'docs' / 'images'
OUT.mkdir(parents=True, exist_ok=True)


def load_font(size: int, zh: bool = False):
    candidates = (
        ['/System/Library/Fonts/STHeiti Medium.ttc', '/System/Library/Fonts/PingFang.ttc']
        if zh
        else ['/System/Library/Fonts/Menlo.ttc', '/System/Library/Fonts/STHeiti Medium.ttc']
    )
    for fp in candidates:
        if Path(fp).exists():
            try:
                return ImageFont.truetype(fp, size)
            except Exception:
                pass
    return ImageFont.load_default()


class CrispScreen:
    def __init__(self):
        self.im = Image.new('RGB', (480, 480), (11, 19, 32))
        self.draw = ImageDraw.Draw(self.im)
        self.fonts = {
            14: load_font(13, zh=False),
            16: load_font(15, zh=False),
            20: load_font(19, zh=False),
        }

    @staticmethod
    def _rgb(argb: int) -> tuple[int, int, int]:
        return ((argb >> 16) & 255, (argb >> 8) & 255, argb & 255)

    def begin(self, opts):
        self.draw.rectangle((0, 0, 479, 479), fill=self._rgb(int(opts['clear'])))

    def fill_rect(self, x, y, w, h, color):
        if w <= 0 or h <= 0:
            return
        self.draw.rectangle((x, y, x + w - 1, y + h - 1), fill=self._rgb(int(color)))

    def fill_round_rect(self, x, y, w, h, r, color):
        if w <= 0 or h <= 0:
            return
        self.draw.rounded_rectangle((x, y, x + w - 1, y + h - 1), radius=max(0, r), fill=self._rgb(int(color)))

    def fill_circle(self, x, y, r, color):
        r = max(0, r)
        self.draw.ellipse((x - r, y - r, x + r, y + r), fill=self._rgb(int(color)))

    def line(self, x1, y1, x2, y2, color):
        self.draw.line((x1, y1, x2, y2), fill=self._rgb(int(color)), width=1)

    def text(self, x, y, value, opts):
        sz = int(opts['font_size']) if opts and 'font_size' in opts else 14
        font = self.fonts.get(sz, self.fonts[14])
        self.draw.text((x, y), str(value), fill=self._rgb(int(opts['color'])), font=font)

    def present(self):
        pass


def render_esp_screens() -> dict[str, Image.Image]:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
        function _make_storage(rf)
          return {
            get_root_dir = function() return '/nand' end,
            join_path = function(...) return table.concat({...}, '/') end,
            read_file = rf,
          }
        end
    """)
    storage = lua.globals()._make_storage(
        lambda p: Path(str(p).replace('/nand/apps/pixel_flight', str(APP))).read_bytes()
    )
    lua.globals()['_ST'] = storage
    lua.execute(
        """
        local orig_require = require
        function require(name)
          if name == 'storage' then return _ST end
          return orig_require(name)
        end
        function dofile(path)
          local real = path:gsub('^/nand/apps/pixel_flight', '"""
        + str(APP).replace('\\', '\\\\')
        + """')
          local chunk, err = loadfile(real)
          assert(chunk, err)
          return chunk()
        end
        _SIM = dofile('/nand/apps/pixel_flight/scripts/flight_sim.lua').new('/nand/apps/pixel_flight/assets/world128.bin')
        _REN = dofile('/nand/apps/pixel_flight/scripts/render_flight.lua')
        """
    )

    sim = lua.globals()._SIM
    ren = lua.globals()._REN
    scr = CrispScreen()

    lua.execute("""
        function _wrap(s)
          local t = {}
          function t:begin(o) s:begin(o) end
          function t:fill_rect(x,y,w,h,c) s:fill_rect(x,y,w,h,c) end
          function t:fill_round_rect(x,y,w,h,r,c) s:fill_round_rect(x,y,w,h,r,c) end
          function t:fill_circle(x,y,r,c) s:fill_circle(x,y,r,c) end
          function t:line(x1,y1,x2,y2,c) s:line(x1,y1,x2,y2,c) end
          function t:text(x,y,v,o) s:text(x,y,v,o) end
          function t:present() s:present() end
          return t
        end
    """)
    wscr = lua.globals()._wrap(scr)

    out = {}
    imu_chase = lua.table_from({'valid': True, 'progress': 100, 'roll': 16.5, 'pitch': 7.2})
    sim.view = 1
    sim.subview = 0
    sim.weapon = 1
    sim.day = 1
    sim.wingmen = 1
    for _ in range(18):
        sim.step(sim, 0.02, 0.48, 0.22, True, True, True)
    ren.draw(wscr, sim, imu_chase, True, True)
    out['chase_level'] = scr.im.copy()

    imu_ov = lua.table_from({'valid': True, 'progress': 100, 'roll': -12.0, 'pitch': 4.5})
    sim.view = 0
    sim.subview = 1
    sim.weapon = 0
    sim.day = 0
    sim.wingmen = 2
    for _ in range(25):
        sim.step(sim, 0.02, -0.35, 0.12, False, True, True)
    ren.draw(wscr, sim, imu_ov, True, False)
    out['overhead_map'] = scr.im.copy()

    imu_ck = lua.table_from({'valid': True, 'progress': 100, 'roll': 11.4, 'pitch': -3.5})
    sim.view = 2
    sim.subview = 0
    sim.weapon = 0
    sim.day = 1
    sim.wingmen = 1
    for _ in range(16):
        sim.step(sim, 0.02, 0.30, -0.15, True, True, True)
    ren.draw(wscr, sim, imu_ck, True, True)
    out['cockpit_gun'] = scr.im.copy()
    return out


def load_desktop_frame(name: str, target_size: tuple[int, int]) -> Image.Image:
    raw = (RUNTIME / f'frame_{name}.rgba').read_bytes()
    im = Image.frombytes('RGBA', (440, 270), raw).convert('RGB')
    return im.resize(target_size, Image.Resampling.NEAREST)


def draw_rounded_card(canvas: Image.Image, box: tuple[int, int, int, int], radius: int, fill, outline, width: int = 2):
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def build_hero_banner(esp: dict[str, Image.Image]):
    W, H = 1440, 760
    bg = Image.new('RGB', (W, H), (10, 17, 30))
    d = ImageDraw.Draw(bg)

    # Subtle grid background
    for gx in range(0, W, 40):
        d.line((gx, 0, gx, H), fill=(18, 29, 48), width=1)
    for gy in range(0, H, 40):
        d.line((0, gy, W, gy), fill=(18, 29, 48), width=1)

    f_title = load_font(34, zh=True)
    f_sub = load_font(18, zh=True)
    f_tag = load_font(14, zh=True)
    f_mono = load_font(14, zh=False)

    # Header
    d.text((48, 30), 'ESP32-Mosaico × Pixel Flight  双端同步像素空战游戏', fill=(244, 248, 255), font=f_title)
    d.text((48, 76), 'ESP32-S31 480×480 上下分屏触控掌机  <->  Mac 桌面 SpriteStack + WebGL2 高帧率战机同步渲染', fill=(92, 230, 192), font=f_sub)

    # Left: Mac Desktop frame (840x515) inside browser mockup
    draw_rounded_card(bg, (48, 128, 888, 692), 14, (19, 32, 54), (77, 122, 153), width=2)
    d.ellipse((68, 144, 80, 156), fill=(239, 68, 68))
    d.ellipse((88, 144, 100, 156), fill=(245, 158, 11))
    d.ellipse((108, 144, 120, 156), fill=(52, 211, 153))
    d.text((138, 140), 'Mac Desktop High-FPS Renderer (http://127.0.0.1:8780)', fill=(186, 214, 238), font=f_mono)

    desk_im = load_desktop_frame('chase', (816, 500))
    bg.paste(desk_im, (60, 174))

    # Overlay HUD strip inside desktop mockup
    d.rounded_rectangle((72, 186, 864, 218), radius=6, fill=(13, 25, 44))
    d.ellipse((84, 196, 94, 206), fill=(52, 211, 153))
    d.text((102, 194), 'ESP-Mosaico 已同步 (32ms) | 视角: 尾随 Chase | 武器: 导弹 | 油门: 加力 100%', fill=(226, 240, 255), font=f_tag)

    # Center Sync Bridge arrow & badges
    d.line((894, 410, 968, 410), fill=(92, 230, 192), width=4)
    d.polygon([(968, 410), (952, 400), (952, 420)], fill=(92, 230, 192))
    d.polygon([(894, 410), (910, 400), (910, 420)], fill=(251, 146, 60))
    d.rounded_rectangle((894, 344, 968, 392), radius=8, fill=(22, 48, 70), outline=(92, 230, 192), width=1)
    d.text((905, 351), 'Wi-Fi', fill=(92, 230, 192), font=f_mono)
    d.text((905, 369), '~30Hz', fill=(255, 255, 255), font=f_mono)

    # Right: ESP-Mosaico Hardware Bezel + 480x480 Screen (scaled 0.84 -> 404x404)
    draw_rounded_card(bg, (974, 134, 1404, 686), 24, (24, 30, 42), (96, 114, 138), width=3)
    d.text((1002, 154), 'ESP-Mosaico (ESP32-S31)', fill=(248, 250, 252), font=f_mono)
    d.text((1248, 154), 'BMI270 6-Axis', fill=(251, 146, 60), font=f_mono)

    esp_im = esp['chase_level'].resize((396, 396), Image.Resampling.BILINEAR)
    bg.paste(esp_im, (991, 186))
    d.rectangle((991, 186, 1387, 582), outline=(66, 94, 128), width=2)

    # Physical button callouts below device bezel
    f_callout = load_font(12, zh=True)
    d.rounded_rectangle((991, 598, 1184, 668), radius=8, fill=(20, 46, 44), outline=(52, 211, 153), width=1)
    d.text((1003, 608), 'GPIO 11 左机械键', fill=(52, 211, 153), font=f_tag)
    d.text((1003, 634), '默认50%巡航 · 按住100%加力', fill=(226, 232, 240), font=f_callout)

    d.rounded_rectangle((1194, 598, 1387, 668), radius=8, fill=(64, 24, 34), outline=(248, 113, 113), width=1)
    d.text((1206, 608), 'GPIO 10 右机械键', fill=(252, 165, 165), font=f_tag)
    d.text((1206, 634), '双端同步发射 导弹 / 机枪', fill=(226, 232, 240), font=f_callout)

    # Footer bar
    d.text((48, 714), '零刷机原生 ESP-Claw Lua 5.4 运行 · 非线性三次摇杆曲线 (Cubic Expo) · 无眩晕协调转弯物理 · 离线可直接键盘/鼠标试玩', fill=(148, 174, 204), font=f_tag)
    bg.save(OUT / 'hero-dual-sync-banner.png', optimize=True)


def build_desktop_views():
    W, H = 1440, 460
    bg = Image.new('RGB', (W, H), (11, 18, 32))
    d = ImageDraw.Draw(bg)
    f_title = load_font(22, zh=True)
    f_cap = load_font(15, zh=True)

    d.text((36, 22), '桌面端高帧率 SpriteStack 像素三视角实机渲染', fill=(241, 245, 249), font=f_title)
    d.text((36, 54), '统一 2048×2048 航海群岛地形 (world128) · 双引擎加力火焰与导弹尾迹实时同步', fill=(92, 230, 192), font=f_cap)

    items = [
        ('overhead', '1. 俯视群岛视角 (Overhead)', '正交体素堆叠海岛 + 翼尖凝结尾迹 + 双僚机编队'),
        ('chase', '2. 日落尾随视角 (Chase · Sunset)', '协调压坡转弯 + 双发加力 + 翼下导弹与火球爆炸'),
        ('cockpit', '3. 座舱仪表视角 (Cockpit HUD)', '随坡度倾斜的天海地平线 + 舱内瞄准光圈 + 战机拉烟'),
    ]
    for idx, (key, title, desc) in enumerate(items):
        x0 = 36 + idx * 462
        y0 = 92
        draw_rounded_card(bg, (x0, y0, x0 + 444, y0 + 344), 12, (20, 32, 52), (68, 108, 138), width=2)
        frame = load_desktop_frame(key, (424, 260))
        bg.paste(frame, (x0 + 10, y0 + 10))
        d.text((x0 + 14, y0 + 282), title, fill=(255, 255, 255), font=f_cap)
        d.text((x0 + 14, y0 + 308), desc, fill=(148, 174, 204), font=load_font(13, zh=True))

    bg.save(OUT / 'desktop-three-views.png', optimize=True)


def build_esp32_showcase(esp: dict[str, Image.Image]):
    W, H = 1480, 560
    bg = Image.new('RGB', (W, H), (11, 18, 32))
    d = ImageDraw.Draw(bg)
    f_title = load_font(24, zh=True)
    f_sub = load_font(15, zh=True)
    f_cap = load_font(14, zh=True)

    d.text((36, 22), 'ESP-Mosaico 480×480 上下分屏电容触控界面详解', fill=(241, 245, 249), font=f_title)
    d.text((36, 56), '顶栏触控切视角/归零 · 上半屏同步空战画面 · 中部触控条选武器(机枪/导弹)与开火 · 下半屏默认水平仪/一键切换实时地图', fill=(92, 230, 192), font=f_sub)

    cards = [
        ('chase_level', '① 尾随视角 + 默认水平仪 (Chase + LEVEL)', '按住左键全速加力 100% · 翼下导弹发射瞬间'),
        ('overhead_map', '② 俯视视角 + 实时海岛地图 (Top + MAP)', '中档 50% 巡航油门 · 下半屏实时地形导航与弹道点'),
        ('cockpit_gun', '③ 第一人称座舱 + 机枪扫射 (Cockpit + GUN)', '座舱准星跟随俯仰横滚 · 中部 GUN/FIRE 触控直达'),
    ]
    for idx, (key, title, desc) in enumerate(cards):
        x0 = 36 + idx * 476
        y0 = 96
        draw_rounded_card(bg, (x0, y0, x0 + 456, y0 + 444), 16, (20, 28, 42), (76, 108, 140), width=2)
        im = esp[key].resize((384, 384), Image.Resampling.BILINEAR)
        bg.paste(im, (x0 + 36, y0 + 14))
        d.rectangle((x0 + 36, y0 + 14, x0 + 420, y0 + 398), outline=(92, 130, 168), width=1)
        d.text((x0 + 22, y0 + 404), title, fill=(255, 255, 255), font=f_cap)
        d.text((x0 + 22, y0 + 424), desc, fill=(148, 174, 204), font=load_font(12, zh=True))

    bg.save(OUT / 'esp32-split-ui-showcase.png', optimize=True)


def build_physics_chart():
    W, H = 1280, 480
    bg = Image.new('RGB', (W, H), (11, 18, 32))
    d = ImageDraw.Draw(bg)
    f_title = load_font(22, zh=True)
    f_sub = load_font(14, zh=True)
    f_mono = load_font(13, zh=False)

    d.text((36, 20), '飞行控制数学模型：三次非线性摇杆曲线 + 协调转弯气动物理', fill=(241, 245, 249), font=f_title)
    d.text((36, 52), '告别眩晕乱翻滚：微倾稳定精细巡航，大倾柔和响应，拉杆配合压坡度自然收紧转弯半径', fill=(92, 230, 192), font=f_sub)

    # Left Chart: Cubic Expo curve (x=48..610, y=96..444)
    draw_rounded_card(bg, (36, 92, 620, 448), 12, (16, 26, 44), (62, 92, 122), width=2)
    d.text((56, 108), '1. 体感摇杆响应曲线 stick_expo (3.5° 死区 + 三次曲线)', fill=(248, 250, 252), font=f_sub)
    ox, oy, pw, ph = 90, 404, 490, 250
    d.line((ox, oy, ox + pw, oy), fill=(100, 116, 139), width=2)
    d.line((ox, oy, ox, oy - ph), fill=(100, 116, 139), width=2)

    # Deadzone shading
    dz_x = ox + int((3.5 / 30.0) * pw)
    d.rectangle((ox + 1, oy - ph, dz_x, oy - 1), fill=(36, 46, 68))
    d.text((ox + 4, oy - 22), '3.5°', fill=(148, 163, 184), font=f_mono)

    # Linear dashed reference
    for i in range(0, 30, 2):
        x1 = ox + int((i / 30.0) * pw)
        y1 = oy - int((i / 30.0) * ph)
        x2 = ox + int(((i + 1) / 30.0) * pw)
        y2 = oy - int(((i + 1) / 30.0) * ph)
        d.line((x1, y1, x2, y2), fill=(71, 85, 105), width=2)

    # Roll Expo (0.55, max=30) & Pitch Expo (0.50, max=26)
    def plot_curve(max_deg, expo, col):
        pts = []
        for step in range(301):
            deg = step * 0.1
            mag = max(0.0, deg - 3.5)
            u = min(1.0, mag / max(1.0, max_deg - 3.5))
            val = (1.0 - expo) * u + expo * (u ** 3) if mag > 0 else 0.0
            pts.append((ox + int((deg / 30.0) * pw), oy - int(val * ph)))
        d.line(pts, fill=col, width=3)

    plot_curve(30.0, 0.55, (92, 230, 192))
    plot_curve(26.0, 0.50, (251, 146, 60))
    d.text((112, 154), '━ 横滚转向 (Dead 3.5°, Max 30°, Expo 0.55)', fill=(92, 230, 192), font=f_sub)
    d.text((112, 180), '━ 俯仰升降 (Dead 3.5°, Max 26°, Expo 0.50)', fill=(251, 146, 60), font=f_sub)
    d.text((112, 206), '--- 线性输入参照 (近中心易抖动)', fill=(100, 116, 139), font=f_sub)
    d.text((ox + pw - 95, oy + 12), '倾转角 (deg)', fill=(148, 163, 184), font=f_sub)

    # Right Chart: Coordinated Turn Rate vs Bank Angle (x=650..1244, y=92..448)
    draw_rounded_card(bg, (652, 92, 1244, 448), 12, (16, 26, 44), (62, 92, 122), width=2)
    d.text((672, 108), '2. 协调转弯角速度 ω = (G·tan φ / V) · LiftFactor', fill=(248, 250, 252), font=f_sub)
    rx, ry, rw, rh = 716, 404, 490, 250
    d.line((rx, ry, rx + rw, ry), fill=(100, 116, 139), width=2)
    d.line((rx, ry, rx, ry - rh), fill=(100, 116, 139), width=2)

    def plot_turn(speed, lift_k, col):
        pts = []
        for b in range(37):
            phi = math.radians(b)
            omega_deg = math.degrees((62.0 * math.tan(phi) / speed) * lift_k)
            pts.append((rx + int((b / 36.0) * rw), ry - int(min(1.0, omega_deg / 52.0) * rh)))
        d.line(pts, fill=col, width=3)

    plot_turn(92.0, 1.0, (92, 230, 192))
    plot_turn(92.0, 1.45, (244, 63, 94))
    plot_turn(161.0, 1.0, (96, 165, 250))
    d.text((736, 154), '━ 中档巡航平转 (V=92, 36° 限幅坡度 ≈ 28°/s)', fill=(92, 230, 192), font=f_sub)
    d.text((736, 180), '━ 压坡+拉杆爬升紧转 (升力增益 ≈ 41°/s)', fill=(244, 63, 94), font=f_sub)
    d.text((736, 206), '━ 全加力高速转弯 (V=161, 半径自然变大)', fill=(96, 165, 250), font=f_sub)
    d.text((rx + rw - 110, ry + 12), '坡度角 φ (0~36°)', fill=(148, 163, 184), font=f_sub)

    bg.save(OUT / 'flight-physics-and-expo-curves.png', optimize=True)


def main():
    esp = render_esp_screens()
    build_hero_banner(esp)
    build_desktop_views()
    build_esp32_showcase(esp)
    build_physics_chart()
    print('All README showcase images generated successfully in docs/images/')


if __name__ == '__main__':
    main()
