// ESP-Mosaico Wi-Fi HTTP/SSE bridge client & telemetry state tracker.
// Renderer-independent: feeds authoritative ESP32 flight state and keyboard feedback cleanly.
// Passive on startup when ESP32 UI is idle; automatically resumes link if pixel_flight UI is already running.

export function createMosaicoLink(onUpdate) {
  const clientId = 'web-' + Math.random().toString(36).slice(2, 10)
  let es = null
  let active = false
  let userPaused = false
  let connected = false
  let uiRunning = false
  let latestSample = null
  let latestAt = 0
  let lastSeq = null
  let lastRttMs = null
  let statusText = '未连接 ESP-Mosaico（支持本地键盘/鼠标试玩）'
  let cmdSeq = 0
  let pendingCmd = null
  let feedbackTimer = null
  let lastKeys = { turn: 0, climb: 0, boost: false, fire: false, manual: false }

  function emit() {
    onUpdate?.({
      active,
      connected,
      uiRunning,
      sample: latestSample,
      sampleAt: latestAt,
      rttMs: lastRttMs,
      statusText,
    })
  }

  function applyStreamPayload(payload) {
    if (!payload || typeof payload !== 'object') return
    uiRunning = Boolean(payload.ui_running)
    lastRttMs = typeof payload.rtt_ms === 'number' ? payload.rtt_ms : null

    if (!uiRunning) {
      userPaused = false
      if (active) {
        active = false
        stopFeedbackLoop()
      }
    } else if (!active && !userPaused) {
      // ESP-Mosaico pixel_flight UI is already running in foreground: resume client heartbeat seamlessly
      active = true
      lastSeq = null
      startFeedbackLoop()
      postFeedback()
    }

    const sample = payload.sample
    const seq = sample && typeof sample.seq === 'number' ? sample.seq : null

    if (payload.connected && sample && sample.sync) {
      if (seq !== null && seq !== lastSeq) {
        lastSeq = seq
        latestAt = performance.now()
      } else if (!latestAt) {
        latestAt = performance.now()
      }
      latestSample = sample
      connected = true
      if (pendingCmd && sample.sync.cmd_ack === pendingCmd.ack_hint) {
        pendingCmd = null
      }
      statusText = sample.valid
        ? `ESP-Mosaico 已同步 (${Math.round(lastRttMs ?? 0)} ms)`
        : `正在握持校准 ${sample.progress ?? 0}% — 请保持稳持`
    } else {
      connected = false
      statusText = payload.error || (uiRunning ? '正在重连 ESP-Mosaico 遥测…' : 'ESP-Mosaico 待命中')
    }
    emit()
  }

  function startStream() {
    if (es) return
    es = new EventSource('/api/stream')
    es.onmessage = (ev) => {
      try {
        applyStreamPayload(JSON.parse(ev.data))
      } catch {
        // Ignore malformed SSE chunk
      }
    }
    es.onerror = () => {
      connected = false
      statusText = '本地桥接已断开，正在重连…'
      emit()
    }
  }

  async function postFeedback(cmdOverride = null) {
    if (!active) return
    const cmd = cmdOverride || pendingCmd
    try {
      await fetch('/api/feedback', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          client: clientId,
          active: true,
          keys: lastKeys,
          cmd: cmd ? {
            action: cmd.action,
            ...(cmd.val !== undefined ? { val: cmd.val } : {}),
            ...(cmd.dir !== undefined ? { dir: cmd.dir } : {}),
            ...(cmd.inv_pitch !== undefined ? { inv_pitch: cmd.inv_pitch } : {}),
            ...(cmd.inv_roll !== undefined ? { inv_roll: cmd.inv_roll } : {}),
            ...(cmd.swap_xy !== undefined ? { swap_xy: cmd.swap_xy } : {}),
            ...(cmd.gain !== undefined ? { gain: cmd.gain } : {}),
            client_cmd_id: cmd.client_cmd_id,
          } : null,
        }),
      })
    } catch {
      // Transient network errors handled by SSE status
    }
  }

  function startFeedbackLoop() {
    if (feedbackTimer) return
    feedbackTimer = window.setInterval(() => postFeedback(), 65)
  }

  function stopFeedbackLoop() {
    if (feedbackTimer) {
      window.clearInterval(feedbackTimer)
      feedbackTimer = null
    }
    fetch('/api/feedback', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client: clientId,
        active: false,
        keys: { turn: 0, climb: 0, boost: false, fire: false, manual: false },
      }),
    }).catch(() => {})
  }

  async function control(action) {
    const res = await fetch('/api/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
    })
    return res.json()
  }

  async function connect() {
    userPaused = false
    statusText = '正在激活 ESP-Mosaico 像素飞行…'
    emit()
    startStream()
    const res = await control('start')
    if (!res.ok) {
      statusText = res.error || '激活失败，请检查设备联网或槽位状态'
      emit()
      return res
    }
    active = true
    lastSeq = null
    startFeedbackLoop()
    await postFeedback()
    emit()
    return res
  }

  async function disconnect() {
    userPaused = true
    active = false
    connected = false
    latestSample = null
    stopFeedbackLoop()
    const res = await control('stop').catch(() => ({ ok: false }))
    statusText = '已退出板载端并释放屏幕（可继续本地试玩）'
    emit()
    return res
  }

  async function switchApp(target) {
    userPaused = true
    active = false
    connected = false
    latestSample = null
    stopFeedbackLoop()
    const res = await control(target)
    statusText = res.ok
      ? (target === 'minna' ? '已切回大家的日语' : '已切回 AI 状态牌')
      : (res.error || '切换失败')
    emit()
    return res
  }

  function sendCommand(action, extra = {}) {
    if (!active) return false
    cmdSeq += 1
    pendingCmd = {
      action,
      ...extra,
      client_cmd_id: `${clientId}-${cmdSeq}`,
    }
    postFeedback(pendingCmd)
    window.setTimeout(() => {
      if (pendingCmd?.client_cmd_id === `${clientId}-${cmdSeq}`) pendingCmd = null
    }, 900)
    return true
  }

  function setHostKeys(turn, climb, boost, manual, fire = false) {
    lastKeys = { turn, climb, boost, fire, manual }
  }

  function getFreshSync(nowMs) {
    if (!active || !connected || !latestSample?.sync) return null
    const ageMs = nowMs - latestAt
    if (ageMs > 750) return null
    return {
      sync: latestSample.sync,
      sample: latestSample,
      ageSec: Math.max(0, ageMs / 1000),
    }
  }

  // Passive status stream on page load (never wakes ESP32 foreground automatically)
  startStream()

  return {
    connect,
    disconnect,
    switchApp,
    sendCommand,
    setHostKeys,
    getFreshSync,
    get isActive() { return active },
    get isConnected() { return connected },
  }
}
