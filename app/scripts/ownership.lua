-- Coexistence foreground ownership helper for pixel_flight on ESP-Mosaico.
-- Matches ONLY verified full device script paths; preserves all passive receivers and Air indicator_worker.

local M = {}

local ALLOWED_FOREGROUND = {
  ['/nand/apps/ai_mac_mini/scripts/main.lua'] = true,
  ['/nand/apps/minna_nihongo/scripts/main.lua'] = true,
  ['/nand/apps/ai_badge/scripts/main.lua'] = true,
  ['/nand/apps/ufo_remote/scripts/main.lua'] = true,
  ['/nand/apps/apple_music_mac_mini/scripts/main.lua'] = true,
  ['/nand/apps/pomodoro_clock/scripts/main.lua'] = true,
}

local OWN_MAIN = '/nand/apps/pixel_flight/scripts/main.lua'

function M.jobs()
  local ok, listing = require('thread').list('running')
  assert(ok, 'Cannot read running jobs')
  local result = {}
  for line in (listing or ''):gmatch('[^\n]+') do
    local id = line:match('^(.-) | ')
    local path = line:match(' | path=(.+)$')
    if id and path then
      result[#result + 1] = {id = id, path = path}
    end
  end
  return result
end

function M.own_ui()
  for _, job in ipairs(M.jobs()) do
    if job.path == OWN_MAIN then return job.id end
  end
  return nil
end

function M.release_foreground()
  local thread = require('thread')
  for _, job in ipairs(M.jobs()) do
    assert(job.path ~= '/nand/apps/ai_badge/scripts/indicator_worker.lua',
      'Air indicators are active; switch through AI Mac mini first')
  end
  for _, job in ipairs(M.jobs()) do
    if ALLOWED_FOREGROUND[job.path] then
      local ok, info = thread.get(job.id)
      assert(ok and (info .. '\n'):find('path=' .. job.path .. '\n', 1, true),
        'Foreground job changed during handoff')
      local stopped, out = thread.stop(job.id, 2000)
      assert(stopped, out)
    end
  end
  for _, job in ipairs(M.jobs()) do
    assert(not ALLOWED_FOREGROUND[job.path], 'Previous foreground UI did not exit')
  end
end

return M
