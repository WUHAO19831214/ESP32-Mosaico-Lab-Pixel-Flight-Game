-- 480x480 upper/lower split-screen renderer for ESP-Mosaico (Lua 5.4).
-- Top bar (y=0..44): Link status, Touch Camera View switcher, CAL zero, Exit
-- Upper half (y=45..239): Live synchronized Flight View + gun/missile effects
-- Middle tactical strip (y=240..286): Touch buttons [GUN] [MISSILE] [FIRE!] [LEVEL] [MAP]
-- Lower half (y=287..480): Default Spirit Level / Switchable Live Island Map
-- Strictly passes integer coordinates to all screen:* primitives.

local M = {}

local WORLD_N = 2048

local function I(v)
  return math.floor(v + 0.5)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function wrap_delta(d)
  if d > WORLD_N * 0.5 then d = d - WORLD_N end
  if d < -WORLD_N * 0.5 then d = d + WORLD_N end
  return d
end

local DAY_THEMES = {
  [0] = { -- Day
    sky = {0xFF3E8EDE, 0xFF56A0E4, 0xFF6DB2EA, 0xFF9CD3F5, 0xFFC6E8FA},
    sea = 0xFF2468B4,
    sea_mid = 0xFF2C7CC6,
    shallow = 0xFF42A0D8,
    surf = 0xFF68CCD6,
    haze = 0xFFBCE0F6,
    sand = 0xFFEEDCA4,
    sand_s = 0xFFCCB47A,
    grass = 0xFF60B234,
    grass_s = 0xFF38782C,
    tree = 0xFF2A7A36,
    tree_s = 0xFF164828,
    rock = 0xFF928C86,
    rock_s = 0xFF605A5C,
    snow = 0xFFF6FAFF,
    snow_s = 0xFFBACAE4,
    sun = 0xFFFFF4C8,
  },
  [1] = { -- Sunset
    sky = {0xFF544496, 0xFF7B509D, 0xFFD26D8C, 0xFFF6A282, 0xFFFFC684},
    sea = 0xFF34487C,
    sea_mid = 0xFF425B8E,
    shallow = 0xFF6682A8,
    surf = 0xFF9EB4BC,
    haze = 0xFFFAB686,
    sand = 0xFFEAC288,
    sand_s = 0xFFC29664,
    grass = 0xFF729244,
    grass_s = 0xFF4A6032,
    tree = 0xFF3E6A38,
    tree_s = 0xFF244228,
    rock = 0xFF9A7A7A,
    rock_s = 0xFF6A5258,
    snow = 0xFFFFDFC8,
    snow_s = 0xFFD2B0AA,
    sun = 0xFFFFAA5C,
  },
  [2] = { -- Night
    sky = {0xFF070A22, 0xFF0C1232, 0xFF121C46, 0xFF1A2858, 0xFF24386E},
    sea = 0xFF0A1B3D,
    sea_mid = 0xFF10244E,
    shallow = 0xFF18366A,
    surf = 0xFF28508A,
    haze = 0xFF1C2C5C,
    sand = 0xFF4E5266,
    sand_s = 0xFF363A4A,
    grass = 0xFF1B3A32,
    grass_s = 0xFF112622,
    tree = 0xFF132E28,
    tree_s = 0xFF0C1E1C,
    rock = 0xFF343A4E,
    rock_s = 0xFF222838,
    snow = 0xFF7088B8,
    snow_s = 0xFF4C608C,
    sun = 0xFFE8EEFF,
  },
}

local function mat_colors(th, mat)
  if mat <= 1 then return th.sea, th.sea
  elseif mat == 2 then return th.shallow, th.sea_mid
  elseif mat == 3 then return th.surf, th.shallow
  elseif mat <= 5 then return th.sand, th.sand_s
  elseif mat <= 8 then return th.grass, th.grass_s
  elseif mat <= 11 then return th.tree, th.tree_s
  elseif mat <= 14 then return th.rock, th.rock_s
  else return th.snow, th.snow_s end
end

local function clip_y(y, lo, hi)
  return clamp(y, lo, hi)
end

local function draw_jet_top(sc, cx, cy, yaw, roll, boost, time_s, scale)
  local sn, cs = math.sin(yaw), math.cos(yaw)
  local cr = clamp(math.abs(math.cos(roll)), 0.35, 1.0)
  local function pt(lx, ly)
    local sx = lx * cr * scale
    local sy = ly * scale
    return I(cx + sx * cs - sy * sn), clamp(I(cy + sx * sn + sy * cs), 48, 236)
  end

  local flicker = 0.75 + 0.35 * math.abs(math.sin(time_s * 38.0))
  local flen = (8.0 + 14.0 * boost) * flicker
  for _, side in ipairs({-3.0, 3.0}) do
    local nx, ny = pt(side, 15)
    local tx, ty = pt(side, 15 + flen)
    sc:line(nx, ny, tx, ty, 0xFFF0580E)
    sc:fill_circle(nx, ny, math.max(1, I(2.0 * scale)), 0xFFFFFCE0)
  end

  local nose_x, nose_y = pt(0, -19)
  local lw_x, lw_y = pt(-16, 8)
  local rw_x, rw_y = pt(16, 8)
  local tail_x, tail_y = pt(0, 14)

  for step = 0, 4 do
    local f = step / 4.0
    local x1, y1 = pt(-15 * f, -5 + 13 * f)
    local x2, y2 = pt(15 * f, -5 + 13 * f)
    sc:line(x1, y1, x2, y2, 0xFF545969)
  end
  sc:line(lw_x, lw_y, I((lw_x + nose_x) * 0.5), I((lw_y + nose_y) * 0.5), 0xFFF0580E)
  sc:line(rw_x, rw_y, I((rw_x + nose_x) * 0.5), I((rw_y + nose_y) * 0.5), 0xFFF0580E)
  sc:line(nose_x, nose_y, tail_x, tail_y, 0xFFC4C9D3)
  local c1x, c1y = pt(0, -8)
  sc:fill_circle(c1x, c1y, math.max(2, I(2.8 * scale)), 0xFF1E8CA0)
end

local function draw_jet_chase(sc, cx, cy, roll, pitch, boost, time_s, scale)
  local cr, sr = math.cos(roll), math.sin(roll)
  local py = pitch * 18.0 * scale
  local function pt(lx, ly)
    return I(cx + (lx * cr - ly * sr) * scale), clamp(I(cy + (lx * sr + ly * cr) * scale - py), 54, 234)
  end

  local lw_x, lw_y = pt(-40, 4)
  local rw_x, rw_y = pt(40, 4)
  local lc_x, lc_y = pt(-12, -2)
  local rc_x, rc_y = pt(12, -2)
  for k = -3, 3 do
    local l1x, l1y = pt(-38, 4 + k * 0.6)
    local r1x, r1y = pt(38, 4 + k * 0.6)
    sc:line(l1x, l1y, r1x, r1y, k < 0 and 0xFF707686 or 0xFF3D4150)
  end
  sc:line(lw_x, lw_y, I((lw_x + lc_x) * 0.5), I((lw_y + lc_y) * 0.5), 0xFFF0580E)
  sc:line(rw_x, rw_y, I((rw_x + rc_x) * 0.5), I((rw_y + rc_y) * 0.5), 0xFFF0580E)

  local fl_x, fl_y = pt(-9, -16)
  local fr_x, fr_y = pt(9, -16)
  local bl_x, bl_y = pt(-11, 2)
  local br_x, br_y = pt(11, 2)
  sc:line(bl_x, bl_y, fl_x, fl_y, 0xFF545969)
  sc:line(br_x, br_y, fr_x, fr_y, 0xFF545969)

  local bx, by = pt(0, -8)
  local cx0, cy0 = pt(0, -1)
  sc:fill_circle(bx, by, math.max(3, I(8 * scale)), 0xFF1E8CA0)
  sc:fill_circle(cx0, cy0, math.max(5, I(10 * scale)), 0xFF545969)

  local flicker = 0.8 + 0.32 * math.sin(time_s * 42.0)
  local frad = clamp(I((5.0 + 7.5 * boost) * flicker * scale), 3, 14)
  for _, ex in ipairs({-6, 6}) do
    local nx, ny = pt(ex, 4)
    sc:fill_circle(nx, ny, math.max(2, I(4 * scale)), 0xFF1D1F2A)
    sc:fill_circle(nx, clamp(ny + 2, 54, 234), frad, 0xFFF0580E)
    sc:fill_circle(nx, clamp(ny + 1, 54, 234), math.max(2, I(frad * 0.5)), 0xFFFFFCE0)
  end
end

local function draw_upper_projectiles(sc, sim, mode, focus_x, focus_y, horizon)
  if not sim.projectiles or #sim.projectiles == 0 then return end
  local sn, cs = math.sin(sim.fyaw), math.cos(sim.fyaw)
  for _, pr in ipairs(sim.projectiles) do
    local dx = wrap_delta(pr.x - sim.x)
    local dy = wrap_delta(pr.y - sim.y)
    if mode == 0 then
      local cx, cy = 240, 142
      local cam_cs, cam_sn = math.cos(sim.cam_yaw), math.sin(sim.cam_yaw)
      local fx = wrap_delta(pr.x - focus_x)
      local fy = wrap_delta(pr.y - focus_y)
      local px = I(cx + (fx * cam_cs - fy * cam_sn) * 1.45)
      local py = I(cy + (fx * cam_sn + fy * cam_cs) * 1.45)
      if px >= 6 and px < 474 and py >= 50 and py < 234 then
        if pr.kind == 0 then
          sc:fill_circle(px, py, 2, 0xFFFFFCE0)
        elseif pr.kind == 1 then
          sc:fill_circle(px - 2, py + 2, 3, 0xFFE2E8F0)
          sc:fill_circle(px, py, 3, 0xFFF0580E)
        else
          local er = clamp(I(5 + pr.age * 36), 4, 18)
          sc:fill_circle(px, py, er, 0xFFF0580E)
          sc:fill_circle(px, py, math.max(2, er // 2), 0xFFFFFCE0)
        end
      end
    else
      -- Perspective ahead distance & lateral offset along aircraft heading
      local ahead = dx * sn - dy * cs
      local lateral = dx * cs + dy * sn
      if ahead > 4.0 and ahead < 520.0 then
        local denom = ahead + 55.0
        local scale = 210.0 / denom
        local px = I(240 + lateral * scale * 1.15)
        local base_y = mode == 1 and (horizon + 24) or horizon
        local py = clamp(I(base_y - (pr.z - sim.z) * scale * 1.3 + 48.0 * scale * (mode == 1 and 1.0 or 0.15)), 50, 232)
        if px >= 8 and px < 472 then
          if pr.kind == 0 then
            local tx = clamp(I(px - lateral * 0.04), 8, 472)
            local ty = clamp(py + 6, 50, 234)
            sc:line(px, py, tx, ty, 0xFFFFA42C)
            sc:fill_circle(px, py, 2, 0xFFFFFCE0)
          elseif pr.kind == 1 then
            local r = clamp(I(2.0 + scale * 1.8), 2, 6)
            sc:fill_circle(px, clamp(py + 5, 50, 234), math.max(2, r), 0xFFCBD5E1)
            sc:fill_circle(px, py, r, 0xFFF0580E)
            sc:fill_circle(px, py, math.max(1, r // 2), 0xFFFFFCE0)
          else
            local er = clamp(I((10 + pr.age * 45) * scale), 4, 24)
            sc:fill_circle(px, py, er, 0xFFF0580E)
            sc:fill_circle(px, py, math.max(2, er // 2), 0xFFFFFCE0)
          end
        end
      end
    end
  end
end

local function draw_overhead_half(sc, sim, th)
  sc:fill_rect(0, 45, 480, 195, th.sea)
  local cx, cy = 240, 142
  local look = 18.0 + 14.0 * sim.boost
  local focus_x = sim.x + math.sin(sim.fyaw) * look
  local focus_y = sim.y - math.cos(sim.fyaw) * look
  local cs = math.cos(sim.cam_yaw)
  local sn = math.sin(sim.cam_yaw)

  local scale = 1.45
  local cell_px = I(16 * scale)
  for gy = -4, 4 do
    for gx = -9, 9 do
      local wx = focus_x + (gx * 16) * cs + (gy * 16) * sn
      local wy = focus_y - (gx * 16) * sn + (gy * 16) * cs
      local h, mat = sim:cell(wx, wy)
      if mat >= 2 then
        local top_col, side_col = mat_colors(th, mat)
        local sx = I(cx + gx * cell_px - cell_px * 0.5)
        local raw_sy = I(cy + gy * cell_px - cell_px * 0.5 - h * 0.65)
        local sy = clip_y(raw_sy, 46, 236)
        local max_h = 238 - sy
        if max_h > 2 and sx > -cell_px and sx < 480 then
          if h > 0 then
            sc:fill_rect(sx, sy, cell_px + 2, clamp(I(h * 0.65) + 4, 2, math.min(28, max_h)), side_col)
          end
          sc:fill_rect(sx, sy, cell_px + 2, math.min(cell_px + 2, max_h), top_col)
        end
      end
    end
  end

  for _, tp in ipairs(sim.trail) do
    local age = sim.time - tp.t
    if age < 2.0 then
      local dx = wrap_delta(tp.x - focus_x)
      local dy = wrap_delta(tp.y - focus_y)
      local tx = I(cx + (dx * cs - dy * sn) * scale)
      local ty = I(cy + (dx * sn + dy * cs) * scale - tp.z * 0.1)
      if tx >= 6 and tx < 474 and ty >= 48 and ty < 235 then
        sc:fill_circle(tx, ty, age < 0.7 and 2 or 1, 0xFFD6E8FA)
      end
    end
  end

  local jx = I(cx + (wrap_delta(sim.x - focus_x) * cs - wrap_delta(sim.y - focus_y) * sn) * scale)
  local jy = I(cy + (wrap_delta(sim.x - focus_x) * sn + wrap_delta(sim.y - focus_y) * cs) * scale)
  local rel_yaw = sim.fyaw + sim.cam_yaw
  local roll_total = sim.froll + sim:spin_angle()

  for w = 1, sim.wingmen do
    local side = (w == 1) and -34 or 34
    local w_sn, w_cs = math.sin(rel_yaw), math.cos(rel_yaw)
    draw_jet_top(sc, I(jx + side * w_cs - 28 * w_sn), I(jy + side * w_sn + 28 * w_cs), rel_yaw, roll_total * 0.9, sim.boost, sim.time + w * 0.7, 0.85)
  end
  draw_jet_top(sc, jx, jy, rel_yaw, roll_total, sim.boost, sim.time, 1.05)
  draw_upper_projectiles(sc, sim, 0, focus_x, focus_y, cy)
end

local function draw_chase_half(sc, sim, th)
  local horizon = clamp(I(124 + sim.fpitch * 80.0), 68, 198)
  local sky_h = horizon - 45
  local band_h = math.max(4, I(sky_h / #th.sky) + 1)
  for i, col in ipairs(th.sky) do
    local y0 = 45 + (i - 1) * band_h
    if y0 < horizon then
      sc:fill_rect(0, y0, 480, math.min(band_h, horizon - y0), col)
    end
  end

  if sim.day ~= 0 then
    local sun_x = clamp(I(240 - math.sin(sim.fyaw) * 150), 28, 452)
    local sun_y = clamp(horizon - 20, 58, horizon - 8)
    sc:fill_circle(sun_x, sun_y, sim.day == 1 and 14 or 9, th.sun)
  end

  sc:fill_rect(0, horizon, 480, math.min(10, 240 - horizon), th.haze)
  local sea_top = math.min(240, horizon + 10)
  if 240 > sea_top then
    sc:fill_rect(0, sea_top, 480, 240 - sea_top, th.sea)
  end

  local sn, cs = math.sin(sim.fyaw), math.cos(sim.fyaw)
  for band = 6, 1, -1 do
    local dist = 55.0 + band * 70.0
    local scale = 190.0 / (dist + 55.0)
    local base_y = horizon + I((236 - horizon) * (1.0 - band / 7.2))
    local col_w = clamp(I(24.0 * scale * 2.2), 12, 44)
    for sx_i = -5, 5 do
      local lateral = sx_i * 64.0 / math.max(0.4, scale * 2.0)
      local wx = sim.x + sn * dist + cs * lateral
      local wy = sim.y - cs * dist + sn * lateral
      local h, mat = sim:cell(wx, wy)
      if mat >= 2 then
        local top_col, side_col = mat_colors(th, mat)
        local px = I(240 + sx_i * 42)
        local ph = I(h * scale * 1.45)
        local y_top = clamp(base_y - ph, 48, 236)
        local wall_h = clamp(base_y - y_top + 4, 2, 238 - y_top)
        if ph > 0 and wall_h > 0 then
          sc:fill_rect(px - col_w // 2, y_top, col_w, wall_h, side_col)
        end
        sc:fill_rect(px - col_w // 2, clamp(y_top - 2, 47, 235), col_w, 4, top_col)
      end
    end
  end

  draw_upper_projectiles(sc, sim, 1, sim.x, sim.y, horizon)

  local roll_total = sim.froll + sim:spin_angle()
  for w = 1, sim.wingmen do
    local side = (w == 1) and -110 or 110
    draw_jet_chase(sc, 240 + side, 176, roll_total * 0.85, sim.fpitch, sim.boost, sim.time + w, 0.62)
  end
  draw_jet_chase(sc, 240, 194, roll_total, sim.fpitch, sim.boost, sim.time, 0.96)
end

local function draw_cockpit_half(sc, sim, th)
  local horizon = clamp(I(142 + sim.fpitch * 105.0), 66, 214)
  local roll = sim.froll + sim:spin_angle()
  local tilt_dy = I(math.sin(roll) * 85.0)

  sc:fill_rect(0, 45, 480, 195, th.sky[3])
  for step = 0, 15 do
    local x0 = step * 30
    local h_at_x = clamp(horizon + I((step - 7.5) / 7.5 * tilt_dy), 52, 234)
    sc:fill_rect(x0, h_at_x, 31, 240 - h_at_x, th.sea)
    sc:fill_rect(x0, h_at_x, 31, 4, th.haze)
  end

  local sn, cs = math.sin(sim.fyaw), math.cos(sim.fyaw)
  for gx = -6, 6 do
    local wx = sim.x + sn * 240.0 + cs * (gx * 48.0)
    local wy = sim.y - cs * 240.0 + sn * (gx * 48.0)
    local h, mat = sim:cell(wx, wy)
    if mat >= 4 then
      local top_col, side_col = mat_colors(th, mat)
      local px = 240 + gx * 36
      local hy = clamp(horizon + I((gx / 6.0) * tilt_dy * 0.7), 62, 232)
      local ph = clamp(I(h * 0.85), 4, 28)
      local y_top = clamp(hy - ph, 48, 228)
      sc:fill_rect(px - 18, y_top, 36, clamp(ph + 4, 4, 236 - y_top), side_col)
      sc:fill_rect(px - 18, y_top, 36, 4, top_col)
    end
  end

  draw_upper_projectiles(sc, sim, 2, sim.x, sim.y, horizon)

  -- HUD Reticle & Canopy Struts
  sc:line(212, 142, 230, 142, 0xFF5CE6C0)
  sc:line(250, 142, 268, 142, 0xFF5CE6C0)
  sc:line(240, 124, 240, 134, 0xFF5CE6C0)
  sc:line(240, 150, 240, 160, 0xFF5CE6C0)
  sc:line(0, 118, 48, 45, 0xFF1A1E2C)
  sc:line(479, 118, 432, 45, 0xFF1A1E2C)
  sc:text(16, 54, string.format('ALT %04dft', I(sim.z * 12)), {color = 0xFF5CE6C0, font_size = 14})
  sc:text(372, 54, string.format('SPD %03dkt', I(sim.speed_now * 4.2)), {color = 0xFF5CE6C0, font_size = 14})
end

local function draw_lower_level(sc, sim, imu_snap)
  sc:fill_rect(0, 287, 480, 193, 0xFF0A1320)

  local roll_deg = imu_snap.roll or 0.0
  local pitch_deg = imu_snap.pitch or 0.0
  local roll_rad = roll_deg * (math.pi / 180.0)

  -- Left half of lower panel: Spirit Level + Artificial Horizon (cx=128, cy=380, r=72)
  local cx, cy, r = 128, 380, 72
  sc:fill_circle(cx, cy, r + 5, 0xFF28384E)
  sc:fill_circle(cx, cy, r, 0xFF2366AD)
  local pitch_px = clamp(I(pitch_deg * 1.4), -50, 50)
  local earth_y = cy + pitch_px
  local earth_h = clamp(cy + r - earth_y, 4, r * 2 - 4)
  sc:fill_rect(cx - 54, earth_y, 108, earth_h, 0xFF7D4E22)

  local hx = I(math.cos(roll_rad) * 62)
  local hy = I(math.sin(roll_rad) * 62)
  sc:line(cx - hx, earth_y - hy, cx + hx, earth_y + hy, 0xFFF0F5FC)
  sc:line(cx - r + 8, cy, cx + r - 8, cy, 0xFF425874)
  sc:line(cx, cy - r + 8, cx, cy + r - 8, 0xFF425874)
  sc:fill_circle(cx, cy, 16, 0xFF132236)
  sc:fill_circle(cx, cy, 11, 0xFF0A1320)

  local bx = cx + clamp(I(roll_deg * 1.8), -52, 52)
  local by = cy - clamp(I(pitch_deg * 1.8), -52, 52)
  local is_level = math.abs(roll_deg) <= 3.0 and math.abs(pitch_deg) <= 3.0
  sc:fill_circle(bx, by, 9, is_level and 0xFF42E39B or 0xFF5CE6C0)
  sc:fill_circle(bx - 2, by - 2, 3, 0xFFFFFFFF)

  -- Right half of lower panel: Attitude, Throttle Bar (MID 50% / MAX 100%), Weapon status
  sc:fill_round_rect(224, 298, 228, 56, 8, 0xFF131D2B)
  sc:text(236, 306, string.format('PITCH %+5.1f deg', pitch_deg), {color = 0xFF5CE6C0, font_size = 16})
  sc:text(236, 329, string.format('ROLL  %+5.1f deg', roll_deg), {color = 0xFFFFAD75, font_size = 16})

  local thr_pct = I((sim.throttle or (0.5 + 0.5 * sim.boost)) * 100)
  local boosting = sim.boost > 0.25
  sc:fill_round_rect(224, 362, 228, 44, 8, 0xFF131D2B)
  sc:text(236, 368, boosting and ('THR MAX ' .. thr_pct .. '%') or ('THR MID ' .. thr_pct .. '%'),
    {color = boosting and 0xFFFFAD75 or 0xFF42E39B, font_size = 14})
  sc:fill_rect(236, 389, 204, 10, 0xFF1E2D40)
  sc:fill_rect(236, 389, clamp(I(204 * thr_pct / 100), 10, 204), 10, boosting and 0xFFF0580E or 0xFF34D399)

  sc:fill_round_rect(224, 414, 228, 46, 8, 0xFF131D2B)
  local wpn_str = (sim.weapon == 0) and 'WPN: GUN (RAPID)' or 'WPN: MISSILE'
  sc:text(236, 420, wpn_str, {color = sim.weapon == 0 and 0xFF5CE6C0 or 0xFFFFAD75, font_size = 14})
  sc:text(236, 439, 'KEY1:THR  KEY2:FIRE', {color = 0xFF94A3B8, font_size = 14})
end

local function draw_lower_map(sc, sim, th)
  sc:fill_rect(0, 287, 480, 193, 0xFF0A1320)

  -- Left Tactical Live Island Map (x=24..279, y=296..461 -> 17 x 11 cells @ 15px)
  local mx, my, cw, ch = 24, 296, 15, 15
  local mw, mh = 17 * cw, 11 * ch
  sc:fill_rect(mx - 2, my - 2, mw + 4, mh + 4, 0xFF2B3D54)
  sc:fill_rect(mx, my, mw, mh, th.sea)

  local stride = 24
  for gy = 0, 10 do
    for gx = 0, 16 do
      local wx = sim.x + (gx - 8) * stride
      local wy = sim.y + (gy - 5) * stride
      local _, mat = sim:cell(wx, wy)
      if mat >= 2 then
        local col = mat_colors(th, mat)
        sc:fill_rect(mx + gx * cw, my + gy * ch, cw, ch, col)
      end
    end
  end

  local cx = mx + 8 * cw + cw // 2
  local cy = my + 5 * ch + ch // 2

  -- Active projectiles on map
  if sim.projectiles then
    for _, pr in ipairs(sim.projectiles) do
      local px = I(cx + wrap_delta(pr.x - sim.x) * (cw / stride))
      local py = I(cy + wrap_delta(pr.y - sim.y) * (ch / stride))
      if px >= mx + 3 and px < mx + mw - 3 and py >= my + 3 and py < my + mh - 3 then
        if pr.kind == 2 then
          sc:fill_circle(px, py, 5, 0xFFF0580E)
          sc:fill_circle(px, py, 2, 0xFFFFFCE0)
        elseif pr.kind == 1 then
          sc:fill_circle(px, py, 3, 0xFFFF5533)
        else
          sc:fill_circle(px, py, 2, 0xFFFFFCE0)
        end
      end
    end
  end

  -- Aircraft heading vector & position
  local hx = I(cx + math.sin(sim.fyaw) * 18)
  local hy = I(cy - math.cos(sim.fyaw) * 18)
  sc:line(cx, cy, hx, hy, 0xFFFFFFFF)
  sc:fill_circle(cx, cy, 4, 0xFFFFAD75)

  -- Right Nav Telemetry Panel
  sc:fill_round_rect(290, 296, 166, 165, 8, 0xFF131D2B)
  sc:text(302, 306, 'LIVE ISLAND MAP', {color = 0xFF5CE6C0, font_size = 14})
  sc:text(302, 330, string.format('POS %04d,%04d', I(sim.x), I(sim.y)), {color = 0xFFF0F5FC, font_size = 14})
  sc:text(302, 352, string.format('ALT %04dft', I(sim.z * 12)), {color = 0xFFA7F3D0, font_size = 14})
  sc:text(302, 374, string.format('SPD %03dkt', I(sim.speed_now * 4.2)), {color = 0xFFA7F3D0, font_size = 14})
  local hdg = (I(sim.fyaw * 180.0 / math.pi) % 360 + 360) % 360
  sc:text(302, 396, string.format('HDG %03d deg', hdg), {color = 0xFFCBD5E1, font_size = 14})
  local thr_pct = I((sim.throttle or (0.5 + 0.5 * sim.boost)) * 100)
  sc:text(302, 418, string.format('THR %d%%', thr_pct), {color = sim.boost > 0.25 and 0xFFFFAD75 or 0xFF42E39B, font_size = 14})
  sc:text(302, 440, sim.weapon == 0 and 'WPN: GUN' or 'WPN: MISSILE', {color = 0xFFFFAD75, font_size = 14})
end

function M.hit_test(tx, ty)
  if not tx or not ty then return nil end
  if ty <= 46 then
    if tx >= 120 and tx < 264 then return 'view'
    elseif tx >= 264 and tx < 368 then return 'cal'
    elseif tx >= 368 then return 'exit' end
    return nil
  end
  if ty >= 238 and ty <= 288 then
    if tx < 99 then return 'gun'
    elseif tx < 193 then return 'msl'
    elseif tx < 287 then return 'fire'
    elseif tx < 381 then return 'sub_level'
    else return 'sub_map' end
  end
  return nil
end

function M.draw(sc, sim, imu_snap, linked, boost_held)
  local th = DAY_THEMES[sim.day] or DAY_THEMES[0]
  sc:begin({clear = 0xFF0B1320})

  -- Upper Half Flight View (y=45..239)
  if sim.view == 0 then
    draw_overhead_half(sc, sim, th)
  elseif sim.view == 1 then
    draw_chase_half(sc, sim, th)
  else
    draw_cockpit_half(sc, sim, th)
  end

  -- Lower Half Switchable Instrument Panel (y=287..480)
  if sim.subview == 1 then
    draw_lower_map(sc, sim, th)
  else
    draw_lower_level(sc, sim, imu_snap)
  end

  -- Top Touch Bar (y=0..44) drawn last so viewport pixels never overlap buttons
  sc:fill_rect(0, 0, 480, 45, 0xFF0E1726)
  sc:fill_circle(24, 22, 5, linked and 0xFF42E39B or 0xFFFFAD75)
  sc:text(34, 14, linked and 'SYNC' or 'LOCAL', {color = 0xFFF0F5FC, font_size = 16})

  local view_names = {[0] = 'VIEW:TOP', [1] = 'VIEW:CHASE', [2] = 'VIEW:SEAT'}
  sc:fill_round_rect(122, 5, 138, 34, 8, 0xFF1E324A)
  sc:text(132, 13, view_names[sim.view] or 'VIEW', {color = 0xFF7CB2FF, font_size = 16})

  sc:fill_round_rect(266, 5, 96, 34, 8, 0xFF1E324A)
  sc:text(286, 13, 'CAL 0', {color = 0xFF5CE6C0, font_size = 16})

  sc:fill_round_rect(368, 5, 86, 34, 8, 0xFF233248)
  sc:text(388, 13, 'EXIT', {color = 0xFFF0F5FC, font_size = 16})

  -- Middle Tactical Control Strip (y=240..286)
  sc:fill_rect(0, 240, 480, 47, 0xFF0E1726)
  local pills = {
    {x = 8,   w = 88, lbl = 'GUN',     bg = sim.weapon == 0 and 0xFF1D6B58 or 0xFF1B2A3E, fg = sim.weapon == 0 and 0xFFFFFFFF or 0xFF94A3B8},
    {x = 102, w = 88, lbl = 'MISSILE', bg = sim.weapon == 1 and 0xFF9A3412 or 0xFF1B2A3E, fg = sim.weapon == 1 and 0xFFFFFFFF or 0xFF94A3B8},
    {x = 196, w = 88, lbl = 'FIRE!',   bg = sim.firing and 0xFFE11D48 or 0xFF5C1D2C, fg = 0xFFFFFFFF},
    {x = 290, w = 88, lbl = 'LEVEL',   bg = sim.subview == 0 and 0xFF1E4E79 or 0xFF1B2A3E, fg = sim.subview == 0 and 0xFFFFFFFF or 0xFF94A3B8},
    {x = 384, w = 88, lbl = 'MAP',     bg = sim.subview == 1 and 0xFF1E4E79 or 0xFF1B2A3E, fg = sim.subview == 1 and 0xFFFFFFFF or 0xFF94A3B8},
  }
  for _, p in ipairs(pills) do
    sc:fill_round_rect(p.x, 244, p.w, 38, 8, p.bg)
    sc:text(p.x + 12, 254, p.lbl, {color = p.fg, font_size = 16})
  end

  sc:present()
end

return M
