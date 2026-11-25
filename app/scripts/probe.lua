-- Bounded, read-only hardware capability inspection for ESP-Mosaico (BMI270 @ 0x69).
local result = {}
local bm_ok, bm = pcall(require, 'board_manager')
if bm_ok and bm and type(bm.get_board_info) == 'function' then
  result.board = bm.get_board_info()
end
local ok_imu, imu = pcall(require, 'imu')
result.native_imu = ok_imu and type(imu) == 'table' and type(imu.new) == 'function'

local bus, dev
local good, err = xpcall(function()
  bus = require('i2c').new(0, 0, 1, 400000)
  dev = bus:device(0x69)
  result.chip_id = dev:read_byte(0x00)
  result.internal_status = dev:read_byte(0x21)
  result.power_control = dev:read_byte(0x7D)
  local raw = dev:read(12, 0x0C)
  local v = {}
  for i = 1, 12, 2 do
    local x = raw:byte(i) + raw:byte(i + 1) * 256
    v[#v + 1] = x >= 32768 and x - 65536 or x
  end
  result.sample = v
end, debug.traceback)
if dev then pcall(dev.close, dev) end
if bus then pcall(bus.close, bus) end
result.ok = good
if not good then result.error = tostring(err) end
return result
