#!/usr/bin/env node
/**
 * Generate world128.bin for ESP-Mosaico using the EXACT same procedural
 * terrain parameters as web/lib/scene.js (seed=7, land=0.33, N=2048).
 *
 * Binary layout (little-endian, 32,772 bytes total):
 *   - uint16 spawnX (0..2047)
 *   - uint16 spawnY (0..2047)
 *   - 128 x 128 cells (row-major y=0..127, x=0..127), 2 bytes/cell:
 *       byte 0: height (0..40)
 *       byte 1: mat    (0..16)
 * Each cell corresponds to world coordinate (x * 16, y * 16).
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const OUT_PATH = path.resolve(__dirname, '../app/assets/world128.bin')

const N = 2048
const NM = N - 1
const NSHIFT = 11
const SEED = 7
const LAND = 0.33
const GRID = 128
const STEP_PX = N / GRID // 16

function mulberry32(seed) {
  let a = seed | 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function hash8(o) {
  let h = Math.imul(o ^ (o >>> 13), 0x5bd1e995)
  h ^= h >>> 15
  h = Math.imul(h, 0x2c1b3c6d)
  return (h >>> 24) & 255
}

function addOctave(field, n, cell, amp, rnd) {
  const P = n / cell
  const lat = new Float32Array(P * P)
  for (let i = 0; i < lat.length; i++) lat[i] = rnd()
  const x0 = new Int32Array(n)
  const x1 = new Int32Array(n)
  const tx = new Float32Array(n)
  for (let x = 0; x < n; x++) {
    const g = x / cell
    const i = Math.floor(g)
    const f = g - i
    x0[x] = i % P
    x1[x] = (i + 1) % P
    tx[x] = f * f * (3 - 2 * f)
  }
  for (let y = 0; y < n; y++) {
    const ra = x0[y] * P
    const rb = x1[y] * P
    const ty = tx[y]
    const row = y * n
    for (let x = 0; x < n; x++) {
      const a0 = lat[ra + x0[x]]
      const b0 = lat[rb + x0[x]]
      const va = a0 + (lat[ra + x1[x]] - a0) * tx[x]
      const vb = b0 + (lat[rb + x1[x]] - b0) * tx[x]
      field[row + x] += amp * (va + (vb - va) * ty)
    }
  }
}

function normalise(field) {
  let mn = Infinity
  let mx = -Infinity
  for (let i = 0; i < field.length; i++) {
    const v = field[i]
    if (v < mn) mn = v
    if (v > mx) mx = v
  }
  const k = 1 / (mx - mn || 1)
  for (let i = 0; i < field.length; i++) field[i] = (field[i] - mn) * k
}

const rnd = mulberry32((SEED | 0) * 7919 + 13)
const nz = new Uint8Array(256 * 256)
for (let i = 0; i < nz.length; i++) nz[i] = (rnd() * 256) | 0

const E = new Float32Array(N * N)
addOctave(E, N, 512, 0.55, rnd)
addOctave(E, N, 256, 1, rnd)
addOctave(E, N, 128, 0.5, rnd)
addOctave(E, N, 64, 0.25, rnd)
addOctave(E, N, 32, 0.11, rnd)
addOctave(E, N, 16, 0.05, rnd)
normalise(E)

const bins = new Uint32Array(1024)
for (let o = 0; o < E.length; o++) bins[(E[o] * 1023) | 0]++
let acc = 0
let sea = 1
const target = (1 - LAND) * E.length
for (let b = 0; b < 1024; b++) {
  acc += bins[b]
  if (acc >= target) { sea = (b + 1) / 1023; break }
}

const SAND = 0.012
const span = Math.max(0.05, 1 - sea - SAND)
const heightMap = new Uint8Array(N * N)
const matMap = new Uint8Array(N * N)

for (let y = 0; y < N; y++) {
  const row = y << NSHIFT
  const rowNW = ((y - 2) & NM) << NSHIFT
  const rowSE = ((y + 2) & NM) << NSHIFT
  for (let x = 0; x < N; x++) {
    const o = row | x
    const e = E[o]
    const hs = hash8(o)
    const d = e - sea
    if (d < 0) {
      const dd = -d + (hs - 128) * 0.00004
      matMap[o] = dd > 0.07 ? 0 : dd > 0.03 ? 1 : dd > 0.008 ? 2 : 3
      heightMap[o] = 0
      continue
    }
    if (d < SAND) {
      matMap[o] = hs < 34 ? 5 : 4
      heightMap[o] = 0
      continue
    }
    const hr = (d - SAND) / span
    let lv = hr < 0.5 ? 1 + ((hr * 16) | 0) : hr < 0.78 ? 9 + (((hr - 0.5) / 0.07) | 0) : 13 + (((hr - 0.78) / 0.09) | 0)
    if (lv > 15) lv = 15
    heightMap[o] = lv <= 8 ? lv * 2 : 16 + (lv - 8) * 3
    const g = E[rowNW | ((x - 2) & NM)] - E[rowSE | ((x + 2) & NM)]
    const lit = g < -0.007
    const shaded = g > 0.007
    if (lv >= 13) matMap[o] = shaded ? 16 : 15
    else if (lv >= 9) matMap[o] = lit ? 14 : shaded ? 13 : hs < 26 ? 13 : 12
    else matMap[o] = lit ? 8 : shaded ? 7 : hs < 22 ? 7 : hs > 240 ? 8 : 6
  }
}

// Forests (identical to scene.js)
const STEP = 5
for (let gy = 0; gy < N; gy += STEP) {
  for (let gx = 0; gx < N; gx += STEP) {
    const hs = hash8(gy * 977 + gx * 131 + 7)
    const cx = (gx + (hs & 3)) & NM
    const cy = (gy + ((hs >> 2) & 3)) & NM
    const o = (cy << NSHIFT) | cx
    const m = matMap[o]
    if (m < 6 || m > 8) continue
    const h0 = heightMap[o]
    if (h0 > 14) continue
    const f = E[(((cy + 613) & NM) << NSHIFT) | ((N - 1 - cx + 911) & NM)]
    const pr = (f - sea) * 30
    if (pr <= 0 || pr * 255 < hash8(o + 99)) continue
    const r = 2 + ((hs >> 4) & 1)
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        const dist = Math.sqrt(dx * dx + dy * dy)
        if (dist > r + 0.3) continue
        const oo = (((cy + dy) & NM) << NSHIFT) | ((cx + dx) & NM)
        if (matMap[oo] < 4) continue
        const nh = h0 + 1 + Math.round((1 - dist / (r + 0.5)) * (r + 1))
        if (nh > heightMap[oo]) {
          heightMap[oo] = nh
          matMap[oo] = dist < 1.1 ? 9 : dist < r - 0.5 ? 10 : 11
        }
      }
    }
  }
}

let spawnX = N / 2
let spawnY = N / 2
let best = -1
for (let tries = 0; tries < 400; tries++) {
  const x = (rnd() * N) | 0
  const y = (rnd() * N) | 0
  const here = matMap[(y << NSHIFT) | x]
  if (here > 2) continue
  let landNear = 0
  for (let a = 0; a < 8; a++) {
    const xx = (x + Math.cos(a * 0.785) * 120) & NM
    const yy = (y + Math.sin(a * 0.785) * 120) & NM
    if (matMap[(yy << NSHIFT) | xx] >= 4) landNear++
  }
  if (landNear > best && landNear <= 5) { best = landNear; spawnX = x; spawnY = y }
}

const out = Buffer.alloc(4 + GRID * GRID * 2)
out.writeUInt16LE(spawnX, 0)
out.writeUInt16LE(spawnY, 2)
let ptr = 4
for (let gy = 0; gy < GRID; gy++) {
  for (let gx = 0; gx < GRID; gx++) {
    // Pick max-height sample within the 16x16 block so coastal/mountain collision stays accurate
    let bestH = 0
    let bestMat = matMap[((gy * STEP_PX + 8) << NSHIFT) | (gx * STEP_PX + 8)]
    for (let dy = 0; dy < STEP_PX; dy += 4) {
      for (let dx = 0; dx < STEP_PX; dx += 4) {
        const idx = (((gy * STEP_PX + dy) & NM) << NSHIFT) | ((gx * STEP_PX + dx) & NM)
        if (heightMap[idx] >= bestH) {
          bestH = heightMap[idx]
          if (bestH > 0 || bestMat < 4) bestMat = matMap[idx]
        }
      }
    }
    out[ptr++] = bestH
    out[ptr++] = bestMat
  }
}

fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true })
fs.writeFileSync(OUT_PATH, out)
console.log(`Generated ${OUT_PATH} (${out.length} bytes), spawn=(${spawnX}, ${spawnY})`)
