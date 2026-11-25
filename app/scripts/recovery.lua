-- Passive recovery helper for pixel_flight: publishes Works entry and restores missing receivers if slot available.
-- Never starts foreground UI and never stops any other task.

local M = {}

function M.run(root)
  local thread = require('thread')
  local capability = require('capability')
  local own = dofile(root .. '/scripts/ownership.lua')

  local ok_pub, pub_out, pub_err = capability.call('publish_app', {app_id = 'pixel_flight'}, {max_output_bytes = 2048})
  local jobs = own.jobs()
  local has_self_rec = false
  for _, j in ipairs(jobs) do
    if j.path == '/nand/apps/pixel_flight/scripts/receiver.lua' then
      has_self_rec = true
    end
  end

  return {
    ok = ok_pub == true,
    published = ok_pub == true,
    publish_result = pub_out,
    publish_error = pub_err,
    receiver_running = has_self_rec,
    slots_used = #jobs,
  }
end

return M
