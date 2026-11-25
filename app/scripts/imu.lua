-- Bosch BMI270 driver + 0ms tangent-plane pose calibration & complementary gyro smoothing
-- Adapted for ESP-Mosaico (ESP32-S31, I2C0 @ 0x69, Lua 5.4).
-- Matches verified ESP-Mosaico BMI270 axis orientation (+X = Right, +Y = Top, +Z = Out).
-- Preserves Bosch license (app/assets/BMI270-LICENSE).

local M = {}

local RAD = math.pi / 180.0
local DEG = 180.0 / math.pi

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function wrap_deg(d)
  return ((d + 180.0) % 360.0) - 180.0
end

local function signed16(lo, hi)
  local n = lo + hi * 256
  return n >= 32768 and n - 65536 or n
end

local function dot3(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function cross3(a, b)
  return {
    a[2] * b[3] - a[3] * b[2],
    a[3] * b[1] - a[1] * b[3],
    a[1] * b[2] - a[2] * b[1],
  }
end

local function norm3(v)
  local mag = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  if mag < 0.05 or mag ~= mag then return nil, 0.0 end
  return {v[1] / mag, v[2] / mag, v[3] / mag}, mag
end

-- Standard flight-simulator non-linear cubic stick S-curve:
-- Softens small wrist inputs near center while reaching full deflection smoothly.
local function stick_expo(deg, dead, max_deg, expo)
  local mag = math.abs(deg) - dead
  if mag <= 0.0 then return 0.0 end
  local u = clamp(mag / math.max(1.0, max_deg - dead), 0.0, 1.0)
  local shaped = (1.0 - expo) * u + expo * u * u * u
  return deg >= 0.0 and shaped or -shaped
end

function M.open(root)
  local self = {
    owned = false,
    mode = 'uninitialized',
    acc_scale = 16384.0,
    gyr_scale = 65.536,
    gyro_enabled = true,
    u = {0.0, 0.0, 1.0},
    cal_g = {0.0, 0.0, 1.0},
    right_vec = {1.0, 0.0, 0.0},
    fwd_vec = {0.0, 1.0, 0.0},
    bias = {0.0, 0.0, 0.0},
    prev_a = {0.0, 0.0, 1.0},
    initialized = false,
    need_zero = true,
    ref_yaw = 0.0,
    raw_yaw = 0.0,
    ready = false,
    sensor_ok = false,
    abs_roll = 0.0,
    abs_pitch = 0.0,
    roll = 0.0,
    pitch = 0.0,
    yaw = 0.0,
    turn = 0.0,
    climb = 0.0,
    accel = {0.0, 0.0, 1.0},
    gyro = {0.0, 0.0, 0.0},
  }

  local delay = require('delay')

  local function build_basis(g)
    local axis = (math.abs(g[1]) > 0.95) and {0.0, 1.0, 0.0} or {1.0, 0.0, 0.0}
    local d = dot3(axis, g)
    local r = norm3({axis[1] - d * g[1], axis[2] - d * g[2], axis[3] - d * g[3]})
    if not r then r = {1.0, 0.0, 0.0} end
    local f = norm3(cross3(g, r)) or {0.0, 1.0, 0.0}
    self.cal_g = {g[1], g[2], g[3]}
    self.right_vec = r
    self.fwd_vec = f
  end

  function self:center()
    self.need_zero = true
    self.roll = 0.0
    self.pitch = 0.0
    self.yaw = 0.0
    self.turn = 0.0
    self.climb = 0.0
  end

  function self:close()
    if self.dev then
      if self.owned and self.saved then
        pcall(self.dev.write_byte, self.dev, self.saved[0x7D], 0x7D)
        for _, r in ipairs({0x40, 0x41, 0x42, 0x43, 0x7C}) do
          pcall(self.dev.write_byte, self.dev, self.saved[r], r)
        end
      end
      pcall(self.dev.close, self.dev)
      self.dev = nil
    end
    if self.bus then
      pcall(self.bus.close, self.bus)
      self.bus = nil
    end
  end

  local ok, err = xpcall(function()
    self.bus = require('i2c').new(0, 0, 1, 400000) -- borrow board bus; never delete it
    self.dev = self.bus:device(0x69)
    local d = self.dev
    assert(d:read_byte(0x00) == 0x24, 'BMI270 chip ID mismatch')
    self.saved = {}
    for _, r in ipairs({0x40, 0x41, 0x42, 0x43, 0x7C, 0x7D}) do
      self.saved[r] = d:read_byte(r)
    end
    if self.saved[0x7D] ~= 0 then
      assert((self.saved[0x7D] & 4) ~= 0 and (d:read_byte(0x21) & 0x0F) == 1,
        'Existing IMU state has no initialized accelerometer; left unchanged')
      self.acc_scale = ({[0] = 16384.0, [1] = 8192.0, [2] = 4096.0, [3] = 2048.0})[self.saved[0x41] & 3]
      self.gyr_scale = ({[0] = 16.384, [1] = 32.768, [2] = 65.536, [3] = 131.072, [4] = 262.144})[self.saved[0x43] & 7]
      self.gyro_enabled = (self.saved[0x7D] & 2) ~= 0
      assert(not self.gyro_enabled or self.gyr_scale, 'Unsupported active gyroscope range; left unchanged')
      self.mode = 'borrowed_active'
    else
      self.owned = true
      self.mode = 'configured'
      self.acc_scale = 16384.0
      self.gyr_scale = 65.536
      self.gyro_enabled = true
      d:write_byte(self.saved[0x7C] & 0xFE, 0x7C)
      delay.delay_ms(2)
      if (d:read_byte(0x21) & 0x0F) ~= 1 then
        local blob = require('storage').read_file(root .. '/assets/bmi270-config.bin')
        assert(#blob == 8192, 'Invalid BMI270 configuration length')
        d:write_byte(0x00, 0x59)
        for offset = 0, #blob - 1, 256 do
          local word = offset // 2
          d:write(string.char(word & 0x0F, (word >> 4) & 0xFF), 0x5B)
          d:write(blob:sub(offset + 1, offset + 256), 0x5E)
        end
        d:write_byte(0x01, 0x59)
        delay.delay_ms(160)
        assert((d:read_byte(0x21) & 0x0F) == 1, 'BMI270 initialization failed')
      end
      d:write_byte(0xA8, 0x40); d:write_byte(0x00, 0x41) -- Accel: 100Hz, +/-2g
      d:write_byte(0xA8, 0x42); d:write_byte(0x02, 0x43) -- Gyro:  100Hz, +/-500 deg/s
      d:write_byte(0x0E, 0x7D)
      delay.delay_ms(100)
      assert(d:read_byte(0x02) == 0, 'BMI270 configuration error')
    end
    self.sensor_ok = true
    self:center()
  end, debug.traceback)

  if not ok then
    if not self.owned then self.saved = nil end
    self:close()
    error(err)
  end

  function self:read_raw()
    local r = self.dev:read(12, 0x0C)
    local ax = signed16(r:byte(1), r:byte(2)) / self.acc_scale
    local ay = signed16(r:byte(3), r:byte(4)) / self.acc_scale
    local az = signed16(r:byte(5), r:byte(6)) / self.acc_scale
    local gx = self.gyro_enabled and (signed16(r:byte(7), r:byte(8)) / self.gyr_scale) or 0.0
    local gy = self.gyro_enabled and (signed16(r:byte(9), r:byte(10)) / self.gyr_scale) or 0.0
    local gz = self.gyro_enabled and (signed16(r:byte(11), r:byte(12)) / self.gyr_scale) or 0.0
    return {ax, ay, az}, {gx, gy, gz}
  end

  function self:step(dt)
    local ok_read, a, g = pcall(self.read_raw, self)
    if not ok_read then
      self.sensor_ok = false
      self.ready = false
      return self:snapshot()
    end
    self.sensor_ok = true
    self.accel = a
    self.gyro = g

    local cdt = clamp(dt, 0.001, 0.1)
    local a_norm, mag = norm3(a)
    if not self.initialized then
      self.u = a_norm or {0.0, 0.0, 1.0}
      self.prev_a = {a[1], a[2], a[3]}
      if math.abs(g[1]) < 15.0 and math.abs(g[2]) < 15.0 and math.abs(g[3]) < 15.0 then
        self.bias = {g[1], g[2], g[3]}
      end
      self.initialized = true
      self.need_zero = true
    else
      local da = math.abs(a[1] - self.prev_a[1]) + math.abs(a[2] - self.prev_a[2]) + math.abs(a[3] - self.prev_a[3])
      self.prev_a = {a[1], a[2], a[3]}
      if mag > 0.90 and mag < 1.10 and da < 0.04 and
         math.abs(g[1]) < 4.0 and math.abs(g[2]) < 4.0 and math.abs(g[3]) < 4.0 then
        for i = 1, 3 do
          self.bias[i] = self.bias[i] * 0.96 + g[i] * 0.04
        end
      end

      local wx = (g[1] - self.bias[1]) * RAD
      local wy = (g[2] - self.bias[2]) * RAD
      local wz = (g[3] - self.bias[3]) * RAD
      self.raw_yaw = wrap_deg(self.raw_yaw + (g[3] - self.bias[3]) * cdt)

      local u = self.u
      -- Body rotation moves gravity vector by du = -cross(w, u) * dt
      local ux = u[1] - (wy * u[3] - wz * u[2]) * cdt
      local uy = u[2] - (wz * u[1] - wx * u[3]) * cdt
      local uz = u[3] - (wx * u[2] - wy * u[1]) * cdt

      if a_norm and mag > 0.75 and mag < 1.25 then
        local alpha = 1.0 - math.exp(-cdt * 14.0)
        ux = ux + (a_norm[1] - ux) * alpha
        uy = uy + (a_norm[2] - uy) * alpha
        uz = uz + (a_norm[3] - uz) * alpha
      end
      self.u = norm3({ux, uy, uz}) or a_norm or {0.0, 0.0, 1.0}
    end

    local u = self.u
    if self.need_zero then
      build_basis(u)
      self.ref_yaw = self.raw_yaw
      self.need_zero = false
      self.ready = true
    end

    -- Project gravity delta onto tangent plane around user's neutral pose (zero gimbal lock):
    --   -dx = right tilt (+roll / turn right); +dy = top edge lifted up (+pitch / climb)
    local delta = {u[1] - self.cal_g[1], u[2] - self.cal_g[2], u[3] - self.cal_g[3]}
    local dx = dot3(delta, self.right_vec)
    local dy = dot3(delta, self.fwd_vec)

    self.roll = clamp(math.asin(clamp(-dx, -1.0, 1.0)) * DEG, -85.0, 85.0)
    self.pitch = clamp(math.asin(clamp(dy, -1.0, 1.0)) * DEG, -85.0, 85.0)
    self.abs_roll = math.atan(-u[1], math.sqrt(u[2] * u[2] + u[3] * u[3])) * DEG
    self.abs_pitch = math.atan(u[2], math.sqrt(u[1] * u[1] + u[3] * u[3])) * DEG
    self.yaw = wrap_deg(self.raw_yaw - self.ref_yaw)

    local raw_turn = stick_expo(self.roll, 3.5, 30.0, 0.55)
    local raw_climb = stick_expo(self.pitch, 3.5, 26.0, 0.50)
    local k = 1.0 - math.exp(-cdt * 10.0)
    self.turn = self.turn + (raw_turn - self.turn) * k
    self.climb = self.climb + (raw_climb - self.climb) * k
    if raw_turn == 0.0 and math.abs(self.turn) < 0.005 then self.turn = 0.0 end
    if raw_climb == 0.0 and math.abs(self.climb) < 0.005 then self.climb = 0.0 end

    return self:snapshot()
  end

  function self:snapshot()
    return {
      sensor = self.sensor_ok and 'ok' or 'missing',
      cal = self.ready and 'ready' or 'calibrating',
      valid = self.ready and self.sensor_ok,
      progress = self.ready and 100 or 0,
      roll = self.roll,
      pitch = self.pitch,
      yaw = self.yaw,
      abs_roll = self.abs_roll,
      abs_pitch = self.abs_pitch,
      turn = self.turn,
      climb = self.climb,
      q = {1.0, 0.0, 0.0, 0.0},
      accel = self.accel,
      gyro = self.gyro,
      imu_mode = self.mode,
    }
  end

  return self
end

return M
