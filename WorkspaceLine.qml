import QtQuick

// The line on the current workspace, and how it gets to the next one: it
// stretches with its leading end out in front, the trailing end catches up,
// and a splash comes off the leading edge. It stops exactly in place, with no
// overshoot. It also draws the drips and flings the bar asks for, and splashes
// anywhere it is told to, which works with no line to draw at all.
//
// It fills its parent, with room around it for droplets, and every rect it is
// given is in the parent's coordinates. Only Qt is imported, so the tests can
// render it on their own.
Item {
  id: root

  property color color: "white"
  // Off, the line jumps straight to the next workspace and draws nothing else.
  property bool animated: true
  property bool splash: true
  property bool vertical: false
  // Toward the middle of the bar across the line: -1 when the line is under
  // the numbers on a horizontal bar, 1 when it is over them.
  property int inward: -1
  property real thickness: 4
  // How far above the line a drip starts, and how high a fling arcs.
  property real dropHeight: 10
  // Room past the parent's edges that droplets can reach.
  property real pad: 16

  // Where the line rests, which workspace that is, and its place in the row.
  property rect target: Qt.rect(0, 0, 0, 0)
  property int targetKey: -1
  property int targetIndex: 0

  // For the tests: a clock in ms, stepped by hand. Negative runs on its own.
  property real manualTime: -1

  property bool running: false
  // The stretch of the row the line covers right now, along the row in the
  // parent's coordinates. Lines behind it leave this out, so none shows past
  // its edges when it is thin. Nothing while it has no line.
  property real coverFrom: -1e9
  property real coverTo: -1e9

  x: -pad
  y: -pad
  width: parent ? parent.width + pad * 2 : 0
  height: parent ? parent.height + pad * 2 : 0

  // Everything that moves, kept out of bindings: a frame sets it all at once.
  // Where the line rests (rest) changes only in retarget, never straight from
  // target: a frame drawn between a new target and its retarget would
  // otherwise put the line at its destination before the move starts.
  property var st: ({
    shown: false, key: -1, index: 0, cur: null, rest: null, runSteps: 0,
    tr: null, settleT0: -1, settleAmp: 0, settleDur: 380, chainUntil: 0, chainDir: 1,
    parts: [], drips: [], flings: [],
    lastT: 0, seed: 1
  })

  property bool keyDirty: false
  onTargetKeyChanged: { keyDirty = true; Qt.callLater(retarget) }
  onTargetChanged: Qt.callLater(retarget)
  onAnimatedChanged: kick()
  onThicknessChanged: kick()
  onInwardChanged: kick()

  function clock() { return manualTime >= 0 ? manualTime : Date.now() }
  function clamp(v) { return v < 0 ? 0 : v > 1 ? 1 : v }
  function lerp(a, b, t) { return a + (b - a) * t }
  function outCubic(t) { t = clamp(t); return 1 - Math.pow(1 - t, 3) }
  function inCubic(t) { t = clamp(t); return t * t * t }
  function inOutCubic(t) { t = clamp(t); return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2 }
  function inOutSine(t) { t = clamp(t); return -(Math.cos(Math.PI * t) - 1) / 2 }
  function rand() {
    st.seed++
    var x = Math.sin(st.seed * 12.9898) * 43758.5453
    return x - Math.floor(x)
  }

  // Shapes are kept along the row (a) and across it (c), so one set of rules
  // covers a horizontal bar and a vertical one.
  function toShape(r) {
    return vertical
      ? { a0: r.y + pad, a1: r.y + r.height + pad, c0: r.x + pad, c1: r.x + r.width + pad }
      : { a0: r.x + pad, a1: r.x + r.width + pad, c0: r.y + pad, c1: r.y + r.height + pad }
  }
  function valid(s) { return s && s.a1 > s.a0 && s.c1 > s.c0 }
  function copy(s) { return { a0: s.a0, a1: s.a1, c0: s.c0, c1: s.c1 } }
  function mid(s) { return (s.a0 + s.a1) / 2 }
  function midC(s) { return (s.c0 + s.c1) / 2 }
  function lerpShape(p, q, t) {
    return { a0: lerp(p.a0, q.a0, t), a1: lerp(p.a1, q.a1, t), c0: lerp(p.c0, q.c0, t), c1: lerp(p.c1, q.c1, t) }
  }
  function centered(a, c, len, cross) {
    return { a0: a - len / 2, a1: a + len / 2, c0: c - cross / 2, c1: c + cross / 2 }
  }
  function ball(a, c, size) { return centered(a, c, size, size) }

  function kick() {
    if (!running && manualTime < 0) st.lastT = clock()
    running = true
  }

  function retarget() {
    var dirty = keyDirty
    keyDirty = false
    var B = toShape(target)
    if (!valid(B)) return
    var now = clock()
    if (!st.shown || !animated || !st.cur) {
      st.shown = true
      st.tr = null
      st.settleT0 = -1
      st.key = targetKey
      st.index = targetIndex
      st.cur = copy(B)
      st.rest = copy(B)
      kick()
      return
    }
    var keyChanged = dirty && targetKey !== st.key
    if (!keyChanged) {
      // The same workspace moved along the row. A move already under way reads
      // the rest every frame, so it just ends in the new place.
      st.rest = copy(B)
      if (st.tr) return
      var c = st.cur
      if (Math.abs(c.a0 - B.a0) < 0.5 && Math.abs(c.a1 - B.a1) < 0.5 && Math.abs(c.c0 - B.c0) < 0.5 && Math.abs(c.c1 - B.c1) < 0.5) return
      st.tr = { kind: "follow", t0: now, dur: 160, from: copy(c), dir: 1, splashed: true }
      st.index = targetIndex
      kick()
      return
    }
    var from = copy(st.cur)
    var steps = Math.max(1, Math.abs(targetIndex - st.index))
    var dir = mid(B) >= mid(from) ? 1 : -1
    // Moves that follow each other the same way, as a hotkey pressed again
    // just after the line has landed, add up: the splash is as big as the whole run.
    var going = (st.tr && st.tr.kind !== "follow" && st.tr.dir === dir) || (now < st.chainUntil && st.chainDir === dir)
    st.runSteps = going ? st.runSteps + steps : steps
    st.tr = { kind: "stretch", t0: now, dur: 360 * (1 + 0.12 * (steps - 1)), from: from, dir: dir,
              splashed: false, splashSize: splashSize(st.runSteps) }
    st.settleT0 = -1
    st.key = targetKey
    st.index = targetIndex
    st.rest = copy(B)
    kick()
  }

  // Straight to this rect as this workspace, with no move, so the next target
  // moves from here. For a line that only shows while it travels.
  function jumpTo(r, key, index) {
    var s = toShape(r)
    if (!valid(s)) return
    st.shown = true
    st.tr = null
    st.settleT0 = -1
    st.chainUntil = 0
    st.key = key
    st.index = index
    st.cur = copy(s)
    st.rest = copy(s)
    kick()
  }

  // A droplet falling onto the row at this rect. onLine says it lands on the
  // line itself, which ripples; anywhere else it spreads out and soaks in.
  function drip(r, onLine) {
    if (!animated) return
    var s = toShape(r)
    if (!valid(s)) return
    st.drips.push({ t0: clock(), dur: 460, s: s, onLine: !!onLine, landed: false })
    kick()
  }

  // A droplet thrown off the line to this rect, which takes it in.
  function fling(r) {
    if (!animated || !st.cur) return
    var s = toShape(r)
    if (!valid(s)) return
    var dir = mid(s) >= mid(st.cur) ? 1 : -1
    st.flings.push({ t0: clock(), dur: 600, to: s, dir: dir, landed: false })
    st.runSteps = 0
    st.chainUntil = 0
    settle(0.45, 360)
    kick()
  }

  // A swell across the line that fades, for a drip landing on it or a fling
  // leaving it. It never moves the line's ends.
  function settle(amp, dur) {
    st.settleT0 = clock()
    st.settleAmp = amp
    st.settleDur = dur
  }

  // Droplets off a point. "edge" sprays forward off a leading edge, "drip" is a
  // few small ones either way. size below 1 makes it smaller: fewer droplets,
  // thrown less far, a little smaller. Past 1 it grows the same ways,
  // repeating the set with fresh jitter.
  function spray(a, c, dir, kind, size) {
    if (!splash) return
    if (size === undefined) size = 1
    var t = thickness
    var sets = {
      edge: [[6, 3.4, 0.5], [26, 3.0, 0.44], [50, 2.5, 0.38], [82, 2.0, 0.4], [-14, 1.8, 0.3], [150, 1.5, 0.3]],
      drip: [[30, 2.0, 0.34], [90, 1.6, 0.3], [150, 2.0, 0.34]],
      // All the way round, for something landing on a spot.
      burst: [[0, 3.2, 0.5], [55, 2.6, 0.42], [110, 3.0, 0.46], [170, 2.4, 0.38], [225, 3.0, 0.44], [290, 2.6, 0.4]]
    }[kind]
    var now = clock()
    // The first of each set are the forward ones, so a small splash keeps those.
    var count = Math.max(2, Math.round(sets.length * size))
    for (var i = 0; i < count; i++) {
      var d = sets[i % sets.length]
      var spread = i < sets.length ? 24 : 40
      var angle = (d[0] + (rand() - 0.5) * spread) * Math.PI / 180
      var dist = d[1] * t * (0.7 + rand() * 0.3) * (0.35 + 0.65 * size)
      st.parts.push({
        t0: now + rand() * 25 * size, life: (340 + rand() * 90) * (0.75 + 0.25 * size),
        a: a, c: c, da: Math.cos(angle) * dir * dist, dc: Math.sin(angle) * inward * dist,
        r: d[2] * t * (1.0 + rand() * 0.35) * (0.75 + 0.25 * Math.min(size, 1.3))
      })
    }
  }

  // A splash of droplets all round a point, in the parent's coordinates.
  function splashAt(x, y, size) {
    if (!animated) return
    spray(x + pad, y + pad, 1, "burst", size)
    kick()
  }

  function droplet(x, y, dx, dy, dist, r) {
    st.parts.push({
      t0: clock() + rand() * 25, life: 340 + rand() * 110,
      a: (vertical ? y : x) + pad, c: (vertical ? x : y) + pad,
      da: (vertical ? dy : dx) * dist, dc: (vertical ? dx : dy) * dist, r: r
    })
  }

  // Droplets off every side of a rect, flung outward, as from something that
  // has landed flat. In the parent's coordinates.
  function splashRect(r, size) {
    if (!animated || !splash || r.width <= 0 || r.height <= 0) return
    if (size === undefined) size = 1
    var t = thickness
    var count = Math.max(5, Math.round(11 * size))
    var around = 2 * (r.width + r.height)
    for (var i = 0; i < count; i++) {
      var d = (i + rand() * 0.7) / count * around
      var x, y, nx, ny
      if (d < r.width) { x = r.x + d; y = r.y; nx = 0; ny = -1 }
      else if (d < r.width + r.height) { x = r.x + r.width; y = r.y + d - r.width; nx = 1; ny = 0 }
      else if (d < 2 * r.width + r.height) { x = r.x + r.width - (d - r.width - r.height); y = r.y + r.height; nx = 0; ny = 1 }
      else { x = r.x; y = r.y + r.height - (d - 2 * r.width - r.height); nx = -1; ny = 0 }
      // Mostly straight out, some a little to the side.
      var turn = (rand() - 0.5) * 0.9
      var dx = nx - ny * turn, dy = ny + nx * turn
      var len = Math.sqrt(dx * dx + dy * dy)
      droplet(x, y, dx / len, dy / len, t * (0.8 + rand() * 0.7) * (0.5 + 0.5 * size), t * (0.3 + rand() * 0.18))
    }
    kick()
  }

  // Drops every impact line, the ones waiting on their delay and the ones
  // showing, for when the thing that braked is moving again.
  function clearImpacts() {
    st.parts = st.parts.filter(function(p) { return p.kind !== "dash" })
    kick()
  }

  // Cartoon impact lines off a leading edge running from (x, y0) to (x, y1),
  // for something going dir along x that has just stopped: three short dashes,
  // straight ahead and angled up and down, that shoot out and are gone. delay
  // holds them back that many ms.
  function impactLines(x, y0, y1, dir, thick, size, delay) {
    if (!animated || !splash) return
    if (size === undefined) size = 1
    var start = clock() + (delay || 0)
    var h = y1 - y0
    var lines = [[y0 + h * 0.5, 0, 1.2], [y0 + h * 0.2, -38, 0.9], [y1 - h * 0.2, 38, 0.9]]
    for (var i = 0; i < lines.length; i++) {
      var angle = lines[i][1] * Math.PI / 180
      var ux = dir * Math.cos(angle), uy = Math.sin(angle)
      st.parts.push({
        kind: "dash", t0: start, life: 240,
        a: (vertical ? lines[i][0] : x) + pad, c: (vertical ? x : lines[i][0]) + pad,
        ua: vertical ? uy : ux, uc: vertical ? ux : uy,
        gap: thick * 1.5, len: Math.max(3, h * 0.06) * lines[i][2] * size, r: thick / 2,
        rot: Math.atan2(vertical ? ux : uy, vertical ? uy : ux) * 180 / Math.PI
      })
    }
    kick()
  }

  // A move of one workspace barely splashes, and each workspace further adds
  // more, past the full set of droplets, up to five.
  function splashSize(steps) { return Math.min(1.65, 0.25 + 0.35 * (steps - 1)) }

  // Where the line is part way through a move, as shapes to draw.
  function travelShapes(tr, u, B, out) {
    var F = tr.from
    var d = tr.dir
    var t = thickness
    if (tr.kind === "follow") {
      var body = lerpShape(F, B, outCubic(u))
      out.push(body)
      return body
    }
    var lead = outCubic(u / 0.62)
    var trail = inOutCubic((u - 0.18) / 0.82)
    var s = {
      a0: lerp(F.a0, B.a0, d > 0 ? trail : lead),
      a1: lerp(F.a1, B.a1, d > 0 ? lead : trail),
      c0: 0, c1: 0
    }
    // Thinner as it stretches.
    var rest = lerp(F.a1 - F.a0, B.a1 - B.a0, u)
    var dist = Math.max(1, Math.abs(mid(B) - mid(F)))
    var thin = 1 - 0.3 * clamp((s.a1 - s.a0 - rest) / dist)
    var cross = lerp(F.c1 - F.c0, B.c1 - B.c0, u)
    cross = Math.max(Math.min(cross, t * 0.6), cross * thin)
    var cc = lerp(midC(F), midC(B), u)
    s.c0 = cc - cross / 2
    s.c1 = cc + cross / 2
    out.push(s)
    if (!tr.splashed && u >= 0.6) {
      tr.splashed = true
      spray(d > 0 ? s.a1 : s.a0, cc, d, "edge", tr.splashSize)
    }
    return s
  }

  function step() {
    var now = clock()
    st.lastT = now
    var busy = false
    var shapes = []
    var B = st.rest
    var t = thickness
    // With no line yet, only the splashes are drawn.
    var hasLine = st.shown && valid(B)

    var body = null
    if (hasLine && st.tr) {
      var u = (now - st.tr.t0) / st.tr.dur
      if (u >= 1) {
        if (st.tr.kind === "stretch") {
          st.chainUntil = now + 380
          st.chainDir = st.tr.dir
        }
        st.tr = null
      } else {
        body = travelShapes(st.tr, Math.max(0, u), B, shapes)
        busy = true
      }
    }

    if (hasLine && !st.tr) {
      body = copy(B)
      // A drip landing on the line, or a fling leaving it, swells it across
      // for a moment.
      if (st.settleT0 >= 0) {
        var sv = (now - st.settleT0) / st.settleDur
        if (sv >= 1) {
          st.settleT0 = -1
        } else {
          busy = true
          var swell = 1 + st.settleAmp * 0.7 * Math.pow(1 - sv, 3)
          var cm = midC(body), half = (body.c1 - body.c0) * swell / 2
          body.c0 = cm - half
          body.c1 = cm + half
        }
      }
      shapes.push(body)
    }
    if (body) st.cur = copy(body)
    // What it covers along the row, for lines meant to sit behind it.
    var from = body ? body.a0 - pad : -1e9
    var to = body ? body.a1 - pad : -1e9
    if (from !== coverFrom) coverFrom = from
    if (to !== coverTo) coverTo = to

    // Drips falling onto the row.
    for (var i = st.drips.length - 1; i >= 0; i--) {
      var dp = st.drips[i]
      var du = (now - dp.t0) / dp.dur
      if (du >= 1) { st.drips.splice(i, 1); continue }
      busy = true
      var lineC = midC(dp.s)
      var size2 = t * 1.35
      if (du < 0.55) {
        var fall = (du / 0.55) * (du / 0.55)
        var cpos = lineC + inward * (dropHeight + t) * (1 - fall)
        shapes.push(centered(mid(dp.s), cpos, size2 * (1 - 0.15 * fall), size2 * (1 + 0.45 * fall)))
      } else {
        if (!dp.landed) {
          dp.landed = true
          // A small splash off the line it lands on.
          splashRect(vertical ? Qt.rect(dp.s.c0 - pad, dp.s.a0 - pad, dp.s.c1 - dp.s.c0, dp.s.a1 - dp.s.a0)
                              : Qt.rect(dp.s.a0 - pad, dp.s.c0 - pad, dp.s.a1 - dp.s.a0, dp.s.c1 - dp.s.c0), 0.45)
          if (dp.onLine) {
            st.runSteps = 0
            st.chainUntil = 0
            settle(0.55, 360)
          }
        }
        if (!dp.onLine) {
          var w = (du - 0.55) / 0.45
          var len = lerp(size2, dp.s.a1 - dp.s.a0, outCubic(w))
          var cross = lerp(t * 1.2, 0, inCubic(w))
          if (cross > 0.2) shapes.push(centered(mid(dp.s), lineC, len, cross))
        }
      }
    }

    // Droplets thrown off the line.
    if (!body) st.flings = []
    for (var j = st.flings.length - 1; j >= 0; j--) {
      var fl = st.flings[j]
      var fu = (now - fl.t0) / fl.dur
      if (fu >= 1) { st.flings.splice(j, 1); continue }
      busy = true
      var size3 = t * 1.4
      var startA = fl.dir > 0 ? body.a1 - size3 / 2 : body.a0 + size3 / 2
      var endA = mid(fl.to)
      var fc = midC(body)
      if (fu < 0.16) {
        // Pinches out of the leading edge.
        shapes.push(ball(lerp(mid(body), startA + fl.dir * size3 * 0.6, outCubic(fu / 0.16)), fc, size3))
      } else if (fu < 0.8) {
        var fv = (fu - 0.16) / 0.64
        var farc = Math.sin(Math.PI * fv)
        shapes.push(centered(lerp(startA + fl.dir * size3 * 0.6, endA, inOutSine(fv)),
                             lerp(fc, midC(fl.to), fv) + inward * dropHeight * 0.8 * farc,
                             size3 * (1 + 0.4 * farc), size3 * (1 - 0.15 * farc)))
      } else {
        if (!fl.landed) {
          fl.landed = true
          spray(endA, midC(fl.to), fl.dir, "drip")
        }
        var fw = (fu - 0.8) / 0.2
        var fs = size3 * (1 - inCubic(fw))
        if (fs > 0.3) shapes.push(centered(endA, midC(fl.to), lerp(size3, (fl.to.a1 - fl.to.a0), outCubic(fw)), fs))
      }
    }

    // Splash droplets: out fast, then drawn back in as they shrink away.
    for (var k = st.parts.length - 1; k >= 0; k--) {
      var p = st.parts[k]
      var pu = (now - p.t0) / p.life
      if (pu >= 1) { st.parts.splice(k, 1); continue }
      busy = true
      if (pu < 0) continue
      if (p.kind === "dash") {
        // Shoots out from the edge, then its inner end catches up with the outer.
        var outer = p.gap + p.len * outCubic(pu / 0.45)
        var inner = p.gap + p.len * inCubic((pu - 0.3) / 0.7)
        var dash = outer - inner
        if (dash > 0.5) {
          var middle = (outer + inner) / 2
          var s1 = centered(p.a + p.ua * middle, p.c + p.uc * middle, dash, p.r * 2)
          s1.rot = p.rot
          shapes.push(s1)
        }
        continue
      }
      var out = pu < 0.35 ? outCubic(pu / 0.35) : 1 - 0.7 * inCubic((pu - 0.35) / 0.65)
      var r = p.r * (1 - Math.pow(clamp((pu - 0.15) / 0.85), 1.6))
      if (r < 0.25) continue
      var pa = p.a + p.da * out
      var pc = p.c + p.dc * out
      // Kept on the bar: past its edge the window cuts them off.
      var lo = pad + r - 2, hi = height - pad - r + 2
      if (!vertical) pc = Math.max(lo, Math.min(hi, pc))
      shapes.push(ball(pa, pc, r * 2))
    }

    draw(shapes)
    running = busy
  }

  // Lays the shapes onto the pool of rounded rectangles.
  function draw(shapes) {
    for (var i = 0; i < blobs.count; i++) {
      var b = blobs.itemAt(i)
      if (!b) continue
      if (i >= shapes.length) {
        b.visible = false
        continue
      }
      var s = shapes[i]
      if (vertical) {
        b.x = s.c0; b.y = s.a0; b.width = s.c1 - s.c0; b.height = s.a1 - s.a0
      } else {
        b.x = s.a0; b.y = s.c0; b.width = s.a1 - s.a0; b.height = s.c1 - s.c0
      }
      b.radius = Math.min(b.width, b.height) / 2
      b.rotation = s.rot || 0
      b.visible = b.width > 0.2 && b.height > 0.2
    }
  }

  FrameAnimation {
    running: root.running && root.manualTime < 0
    onTriggered: root.step()
  }
  onRunningChanged: if (running && manualTime < 0) step()

  Repeater {
    id: blobs
    model: 32

    Rectangle {
      visible: false
      color: root.color
      antialiasing: true
    }
  }
}
