import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createScene, DEFAULT_PARAMS } from '../web/lib/scene.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..')
const OUT_DIR = path.join(ROOT, '.runtime')
fs.mkdirSync(OUT_DIR, { recursive: true })

const W = 440
const H = 270

function renderVariant(name, opts) {
  const scene = createScene({
    ...DEFAULT_PARAMS,
    altitude: 120,
    ceiling: 650,
    jetScale: 0.62,
    bank: 36,
    stunts: false,
    intro: false,
    flameStyle: 'pixel',
    afterburner: 1,
    timeOfDay: opts.timeOfDay,
    view: opts.view,
    wingmen: opts.wingmen,
  })
  scene.resize(W, H)
  scene.setKeys(opts.turn, opts.climb, opts.boost, 0, true)

  for (let i = 0; i < opts.warmSteps; i++) {
    scene.step(0.02, false)
  }
  scene.setWeapon(1)
  scene.fireOnce()
  for (let i = 0; i < 8; i++) {
    scene.step(0.02, false)
  }
  scene.setWeapon(0)
  scene.fireOnce()
  for (let i = 0; i < 4; i++) {
    scene.step(0.02, false)
  }

  const rgba = Buffer.from(scene.render())
  const outPath = path.join(OUT_DIR, `frame_${name}.rgba`)
  fs.writeFileSync(outPath, rgba)
  console.log(`Rendered ${name}: ${W}x${H} -> ${outPath}`)
}

renderVariant('overhead', { timeOfDay: 'day', view: 'top', wingmen: 2, turn: 0.45, climb: 0.1, boost: true, warmSteps: 65 })
renderVariant('chase', { timeOfDay: 'sunset', view: 'chase', wingmen: 2, turn: -0.45, climb: 0.25, boost: true, warmSteps: 45 })
renderVariant('cockpit', { timeOfDay: 'sunset', view: 'cockpit', wingmen: 1, turn: 0.32, climb: 0.15, boost: true, warmSteps: 55 })
