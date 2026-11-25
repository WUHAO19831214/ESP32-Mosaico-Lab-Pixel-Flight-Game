-- Authoritative deterministic flight simulation for ESP-Mosaico (Lua 5.4)
-- Supports mid/high throttle (50% cruise / 100% boost), selectable weapons (Gun / Missile),
-- 3 camera views (Overhead / Chase / Cockpit), and lower-half instrument sub-views (Level / Live Map).

local M = {}

local TAU = math.pi * 2.0
local RAD = math.pi / 180.0
local GRID = 128
local WORLD_N = 2048
local TRAIL_CAP = 32
local MAX_PROJ = 10

local SETTINGS = {
  speed = 92.0,
  boost = 1.75,
  agility = 1.05,
  bank = 36.0,
  turn_g = 62.0,
  altitude = 120.0,
  ceiling = 650.0,
  clearance = 7.0,
  jet_scale = 0.6,
  camera_follow = 0.6,
}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function follow(val, target, rate, dt)
  return val + (target - val) * (1.0 - math.exp(-dt * rate))
end

local function load_world(world_path)
  local storage = require('storage')
  local raw = storage.read_file(world_path)
  assert(raw and #raw >= 4 + GRID * GRID * 2, 'Invalid world128.bin')
  local b1, b2, b3, b4 = raw:byte(1, 4)
  local spawn_x = b1 + b2 * 256
  local spawn_y = b3 + b4 * 256
  local heights = {}
  local mats = {}
  local idx = 1
  for pos = 5, 4 + GRID * GRID * 2, 2 do
    local h, m = raw:byte(pos, pos + 1)
    heights[idx] = h
    mats[idx] = m
    idx = idx + 1
  end
  return {
    spawn_x = spawn_x,
    spawn_y = spawn_y,
    heights = heights,
    mats = mats,
  }
end

function M.new(world_path)
  local world = load_world(world_path)
  local s = {
    world = world,
    time = 0.0,
    x = world.spawn_x + 0.0,
    y = world.spawn_y + 0.0,
    z = SETTINGS.altitude,
    vx = 0.0,
    vy = 0.0,
    fyaw = 0.9,
    yaw_rate = 0.0,
    froll = 0.0,
    fpitch = 0.0,
    cam_yaw = -0.9 * SETTINGS.camera_follow,
    alt_goal = SETTINGS.altitude,
    climb_v = 0.0,
    climb_tilt = 0.0,
    floor_s = 0.0,
    boost = 0.0,
    throttle = 0.5, -- 0.5 mid cruise -> 1.0 full boost
    speed_now = SETTINGS.speed,
    stunt = -1.0,
    stunt_dir = 1,
    view = 1,    -- 0: Overhead, 1: Chase, 2: Cockpit
    subview = 0, -- 0: Spirit Level (default), 1: Live Island Map
    weapon = 1,  -- 0: Machine Gun, 1: Missile (default)
    firing = false,
    gun_cd = 0.0,
    msl_cd = 0.0,
    gun_seq = 0,
    msl_seq = 0,
    msl_side = 1,
    projectiles = {},
    day = 0,     -- 0: Day, 1: Sunset, 2: Night
    wingmen = 0,
    trail = {},
    trail_head = 0,
    last_trail_x = world.spawn_x + 0.0,
    last_trail_y = world.spawn_y + 0.0,
    last_cmd_id = '',
    swap_xy = false,
    inv_pitch = false,
    inv_roll = false,
    gain = 1.0,
  }

  function s:cell(wx, wy)
    local gx = (math.floor(wx) % WORLD_N) // 16
    local gy = (math.floor(wy) % WORLD_N) // 16
    local idx = gy * GRID + gx + 1
    return self.world.heights[idx] or 0, self.world.mats[idx] or 0
  end

  function s:ground_at(wx, wy)
    local h = self:cell(wx, wy)
    return h
  end

  function s:ground_ahead(speed)
    local sn = math.sin(self.fyaw)
    local cs = math.cos(self.fyaw)
    local top = 0.0
    for i = 0, 4 do
      local d = speed * 0.16 * i
      for side = -1, 1 do
        local h = self:ground_at(self.x + sn * d + cs * side * 7.0, self.y - cs * d + sn * side * 7.0)
        if h > top then top = h end
      end
    end
    return top
  end

  function s:spin_angle()
    return 0.0
  end

  function s:trigger_roll(_dir)
    -- Barrel-roll stunts disabled: real stick coordinated turn only
    self.stunt = -1.0
  end

  function s:cycle_view()
    self.view = (self.view + 1) % 3
  end

  function s:set_subview(sv)
    self.subview = math.floor(sv) % 2
  end

  function s:cycle_subview()
    self.subview = (self.subview + 1) % 2
  end

  function s:set_weapon(w)
    self.weapon = math.floor(w) % 2
  end

  function s:cycle_weapon()
    self.weapon = (self.weapon + 1) % 2
  end

  function s:cycle_day()
    self.day = (self.day + 1) % 3
  end

  function s:cycle_wingmen()
    self.wingmen = (self.wingmen + 1) % 3
  end

  function s:fire_once(kind)
    local k = (kind ~= nil) and kind or self.weapon
    local sn, cs = math.sin(self.fyaw), math.cos(self.fyaw)
    local cp, sp = math.cos(self.fpitch), math.sin(self.fpitch)
    local fx, fy, fz = sn * cp, -cs * cp, sp
    if #self.projectiles >= MAX_PROJ then
      table.remove(self.projectiles, 1)
    end
    if k == 0 then
      self.gun_seq = self.gun_seq + 1
      local spd = self.speed_now + 260.0
      self.projectiles[#self.projectiles + 1] = {
        kind = 0,
        x = (self.x + fx * 14.0) % WORLD_N,
        y = (self.y + fy * 14.0) % WORLD_N,
        z = self.z + fz * 14.0,
        vx = fx * spd,
        vy = fy * spd,
        vz = fz * spd,
        age = 0.0,
        max_age = 0.95,
      }
    else
      self.msl_seq = self.msl_seq + 1
      self.msl_side = -self.msl_side
      local side = self.msl_side * 9.0
      local spd = self.speed_now + 210.0
      self.projectiles[#self.projectiles + 1] = {
        kind = 1,
        x = (self.x + fx * 8.0 + cs * side) % WORLD_N,
        y = (self.y + fy * 8.0 + sn * side) % WORLD_N,
        z = math.max(4.0, self.z - 2.0),
        vx = fx * spd,
        vy = fy * spd,
        vz = fz * spd,
        age = 0.0,
        max_age = 1.55,
      }
    end
  end

  function s:apply_host_cmd(cmd)
    if type(cmd) ~= 'table' or type(cmd.id) ~= 'string' or cmd.id == '' then
      return false
    end
    if cmd.id == self.last_cmd_id then return false end
    self.last_cmd_id = cmd.id
    local act = cmd.action
    if act == 'view' then
      if type(cmd.val) == 'number' then self.view = math.floor(cmd.val) % 3
      else self:cycle_view() end
    elseif act == 'subview' then
      if type(cmd.val) == 'number' then self:set_subview(cmd.val)
      else self:cycle_subview() end
    elseif act == 'weapon' then
      if type(cmd.val) == 'number' then self:set_weapon(cmd.val)
      else self:cycle_weapon() end
    elseif act == 'fire' then
      if self.weapon == 0 and self.gun_cd <= 0.0 then
        self:fire_once(0)
        self.gun_cd = 0.09
      elseif self.weapon == 1 and self.msl_cd <= 0.0 then
        self:fire_once(1)
        self.msl_cd = 0.38
      end
    elseif act == 'day' then
      if type(cmd.val) == 'number' then self.day = math.floor(cmd.val) % 3
      else self:cycle_day() end
    elseif act == 'wingmen' then
      if type(cmd.val) == 'number' then self.wingmen = clamp(math.floor(cmd.val), 0, 2)
      else self:cycle_wingmen() end
    elseif act == 'roll' then
      self:trigger_roll(cmd.dir or 0)
    elseif act == 'tune' then
      if type(cmd.inv_pitch) == 'boolean' then self.inv_pitch = cmd.inv_pitch end
      if type(cmd.inv_roll) == 'boolean' then self.inv_roll = cmd.inv_roll end
      if type(cmd.swap_xy) == 'boolean' then self.swap_xy = cmd.swap_xy end
      if type(cmd.gain) == 'number' then self.gain = clamp(cmd.gain, 0.4, 2.5) end
    elseif act == 'reset' then
      self.x = self.world.spawn_x + 0.0
      self.y = self.world.spawn_y + 0.0
      self.z = SETTINGS.altitude
      self.alt_goal = SETTINGS.altitude
      self.fyaw = 0.9
      self.yaw_rate = 0.0
      self.froll = 0.0
      self.fpitch = 0.0
      self.projectiles = {}
    end
    return act == 'center'
  end

  function s:step(dt_raw, turn_in, climb_in, boost_held, imu_ready, fire_held)
    local dt = clamp(dt_raw, 0.001, 0.05)
    self.time = self.time + dt

    local boost_goal = boost_held and 1.0 or 0.0
    self.boost = follow(self.boost, boost_goal, boost_held and 6.0 or 2.8, dt)
    if not boost_held and self.boost < 0.0005 then self.boost = 0.0 end
    self.throttle = 0.5 + 0.5 * self.boost

    local speed = SETTINGS.speed * (1.0 + (SETTINGS.boost - 1.0) * self.boost)
    self.speed_now = speed

    local floor_now = self:ground_ahead(speed) + SETTINGS.clearance
    if self.floor_s == 0.0 then self.floor_s = floor_now end
    self.floor_s = follow(self.floor_s, floor_now, floor_now > self.floor_s and 9.0 or 3.0, dt)

    local max_rate = SETTINGS.agility
    local climb_max = speed * 0.46
    local want
    local flown = false
    local direct_climb = clamp(climb_in, -1.0, 1.0)
    local direct_turn = clamp(turn_in, -1.0, 1.0)
    local bank_max = SETTINGS.bank * RAD

    if imu_ready or math.abs(direct_turn) > 0.001 or math.abs(direct_climb) > 0.001 then
      flown = true
      local bank_target = direct_turn * bank_max
      self.froll = follow(self.froll, bank_target, 4.8, dt)
      -- Real coordinated turn: omega = (G * tan(phi) / V) * lift_factor (pulling back tightens turn)
      local lift_turn = 1.0 + 0.65 * math.max(0.0, direct_climb) - 0.15 * math.max(0.0, -direct_climb)
      want = (SETTINGS.turn_g * math.tan(self.froll) / math.max(60.0, speed)) * lift_turn
      want = clamp(want, -max_rate, max_rate)
      local bank_sink = (1.0 - math.cos(self.froll)) * 10.0
      self.alt_goal = self.alt_goal + (direct_climb * climb_max - bank_sink) * dt
    else
      want = max_rate * 0.45 * (0.55 * math.sin(self.time * 0.28 + 1.1) + 0.25 * math.sin(self.time * 0.62))
      want = clamp(want, -max_rate, max_rate)
      local roll_target = clamp(self.yaw_rate / max_rate, -1.0, 1.0) * bank_max
      self.froll = follow(self.froll, roll_target, 4.8, dt)
    end

    self.yaw_rate = follow(self.yaw_rate, want, 6.0, dt)
    self.fyaw = self.fyaw + self.yaw_rate * dt

    self.vx = math.sin(self.fyaw) * speed
    self.vy = -math.cos(self.fyaw) * speed
    self.x = (self.x + self.vx * dt) % WORLD_N
    self.y = (self.y + self.vy * dt) % WORLD_N

    if not flown then
      self.alt_goal = follow(self.alt_goal, SETTINGS.altitude, 0.9, dt)
    end
    self.alt_goal = clamp(self.alt_goal, self.floor_s, math.max(self.floor_s, SETTINGS.ceiling))

    local target_z = self.alt_goal + math.sin(self.time * 0.9) * 1.2
    local dz = clamp((target_z - self.z) * (1.0 - math.exp(-dt * 4.5)), -climb_max * dt, climb_max * dt)
    self.z = self.z + dz
    local hard = self:ground_at(self.x, self.y) + SETTINGS.clearance * 0.7
    if self.z < hard then
      self.z = follow(self.z, hard, 22.0, dt)
    end

    self.climb_v = follow(self.climb_v, dz / math.max(dt, 0.0001), 7.5, dt)
    local climbing = (self.climb_v >= 0 and 1 or -1) * math.max(0.0, math.abs(self.climb_v) - 2.0)
    self.climb_tilt = clamp((climbing / math.max(20.0, speed)) * 0.85, -0.35, 0.35)
    local pitch_target = clamp(direct_climb * 0.30 + self.climb_tilt * 0.22, -0.385, 0.385)
    self.fpitch = follow(self.fpitch, pitch_target, 5.2, dt)

    self.cam_yaw = follow(self.cam_yaw, -self.fyaw * SETTINGS.camera_follow, 1.6, dt)
    self.stunt = -1.0

    -- Weapons cooldown & firing
    self.gun_cd = math.max(0.0, self.gun_cd - dt)
    self.msl_cd = math.max(0.0, self.msl_cd - dt)
    self.firing = (fire_held == true)
    if self.firing then
      if self.weapon == 0 and self.gun_cd <= 0.0 then
        self:fire_once(0)
        self.gun_cd = 0.09
      elseif self.weapon == 1 and self.msl_cd <= 0.0 then
        self:fire_once(1)
        self.msl_cd = 0.38
      end
    end

    -- Step active ordnance
    local i = 1
    while i <= #self.projectiles do
      local pr = self.projectiles[i]
      pr.age = pr.age + dt
      if pr.kind < 2 then
        pr.x = (pr.x + pr.vx * dt) % WORLD_N
        pr.y = (pr.y + pr.vy * dt) % WORLD_N
        pr.z = pr.z + pr.vz * dt
        local gh = self:ground_at(pr.x, pr.y)
        if pr.age >= pr.max_age or pr.z <= gh + 1.0 then
          if pr.kind == 1 then
            pr.kind = 2
            pr.vx, pr.vy, pr.vz = 0.0, 0.0, 0.0
            pr.z = math.max(pr.z, gh + 2.0)
            pr.age = 0.0
            pr.max_age = 0.35
            i = i + 1
          else
            table.remove(self.projectiles, i)
          end
        else
          i = i + 1
        end
      else
        if pr.age >= pr.max_age then
          table.remove(self.projectiles, i)
        else
          i = i + 1
        end
      end
    end

    local ddx = self.x - self.last_trail_x
    local ddy = self.y - self.last_trail_y
    if ddx * ddx + ddy * ddy > 16.0 then
      self.last_trail_x = self.x
      self.last_trail_y = self.y
      self.trail_head = (self.trail_head % TRAIL_CAP) + 1
      self.trail[self.trail_head] = {x = self.x, y = self.y, z = self.z, t = self.time}
    end
  end

  function s:sync_payload()
    return {
      x = self.x,
      y = self.y,
      z = self.z,
      vx = self.vx,
      vy = self.vy,
      fyaw = self.fyaw,
      froll = self.froll,
      fpitch = self.fpitch,
      yaw_rate = self.yaw_rate,
      boost = self.boost,
      throttle = self.throttle,
      speed = self.speed_now,
      stunt = self.stunt,
      stunt_dir = self.stunt_dir,
      view = self.view,
      subview = self.subview,
      weapon = self.weapon,
      firing = self.firing,
      gun_seq = self.gun_seq,
      msl_seq = self.msl_seq,
      day = self.day,
      wingmen = self.wingmen,
      cmd_ack = self.last_cmd_id,
    }
  end

  return s
end

return M
