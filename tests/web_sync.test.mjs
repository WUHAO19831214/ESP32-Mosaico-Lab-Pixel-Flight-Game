import test from 'node:test'
import assert from 'node:assert/strict'
import { createScene, DEFAULT_PARAMS } from '../web/lib/scene.js'

test('scene.js authoritative sync converges without drift and spawns weapon ordnance', () => {
  const scene = createScene({ ...DEFAULT_PARAMS, intro: false, flameStyle: 'pixel' })
  scene.resize(320, 200)

  const syncFrame = {
    x: 1200.5,
    y: 450.25,
    z: 145.0,
    vx: 60.0,
    vy: -80.0,
    fyaw: 1.15,
    froll: -0.32,
    fpitch: 0.12,
    yaw_rate: -0.4,
    boost: 0.85,
    throttle: 0.92,
    speed: 148.0,
    stunt: -1.0,
    stunt_dir: 1,
    view: 2,
    subview: 1,
    weapon: 1,
    firing: true,
    gun_seq: 0,
    msl_seq: 1,
    day: 1,
    wingmen: 2,
  }

  scene.applyAuthoritativeSync(syncFrame, 0.01, 0.016)
  // Next frame increments msl_seq & gun_seq so desktop spawns matching missile & tracer ordnance
  for (let i = 0; i < 20; i++) {
    scene.step(0.016, true)
    scene.applyAuthoritativeSync({ ...syncFrame, gun_seq: 2, msl_seq: 2 }, 0.01, 0.016)
  }

  const snap = scene.getStateSnapshot()
  assert.equal(snap.view, 2)
  assert.equal(scene.view, 'cockpit')
  assert.equal(snap.timeOfDay, 'sunset')
  assert.equal(snap.wingmen, 2)
  assert.equal(snap.weapon, 1)
  assert.ok(snap.ords.length >= 2, 'Expected spawned missile and tracer ordnance')
  assert.ok(Math.abs(snap.x - (1200.5 + 0.6)) < 1.5, `x drift too large: ${snap.x}`)
  assert.ok(Math.abs(snap.y - (450.25 - 0.8)) < 1.5, `y drift too large: ${snap.y}`)
  assert.ok(Math.abs(snap.z - 145.0) < 1.0, `z drift too large: ${snap.z}`)
  assert.ok(Math.abs(snap.boost - 0.85) < 0.05)

  // Ensure sampleMap returns valid height & material for Live Island Map PIP
  const cell = scene.sampleMap(snap.x, snap.y)
  assert.equal(typeof cell.h, 'number')
  assert.equal(typeof cell.mat, 'number')

  // Ensure rendering with active ordnance produces valid non-empty RGBA bytes
  const bytes = scene.render()
  assert.equal(bytes.length, 320 * 200 * 4)
  assert.ok(bytes.some((v) => v !== 0))
})
