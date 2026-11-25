-- ESP-Mosaico Pixel Flight Sync Foreground App (/nand/apps/pixel_flight/scripts/main.lua)
-- Reads BMI270 + GPIO 11 (Throttle Boost) / GPIO 10 (Fire Weapon) + 480x480 touch,
-- steps authoritative flight physics, renders split-screen 480x480 UI, and streams sync frames.

local storage = require('storage')
local json = require('json')
local thread = require('thread')
local system = require('system')
local delay = require('delay')
local display = require('display')
local gpio = require('gpio')

local root = storage.join_path(storage.get_root_dir(), 'apps', 'pixel_flight')
local own = dofile(root .. '/scripts/ownership.lua')
local imu_mod = dofile(root .. '/scripts/imu.lua')
local sim_mod = dofile(root .. '/scripts/flight_sim.lua')
local renderer = dofile(root .. '/scripts/render_flight.lua')

local screen, imu, button_driver, strip
local buttons = {}
local seq = 0

local function push_sample(d)
  local raw = json.encode(d)
  if not thread.sync.queue_send('pixel_flight_samples', raw, 0) then
    thread.sync.queue_recv('pixel_flight_samples', 0)
    thread.sync.queue_send('pixel_flight_samples', raw, 0)
  end
end

local function run()
  own.release_foreground()

  if not (args and args.lifecycle_prepared) then
    for _, q in ipairs({
      {'pixel_flight_lifecycle', 64, 2},
      {'pixel_flight_samples', 2048, 1},
      {'pixel_flight_feedback', 1024, 1},
      {'pixel_flight_cmds', 512, 8},
    }) do
      local ok, err = thread.sync.queue_create(q[1], {item_size = q[2], depth = q[3]})
      assert(ok or err == 'exists', err)
      while thread.sync.queue_recv(q[1], 0) do end
    end
  end

  -- Stability profile: motor GPIO8 LOW; clear LED strip GPIO38 once and release handle
  gpio.set_direction(8, 'output')
  gpio.set_level(8, 0)
  pcall(function()
    local lights = assert(require('led_strip').new(38, 6))
    strip = lights
    lights:clear()
    lights:refresh()
    lights:close()
    strip = nil
  end)

  imu = imu_mod.open(root)
  local sim = sim_mod.new(root .. '/assets/world128.bin')

  button_driver = require('button')
  for _, pin in ipairs({11, 10}) do
    buttons[#buttons + 1] = assert(button_driver.new(pin, 0))
  end

  screen = display.open()
  local began = system.millis()
  local session_id = string.format('%.0f', began)
  local prev_ms = began

  local feedback = {ms = -100000, active = false, turn = 0, climb = 0, boost = false, fire = false, manual = false}
  local armed = false
  local prev_touch_btn = nil

  while true do
    local now = system.millis()
    if thread.sync.queue_recv('pixel_flight_lifecycle', 0) == 'exit' then break end

    local dt = math.min(0.05, math.max(0.005, (now - prev_ms) / 1000.0))
    prev_ms = now

    -- Drain host feedback & discrete commands
    while true do
      local raw = thread.sync.queue_recv('pixel_flight_feedback', 0)
      if not raw then break end
      local ok, d = pcall(json.decode, raw)
      if ok and type(d) == 'table' then feedback = d end
    end
    local linked = (feedback.active == true) and ((now - (feedback.ms or 0)) < 1200)

    while true do
      local raw = thread.sync.queue_recv('pixel_flight_cmds', 0)
      if not raw then break end
      local ok, cmd = pcall(json.decode, raw)
      if ok and type(cmd) == 'table' then
        local need_center = sim:apply_host_cmd(cmd)
        if need_center then imu:center() end
      end
    end

    gpio.set_level(8, 0)

    -- Mechanical buttons:
    --   GPIO11 (Left)  = hold throttle boost (50% mid cruise -> 100% boost)
    --   GPIO10 (Right) = hold/press to fire selected weapon (Gun or Missile)
    local left_down = gpio.get_level(11) == 0
    local right_down = gpio.get_level(10) == 0
    if not left_down and not right_down then armed = true end

    local key_boost = false
    local key_fire = false
    if armed then
      key_boost = left_down
      key_fire = right_down
    end

    -- 480x480 touchscreen controls (View Switch, CAL Zero, Exit, Weapon Select, Fire, Subview Select)
    local touch_pts = screen:touch().points
    local t1 = touch_pts and touch_pts[1] or nil
    local touch_btn = t1 and renderer.hit_test(t1.x, t1.y) or nil
    if touch_btn == 'exit' then break end
    if touch_btn ~= prev_touch_btn and touch_btn ~= nil then
      if touch_btn == 'view' then sim:cycle_view()
      elseif touch_btn == 'cal' then imu:center()
      elseif touch_btn == 'gun' then sim:set_weapon(0)
      elseif touch_btn == 'msl' then sim:set_weapon(1)
      elseif touch_btn == 'sub_level' then sim:set_subview(0)
      elseif touch_btn == 'sub_map' then sim:set_subview(1)
      end
    end
    prev_touch_btn = touch_btn
    local touch_fire = (touch_btn == 'fire')

    -- Step IMU (real-stick expo curves, no stunt roll)
    local imu_snap = imu:step(dt)

    -- Combine IMU + tuning + host inputs
    local gain = sim.gain or 1.0
    local raw_turn = sim.swap_xy and imu_snap.climb or imu_snap.turn
    local raw_climb = sim.swap_xy and imu_snap.turn or imu_snap.climb
    local turn_in = (sim.inv_roll and -raw_turn or raw_turn) * gain
    local climb_in = (sim.inv_pitch and -raw_climb or raw_climb) * gain
    local host_boost = false
    local host_fire = false
    if linked and feedback.manual then
      if math.abs(feedback.turn or 0) > 0.01 then turn_in = feedback.turn end
      if math.abs(feedback.climb or 0) > 0.01 then climb_in = feedback.climb end
      host_boost = feedback.boost == true
    end
    if linked then
      host_fire = feedback.fire == true
    end
    local boost_held = key_boost or host_boost
    local fire_held = key_fire or touch_fire or host_fire

    -- Step authoritative flight physics & weapons
    sim:step(dt, turn_in, climb_in, boost_held, imu_snap.valid, fire_held)

    seq = seq + 1
    push_sample({
      v = 2,
      session = session_id,
      seq = seq,
      ms = now,
      roll = imu_snap.roll,
      pitch = imu_snap.pitch,
      yaw = imu_snap.yaw,
      abs_roll = imu_snap.abs_roll,
      abs_pitch = imu_snap.abs_pitch,
      q = imu_snap.q,
      sensor = imu_snap.sensor,
      cal = imu_snap.cal,
      valid = imu_snap.valid,
      progress = imu_snap.progress,
      imu_mode = imu_snap.imu_mode,
      keys = {
        left = key_boost,
        right = key_fire,
        touch_fire = touch_fire,
      },
      sync = sim:sync_payload(),
    })

    renderer.draw(screen, sim, imu_snap, linked, boost_held)

    if args and args.smoke_ms and (now - began) >= args.smoke_ms then break end
    delay.delay_ms(20)
  end
end

local ok, err = xpcall(run, debug.traceback)
pcall(gpio.set_level, 8, 0)
if strip then pcall(strip.clear, strip); pcall(strip.close, strip) end
for _, h in ipairs(buttons) do pcall(button_driver.close, h) end
if imu then pcall(imu.close, imu) end
if screen then pcall(screen.close, screen) end

if not ok then
  pcall(storage.write_file, root .. '/last-error.txt', tostring(err))
  error(err)
end
print('[pixel_flight] cleanly released all hardware handles')
