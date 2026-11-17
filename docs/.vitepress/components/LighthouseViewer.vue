<script setup>
// Lighthouse export viewer: loads the JSON from Lighthouse.export() (file, drop or paste) and shows
// the frame timeline (canvas, zoom and pan), flares, probes, network, memory and telemetry.
// Plain canvas, no chart library. Everything runs in the browser; nothing is uploaded.
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, shallowRef, watch } from 'vue'
import { withBase } from 'vitepress'

const doc = shallowRef(null)
const error = ref('')
const fileName = ref('')
const pasteText = ref('')
const dragging = ref(false)
const side = ref('client')

// ---------- loading ----------

function load(text, name) {
  error.value = ''
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    error.value = 'That is not valid JSON: ' + e.message
    return
  }
  if (!parsed || typeof parsed !== 'object' || parsed.lighthouse !== 1) {
    error.value = 'This JSON is not a Lighthouse export (it has no "lighthouse": 1 field).'
    return
  }
  doc.value = parsed
  fileName.value = name
  side.value = parsed.client ? 'client' : 'server'
  if (parsed.side && parsed[parsed.side]) side.value = parsed.side
  view.value = null
  selected.value = -1
  nextTick(draw)
}

function onFile(ev) {
  const file = ev.target.files && ev.target.files[0]
  if (file) file.text().then((t) => load(t, file.name))
  ev.target.value = ''
}

function onDrop(ev) {
  dragging.value = false
  const file = ev.dataTransfer && ev.dataTransfer.files && ev.dataTransfer.files[0]
  if (file) {
    file.text().then((t) => load(t, file.name))
    return
  }
  const text = ev.dataTransfer && ev.dataTransfer.getData('text')
  if (text) load(text, 'dropped text')
}

function onPaste(ev) {
  const text = ev.clipboardData && ev.clipboardData.getData('text')
  if (text && text.trim().startsWith('{')) {
    ev.preventDefault()
    load(text, 'pasted')
  }
}

function loadPasted() {
  if (pasteText.value.trim()) load(pasteText.value, 'pasted')
}

async function loadSample() {
  try {
    const res = await fetch(withBase('/sample-export.json'))
    load(await res.text(), 'sample-export.json (sample data)')
  } catch (e) {
    error.value = 'Could not load the sample: ' + e.message
  }
}

// ---------- data ----------

const snap = computed(() => (doc.value ? doc.value[side.value] || null : null))
const sides = computed(() => (doc.value ? ['client', 'server'].filter((s) => doc.value[s]) : []))
const isSample = computed(() => !!(doc.value && doc.value._sample))
const budget = computed(() => {
  const b = snap.value && snap.value.frame && snap.value.frame.budget
  if (typeof b !== 'number' || b <= 0) return 1000 / 60
  return b < 1 ? b * 1000 : b
})

// The timeline uses the recording (every frame) when it belongs to the side shown, else the
// snapshot's last 120 frames.
const series = computed(() => {
  const d = doc.value
  if (!d) return null
  const rec = d.recording
  const recSide = d.side || (d.client ? 'client' : 'server')
  if (rec && rec.frames && Array.isArray(rec.frames.dt) && rec.frames.dt.length > 0 && recSide === side.value) {
    const n = rec.frames.dt.length
    const t = Array.isArray(rec.frames.t) && rec.frames.t.length === n ? rec.frames.t : null
    return {
      source: 'recording',
      n,
      dt: rec.frames.dt.map(num),
      script: Array.isArray(rec.frames.script) ? rec.frames.script.map(num) : null,
      t: t ? t.map(num) : cumulative(rec.frames.dt),
      t0: num(rec.t0),
      probes: Array.isArray(rec.probes) ? rec.probes : [],
      self: Array.isArray(rec.frames.self) ? rec.frames.self : [],
    }
  }
  const h = snap.value && snap.value.frame && snap.value.frame.history
  if (Array.isArray(h) && h.length > 0) {
    return { source: 'history', n: h.length, dt: h.map(num), script: null, t: cumulative(h), t0: 0, probes: [], self: [] }
  }
  return null
})

function num(v) {
  return typeof v === 'number' && isFinite(v) ? v : 0
}

function cumulative(dts) {
  const out = new Array(dts.length)
  let acc = 0
  for (let i = 0; i < dts.length; i++) {
    out[i] = acc
    acc += num(dts[i]) / 1000
  }
  return out
}

function pct(sorted, q) {
  if (sorted.length === 0) return 0
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]
}

// ---------- formatting ----------

function ms(v) {
  if (typeof v !== 'number' || !isFinite(v)) return '-'
  if (v >= 100) return v.toFixed(0)
  if (v >= 10) return v.toFixed(1)
  return v.toFixed(2)
}
function bytes(v) {
  v = num(v)
  if (v >= 1048576) return (v / 1048576).toFixed(2) + ' MB'
  if (v >= 1024) return (v / 1024).toFixed(1) + ' KB'
  return Math.round(v) + ' B'
}
function count(v) {
  v = num(v)
  if (Number.isInteger(v)) return String(v)
  return v >= 10 ? v.toFixed(1) : v.toFixed(2)
}
function mb(v) {
  v = num(v)
  return v >= 100 ? v.toFixed(0) : v.toFixed(1)
}
function frameClass(v) {
  if (typeof v !== 'number') return ''
  if (v <= budget.value) return 'good'
  if (v <= budget.value * 2) return 'warn'
  return 'bad'
}

// ---------- timeline (canvas) ----------

const canvas = ref(null)
const wrap = ref(null)
const view = ref(null) // { a, b }: visible frame range [a, b)
const hover = ref(-1)
const selected = ref(-1)
const tip = ref({ x: 0, y: 0, show: false })
let dragFrom = null
let resizeObs = null
let themeObs = null

function range() {
  const s = series.value
  if (!s) return { a: 0, b: 1 }
  return view.value || { a: 0, b: s.n }
}

function setRange(a, b) {
  const s = series.value
  if (!s) return
  const minSpan = Math.min(20, s.n)
  let span = Math.max(minSpan, Math.min(s.n, b - a))
  a = Math.max(0, Math.min(s.n - span, a))
  view.value = { a, b: a + span }
}

function zoom(factor, centerFrac = 0.5) {
  const { a, b } = range()
  const span = b - a
  const c = a + span * centerFrac
  const next = span * factor
  setRange(c - next * centerFrac, c - next * centerFrac + next)
}

function resetZoom() {
  view.value = null
}

function zoomToFrame(i) {
  setRange(i - 30, i + 30)
  selected.value = i
}

function css(name, fallback) {
  if (typeof window === 'undefined') return fallback
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || fallback
}

const flareFrames = computed(() => {
  // Map flares to recording frames by time (flare.t is os.clock seconds, like recording.t0).
  const s = series.value
  const flares = (snap.value && snap.value.flares) || []
  const out = new Set()
  if (!s || s.source !== 'recording') return out
  for (const f of flares) {
    if (!f || typeof f.t !== 'number') continue
    const rel = f.t - s.t0
    let lo = 0
    let hi = s.n - 1
    if (rel < s.t[0] - 0.05 || rel > s.t[hi] + 0.5) continue
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (s.t[mid] <= rel + 1e-6) lo = mid
      else hi = mid - 1
    }
    out.add(lo)
  }
  return out
})

const visibleStats = computed(() => {
  const s = series.value
  if (!s) return null
  const { a, b } = range()
  const i0 = Math.floor(a)
  const i1 = Math.ceil(b)
  const vals = s.dt.slice(i0, i1).sort((x, y) => x - y)
  let sum = 0
  for (const v of vals) sum += v
  let script = 0
  if (s.script) for (let i = i0; i < i1; i++) script += s.script[i]
  const n = vals.length
  return {
    n,
    seconds: n ? (s.t[Math.min(i1, s.n) - 1] - s.t[i0]) + s.dt[Math.min(i1, s.n) - 1] / 1000 : 0,
    avg: n ? sum / n : 0,
    p50: pct(vals, 0.5),
    p95: pct(vals, 0.95),
    p99: pct(vals, 0.99),
    max: n ? vals[n - 1] : 0,
    script: s.script && n ? script / n : null,
    over: vals.filter((v) => v > budget.value).length,
  }
})

function draw() {
  const cv = canvas.value
  const s = series.value
  if (!cv || !s) return
  const dpr = window.devicePixelRatio || 1
  const W = cv.clientWidth
  const H = cv.clientHeight
  if (W === 0 || H === 0) return
  if (cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)) {
    cv.width = Math.round(W * dpr)
    cv.height = Math.round(H * dpr)
  }
  const g = cv.getContext('2d')
  g.setTransform(dpr, 0, 0, dpr, 0, 0)
  g.clearRect(0, 0, W, H)

  const colors = {
    good: css('--vp-c-green-1', '#2f9e6a'),
    warn: css('--lib-accent', '#d98a00'),
    bad: css('--vp-c-red-1', '#d0383e'),
    grid: css('--vp-c-divider', '#ddd'),
    text: css('--vp-c-text-2', '#666'),
    line: css('--vp-c-text-1', '#111'),
    sel: css('--vp-c-text-1', '#111'),
  }
  const padL = 40
  const padB = 18
  const padT = 10
  const plotW = W - padL - 6
  const plotH = H - padB - padT
  const { a, b } = range()
  const span = b - a
  const i0 = Math.floor(a)
  const i1 = Math.min(s.n, Math.ceil(b))

  let peak = budget.value * 2
  for (let i = i0; i < i1; i++) if (s.dt[i] > peak) peak = s.dt[i]
  const top = niceTop(peak)
  const y = (v) => padT + plotH - (Math.min(v, top) / top) * plotH
  const x = (i) => padL + ((i - a) / span) * plotW

  // grid and labels
  g.font = '11px ui-monospace, SFMono-Regular, Menlo, monospace'
  g.fillStyle = colors.text
  g.strokeStyle = colors.grid
  g.lineWidth = 1
  g.textAlign = 'right'
  g.textBaseline = 'middle'
  for (const v of [0, top / 2, top]) {
    g.beginPath()
    g.moveTo(padL, Math.round(y(v)) + 0.5)
    g.lineTo(padL + plotW, Math.round(y(v)) + 0.5)
    g.stroke()
    g.fillText(ms(v), padL - 4, y(v))
  }

  // bars: one per frame, or the max per pixel column when frames are narrower than a pixel
  const perPx = span / plotW
  if (perPx <= 1) {
    const w = Math.max(1, plotW / span - (plotW / span > 3 ? 1 : 0))
    for (let i = i0; i < i1; i++) {
      const v = s.dt[i]
      g.fillStyle = colors[frameClass(v)] || colors.good
      g.fillRect(x(i), y(v), w, padT + plotH - y(v))
      if (s.script) {
        g.fillStyle = 'rgba(0,0,0,0.28)'
        const sv = Math.min(s.script[i], v)
        g.fillRect(x(i), y(sv), w, padT + plotH - y(sv))
      }
    }
  } else {
    for (let px = 0; px < plotW; px++) {
      const f0 = Math.floor(a + px * perPx)
      const f1 = Math.min(s.n, Math.floor(a + (px + 1) * perPx))
      let v = 0
      let sv = 0
      for (let i = f0; i < Math.max(f1, f0 + 1) && i < s.n; i++) {
        if (s.dt[i] > v) {
          v = s.dt[i]
          sv = s.script ? s.script[i] : 0
        }
      }
      g.fillStyle = colors[frameClass(v)] || colors.good
      g.fillRect(padL + px, y(v), 1, padT + plotH - y(v))
      if (s.script) {
        g.fillStyle = 'rgba(0,0,0,0.28)'
        g.fillRect(padL + px, y(sv), 1, padT + plotH - y(sv))
      }
    }
  }

  // budget line
  g.strokeStyle = colors.line
  g.setLineDash([4, 3])
  g.beginPath()
  g.moveTo(padL, Math.round(y(budget.value)) + 0.5)
  g.lineTo(padL + plotW, Math.round(y(budget.value)) + 0.5)
  g.stroke()
  g.setLineDash([])
  g.fillStyle = colors.text
  g.textAlign = 'left'
  g.fillText('budget ' + ms(budget.value), padL + 4, y(budget.value) - 7)

  // flare markers
  g.fillStyle = colors.bad
  for (const i of flareFrames.value) {
    if (i < i0 || i >= i1) continue
    const cx = x(i + 0.5)
    g.beginPath()
    g.moveTo(cx - 4, padT - 8)
    g.lineTo(cx + 4, padT - 8)
    g.lineTo(cx, padT - 2)
    g.closePath()
    g.fill()
  }

  // hover and selection
  for (const [i, alpha] of [
    [hover.value, 0.12],
    [selected.value, 0.22],
  ]) {
    if (i < i0 || i >= i1 || i < 0) continue
    g.fillStyle = `rgba(127,127,127,${alpha})`
    g.fillRect(x(i), padT, Math.max(1, plotW / span), plotH)
  }

  // time axis
  g.fillStyle = colors.text
  g.textBaseline = 'alphabetic'
  g.textAlign = 'left'
  g.fillText(s.t[i0].toFixed(2) + ' s', padL, H - 4)
  g.textAlign = 'right'
  g.fillText(s.t[Math.max(i0, i1 - 1)].toFixed(2) + ' s', padL + plotW, H - 4)
  g.textAlign = 'center'
  g.fillText(s.source === 'recording' ? 'frames ' + (i0 + 1) + ' to ' + i1 + ' of ' + s.n : 'last ' + s.n + ' frames (snapshot)', padL + plotW / 2, H - 4)
}

const STEPS = [20, 25, 33.4, 40, 50, 66.7, 100, 150, 200, 300, 500, 1000, 2000]
function niceTop(v) {
  for (const s of STEPS) if (v <= s) return s
  return Math.ceil(v / 1000) * 1000
}

function frameAt(ev) {
  const cv = canvas.value
  const s = series.value
  if (!cv || !s) return -1
  const rect = cv.getBoundingClientRect()
  const px = ev.clientX - rect.left - 40
  const plotW = rect.width - 46
  if (px < 0 || px > plotW) return -1
  const { a, b } = range()
  const i = Math.floor(a + (px / plotW) * (b - a))
  return i >= 0 && i < s.n ? i : -1
}

function onMove(ev) {
  if (dragFrom) {
    const rect = canvas.value.getBoundingClientRect()
    const plotW = rect.width - 46
    const { a, b } = dragFrom.range
    const shift = ((dragFrom.x - ev.clientX) / plotW) * (b - a)
    if (Math.abs(dragFrom.x - ev.clientX) > 3) dragFrom.moved = true
    setRange(a + shift, b + shift)
    return
  }
  const i = frameAt(ev)
  hover.value = i
  const rect = wrap.value.getBoundingClientRect()
  tip.value = { x: ev.clientX - rect.left, y: ev.clientY - rect.top, show: i >= 0 }
}

function onLeave() {
  hover.value = -1
  tip.value = { ...tip.value, show: false }
  dragFrom = null
}

function onDown(ev) {
  dragFrom = { x: ev.clientX, range: { ...range() }, moved: false }
  canvas.value.setPointerCapture && canvas.value.setPointerCapture(ev.pointerId)
}

function onUp(ev) {
  if (dragFrom && !dragFrom.moved) {
    const i = frameAt(ev)
    selected.value = i === selected.value ? -1 : i
  }
  dragFrom = null
}

function onWheel(ev) {
  if (!series.value) return
  ev.preventDefault()
  const rect = canvas.value.getBoundingClientRect()
  const frac = Math.max(0, Math.min(1, (ev.clientX - rect.left - 40) / (rect.width - 46)))
  zoom(ev.deltaY > 0 ? 1.25 : 0.8, frac)
}

function onKey(ev) {
  if (!series.value) return
  const { a, b } = range()
  const step = (b - a) * 0.2
  if (ev.key === '+' || ev.key === '=') zoom(0.8)
  else if (ev.key === '-') zoom(1.25)
  else if (ev.key === 'ArrowLeft') setRange(a - step, b - step)
  else if (ev.key === 'ArrowRight') setRange(a + step, b + step)
  else if (ev.key === '0') resetZoom()
  else return
  ev.preventDefault()
}

// probes of one frame, from the recording
function frameProbes(i) {
  const s = series.value
  if (!s || i < 0 || s.source !== 'recording') return []
  const out = []
  for (let p = 0; p < s.probes.length; p++) {
    const v = s.self[p] && s.self[p][i]
    if (typeof v === 'number' && v > 0) out.push({ name: s.probes[p], ms: v })
  }
  out.sort((x, y) => y.ms - x.ms)
  return out
}

const hoverInfo = computed(() => {
  const s = series.value
  const i = hover.value
  if (!s || i < 0) return null
  return { i, t: s.t[i], dt: s.dt[i], script: s.script ? s.script[i] : null, top: frameProbes(i).slice(0, 5) }
})

const selectedInfo = computed(() => {
  const s = series.value
  const i = selected.value
  if (!s || i < 0 || i >= s.n) return null
  const list = frameProbes(i)
  const max = list.length ? list[0].ms : 0
  return { i, t: s.t[i], dt: s.dt[i], script: s.script ? s.script[i] : null, list, max }
})

watch([series, view, hover, selected, side], () => nextTick(draw))

// ---------- tables ----------

const probeSource = ref('auto') // 'auto' | 'snapshot' | 'range'
const probeFilter = ref('')
const probeSort = reactive({ key: 'selfAvg', dir: -1 })

const useRange = computed(() => {
  const s = series.value
  const hasRec = s && s.source === 'recording' && s.probes.length > 0
  if (probeSource.value === 'snapshot') return false
  if (probeSource.value === 'range') return !!hasRec
  return !!hasRec
})

const probeRows = computed(() => {
  let rows = []
  if (useRange.value) {
    const s = series.value
    const { a, b } = range()
    const i0 = Math.floor(a)
    const i1 = Math.min(s.n, Math.ceil(b))
    const n = Math.max(1, i1 - i0)
    for (let p = 0; p < s.probes.length; p++) {
      const col = s.self[p] || []
      let sum = 0
      let max = 0
      let ran = 0
      const vals = []
      for (let i = i0; i < i1; i++) {
        const v = num(col[i])
        sum += v
        if (v > max) max = v
        if (v > 0) {
          ran++
          vals.push(v)
        }
      }
      vals.sort((x, y) => x - y)
      rows.push({ name: s.probes[p], selfAvg: sum / n, selfP95: pct(vals, 0.95), selfMax: max, frames: ran / n })
    }
  } else {
    const list = (snap.value && snap.value.probes) || []
    rows = list
      .filter((p) => p && typeof p.name === 'string')
      .map((p) => ({ name: p.name, selfAvg: num(p.selfAvg), selfP95: num(p.selfP95), selfMax: num(p.selfMax), totalAvg: num(p.totalAvg), calls: num(p.calls) }))
  }
  const f = probeFilter.value.trim().toLowerCase()
  if (f) rows = rows.filter((r) => r.name.toLowerCase().includes(f))
  const { key, dir } = probeSort
  rows.sort((x, y) => {
    const va = x[key]
    const vb = y[key]
    if (typeof va === 'string') return dir * va.localeCompare(vb)
    return dir * ((va || 0) - (vb || 0))
  })
  const maxSelf = rows.reduce((m, r) => Math.max(m, r.selfAvg), 0)
  return rows.map((r) => ({ ...r, share: maxSelf > 0 ? r.selfAvg / maxSelf : 0 }))
})

const probeGroups = computed(() => {
  const groups = new Map()
  for (const r of probeRows.value) {
    const dot = r.name.indexOf('.')
    const g = dot > 0 ? r.name.slice(0, dot) : r.name
    groups.set(g, (groups.get(g) || 0) + r.selfAvg)
  }
  return [...groups.entries()].sort((x, y) => y[1] - x[1]).slice(0, 8)
})

// st is a reactive { key, dir }: click a header to sort by it, click again to flip the order.
function sortBy(st, key) {
  st.dir = st.key === key ? -st.dir : key === 'name' || key === 'lib' || key === 'channel' || key === 'dir' ? 1 : -1
  st.key = key
}
function arrow(st, key) {
  return st.key === key ? (st.dir < 0 ? ' ▼' : ' ▲') : ''
}

const netSort = reactive({ key: 'bps', dir: -1 })
const netRows = computed(() => {
  const list = ((snap.value && snap.value.net) || []).filter((c) => c && typeof c === 'object')
  const rows = list.map((c) => ({ lib: String(c.lib ?? '?'), channel: String(c.channel ?? '?'), dir: c.dir === 'in' ? 'in' : 'out', bps: num(c.bps), pps: num(c.pps), avg: num(c.avg), peak: num(c.peak) }))
  const { key, dir } = netSort
  rows.sort((x, y) => (typeof x[key] === 'string' ? dir * x[key].localeCompare(y[key]) : dir * (x[key] - y[key])))
  return rows
})
const netTotals = computed(() => {
  const t = { in: 0, out: 0 }
  for (const r of netRows.value) t[r.dir] += r.bps
  return t
})

const memTags = computed(() => {
  const m = snap.value && snap.value.memory
  if (!m || !m.tags || typeof m.tags !== 'object') return []
  const total = num(m.totalMb)
  return Object.entries(m.tags)
    .filter(([, v]) => typeof v === 'number')
    .sort((x, y) => y[1] - x[1])
    .map(([tag, v]) => ({ tag, mb: v, share: total > 0 ? v / total : 0 }))
})

const flares = computed(() => ((snap.value && snap.value.flares) || []).filter((f) => f && typeof f === 'object'))

function flareFrameIndex(f) {
  const s = series.value
  if (!s || s.source !== 'recording' || typeof f.t !== 'number') return -1
  const rel = f.t - s.t0
  let best = -1
  let bestD = Infinity
  for (const i of flareFrames.value) {
    const d = Math.abs(s.t[i] - rel)
    if (d < bestD) {
      bestD = d
      best = i
    }
  }
  return bestD < 0.5 ? best : -1
}

const telemetry = computed(() => {
  const d = doc.value
  if (!d) return null
  const r = d.reports || (d.server && d.server.reports)
  return r && Array.isArray(r.devices) ? r : null
})

// ---------- lifecycle ----------

onMounted(() => {
  window.addEventListener('paste', onPaste)
  if (typeof ResizeObserver !== 'undefined') {
    resizeObs = new ResizeObserver(() => draw())
    if (wrap.value) resizeObs.observe(wrap.value)
  }
  themeObs = new MutationObserver(() => draw())
  themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
  if (new URLSearchParams(window.location.search).has('sample')) loadSample()
})

watch(wrap, (el) => {
  if (el && resizeObs) resizeObs.observe(el)
})

onBeforeUnmount(() => {
  window.removeEventListener('paste', onPaste)
  if (resizeObs) resizeObs.disconnect()
  if (themeObs) themeObs.disconnect()
})
</script>

<template>
  <div class="lhv">
    <div
      class="lhv-drop"
      :class="{ dragging }"
      tabindex="0"
      @dragover.prevent="dragging = true"
      @dragleave="dragging = false"
      @drop.prevent="onDrop"
    >
      <p class="lhv-drop-title">Drop an export here, paste it anywhere on this page, or pick a file.</p>
      <div class="lhv-actions">
        <label class="lhv-button brand">
          Choose file
          <input type="file" accept=".json,application/json,text/plain" @change="onFile" />
        </label>
        <button class="lhv-button" type="button" @click="loadSample">Load the sample</button>
      </div>
      <details class="lhv-paste">
        <summary>Paste into a box instead</summary>
        <textarea v-model="pasteText" rows="4" placeholder='{"lighthouse":1, ...}' spellcheck="false"></textarea>
        <button class="lhv-button" type="button" @click="loadPasted">Load pasted text</button>
      </details>
      <p class="lhv-note">The file stays in your browser. Nothing is uploaded.</p>
    </div>

    <p v-if="error" class="lhv-error">{{ error }}</p>

    <template v-if="doc">
      <div class="lhv-bar">
        <span class="lhv-file">{{ fileName }}</span>
        <span v-if="isSample" class="lhv-badge">sample data, not from a real game</span>
        <span class="lhv-spacer"></span>
        <div v-if="sides.length > 1" class="lhv-seg" role="tablist">
          <button v-for="s in sides" :key="s" type="button" :class="{ on: side === s }" @click="side = s">{{ s }}</button>
        </div>
      </div>

      <div v-if="snap" class="lhv-cards">
        <div class="lhv-card"><span>p50</span><b :class="frameClass(snap.frame && snap.frame.p50)">{{ ms(snap.frame && snap.frame.p50) }} ms</b></div>
        <div class="lhv-card"><span>p95</span><b :class="frameClass(snap.frame && snap.frame.p95)">{{ ms(snap.frame && snap.frame.p95) }} ms</b></div>
        <div class="lhv-card"><span>p99</span><b :class="frameClass(snap.frame && snap.frame.p99)">{{ ms(snap.frame && snap.frame.p99) }} ms</b></div>
        <div class="lhv-card"><span>fps</span><b>{{ snap.frame && typeof snap.frame.fps === 'number' ? snap.frame.fps.toFixed(0) : '-' }}</b></div>
        <div class="lhv-card"><span>script / frame</span><b>{{ ms(snap.frame && snap.frame.scriptMs) }} / {{ ms(snap.frame && snap.frame.avg1) }}</b></div>
        <div class="lhv-card"><span>device</span><b>{{ snap.device || (snap.players != null ? snap.players + ' players' : snap.side) }}</b></div>
      </div>

      <h2 id="timeline">Frame timeline</h2>
      <div v-if="series" class="lhv-timeline">
        <div class="lhv-tools">
          <button class="lhv-button small" type="button" @click="zoom(0.6)" aria-label="Zoom in">+</button>
          <button class="lhv-button small" type="button" @click="zoom(1.6)" aria-label="Zoom out">−</button>
          <button class="lhv-button small" type="button" @click="resetZoom">Reset</button>
          <span v-if="visibleStats" class="lhv-stats">
            {{ visibleStats.n }} frames, {{ visibleStats.seconds.toFixed(1) }} s · avg {{ ms(visibleStats.avg) }} · p50 {{ ms(visibleStats.p50) }} · p95
            {{ ms(visibleStats.p95) }} · p99 {{ ms(visibleStats.p99) }} · max {{ ms(visibleStats.max) }} ms<template v-if="visibleStats.script != null">
              · script {{ ms(visibleStats.script) }} ms</template
            >
            · {{ visibleStats.over }} over budget
          </span>
        </div>
        <div ref="wrap" class="lhv-canvas-wrap">
          <canvas
            ref="canvas"
            class="lhv-canvas"
            tabindex="0"
            aria-label="Frame time timeline. Scroll or use plus and minus to zoom, drag or arrow keys to pan, click a frame to inspect it."
            @pointermove="onMove"
            @pointerleave="onLeave"
            @pointerdown="onDown"
            @pointerup="onUp"
            @wheel="onWheel"
            @keydown="onKey"
          ></canvas>
          <div v-if="tip.show && hoverInfo" class="lhv-tip" :style="{ left: tip.x + 14 + 'px', top: tip.y + 10 + 'px' }">
            <b :class="frameClass(hoverInfo.dt)">{{ ms(hoverInfo.dt) }} ms</b>
            <span v-if="hoverInfo.script != null"> · script {{ ms(hoverInfo.script) }}</span>
            <div class="lhv-dim">frame {{ hoverInfo.i + 1 }} at {{ hoverInfo.t.toFixed(3) }} s</div>
            <div v-for="p in hoverInfo.top" :key="p.name">{{ p.name }} {{ ms(p.ms) }}</div>
          </div>
        </div>
        <p class="lhv-help">
          Bars are frame times: green within budget, amber up to twice the budget, red beyond. The darker part is script time.
          Red triangles are flares. Scroll or press + and − to zoom, drag or use the arrow keys to pan, click a frame to inspect it.
        </p>
        <div v-if="selectedInfo" class="lhv-frame">
          <div class="lhv-frame-head">
            <b>Frame {{ selectedInfo.i + 1 }}</b>
            <span>
              {{ ms(selectedInfo.dt) }} ms<template v-if="selectedInfo.script != null">, script {{ ms(selectedInfo.script) }} ms, unmeasured
                {{ ms(Math.max(0, selectedInfo.dt - selectedInfo.script)) }} ms</template
              >
            </span>
            <button class="lhv-button small" type="button" @click="selected = -1">Close</button>
          </div>
          <div v-if="selectedInfo.list.length === 0" class="lhv-dim">No probe ran in this frame.</div>
          <div v-for="p in selectedInfo.list" :key="p.name" class="lhv-barrow">
            <span class="lhv-bar-fill" :style="{ width: (selectedInfo.max ? (p.ms / selectedInfo.max) * 100 : 0) + '%' }"></span>
            <span class="lhv-bar-name">{{ p.name }}</span>
            <span class="lhv-bar-val">{{ ms(p.ms) }} ms</span>
          </div>
        </div>
      </div>
      <p v-else class="lhv-dim">This export has no frame history for the {{ side }}.</p>

      <h2 id="flares">Flares</h2>
      <p v-if="flares.length === 0" class="lhv-dim">No flares: no frame went over budget and over 1.5 times the median.</p>
      <div v-else class="lhv-table-wrap">
        <table class="lhv-table">
          <thead>
            <tr><th class="num">frame ms</th><th>slowest probes in that frame</th><th></th></tr>
          </thead>
          <tbody>
            <tr v-for="(f, k) in flares" :key="k">
              <td class="num" :class="frameClass(f.frameMs)">{{ ms(f.frameMs) }}</td>
              <td>
                <span v-for="(p, j) in f.top || []" :key="j" class="lhv-chip">{{ p.name }} {{ ms(p.ms) }}</span>
              </td>
              <td class="num">
                <button v-if="flareFrameIndex(f) >= 0" class="lhv-button small" type="button" @click="zoomToFrame(flareFrameIndex(f))">Show</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 id="probes">Probes</h2>
      <div class="lhv-tools">
        <input v-model="probeFilter" class="lhv-input" type="search" placeholder="Filter, e.g. Crowd" aria-label="Filter probes" />
        <div v-if="series && series.source === 'recording' && series.probes.length" class="lhv-seg">
          <button type="button" :class="{ on: useRange }" @click="probeSource = 'range'">visible range</button>
          <button type="button" :class="{ on: !useRange }" @click="probeSource = 'snapshot'">snapshot</button>
        </div>
      </div>
      <p class="lhv-dim small">
        <template v-if="useRange">Self time per frame over the frames visible in the timeline. Zoom the timeline to change the range.</template>
        <template v-else>From the snapshot: averages over the last second, p95 and max over 10 s.</template>
        Groups: <span v-for="[g, v] in probeGroups" :key="g" class="lhv-chip">{{ g }} {{ ms(v) }}</span>
      </p>
      <div class="lhv-table-wrap">
        <table class="lhv-table sortable">
          <thead>
            <tr>
              <th @click="sortBy(probeSort, 'name')">probe{{ arrow(probeSort, 'name') }}</th>
              <th class="num" @click="sortBy(probeSort, 'selfAvg')">self ms{{ arrow(probeSort, 'selfAvg') }}</th>
              <th class="num" @click="sortBy(probeSort, 'selfP95')">p95{{ arrow(probeSort, 'selfP95') }}</th>
              <th class="num" @click="sortBy(probeSort, 'selfMax')">max{{ arrow(probeSort, 'selfMax') }}</th>
              <th v-if="useRange" class="num" @click="sortBy(probeSort, 'frames')">ran in{{ arrow(probeSort, 'frames') }}</th>
              <th v-if="!useRange" class="num" @click="sortBy(probeSort, 'totalAvg')">total{{ arrow(probeSort, 'totalAvg') }}</th>
              <th v-if="!useRange" class="num" @click="sortBy(probeSort, 'calls')">calls{{ arrow(probeSort, 'calls') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in probeRows" :key="r.name">
              <td class="lhv-namecell"><span class="lhv-share" :style="{ width: r.share * 100 + '%' }"></span><span class="lhv-name">{{ r.name }}</span></td>
              <td class="num">{{ ms(r.selfAvg) }}</td>
              <td class="num">{{ ms(r.selfP95) }}</td>
              <td class="num">{{ ms(r.selfMax) }}</td>
              <td v-if="useRange" class="num">{{ (r.frames * 100).toFixed(0) }}%</td>
              <td v-if="!useRange" class="num">{{ ms(r.totalAvg) }}</td>
              <td v-if="!useRange" class="num">{{ count(r.calls) }}</td>
            </tr>
            <tr v-if="probeRows.length === 0"><td colspan="6" class="lhv-dim">No probes.</td></tr>
          </tbody>
        </table>
      </div>

      <h2 id="network">Network</h2>
      <p class="lhv-dim small">
        Channels: in {{ bytes(netTotals.in) }}/s, out {{ bytes(netTotals.out) }}/s.
        <template v-if="snap && snap.engine">Engine: receive {{ (num(snap.engine.recvKbps) / 8).toFixed(1) }} KB/s, send {{ (num(snap.engine.sendKbps) / 8).toFixed(1) }} KB/s<template v-if="typeof snap.engine.ping === 'number'">, ping {{ snap.engine.ping.toFixed(0) }} ms</template>.</template>
      </p>
      <div class="lhv-table-wrap">
        <table class="lhv-table sortable">
          <thead>
            <tr>
              <th @click="sortBy(netSort, 'lib')">lib{{ arrow(netSort, 'lib') }}</th>
              <th @click="sortBy(netSort, 'channel')">channel{{ arrow(netSort, 'channel') }}</th>
              <th @click="sortBy(netSort, 'dir')">dir{{ arrow(netSort, 'dir') }}</th>
              <th class="num" @click="sortBy(netSort, 'bps')">per s{{ arrow(netSort, 'bps') }}</th>
              <th class="num" @click="sortBy(netSort, 'pps')">pkt/s{{ arrow(netSort, 'pps') }}</th>
              <th class="num" @click="sortBy(netSort, 'avg')">avg{{ arrow(netSort, 'avg') }}</th>
              <th class="num" @click="sortBy(netSort, 'peak')">peak{{ arrow(netSort, 'peak') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(r, k) in netRows" :key="k">
              <td>{{ r.lib }}</td>
              <td>{{ r.channel }}</td>
              <td>{{ r.dir }}</td>
              <td class="num">{{ bytes(r.bps) }}</td>
              <td class="num">{{ count(r.pps) }}</td>
              <td class="num">{{ bytes(r.avg) }}</td>
              <td class="num">{{ bytes(r.peak) }}</td>
            </tr>
            <tr v-if="netRows.length === 0"><td colspan="7" class="lhv-dim">No channels.</td></tr>
          </tbody>
        </table>
      </div>
      <div v-if="snap && Array.isArray(snap.netTop) && snap.netTop.length" class="lhv-dim small">
        Top players by bytes out:
        <span v-for="p in snap.netTop" :key="p.who" class="lhv-chip">{{ p.who }} {{ bytes(p.bps) }}/s</span>
      </div>

      <h2 id="memory">Memory</h2>
      <div v-if="snap && snap.memory" class="lhv-cards">
        <div class="lhv-card"><span>total</span><b>{{ mb(snap.memory.totalMb) }} MB</b></div>
        <div class="lhv-card"><span>Luau heap</span><b>{{ mb(snap.memory.luaHeapMb) }} MB</b></div>
        <div class="lhv-card">
          <span>garbage</span
          ><b :class="num(snap.memory.gcKbPerSec) >= 2000 ? 'bad' : num(snap.memory.gcKbPerSec) >= 500 ? 'warn' : 'good'">{{ num(snap.memory.gcKbPerSec).toFixed(0) }} KB/s</b>
        </div>
        <div class="lhv-card"><span>instances</span><b>{{ snap.engine && typeof snap.engine.instances === 'number' ? snap.engine.instances.toLocaleString('en-US') : '-' }}</b></div>
      </div>
      <div v-for="t in memTags" :key="t.tag" class="lhv-barrow">
        <span class="lhv-bar-fill" :style="{ width: t.share * 100 + '%' }"></span>
        <span class="lhv-bar-name">{{ t.tag }}</span>
        <span class="lhv-bar-val">{{ mb(t.mb) }} MB · {{ (t.share * 100).toFixed(0) }}%</span>
      </div>
      <p v-if="memTags.length === 0" class="lhv-dim">No memory tags in this snapshot.</p>

      <template v-if="telemetry">
        <h2 id="players">Players</h2>
        <p class="lhv-dim small">{{ telemetry.players }} players reported {{ telemetry.reports }} times. Percentiles are from merged histograms per device class.</p>
        <div class="lhv-table-wrap">
          <table class="lhv-table">
            <thead>
              <tr>
                <th>device</th><th class="num">players</th><th class="num">p50</th><th class="num">p95</th><th class="num">p99</th><th class="num">script p50</th><th class="num">memory</th><th class="num">ping</th><th>top probes</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="d in telemetry.devices" :key="d.device">
                <td>{{ d.device }}</td>
                <td class="num">{{ d.players }}</td>
                <td class="num" :class="frameClass(d.frameP50)">{{ ms(d.frameP50) }}</td>
                <td class="num" :class="frameClass(d.frameP95)">{{ ms(d.frameP95) }}</td>
                <td class="num" :class="frameClass(d.frameP99)">{{ ms(d.frameP99) }}</td>
                <td class="num">{{ ms(d.scriptP50) }}</td>
                <td class="num">{{ mb(d.memoryMb) }} MB</td>
                <td class="num">{{ typeof d.pingMs === 'number' ? d.pingMs.toFixed(0) : '-' }}</td>
                <td><span v-for="p in d.probes || []" :key="p.name" class="lhv-chip">{{ p.name }} {{ ms(p.ms) }}</span></td>
              </tr>
            </tbody>
          </table>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.lhv {
  --good: var(--vp-c-green-1, #2f9e6a);
  --warn: var(--lib-accent, #d98a00);
  --bad: var(--vp-c-red-1, #d0383e);
  margin-top: 16px;
}
.lhv h2 {
  margin-top: 40px;
}
.lhv-drop {
  border: 2px dashed var(--vp-c-divider);
  border-radius: 12px;
  padding: 20px;
  text-align: center;
  background: var(--vp-c-bg-soft);
  transition: border-color 0.15s;
}
.lhv-drop.dragging,
.lhv-drop:focus-visible {
  border-color: var(--vp-c-brand-1);
  outline: none;
}
.lhv-drop-title {
  margin: 0 0 12px;
  font-weight: 600;
}
.lhv-actions {
  display: flex;
  gap: 8px;
  justify-content: center;
  flex-wrap: wrap;
}
.lhv-button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  padding: 6px 14px;
  font-size: 14px;
  font-weight: 500;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  cursor: pointer;
}
.lhv-button:hover {
  border-color: var(--vp-c-brand-1);
}
.lhv-button.brand {
  background: var(--vp-button-brand-bg);
  color: var(--vp-button-brand-text);
  border-color: var(--vp-button-brand-border);
}
.lhv-button.small {
  padding: 2px 10px;
  font-size: 13px;
}
.lhv-button input[type='file'] {
  display: none;
}
.lhv-paste {
  margin-top: 12px;
  text-align: left;
}
.lhv-paste summary {
  cursor: pointer;
  color: var(--vp-c-text-2);
  font-size: 14px;
}
.lhv-paste textarea {
  width: 100%;
  margin: 8px 0;
  padding: 8px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  background: var(--vp-c-bg);
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
}
.lhv-note,
.lhv-dim {
  color: var(--vp-c-text-2);
}
.lhv-note {
  margin: 12px 0 0;
  font-size: 13px;
}
.small {
  font-size: 13px;
}
.lhv-error {
  color: var(--bad);
  font-weight: 600;
}
.lhv-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 20px;
  flex-wrap: wrap;
}
.lhv-file {
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  color: var(--vp-c-text-2);
}
.lhv-badge {
  font-size: 12px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 999px;
  background: var(--vp-c-brand-soft);
  color: var(--vp-c-brand-1);
}
.lhv-spacer {
  flex: 1;
}
.lhv-seg {
  display: inline-flex;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  overflow: hidden;
}
.lhv-seg button {
  padding: 4px 12px;
  font-size: 13px;
  color: var(--vp-c-text-2);
}
.lhv-seg button.on {
  background: var(--vp-c-brand-soft);
  color: var(--vp-c-brand-1);
  font-weight: 600;
}
.lhv-cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 8px;
  margin-top: 16px;
}
.lhv-card {
  border: 1px solid var(--vp-c-divider);
  border-radius: 10px;
  padding: 8px 12px;
  display: flex;
  flex-direction: column;
}
.lhv-card span {
  font-size: 12px;
  color: var(--vp-c-text-2);
}
.lhv-card b {
  font-family: var(--vp-font-family-mono);
  font-size: 18px;
}
.good {
  color: var(--good);
}
.warn {
  color: var(--warn);
}
.bad {
  color: var(--bad);
}
.lhv-tools {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  margin: 8px 0;
}
.lhv-stats {
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
  color: var(--vp-c-text-2);
  margin-left: 6px;
}
.lhv-canvas-wrap {
  position: relative;
}
.lhv-canvas {
  display: block;
  width: 100%;
  height: 240px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 10px;
  background: var(--vp-c-bg-soft);
  cursor: crosshair;
  touch-action: pan-y;
}
.lhv-canvas:focus-visible {
  outline: 2px solid var(--vp-c-brand-1);
}
.lhv-tip {
  position: absolute;
  pointer-events: none;
  z-index: 2;
  min-width: 160px;
  padding: 6px 10px;
  border-radius: 8px;
  border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-elv);
  box-shadow: var(--vp-shadow-2);
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
  line-height: 1.5;
  white-space: nowrap;
}
.lhv-help {
  font-size: 13px;
  color: var(--vp-c-text-2);
}
.lhv-frame {
  border: 1px solid var(--vp-c-divider);
  border-radius: 10px;
  padding: 10px 12px;
}
.lhv-frame-head {
  display: flex;
  gap: 10px;
  align-items: center;
  margin-bottom: 6px;
  flex-wrap: wrap;
}
.lhv-frame-head span {
  flex: 1;
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
}
.lhv-barrow {
  position: relative;
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding: 2px 8px;
  margin: 2px 0;
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  border-radius: 4px;
  overflow: hidden;
}
.lhv-bar-fill {
  position: absolute;
  inset: 0 auto 0 0;
  background: var(--vp-c-brand-soft);
  z-index: 0;
}
.lhv-bar-name,
.lhv-bar-val {
  position: relative;
  z-index: 1;
}
.lhv-table-wrap {
  overflow-x: auto;
}
.lhv-table {
  display: table;
  width: 100%;
  margin: 8px 0;
  font-size: 13px;
}
.lhv-table th,
.lhv-table td {
  padding: 4px 10px;
}
.lhv-table td.num,
.lhv-table th.num {
  text-align: right;
  font-family: var(--vp-font-family-mono);
  white-space: nowrap;
}
.lhv-table.sortable th {
  cursor: pointer;
  user-select: none;
  white-space: nowrap;
}
.lhv-namecell {
  position: relative;
  font-family: var(--vp-font-family-mono);
}
.lhv-share {
  position: absolute;
  inset: 3px auto 3px 0;
  background: var(--vp-c-brand-soft);
  border-radius: 3px;
}
.lhv-name {
  position: relative;
}
.lhv-chip {
  display: inline-block;
  margin: 2px 4px 2px 0;
  padding: 0 8px;
  border-radius: 999px;
  background: var(--vp-c-default-soft);
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
  white-space: nowrap;
}
.lhv-input {
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  padding: 4px 10px;
  font-size: 13px;
  background: var(--vp-c-bg);
  min-width: 200px;
}
</style>
