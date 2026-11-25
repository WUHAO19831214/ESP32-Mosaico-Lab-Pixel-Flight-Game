import { createScene, DEFAULT_PARAMS } from './lib/scene.js'
import { createFlameLayer } from './lib/flame-layer.js'
import { createMosaicoLink } from './mosaico-link.js'

const canvas = document.getElementById('scene-canvas')
const fireCanvas = document.getElementById('fire-canvas')
const wrap = document.getElementById('viewport')
const ctx = canvas.getContext('2d')

const btnConnect = document.getElementById('btn-connect')
const btnCenter = document.getElementById('btn-center')
const btnView = document.getElementById('btn-view')
const btnDay = document.getElementById('btn-day')
const btnWing = document.getElementById('btn-wing')
const btnWeapon = document.getElementById('btn-weapon')
const btnFire = document.getElementById('btn-fire')
const thrPill = document.getElementById('thr-pill')
const btnMinna = document.getElementById('btn-minna')
const btnBadge = document.getElementById('btn-badge')
const btnHud = document.getElementById('btn-hud')
const statusEl = document.getElementById('status-text')
const dotEl = document.getElementById('status-dot')
const hintEl = document.getElementById('hint-line')

const pipWindow = document.getElementById('pip-window')
const pipTitle = document.getElementById('pip-title')
const pipCanvas = document.getElementById('pip-canvas')
const pipCtx = pipCanvas.getContext('2d')
const hudBody = document.getElementById('telemetry-body')
const tunePanel = document.getElementById('tune-panel')
const btnPipRef = document.getElementById('btn-pip-ref')
const btnPipZero = document.getElementById('btn-pip-zero')
const chkInvPitch = document.getElementById('chk-inv-pitch')
const chkInvRoll = document.getElementById('chk-inv-roll')
const chkSwapXy = document.getElementById('chk-swap-xy')
const rngGain = document.getElementById('rng-gain')
const lblGain = document.getElementById('lbl-gain')
const btnTuneReset = document.getElementById('btn-tune-reset')
const pipTabs = Array.from(document.querySelectorAll('.pip-tab'))

const params = {
  ...DEFAULT_PARAMS,
  altitude: 120,
  ceiling: 650,
  jetScale: 0.6,
  bank: 36,
  stunts: false,
  intro: false,
  flameStyle: 'realistic',
  afterburner: 1,
}

const scene = createScene(params)
let imageData = null
let fireLayer = null
let fireDead = false
let pixelScale = 3
let showHud = true
let pipMode = 'level' // 'level' | 'radar' | 'telemetry' | 'tune'
let levelAbsolute = false
let lastBoardSubview = null

const VIEW_NAMES = ['俯视 Overhead', '尾随 Chase', '驾驶舱 Cockpit']
const DAY_NAMES = ['白昼 Day', '日落 Sunset', '夜间 Night']
const DAY_KEYS = ['day', 'sunset', 'night']
const PIP_TITLES = {
  level: '双轴水平仪',
  radar: '实时海岛地图',
  telemetry: '实时遥测监控',
  tune: '摇杆曲线与轴向',
}

function setPipMode(mode, fromBoard = false) {
  pipMode = mode
  pipTitle.textContent = PIP_TITLES[mode] || '仪表小窗'
  pipCanvas.style.display = (mode === 'level' || mode === 'radar') ? 'block' : 'none'
  hudBody.style.display = mode === 'telemetry' ? 'block' : 'none'
  tunePanel.style.display = mode === 'tune' ? 'flex' : 'none'
  btnPipRef.style.display = mode === 'level' ? 'inline-block' : 'none'
  for (const t of pipTabs) {
    t.classList.toggle('active', t.dataset.mode === mode)
  }
  if (!fromBoard && link?.isActive && (mode === 'level' || mode === 'radar')) {
    link.sendCommand('subview', { val: mode === 'level' ? 0 : 1 })
  }
}

pipTabs.forEach((btn) => {
  btn.onclick = () => setPipMode(btn.dataset.mode)
})

btnPipRef.onclick = () => {
  levelAbsolute = !levelAbsolute
  btnPipRef.textContent = levelAbsolute ? '绝对水平' : '相对归零'
}

btnPipZero.onclick = () => {
  link.sendCommand('center')
}

function pushTuneToDevice() {
  const gain = Number(rngGain.value) || 1.0
  lblGain.textContent = `${gain.toFixed(1)}x`
  link.sendCommand('tune', {
    inv_pitch: chkInvPitch.checked,
    inv_roll: chkInvRoll.checked,
    swap_xy: chkSwapXy.checked,
    gain,
  })
}

chkInvPitch.onchange = pushTuneToDevice
chkInvRoll.onchange = pushTuneToDevice
chkSwapXy.onchange = pushTuneToDevice
rngGain.oninput = pushTuneToDevice
btnTuneReset.onclick = () => {
  chkInvPitch.checked = false
  chkInvRoll.checked = false
  chkSwapXy.checked = false
  rngGain.value = '1.0'
  pushTuneToDevice()
}

function layout() {
  const cw = wrap.clientWidth
  const ch = wrap.clientHeight
  if (!cw || !ch) return
  pixelScale = Math.min(10, Math.max(2, Math.round(Math.sqrt((cw * ch) / 110000))))
  const lw = Math.ceil(cw / pixelScale)
  const lh = Math.ceil(ch / pixelScale)
  if (canvas.width !== lw || canvas.height !== lh) {
    canvas.width = lw
    canvas.height = lh
    scene.resize(lw, lh)
    imageData = null
  }
  const sw = `${lw * pixelScale}px`
  const sh = `${lh * pixelScale}px`
  const sl = `${Math.round((cw - lw * pixelScale) / 2)}px`
  const st = `${Math.round((ch - lh * pixelScale) / 2)}px`
  canvas.style.width = sw
  canvas.style.height = sh
  canvas.style.left = sl
  canvas.style.top = st

  const dpr = Math.min(2, window.devicePixelRatio || 1)
  const fw = Math.round(lw * pixelScale * dpr)
  const fh = Math.round(lh * pixelScale * dpr)
  if (fireCanvas.width !== fw || fireCanvas.height !== fh) {
    fireCanvas.width = fw
    fireCanvas.height = fh
  }
  fireCanvas.style.width = sw
  fireCanvas.style.height = sh
  fireCanvas.style.left = sl
  fireCanvas.style.top = st
}

layout()
new ResizeObserver(layout).observe(wrap)
fireCanvas.addEventListener('webglcontextlost', (e) => {
  e.preventDefault()
  fireLayer = null
  fireDead = true
  scene.setParams({ ...params, flameStyle: 'pixel' })
})

let latestLinkState = { active: false, connected: false, sample: null, rttMs: null, statusText: '' }
const link = createMosaicoLink((state) => {
  latestLinkState = state
  statusEl.textContent = state.statusText
  dotEl.className = state.connected ? 'dot online' : state.active ? 'dot wait' : 'dot'
  btnConnect.textContent = state.active ? '断开并释放 ESP32' : '连接 ESP-Mosaico'
  btnConnect.classList.toggle('active', state.active)
  btnCenter.disabled = !state.active
  const sv = state.sample?.sync?.subview
  if (state.connected && (sv === 0 || sv === 1) && sv !== lastBoardSubview) {
    lastBoardSubview = sv
    if (pipMode === 'level' || pipMode === 'radar') {
      setPipMode(sv === 1 ? 'radar' : 'level', true)
    }
  }
})

setPipMode('level', true)

// Local keyboard & pointer controls (also synced back to ESP-Mosaico when connected)
const held = new Set()
let mouseFire = false
let btnFireHeld = false
const FLY = {
  ArrowLeft: 'left', KeyA: 'left',
  ArrowRight: 'right', KeyD: 'right',
  ArrowUp: 'up', KeyW: 'up',
  ArrowDown: 'down', KeyS: 'down',
  ShiftLeft: 'boost', ShiftRight: 'boost',
  KeyJ: 'fire',
}

function computeKeyAxes() {
  let turn = 0
  let climb = 0
  let boost = false
  let fire = mouseFire || btnFireHeld
  held.forEach((c) => {
    const k = FLY[c]
    if (k === 'left') turn -= 1
    else if (k === 'right') turn += 1
    else if (k === 'up') climb += 1
    else if (k === 'down') climb -= 1
    else if (k === 'boost') boost = true
    else if (k === 'fire') fire = true
  })
  const manual = turn !== 0 || climb !== 0 || boost
  scene.setKeys(turn, climb, boost, 0, manual)
  scene.setFiring(fire)
  link.setHostKeys(turn, climb, boost, manual, fire)
  btnFire.classList.toggle('firing', fire)
}

function cycleView() {
  if (link.isActive) {
    const cur = latestLinkState.sample?.sync?.view ?? scene.getStateSnapshot().view
    const next = (cur + 1) % 3
    link.sendCommand('view', { val: next })
  } else {
    scene.toggleView()
  }
}

function cycleDay() {
  const curIdx = DAY_KEYS.indexOf(params.timeOfDay)
  const nextIdx = (curIdx + 1) % 3
  params.timeOfDay = DAY_KEYS[nextIdx]
  if (link.isActive) {
    link.sendCommand('day', { val: nextIdx })
  } else {
    scene.setParams(params)
  }
}

function cycleWingmen() {
  const next = (Math.round(params.wingmen) + 1) % 3
  params.wingmen = next
  if (link.isActive) {
    link.sendCommand('wingmen', { val: next })
  } else {
    scene.setParams(params)
  }
}

function toggleWeapon() {
  const cur = scene.getStateSnapshot().weapon
  const next = cur === 0 ? 1 : 0
  if (link.isActive) {
    link.sendCommand('weapon', { val: next })
  } else {
    scene.setWeapon(next)
  }
}

window.addEventListener('keydown', (e) => {
  if (e.target && /^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(e.target.tagName)) return
  if (e.code === 'Space') {
    e.preventDefault()
    if (!e.repeat) cycleView()
    return
  }
  if (!e.repeat) {
    if (e.code === 'Digit1') {
      if (link.isActive) link.sendCommand('view', { val: 0 })
      else scene.setParams({ ...params, view: 'top' })
      return
    }
    if (e.code === 'Digit2') {
      if (link.isActive) link.sendCommand('view', { val: 1 })
      else scene.setParams({ ...params, view: 'chase' })
      return
    }
    if (e.code === 'Digit3') {
      if (link.isActive) link.sendCommand('view', { val: 2 })
      else scene.setParams({ ...params, view: 'cockpit' })
      return
    }
    if (e.code === 'KeyL') {
      showHud = true
      pipWindow.classList.remove('hidden')
      setPipMode('level')
      return
    }
    if (e.code === 'KeyM') {
      showHud = true
      pipWindow.classList.remove('hidden')
      setPipMode('radar')
      return
    }
    if (e.code === 'KeyG') { toggleWeapon(); return }
    if (e.code === 'KeyC') { link.sendCommand('center'); return }
    if (e.code === 'KeyT') { cycleDay(); return }
    if (e.code === 'KeyF') { cycleWingmen(); return }
    if (e.code === 'KeyE') {
      params.spread = params.spread > 1 ? 1 : 5
      scene.setParams(params)
      return
    }
    if (e.code === 'KeyR') {
      if (link.isActive) link.sendCommand('reset')
      else scene.replayIntro()
      return
    }
    if (e.code === 'KeyD') {
      showHud = !showHud
      pipWindow.classList.toggle('hidden', !showHud)
      return
    }
  }
  if (FLY[e.code]) {
    if (e.code.startsWith('Arrow')) e.preventDefault()
    held.add(e.code)
    computeKeyAxes()
  }
})

window.addEventListener('keyup', (e) => {
  if (held.delete(e.code)) computeKeyAxes()
})

window.addEventListener('blur', () => {
  held.clear()
  mouseFire = false
  btnFireHeld = false
  computeKeyAxes()
})

const toScene = (e) => {
  const r = canvas.getBoundingClientRect()
  return [(e.clientX - r.left) / pixelScale, (e.clientY - r.top) / pixelScale]
}
wrap.addEventListener('pointermove', (e) => {
  if (link.isConnected) return
  const [x, y] = toScene(e)
  scene.pointerMove(x, y)
})
wrap.addEventListener('pointerdown', (e) => {
  if (e.target.closest('.hud-bar') || e.target.closest('#pip-window')) return
  if (link.isConnected) {
    mouseFire = true
    computeKeyAxes()
    link.sendCommand('fire')
    return
  }
  const [x, y] = toScene(e)
  scene.pointerMove(x, y)
  mouseFire = true
  computeKeyAxes()
  scene.fireOnce()
})
wrap.addEventListener('pointerup', () => {
  if (mouseFire) {
    mouseFire = false
    computeKeyAxes()
  }
  if (!link.isConnected) scene.release()
})
wrap.addEventListener('pointerleave', () => {
  if (mouseFire) {
    mouseFire = false
    computeKeyAxes()
  }
  if (!link.isConnected) scene.pointerLeave()
})

btnFire.onpointerdown = () => {
  btnFireHeld = true
  computeKeyAxes()
  if (link.isActive) link.sendCommand('fire')
  else scene.fireOnce()
}
btnFire.onpointerup = () => { btnFireHeld = false; computeKeyAxes() }
btnFire.onpointerleave = () => { btnFireHeld = false; computeKeyAxes() }

btnConnect.onclick = async () => {
  btnConnect.disabled = true
  try {
    if (link.isActive) await link.disconnect()
    else await link.connect()
  } finally {
    btnConnect.disabled = false
  }
}
btnCenter.onclick = () => link.sendCommand('center')
btnView.onclick = cycleView
btnDay.onclick = cycleDay
btnWing.onclick = cycleWingmen
btnWeapon.onclick = toggleWeapon
btnMinna.onclick = () => link.switchApp('minna')
btnBadge.onclick = () => link.switchApp('badge')
btnHud.onclick = () => {
  showHud = !showHud
  pipWindow.classList.toggle('hidden', !showHud)
}

function drawLevelPip(sample, snap) {
  const W = pipCanvas.width
  const H = pipCanvas.height
  pipCtx.clearRect(0, 0, W, H)

  const pitchDeg = sample
    ? (levelAbsolute ? (sample.abs_pitch ?? sample.pitch ?? 0) : (sample.pitch ?? 0))
    : (snap.pitch * 180) / Math.PI
  const rollDeg = sample
    ? (levelAbsolute ? (sample.abs_roll ?? sample.roll ?? 0) : (sample.roll ?? 0))
    : (snap.roll * 180) / Math.PI

  const cx = 104
  const cy = 105
  const R = 82

  pipCtx.save()
  pipCtx.beginPath()
  pipCtx.arc(cx, cy, R, 0, Math.PI * 2)
  pipCtx.clip()

  pipCtx.translate(cx, cy)
  pipCtx.rotate((-rollDeg * Math.PI) / 180)
  const py = Math.max(-R, Math.min(R, pitchDeg * 2.2))
  pipCtx.fillStyle = '#1e5b9e'
  pipCtx.fillRect(-R * 2, -R * 2, R * 4, R * 2 + py)
  pipCtx.fillStyle = '#734820'
  pipCtx.fillRect(-R * 2, py, R * 4, R * 2)
  pipCtx.strokeStyle = '#e2e8f0'
  pipCtx.lineWidth = 2
  pipCtx.beginPath()
  pipCtx.moveTo(-R, py)
  pipCtx.lineTo(R, py)
  pipCtx.stroke()

  pipCtx.strokeStyle = 'rgba(255,255,255,0.55)'
  pipCtx.lineWidth = 1.2
  for (const deg of [-20, -10, 10, 20]) {
    const ry = py - deg * 2.2
    const hw = Math.abs(deg) === 20 ? 18 : 11
    pipCtx.beginPath()
    pipCtx.moveTo(-hw, ry)
    pipCtx.lineTo(hw, ry)
    pipCtx.stroke()
  }
  pipCtx.restore()

  pipCtx.strokeStyle = '#5a8aa8'
  pipCtx.lineWidth = 2
  pipCtx.beginPath()
  pipCtx.arc(cx, cy, R, 0, Math.PI * 2)
  pipCtx.stroke()

  pipCtx.strokeStyle = 'rgba(92, 230, 192, 0.35)'
  pipCtx.lineWidth = 1
  pipCtx.beginPath()
  pipCtx.moveTo(cx - R, cy); pipCtx.lineTo(cx + R, cy)
  pipCtx.moveTo(cx, cy - R); pipCtx.lineTo(cx, cy + R)
  pipCtx.stroke()

  pipCtx.strokeStyle = 'rgba(92, 230, 192, 0.85)'
  pipCtx.beginPath()
  pipCtx.arc(cx, cy, 14, 0, Math.PI * 2)
  pipCtx.stroke()

  const bx = cx + Math.max(-R + 14, Math.min(R - 14, rollDeg * 2.1))
  const by = cy - Math.max(-R + 14, Math.min(R - 14, pitchDeg * 2.1))
  const levelOk = Math.abs(rollDeg) <= 3.5 && Math.abs(pitchDeg) <= 3.5
  pipCtx.fillStyle = levelOk ? '#34d399' : '#5ce6c0'
  pipCtx.beginPath()
  pipCtx.arc(bx, by, 10, 0, Math.PI * 2)
  pipCtx.fill()
  pipCtx.fillStyle = '#ffffff'
  pipCtx.beginPath()
  pipCtx.arc(bx - 3, by - 3, 3, 0, Math.PI * 2)
  pipCtx.fill()

  const rx = 200
  pipCtx.fillStyle = '#94a3b8'
  pipCtx.font = '11px ui-monospace, monospace'
  pipCtx.fillText(sample ? (levelAbsolute ? '物理绝对水平' : '握持相对姿态') : '桌面模拟姿态', rx, 24)

  pipCtx.fillStyle = '#5ce6c0'
  pipCtx.font = 'bold 15px ui-monospace, monospace'
  pipCtx.fillText(`P ${pitchDeg >= 0 ? '+' : ''}${pitchDeg.toFixed(1)}°`, rx, 50)
  pipCtx.fillStyle = '#cbd5e1'
  pipCtx.font = '11px ui-monospace, monospace'
  pipCtx.fillText(Math.abs(pitchDeg) < 3.5 ? '• 平飞保持' : pitchDeg > 0 ? '↑ 抬头拉起' : '↓ 低头俯冲', rx, 67)

  pipCtx.fillStyle = '#fb923c'
  pipCtx.font = 'bold 15px ui-monospace, monospace'
  pipCtx.fillText(`R ${rollDeg >= 0 ? '+' : ''}${rollDeg.toFixed(1)}°`, rx, 94)
  pipCtx.fillStyle = '#cbd5e1'
  pipCtx.font = '11px ui-monospace, monospace'
  pipCtx.fillText(Math.abs(rollDeg) < 3.5 ? '• 翼面平直' : rollDeg > 0 ? '→ 右倾转弯' : '← 左倾转弯', rx, 111)

  const thrPct = Math.round((snap.throttle ?? (0.5 + 0.5 * snap.boost)) * 100)
  const boosting = snap.boost > 0.25
  pipCtx.fillStyle = boosting ? '#fb923c' : '#34d399'
  pipCtx.font = '11px ui-monospace, monospace'
  pipCtx.fillText(`油门 ${boosting ? '加力' : '中档'} ${thrPct}%`, rx, 140)
  pipCtx.fillStyle = '#1e293b'
  pipCtx.fillRect(rx, 147, 116, 8)
  pipCtx.fillStyle = boosting ? '#f0580e' : '#34d399'
  pipCtx.fillRect(rx, 147, Math.round((116 * thrPct) / 100), 8)

  pipCtx.fillStyle = snap.weapon === 0 ? '#5ce6c0' : '#fb923c'
  pipCtx.fillText(`武器: ${snap.weapon === 0 ? '机枪 GUN' : '导弹 MSL'}`, rx, 178)
  pipCtx.fillStyle = '#94a3b8'
  pipCtx.fillText(`ALT ${(snap.z * 12).toFixed(0)}ft  ${(snap.speed * 4.2).toFixed(0)}kt`, rx, 198)
}

const MAP_PAL = [
  '#2468b4', '#2c7cc6', '#42a0d8', '#68ccd6',
  '#eedca4', '#dec88c', '#60b234', '#46942c', '#86ce4c',
  '#469e40', '#2a7a36', '#1c5c2e', '#928c86', '#76706e', '#b2aca2', '#f6faff', '#d6e2f4',
]

function drawMapPip(snap) {
  const W = pipCanvas.width
  const H = pipCanvas.height
  pipCtx.fillStyle = '#091728'
  pipCtx.fillRect(0, 0, W, H)

  // Real-time scrolling island map (left 186x186)
  const mx = 10
  const my = 12
  const cw = 6
  const cols = 31
  const rows = 31
  const stride = 20
  const half = 15

  for (let gy = 0; gy < rows; gy++) {
    for (let gx = 0; gx < cols; gx++) {
      const wx = snap.x + (gx - half) * stride
      const wy = snap.y + (gy - half) * stride
      const { mat } = scene.sampleMap(wx, wy)
      pipCtx.fillStyle = MAP_PAL[mat] || MAP_PAL[0]
      pipCtx.fillRect(mx + gx * cw, my + gy * cw, cw, cw)
    }
  }
  pipCtx.strokeStyle = 'rgba(92, 230, 192, 0.5)'
  pipCtx.strokeRect(mx, my, cols * cw, rows * cw)

  const cx = mx + half * cw + cw / 2
  const cy = my + half * cw + cw / 2

  // Live projectiles on map
  for (const pr of snap.ords || []) {
    let dx = pr.x - snap.x
    let dy = pr.y - snap.y
    if (dx > 1024) dx -= 2048
    if (dx < -1024) dx += 2048
    if (dy > 1024) dy -= 2048
    if (dy < -1024) dy += 2048
    const px = cx + (dx * cw) / stride
    const py = cy + (dy * cw) / stride
    if (px >= mx + 2 && px <= mx + cols * cw - 2 && py >= my + 2 && py <= my + rows * cw - 2) {
      pipCtx.fillStyle = pr.kind === 2 ? '#f97316' : pr.kind === 1 ? '#ef4444' : '#fef9c3'
      pipCtx.beginPath()
      pipCtx.arc(px, py, pr.kind === 2 ? 4 : pr.kind === 1 ? 2.5 : 1.5, 0, Math.PI * 2)
      pipCtx.fill()
    }
  }

  // Heading arrow
  const vx = Math.sin(snap.yaw) * 18
  const vy = -Math.cos(snap.yaw) * 18
  pipCtx.strokeStyle = '#ffffff'
  pipCtx.lineWidth = 2
  pipCtx.beginPath()
  pipCtx.moveTo(cx, cy)
  pipCtx.lineTo(cx + vx, cy + vy)
  pipCtx.stroke()
  pipCtx.fillStyle = '#fb923c'
  pipCtx.beginPath()
  pipCtx.arc(cx, cy, 4, 0, Math.PI * 2)
  pipCtx.fill()

  const rx = 206
  pipCtx.fillStyle = '#5ce6c0'
  pipCtx.font = 'bold 12px ui-monospace, monospace'
  pipCtx.fillText('实时海岛地图', rx, 28)
  pipCtx.fillStyle = '#cbd5e1'
  pipCtx.font = '12px ui-monospace, monospace'
  pipCtx.fillText(`X: ${snap.x.toFixed(0)}`, rx, 56)
  pipCtx.fillText(`Y: ${snap.y.toFixed(0)}`, rx, 76)
  pipCtx.fillText(`ALT: ${(snap.z * 12).toFixed(0)} ft`, rx, 102)
  pipCtx.fillText(`SPD: ${(snap.speed * 4.2).toFixed(0)} kt`, rx, 122)
  pipCtx.fillText(`HDG: ${(((snap.yaw * 180) / Math.PI) % 360 + 360) % 360 | 0}°`, rx, 142)
  const thrPct = Math.round((snap.throttle ?? (0.5 + 0.5 * snap.boost)) * 100)
  pipCtx.fillStyle = snap.boost > 0.25 ? '#fb923c' : '#34d399'
  pipCtx.fillText(`THR: ${thrPct}%`, rx, 168)
  pipCtx.fillStyle = snap.weapon === 0 ? '#5ce6c0' : '#fb923c'
  pipCtx.fillText(`WPN: ${snap.weapon === 0 ? '机枪' : '导弹'}`, rx, 190)
}

let lastNow = performance.now()
let lastHudAt = 0

function loop(now) {
  requestAnimationFrame(loop)
  const dt = Math.min(0.05, Math.max(0.001, (now - lastNow) / 1000))
  lastNow = now

  if (!scene.width) return

  const auth = link.getFreshSync(now)
  if (auth) {
    scene.step(dt, true)
    scene.applyAuthoritativeSync(auth.sync, auth.ageSec, dt)
    params.timeOfDay = DAY_KEYS[auth.sync.day | 0] || params.timeOfDay
    params.wingmen = auth.sync.wingmen ?? params.wingmen
  } else {
    scene.step(dt, false)
  }

  const bytes = scene.render()
  if (!imageData) imageData = new ImageData(bytes, scene.width, scene.height)
  ctx.putImageData(imageData, 0, 0)

  const flames = scene.flames
  if (flames.count > 0 && !fireLayer && !fireDead) {
    fireLayer = createFlameLayer(fireCanvas)
    if (!fireLayer) {
      fireDead = true
      scene.setParams({ ...params, flameStyle: 'pixel' })
    }
  }
  if (fireLayer) {
    fireLayer.draw(flames.count, flames.data, fireCanvas.width / scene.width, now / 1000)
  }

  if (now - lastHudAt > 50) {
    lastHudAt = now
    const snap = scene.getStateSnapshot()
    btnView.textContent = `视角: ${VIEW_NAMES[snap.view] || '尾随'}`
    btnDay.textContent = DAY_NAMES[DAY_KEYS.indexOf(snap.timeOfDay)] || '白昼'
    btnWing.textContent = `僚机: +${snap.wingmen}`
    btnWeapon.textContent = snap.weapon === 0 ? '武器: 机枪 (G)' : '武器: 导弹 (G)'
    const thrPct = Math.round((snap.throttle ?? (0.5 + 0.5 * snap.boost)) * 100)
    const boosting = snap.boost > 0.25
    thrPill.textContent = `油门: ${boosting ? '加力' : '中档'} ${thrPct}%`
    thrPill.classList.toggle('boost', boosting)

    hintEl.textContent = link.isConnected
      ? 'ESP-Mosaico 双端同步 · 摇杆式倾斜控制(上抬拉起/下压俯冲/左右压坡转弯) · 左键按住加力 · 右键发射武器 · 屏幕触控切视角/武器/地图'
      : '鼠标/WASD 试玩 · Shift 加力 · Space 切视角 · G 切武器 · J/点击发射 · L 水平仪 / M 实时地图'

    if (showHud) {
      const s = latestLinkState.sample
      if (pipMode === 'level') {
        drawLevelPip(s, snap)
      } else if (pipMode === 'radar') {
        drawMapPip(snap)
      } else if (pipMode === 'telemetry') {
        const syncLines = s ? [
          `SEQ #${s.seq} | RTT ${Math.round(latestLinkState.rttMs ?? 0)}ms | ${s.imu_mode || '-'}`,
          `REL   P ${s.pitch.toFixed(1)}°  R ${s.roll.toFixed(1)}°  Y ${s.yaw.toFixed(1)}°`,
          `ABS   P ${(s.abs_pitch ?? 0).toFixed(1)}°  R ${(s.abs_roll ?? 0).toFixed(1)}°`,
          `POS   X ${snap.x.toFixed(1)}  Y ${snap.y.toFixed(1)}  ALT ${(snap.z * 12).toFixed(0)}ft`,
          `THR   ${thrPct}% | SPD ${(snap.speed * 4.2).toFixed(0)}kt | WPN ${snap.weapon === 0 ? 'GUN' : 'MSL'}`,
          `SHOTS GUN:${s.sync?.gun_seq ?? 0}  MSL:${s.sync?.msl_seq ?? 0}`,
          `KEYS  THR:${s.keys?.left ? 'BOOST' : 'mid'}  FIRE:${s.keys?.right ? 'ON' : 'off'}`,
        ] : [
          'MODE  LOCAL SIMULATION (DESKTOP)',
          `POS   X ${snap.x.toFixed(1)}  Y ${snap.y.toFixed(1)}  ALT ${(snap.z * 12).toFixed(0)}ft`,
          `THR   ${thrPct}% | SPD ${(snap.speed * 4.2).toFixed(0)}kt | WPN ${snap.weapon === 0 ? 'GUN' : 'MSL'}`,
          `ATT   P ${(snap.pitch * 180 / Math.PI).toFixed(1)}°  R ${(snap.roll * 180 / Math.PI).toFixed(1)}°`,
        ]
        hudBody.textContent = syncLines.join('\n')
      }
    }
  }
}

requestAnimationFrame(loop)
