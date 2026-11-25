-- Optional zero-slot transport extension attachable to an existing passive receiver
-- (e.g. minna_nihongo) when all 3 receiver slots are already occupied.
-- Uses pixel_flight's own token, queues and routes (/pixel_flight/*).

local M = {}

function M.attach(app)
  local json = require('json')
  local storage = require('storage')
  local thread = require('thread')
  local capability = require('capability')
  local system = require('system')

  local root = storage.join_path(storage.get_root_dir(), 'apps', 'pixel_flight')
  local cfg = json.decode(assert(storage.read_file(root .. '/config.json')))
  local own = dofile(root .. '/scripts/ownership.lua')

  for _, q in ipairs({
    {'pixel_flight_samples', 2048, 1},
    {'pixel_flight_feedback', 1024, 1},
    {'pixel_flight_cmds', 512, 8},
    {'pixel_flight_lifecycle', 64, 2},
  }) do
    local ok, err = thread.sync.queue_create(q[1], {item_size = q[2], depth = q[3]})
    assert(ok or err == 'exists', err)
  end

  local latest, last_cmd_ack = nil, ''

  local function auth(req)
    local ok, d = pcall(json.decode, req.body)
    if ok and type(d) == 'table' and d.token == cfg.token then return d end
    return nil
  end

  local function push_latest(q, d)
    local raw = json.encode(d)
    if not thread.sync.queue_send(q, raw, 0) then
      thread.sync.queue_recv(q, 0)
      return thread.sync.queue_send(q, raw, 0)
    end
    return true
  end

  local function drain_status()
    while true do
      local raw = thread.sync.queue_recv('pixel_flight_samples', 0)
      if not raw then break end
      local ok, d = pcall(json.decode, raw)
      if ok then
        latest = d
        if type(d.sync) == 'table' and type(d.sync.cmd_ack) == 'string' then
          last_cmd_ack = d.sync.cmd_ack
        end
      end
    end
    local ui = own.own_ui() ~= nil
    return {
      ok = true,
      ui_running = ui,
      receiver_only = not ui,
      uptime_ms = system.millis(),
      sample = ui and latest or nil,
      sample_age_ms = (ui and latest) and (system.millis() - latest.ms) or nil,
      cmd_ack = last_cmd_ack,
      shared_transport = true,
    }
  end

  app:get('/pixel_flight/status', function() return {json = drain_status()} end)

  app:post('/pixel_flight/probe', function(req)
    if not auth(req) then return {status = 403, json = {ok = false}} end
    return {json = dofile(root .. '/scripts/probe.lua')}
  end)

  app:post('/pixel_flight/exchange', function(req)
    local d = auth(req)
    if not d then return {status = 403, json = {ok = false}} end
    local keys = type(d.keys) == 'table' and d.keys or {}
    push_latest('pixel_flight_feedback', {
      ms = system.millis(),
      active = d.active == true,
      turn = tonumber(keys.turn) or 0,
      climb = tonumber(keys.climb) or 0,
      boost = keys.boost == true,
      manual = keys.manual == true,
    })
    local c = d.cmd
    if d.active and type(c) == 'table' and type(c.id) == 'string' and #c.id <= 80 and c.id ~= last_cmd_ack then
      thread.sync.queue_send('pixel_flight_cmds', json.encode(c), 0)
    end
    return {json = drain_status()}
  end)

  app:post('/pixel_flight/start', function(req)
    if not auth(req) then return {status = 403, json = {ok = false}} end
    if own.own_ui() then return {json = {ok = true, already_running = true}} end
    local ok, out = xpcall(function()
      own.release_foreground()
      assert(#own.jobs() < 4, 'No Lua slot available; other jobs preserved')
      for _, q in ipairs({'lifecycle', 'samples', 'feedback', 'cmds'}) do
        while thread.sync.queue_recv('pixel_flight_' .. q, 0) do end
      end
      latest = nil
      last_cmd_ack = ''
      local started, result = thread.start(root .. '/scripts/main.lua', {lifecycle_prepared = true}, {
        name = 'pixel_flight_ui',
        exclusive = 'pixel_flight_ui',
        replace = false,
        timeout_ms = 0,
      })
      assert(started, result)
      return result
    end, debug.traceback)
    return {json = {ok = ok, result = out, recoverable = not ok}}
  end)

  app:post('/pixel_flight/stop', function(req)
    if not auth(req) then return {status = 403, json = {ok = false}} end
    if not own.own_ui() then return {json = {ok = true, already_stopped = true}} end
    return {json = {ok = thread.sync.queue_send('pixel_flight_lifecycle', 'exit', 0) == true}}
  end)

  app:post('/pixel_flight/jobs', function(req)
    if not auth(req) then return {status = 403, json = {ok = false}} end
    return {json = {ok = true, jobs = own.jobs()}}
  end)

  app:post('/pixel_flight/publish', function(req)
    if not auth(req) then return {status = 403, json = {ok = false}} end
    local ok, out, err = capability.call('publish_app', {app_id = 'pixel_flight'}, {max_output_bytes = 2048})
    return {json = {ok = ok, result = out, error = err}}
  end)

  app:post('/pixel_flight/recover', function(req)
    if not auth(req) then return {status = 403, json = {ok = false}} end
    local ok, out = xpcall(function() return dofile(root .. '/scripts/recovery.lua').run(root) end, debug.traceback)
    return {json = ok and out or {ok = false, recoverable = true, error = tostring(out)}}
  end)

  print('[pixel_flight] zero-slot transport attached; no screen ownership')
end

return M
