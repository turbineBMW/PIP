import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Controls
import qs.Commons

// Edge-docked picture-in-picture.
//
// The PiP window (anything Hyprland tags `pip`) is kept docked against one of
// the four screen edges. While the pointer is over it, the window slides off
// past its edge and a small tab takes its place, so whatever was underneath
// can be seen and clicked without moving the PiP. The tab carries a close
// button, resize and opacity buttons, play/pause (when the PiP's player speaks MPRIS)
// and a handle: drag the handle to re-dock the PiP
// anywhere along any edge, or click it to bring the PiP back under the pointer
// until the pointer leaves (to reach the player's own controls). The resize
// button brings it back the same way, with grips on its two inner corners.
//
// Settings are inline on this plugin's entry in ~/.config/omarchy/shell.json:
//
//   { "id": "turbinebmw.pip", "margin": 10, "hideDelay": 0, "showDelay": 120,
//     "pollInterval": 33, "autoHide": true }
//
// IPC: omarchy-shell pip <toggle|peek|resize|transparency|playPause|close>
Item {
  id: root

  // Injected by the host: scoped shell facade (bar state) and our manifest.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? manifest.id : "turbinebmw.pip"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  // ---- settings ------------------------------------------------------------

  property var settings: ({})

  function setting(key, fallback) {
    var value = settings ? settings[key] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  readonly property int margin: Math.max(0, Number(setting("margin", 10)) || 0)
  readonly property int hideDelay: Math.max(0, Number(setting("hideDelay", 0)) || 0)
  readonly property int showDelay: Math.max(0, Number(setting("showDelay", 120)) || 0)
  readonly property int pollInterval: Math.max(5, Number(setting("pollInterval", 33)) || 33)
  property bool autoHide: true

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var plugins = JSON.parse(text()).plugins || []
        root.settings = plugins.find(p => p && p.id === root.pluginId) || ({})
        root.autoHide = root.setting("autoHide", true) === true
      } catch (e) {
        console.warn(root.pluginId + ": could not read settings:", e)
      }
    }
  }

  // Where the PiP was last docked, so the next one opens in the same spot.
  FileView {
    id: dockFile
    path: Color.stateHome + "/omarchy/pip-dock.json"
    blockLoading: true
    printErrors: false
    onLoaded: {
      try {
        var saved = JSON.parse(text())
        if (["left", "right", "top", "bottom"].indexOf(saved.edge) >= 0) {
          root.edge = saved.edge
          root.along = Math.max(0, Math.min(1, Number(saved.along) || 0))
          root.dockRestored = true
        }
        if (typeof saved.opacity === "number" && isFinite(saved.opacity))
          root.pipOpacity = root.clamp(saved.opacity, 0.1, 1)
        root.savedWidth = Math.max(0, Math.round(Number(saved.width) || 0))
      } catch (e) {}
    }
  }

  function saveDock() {
    dockFile.setText(JSON.stringify({ edge: root.edge, along: root.along, width: root.savedWidth, opacity: root.pipOpacity }) + "\n")
  }

  // Keep the last chosen opacity across PiP windows and shell reloads.
  property real pipOpacity: 1
  property var originalOpacity: []
  readonly property var opacityProps: ["opacity", "opacity_inactive", "opacity_override", "opacity_inactive_override", "no_blur"]

  function dispatchOpacity(values) {
    var commands = opacityProps.map((prop, i) =>
      (i === opacityProps.length - 1 ? "return " : "hl.dispatch(") + "hl.dsp.window.set_prop({ window = 'address:" + pipAddress
      + "', prop = '" + prop + "', value = '" + values[i] + "' })" + (i === opacityProps.length - 1 ? "" : ")"))
    Hyprland.dispatch("(function() " + commands.join(" ") + " end)()")
  }

  function applyOpacity() {
    if (!active || originalOpacity.length !== opacityProps.length) return
    var value = pipOpacity.toFixed(2)
    dispatchOpacity([value, value, "1", "1", pipOpacity < 1 ? "1" : originalOpacity[4]])
  }

  function clearOpacity() {
    opacityTimer.stop()
    if (active && originalOpacity.length === opacityProps.length) dispatchOpacity(originalOpacity)
    originalOpacity = []
  }

  // Read the existing active/inactive values before overriding them, so unloading
  // or losing the PiP tag can restore the window's previous appearance.
  function captureOpacity() {
    if (!active || opacityRead.running) return
    opacityRead.address = pipAddress
    opacityRead.command = ["hyprctl", "--batch", opacityProps.map(prop =>
      "getprop address:" + pipAddress + " " + prop).join(";")]
    opacityRead.running = true
  }

  Process {
    id: opacityRead
    property string address: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (opacityRead.address !== root.pipAddress) return
        var values = text.trim().split(/\s+/).map(v => v === "true" ? "1" : v === "false" ? "0" : v)
        if (values.length !== root.opacityProps.length || values.some(v => !isFinite(Number(v)))) return
        root.originalOpacity = values
        root.applyOpacity()
      }
    }
    onExited: if (root.active && address !== root.pipAddress) root.captureOpacity()
  }

  // Coalesce slider movement to one compositor update per frame.
  Timer {
    id: opacityTimer
    interval: 16
    onTriggered: root.applyOpacity()
  }

  // ---- state ---------------------------------------------------------------

  property string pipAddress: ""        // "0x…", empty while there is no PiP
  property int pipW: 0
  property int pipH: 0
  property string screenName: ""
  property int pipPid: 0
  property string pipClass: ""

  property string edge: "right"         // edge the PiP is docked to
  property real along: 0                // 0..1 position along that edge
  property bool dockRestored: false
  property int savedWidth: 0            // width chosen with the grips; 0 = the window's own

  // shown: PiP at its dock. hidden: PiP parked off-screen, tab in its place.
  // peek: PiP at its dock and immune to hover until the pointer leaves.
  // resize: peek, plus corner grips. opacity: peek, plus a live slider.
  property string mode: "shown"

  property bool dragging: false
  property string dragEdge: "right"
  property real dragAlong: 0
  property bool resizing: false         // a grip is held
  readonly property int minWidth: 160

  property int cursorX: -1
  property int cursorY: -1

  readonly property bool active: pipAddress !== ""

  readonly property var pipScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === screenName) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  // ---- geometry (global layout coordinates) --------------------------------

  readonly property var barState: shell ? shell.bar : null

  // The screen minus the bar: the PiP and its tab dock against this.
  readonly property rect usable: {
    var s = pipScreen
    if (!s) return Qt.rect(0, 0, 0, 0)
    var x = s.x, y = s.y, w = s.width, h = s.height
    var bar = barState && !barState.barHidden ? barState.barSize : 0
    var pos = barState ? barState.position : "top"
    if (bar > 0) {
      if (pos === "top") { y += bar; h -= bar }
      else if (pos === "bottom") h -= bar
      else if (pos === "left") { x += bar; w -= bar }
      else if (pos === "right") w -= bar
    }
    return Qt.rect(x, y, w, h)
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function homeRect(e, t) {
    var u = usable, m = margin
    var spanX = Math.max(0, u.width - 2 * m - pipW)
    var spanY = Math.max(0, u.height - 2 * m - pipH)
    if (e === "left") return Qt.rect(u.x + m, u.y + m + t * spanY, pipW, pipH)
    if (e === "right") return Qt.rect(u.x + u.width - m - pipW, u.y + m + t * spanY, pipW, pipH)
    if (e === "top") return Qt.rect(u.x + m + t * spanX, u.y + m, pipW, pipH)
    return Qt.rect(u.x + m + t * spanX, u.y + u.height - m - pipH, pipW, pipH)
  }

  readonly property rect home: homeRect(edge, along)

  // The dock the pointer position (px, py) asks for: nearest edge, centred on
  // the pointer along it.
  function dockAt(px, py) {
    var u = usable, m = margin
    var d = {
      left: px - u.x, right: u.x + u.width - px,
      top: py - u.y, bottom: u.y + u.height - py
    }
    var e = "left"
    for (var k in d) if (d[k] < d[e]) e = k
    var vertical = e === "left" || e === "right"
    var span = vertical ? u.height - 2 * m - pipH : u.width - 2 * m - pipW
    var start = vertical ? u.y + m : u.x + m
    var pos = (vertical ? py - pipH / 2 : px - pipW / 2) - start
    return { edge: e, along: span > 0 ? clamp(pos / span, 0, 1) : 0 }
  }

  // The rect a grip drag asks for. (sx, sy) says which corner the grip is, the
  // opposite corner (fx, fy) stays put, and the aspect ratio is kept.
  function resizeRect(sx, sy, fx, fy, px, py, aspect) {
    var u = usable, m = margin
    var availW = sx > 0 ? u.x + u.width - m - fx : fx - (u.x + m)
    var availH = sy > 0 ? u.y + u.height - m - fy : fy - (u.y + m)
    var maxW = Math.min(availW, availH * aspect)
    var w = Math.max(sx * (px - fx), sy * (py - fy) * aspect)
    w = Math.round(clamp(w, Math.min(minWidth, maxW), maxW))
    var h = Math.round(w / aspect)
    return Qt.rect(sx > 0 ? fx : fx - w, sy > 0 ? fy : fy - h, w, h)
  }

  // Take on rect r as the new dock: same edge, new size and spot along it.
  function adoptRect(r) {
    var u = usable, m = margin
    var vertical = edge === "left" || edge === "right"
    var span = vertical ? u.height - 2 * m - r.height : u.width - 2 * m - r.width
    var pos = vertical ? r.y - u.y - m : r.x - u.x - m
    pipW = r.width
    pipH = r.height
    along = span > 0 ? clamp(pos / span, 0, 1) : 0
  }

  // Off-screen parking spot for the current dock: just past the docked edge,
  // so Hyprland's move animation reads as the PiP sliding into the tab.
  function parkedRect() {
    var s = pipScreen, h = home, gap = 8
    if (edge === "left") return Qt.rect(s.x - pipW - gap, h.y, pipW, pipH)
    if (edge === "right") return Qt.rect(s.x + s.width + gap, h.y, pipW, pipH)
    if (edge === "top") return Qt.rect(h.x, s.y - pipH - gap, pipW, pipH)
    return Qt.rect(h.x, s.y + s.height + gap, pipW, pipH)
  }

  function intersects(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
  }

  // Past that edge there may be another monitor; then park clear of every
  // monitor instead, and jump rather than slide across the neighbour.
  function parking() {
    var r = parkedRect(), screens = Quickshell.screens
    var blocked = false, maxX = 0, maxY = 0
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      var sr = Qt.rect(s.x, s.y, s.width, s.height)
      if (s !== pipScreen && intersects(r, sr)) blocked = true
      maxX = Math.max(maxX, s.x + s.width)
      maxY = Math.max(maxY, s.y + s.height)
    }
    return blocked ? { x: maxX + 200, y: maxY + 200, slide: false } : { x: r.x, y: r.y, slide: true }
  }

  // The hover zone: the dock rect stretched out to the screen edge, so the
  // margin strip and the tab count as "still over the PiP".
  readonly property rect zone: {
    var h = home, u = usable
    if (edge === "left") return Qt.rect(u.x, h.y, h.x + h.width - u.x, h.height)
    if (edge === "right") return Qt.rect(h.x, h.y, u.x + u.width - h.x, h.height)
    if (edge === "top") return Qt.rect(h.x, u.y, h.width, h.y + h.height - u.y)
    return Qt.rect(h.x, h.y, h.width, u.y + u.height - h.y)
  }

  function inside(r, px, py, grow) {
    return px >= r.x - grow && px < r.x + r.width + grow && py >= r.y - grow && py < r.y + r.height + grow
  }

  // ---- media ---------------------------------------------------------------

  // The MPRIS player behind the PiP: the one whose bus name carries the
  // window's pid (Chromium-family), else one named like the window's class,
  // else whatever is playing.
  readonly property var player: {
    if (!active) return null
    var players = (Mpris.players ? Mpris.players.values : []).filter(p => p && p.canTogglePlaying)
    if (players.length === 0) return null
    var cls = pipClass.toLowerCase().replace(/[-_. ].*$/, "")
    var byPid = players.find(p => pipPid > 0 && String(p.dbusName || "").indexOf("instance" + pipPid) >= 0)
    var byName = cls === "" ? null : players.find(p =>
      [p.dbusName, p.desktopEntry, p.identity].some(n => String(n || "").toLowerCase().indexOf(cls) >= 0))
    return byPid || byName || players.find(p => p.isPlaying) || players[0]
  }

  function playPause() {
    if (player) player.togglePlaying()
  }

  // ---- Hyprland ------------------------------------------------------------

  function moveWindow(x, y, animate) {
    if (!active) return
    var win = "'address:" + pipAddress + "'"
    Hyprland.dispatch("(function() hl.dispatch(hl.dsp.window.set_prop({ window = " + win
      + ", prop = 'no_anim', value = '" + (animate ? "0" : "1") + "' })) return hl.dsp.window.move({ window = "
      + win + ", x = " + Math.round(x) + ", y = " + Math.round(y) + " }) end)()")
  }

  // Resize to pipW x pipH and sit at the dock, in one un-animated step.
  function applySize() {
    if (!active) return
    var win = "'address:" + pipAddress + "'"
    Hyprland.dispatch("(function() hl.dispatch(hl.dsp.window.set_prop({ window = " + win
      + ", prop = 'no_anim', value = '1' })) hl.dispatch(hl.dsp.window.resize({ window = " + win
      + ", x = " + pipW + ", y = " + pipH + " })) return hl.dsp.window.move({ window = " + win
      + ", x = " + Math.round(home.x) + ", y = " + Math.round(home.y) + " }) end)()")
  }

  function show(animate) {
    moveWindow(home.x, home.y, animate && parking().slide)
  }

  function hide(animate) {
    var p = parking()
    moveWindow(p.x, p.y, animate && p.slide)
  }

  function setMode(next) {
    showTimer.stop()
    hideTimer.stop()
    if (next === "hidden") hide(mode !== "hidden")
    else show(true)
    mode = next
  }

  function closePip() {
    if (active) Hyprland.dispatch("hl.dsp.window.close({ window = 'address:" + pipAddress + "' })")
  }

  function release() {
    clearOpacity()
    pipAddress = ""
    mode = "shown"
    dragging = false
    resizing = false
    showTimer.stop()
    hideTimer.stop()
  }

  function isPip(c) {
    if (!c || !c.mapped || c.hidden || !c.floating || c.fullscreen) return false
    var tags = c.tags || []
    return tags.indexOf("pip") >= 0 || tags.indexOf("pip*") >= 0
  }

  function applyClients(json) {
    var clients
    try { clients = JSON.parse(json) } catch (e) { return }
    var pips = clients.filter(isPip)
    var pip = pips.find(c => c.address === pipAddress) || pips[0]
    if (!pip) { release(); return }

    var w = pip.size[0], h = pip.size[1]
    if (pip.address !== pipAddress) {
      // Adopt: keep the remembered dock, or else the edge it opened nearest to.
      var monitors = Hyprland.monitors ? Hyprland.monitors.values : []
      var monitor = monitors.find(m => m.id === pip.monitor)
      clearOpacity()
      pipAddress = pip.address
      pipPid = pip.pid || 0
      pipClass = pip.class || pip.initialClass || ""
      screenName = monitor ? monitor.name : ""
      pipW = w
      pipH = h
      if (!dockRestored) {
        var dock = dockAt(pip.at[0] + w / 2, pip.at[1] + h / 2)
        edge = dock.edge
        along = dock.along
      }
      mode = "shown"
      captureOpacity()
      if (savedWidth > 0 && Math.abs(savedWidth - w) > 1 && w > 0 && h > 0) {
        var maxW = Math.min(usable.width - 2 * margin, (usable.height - 2 * margin) * w / h)
        pipW = Math.round(Math.min(savedWidth, maxW))
        pipH = Math.round(pipW * h / w)
        applySize()
      } else {
        show(true)
      }
      evaluate()
      return
    }

    if (dragging || resizing) return
    var resized = w !== pipW || h !== pipH
    pipW = w
    pipH = h
    if (mode === "hidden") {
      if (resized) hide(false)
      return
    }
    // Moved by hand (keyboard, Super-drag): re-dock to wherever it was left.
    if (Math.abs(pip.at[0] - home.x) > 1 || Math.abs(pip.at[1] - home.y) > 1) {
      if (!resized) {
        var moved = dockAt(pip.at[0] + w / 2, pip.at[1] + h / 2)
        edge = moved.edge
        along = moved.along
        saveDock()
      }
      show(true)
    }
  }

  Process {
    id: clientsProc
    property bool rerun: false
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.applyClients(text)
    }
    onExited: {
      if (rerun) { rerun = false; running = true }
    }
  }

  function scan() {
    if (clientsProc.running) clientsProc.rerun = true
    else clientsProc.running = true
  }

  Timer {
    id: scanDebounce
    interval: 40
    onTriggered: root.scan()
  }

  // No socket event covers moves and resizes, so re-check a live PiP now and then.
  Timer {
    interval: 1500
    repeat: true
    running: root.active && !root.dragging && !root.resizing
    onTriggered: root.scan()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name
      if (n === "openwindow" || n === "closewindow" || n === "windowtitlev2" || n === "changefloatingmode"
          || n === "fullscreen" || n === "pin" || n === "configreloaded"
          || n === "monitoraddedv2" || n === "monitorremoved") scanDebounce.restart()
    }
  }

  onUsableChanged: if (active && !dragging) { if (mode === "hidden") hide(false); else show(true) }

  Component.onCompleted: scan()
  Component.onDestruction: {
    if (active && mode === "hidden") show(false)
    clearOpacity()
  }

  // ---- pointer -------------------------------------------------------------

  Process {
    running: root.active && (root.autoHide || root.mode === "opacity")
    command: [root.pluginDir + "scripts/cursor-watch", String(root.pollInterval)]
    stdout: SplitParser {
      onRead: line => {
        var parts = line.split(" ")
        root.cursorX = parseInt(parts[0])
        root.cursorY = parseInt(parts[1])
        root.evaluate()
      }
    }
  }

  function evaluate() {
    if (!active || dragging || resizing || cursorX < 0) return
    if (mode === "opacity") {
      if (!opacitySlider.pressed && !inside(zone, cursorX, cursorY, 6)) mode = "shown"
      return
    }
    if (!autoHide) {
      if (mode !== "shown") setMode("shown")
      return
    }
    if (mode === "shown") {
      if (inside(home, cursorX, cursorY, 0)) {
        if (hideDelay === 0) setMode("hidden")
        else if (!hideTimer.running) hideTimer.start()
      } else {
        hideTimer.stop()
      }
    } else if (mode === "hidden") {
      if (inside(zone, cursorX, cursorY, 6)) showTimer.stop()
      else if (!showTimer.running) showTimer.start()
    } else if (!inside(zone, cursorX, cursorY, 6)) {
      mode = "shown" // peek or resize over: hover hides again
    }
  }

  onAutoHideChanged: evaluate()

  Timer {
    id: hideTimer
    interval: root.hideDelay
    onTriggered: if (root.mode === "shown" && root.inside(root.home, root.cursorX, root.cursorY, 0)) root.setMode("hidden")
  }

  Timer {
    id: showTimer
    interval: root.showDelay
    onTriggered: if (root.mode === "hidden" && !root.dragging) root.setMode("shown")
  }

  // ---- IPC (omarchy-shell pip <toggle|peek|close>) --------------------------

  IpcHandler {
    target: "pip"

    function toggle(): string { root.autoHide = !root.autoHide; return root.autoHide ? "on" : "off" }
    function peek(): string { if (root.active) root.setMode("peek"); return root.active ? "ok" : "no pip" }
    function resize(): string { if (root.active) root.setMode("resize"); return root.active ? "ok" : "no pip" }
    function transparency(): string { if (root.active) root.setMode("opacity"); return root.active ? "ok" : "no pip" }
    function playPause(): string { root.playPause(); return root.player ? "ok" : "no player" }
    function close(): string { root.closePip(); return root.active ? "ok" : "no pip" }
  }

  // ---- tab -----------------------------------------------------------------

  // One transparent full-screen surface; only the tab itself takes input. Being
  // full-screen keeps pointer coordinates stable while the handle is dragged.
  PanelWindow {
    id: overlay

    visible: root.active
    screen: root.pipScreen
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omarchy-pip-tab"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region {
      item: tab.shown ? tab : null
      Region { item: root.mode === "resize" ? gripA : null }
      Region { item: root.mode === "resize" ? gripB : null }
      Region { item: root.mode === "opacity" ? opacityPanel : null }
    }

    readonly property real originX: root.pipScreen ? root.pipScreen.x : 0
    readonly property real originY: root.pipScreen ? root.pipScreen.y : 0

    // Where the PiP will land if the handle is dropped now.
    Rectangle {
      id: ghost
      readonly property rect target: root.homeRect(root.dragEdge, root.dragAlong)
      visible: root.dragging
      x: target.x - overlay.originX
      y: target.y - overlay.originY
      width: target.width
      height: target.height
      radius: Style.cornerRadius
      color: Util.alpha(Color.menu.background, 0.55)
      border.width: 2
      border.color: Color.menu.text

      Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    }

    // Only this compact panel intercepts input; the video stays visible behind it.
    Rectangle {
      id: opacityPanel
      visible: root.mode === "opacity"
      x: root.home.x - overlay.originX + (root.home.width - width) / 2
      y: root.home.y - overlay.originY + (root.home.height - height) / 2
      width: Math.max(120, Math.min(260, root.home.width - 16))
      height: 68
      radius: Style.cornerRadius
      color: Color.menu.background
      border.width: 1
      border.color: Util.alpha(Color.menu.text, 0.25)

      // Absorb clicks in the panel padding instead of passing them to the player.
      MouseArea { anchors.fill: parent }

      Text {
        x: 12
        y: 8
        text: "Opacity  " + Math.round(root.pipOpacity * 100) + "%"
        color: Color.menu.text
        font.family: Style.fontFamily
        font.pixelSize: 12
      }

      Slider {
        id: opacitySlider
        x: 12
        y: 30
        width: parent.width - 24
        height: 30
        from: 0.1
        to: 1
        stepSize: 0.01
        value: root.pipOpacity
        Accessible.name: "PiP opacity"
        onMoved: {
          root.pipOpacity = value
          if (!opacityTimer.running) opacityTimer.start()
        }
        onPressedChanged: {
          if (!pressed) {
            opacityTimer.stop()
            root.applyOpacity()
            root.saveDock()
            root.evaluate()
          }
        }

        background: Rectangle {
          x: opacitySlider.leftPadding
          y: (opacitySlider.height - height) / 2
          width: opacitySlider.availableWidth
          height: 4
          radius: 2
          color: Util.alpha(Color.menu.text, 0.25)
          Rectangle {
            width: opacitySlider.visualPosition * parent.width
            height: parent.height
            radius: 2
            color: Color.menu.text
          }
        }
        handle: Rectangle {
          x: opacitySlider.leftPadding + opacitySlider.visualPosition * (opacitySlider.availableWidth - width)
          y: (opacitySlider.height - height) / 2
          width: 16
          height: 16
          radius: 8
          color: Color.menu.text
        }
      }
    }

    // Resize mode: a frame around the PiP and a grip on each inner corner.
    Rectangle {
      visible: root.mode === "resize"
      x: root.home.x - overlay.originX - 2
      y: root.home.y - overlay.originY - 2
      width: root.home.width + 4
      height: root.home.height + 4
      radius: Style.cornerRadius + 2
      color: "transparent"
      border.width: 2
      border.color: Color.menu.text
    }

    component Grip: Rectangle {
      id: grip

      // Which corner of the PiP this grip is: +1 right / bottom, -1 left / top.
      required property int sx
      required property int sy

      visible: root.mode === "resize"
      width: 22
      height: 22
      radius: 7
      x: root.home.x - overlay.originX + (sx > 0 ? root.home.width - width + 5 : -5)
      y: root.home.y - overlay.originY + (sy > 0 ? root.home.height - height + 5 : -5)
      color: gripArea.pressed ? Color.menu.text : Color.menu.background
      border.width: 2
      border.color: Color.menu.text

      Rectangle {
        anchors.centerIn: parent
        width: 8
        height: 8
        radius: 4
        color: gripArea.pressed ? Color.menu.background : Color.menu.text
      }

      MouseArea {
        id: gripArea
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: grip.sx === grip.sy ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor

        property real fixedX: 0
        property real fixedY: 0
        property real aspect: 1
        property rect pending: Qt.rect(0, 0, 0, 0)

        // Coalesce pointer motion into at most one window resize per frame.
        Timer {
          id: applyTimer
          interval: 16
          onTriggered: { root.adoptRect(gripArea.pending); root.applySize() }
        }

        onPressed: {
          var h = root.home
          fixedX = grip.sx > 0 ? h.x : h.x + h.width
          fixedY = grip.sy > 0 ? h.y : h.y + h.height
          aspect = h.height > 0 ? h.width / h.height : 16 / 9
          root.resizing = true
        }
        onPositionChanged: mouse => {
          if (!pressed || !root.resizing) return
          var p = mapToItem(null, mouse.x, mouse.y)
          pending = root.resizeRect(grip.sx, grip.sy, fixedX, fixedY,
            p.x + overlay.originX, p.y + overlay.originY, aspect)
          if (!applyTimer.running) applyTimer.start()
        }
        onReleased: finish()
        onCanceled: finish()

        function finish() {
          if (!root.resizing) return
          if (applyTimer.running) { applyTimer.stop(); root.adoptRect(pending); root.applySize() }
          root.resizing = false
          root.savedWidth = root.pipW
          root.saveDock()
          root.evaluate()
        }
      }
    }

    // Inner corners: the two away from the docked edge.
    Grip {
      id: gripA
      sx: root.edge === "right" ? -1 : 1
      sy: root.edge === "bottom" ? -1 : root.edge === "top" ? 1 : -1
    }
    Grip {
      id: gripB
      sx: root.edge === "left" ? 1 : root.edge === "right" ? -1 : -1
      sy: root.edge === "bottom" ? -1 : 1
    }

    Rectangle {
      id: tab

      readonly property string onEdge: root.dragging ? root.dragEdge : root.edge
      readonly property rect dock: root.dragging ? ghost.target : root.home
      readonly property bool vertical: onEdge === "left" || onEdge === "right"
      readonly property bool shown: root.active && (root.mode === "hidden" || root.dragging)
      readonly property int thickness: 30
      readonly property int length: root.player ? 152 : 126
      readonly property int rounding: 10

      // 0 tucked past the edge, 1 fully out.
      property real reveal: shown ? 1 : 0
      Behavior on reveal { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      readonly property real ux: root.usable.x - overlay.originX
      readonly property real uy: root.usable.y - overlay.originY

      visible: reveal > 0
      width: vertical ? thickness : length
      height: vertical ? length : thickness
      x: onEdge === "left" ? ux - width * (1 - reveal)
        : onEdge === "right" ? ux + root.usable.width - width * reveal
        : root.clamp(dock.x - overlay.originX + (dock.width - width) / 2, ux, ux + root.usable.width - width)
      y: onEdge === "top" ? uy - height * (1 - reveal)
        : onEdge === "bottom" ? uy + root.usable.height - height * reveal
        : root.clamp(dock.y - overlay.originY + (dock.height - height) / 2, uy, uy + root.usable.height - height)

      color: Color.menu.background
      border.width: 1
      border.color: Util.alpha(Color.menu.text, 0.25)
      // Square against the screen edge, rounded toward the desktop.
      topLeftRadius: onEdge === "right" || onEdge === "bottom" ? rounding : 0
      topRightRadius: onEdge === "left" || onEdge === "bottom" ? rounding : 0
      bottomLeftRadius: onEdge === "right" || onEdge === "top" ? rounding : 0
      bottomRightRadius: onEdge === "left" || onEdge === "top" ? rounding : 0

      // Close
      Rectangle {
        id: closeButton
        width: 22
        height: 22
        radius: 6
        x: tab.vertical ? (tab.width - width) / 2 : tab.width - width - 6
        y: tab.vertical ? 6 : (tab.height - height) / 2
        color: closeArea.pressed ? Util.alpha(Color.urgent, 0.9)
          : closeArea.containsMouse ? Util.alpha(Color.urgent, 0.6) : "transparent"

        Repeater {
          model: [45, -45]
          Rectangle {
            required property int modelData
            anchors.centerIn: parent
            width: 12
            height: 2
            radius: 1
            rotation: modelData
            color: Color.menu.text
            antialiasing: true
          }
        }

        MouseArea {
          id: closeArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.closePip()
        }
      }

      // Resize: bring the PiP back with its grips.
      Rectangle {
        id: resizeButton
        width: 22
        height: 22
        radius: 6
        x: tab.vertical ? (tab.width - width) / 2 : closeButton.x - width - 4
        y: tab.vertical ? closeButton.y + closeButton.height + 4 : (tab.height - height) / 2
        color: resizeArea.pressed ? Util.alpha(Color.menu.text, 0.22)
          : resizeArea.containsMouse ? Util.alpha(Color.menu.text, 0.12) : "transparent"

        // Two opposed corner brackets.
        Item {
          anchors.centerIn: parent
          width: 12
          height: 12
          Rectangle { x: 5; y: 0; width: 7; height: 2; radius: 1; color: Color.menu.text }
          Rectangle { x: 10; y: 0; width: 2; height: 7; radius: 1; color: Color.menu.text }
          Rectangle { x: 0; y: 10; width: 7; height: 2; radius: 1; color: Color.menu.text }
          Rectangle { x: 0; y: 5; width: 2; height: 7; radius: 1; color: Color.menu.text }
        }

        MouseArea {
          id: resizeArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setMode("resize")
        }
      }

      // Opacity: overlapping squares suggest seeing through the PiP.
      Rectangle {
        id: opacityButton
        width: 22
        height: 22
        radius: 6
        x: tab.vertical ? (tab.width - width) / 2 : resizeButton.x - width - 4
        y: tab.vertical ? resizeButton.y + resizeButton.height + 4 : (tab.height - height) / 2
        color: opacityArea.pressed ? Util.alpha(Color.menu.text, 0.22)
          : opacityArea.containsMouse ? Util.alpha(Color.menu.text, 0.12) : "transparent"
        Rectangle {
          x: 4; y: 4; width: 10; height: 10; radius: 2
          color: "transparent"
          border.width: 1
          border.color: Color.menu.text
        }
        Rectangle {
          x: 8; y: 8; width: 10; height: 10; radius: 2
          color: Util.alpha(Color.menu.text, 0.5)
          border.width: 1
          border.color: Color.menu.text
        }
        ToolTip.visible: opacityArea.containsMouse
        ToolTip.text: "Adjust opacity"
        ToolTip.delay: 500
        MouseArea {
          id: opacityArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setMode("opacity")
        }
      }

      // Play / pause, when the PiP's player is on MPRIS.
      Rectangle {
        id: playButton
        readonly property bool playing: root.player ? root.player.isPlaying : false
        visible: root.player !== null
        width: 22
        height: 22
        radius: 6
        x: tab.vertical ? (tab.width - width) / 2 : opacityButton.x - width - 4
        y: tab.vertical ? opacityButton.y + opacityButton.height + 4 : (tab.height - height) / 2
        color: playArea.pressed ? Util.alpha(Color.menu.text, 0.22)
          : playArea.containsMouse ? Util.alpha(Color.menu.text, 0.12) : "transparent"

        Row {
          anchors.centerIn: parent
          visible: playButton.playing
          spacing: 3
          Repeater {
            model: 2
            Rectangle { width: 3; height: 11; radius: 1; color: Color.menu.text }
          }
        }

        Canvas {
          id: playIcon
          anchors.centerIn: parent
          anchors.horizontalCenterOffset: 1
          visible: !playButton.playing
          width: 10
          height: 12
          property color fill: Color.menu.text
          onFillChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.fillStyle = fill
            ctx.beginPath()
            ctx.moveTo(0, 0)
            ctx.lineTo(width, height / 2)
            ctx.lineTo(0, height)
            ctx.closePath()
            ctx.fill()
          }
        }

        MouseArea {
          id: playArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.playPause()
        }
      }

      // Handle: drag to re-dock, click to peek.
      Rectangle {
        id: handle
        radius: 6
        x: tab.vertical ? 4 : 6
        readonly property Item lastButton: playButton.visible ? playButton : opacityButton
        y: tab.vertical ? lastButton.y + lastButton.height + 4 : 4
        width: tab.vertical ? tab.width - 8 : lastButton.x - 10
        height: tab.vertical ? tab.height - y - 6 : tab.height - 8
        color: handleArea.pressed || root.dragging ? Util.alpha(Color.menu.text, 0.22)
          : handleArea.containsMouse ? Util.alpha(Color.menu.text, 0.12) : "transparent"

        Grid {
          anchors.centerIn: parent
          columns: tab.vertical ? 2 : 3
          spacing: 4
          Repeater {
            model: 6
            Rectangle {
              width: 3
              height: 3
              radius: 1.5
              color: Util.alpha(Color.menu.text, 0.8)
            }
          }
        }

        MouseArea {
          id: handleArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          preventStealing: true

          property point pressPoint: Qt.point(0, 0)

          onPressed: mouse => pressPoint = mapToItem(null, mouse.x, mouse.y)
          onPositionChanged: mouse => {
            if (!pressed) return
            var p = mapToItem(null, mouse.x, mouse.y)
            if (!root.dragging) {
              if (Math.abs(p.x - pressPoint.x) + Math.abs(p.y - pressPoint.y) < 8) return
            }
            var dock = root.dockAt(p.x + overlay.originX, p.y + overlay.originY)
            root.dragEdge = dock.edge
            root.dragAlong = dock.along
            root.dragging = true
          }
          onReleased: {
            if (!root.dragging) { root.setMode("peek"); return }
            root.edge = root.dragEdge
            root.along = root.dragAlong
            root.dragging = false
            root.saveDock()
            // Still tucked away: re-park behind the new edge, and let the
            // pointer leaving the new spot bring the PiP out there.
            root.hide(false)
          }
          onCanceled: root.dragging = false
        }
      }
    }
  }
}
