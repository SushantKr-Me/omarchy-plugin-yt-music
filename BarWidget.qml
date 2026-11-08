import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "sushantkr.yt-music"

  // ------------------------------------------------------------------
  // Visualizer settings & State
  // ------------------------------------------------------------------
  property string visualizerMode: "wave" // wave, bars, dots, particles, pulse
  property bool showText: true
  property bool isMinimized: false
  property bool popupOpen: false
  property string activeTab: "search" // "search" or "queue"

  IpcHandler {
    target: "sushantkr.yt-music"
    function toggle() {
      root.popupOpen = !root.popupOpen
    }
  }

  function close() { popupOpen = false }

  // YouTube Music search & playback backend script
  readonly property string ytMusicScriptPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/plugins/sushantkr.yt-music/scripts/ytmusic.py"

  property var ytSearchResults: []
  property bool ytSearching: false
  property string ytSearchError: ""
  property string ytLastPlayedId: ""
  property string lastPlayedTitle: ""
  property string lastPlayedArtist: ""
  property string lastPlayedThumbnail: ""
  property string currentCoverUrl: ""

  // Queue state
  property var ytQueueItems: []
  property int ytQueueCurrentIndex: -1
  property bool ytQueueLoading: false
  property string ytQueueNotification: ""
  property real livePositionSec: 0

  Timer {
    id: progressTicker
    interval: 500
    running: root.isPlaying && root.popupOpen
    repeat: true
    onTriggered: {
      var rawP = Number(activePlayer ? (activePlayer.position || 0) : 0)
      if (rawP > 100000) rawP = rawP / 1000000
      if (Math.abs(rawP - root.livePositionSec) > 2.5) {
        root.livePositionSec = rawP
      } else {
        root.livePositionSec = Math.min(root.trackLength > 0 ? root.trackLength : 99999, root.livePositionSec + 0.5)
      }
      seekWave.requestPaint()
    }
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      var rawP = Number(activePlayer ? (activePlayer.position || 0) : 0)
      if (rawP > 100000) rawP = rawP / 1000000
      root.livePositionSec = rawP
      seekWave.requestPaint()
      fetchQueue()
      Qt.callLater(function() {
        if (root.activeTab === "search" && typeof searchInput !== "undefined" && searchInput) {
          searchInput.forceActiveFocus()
        }
      })
    }
  }

  readonly property var vibeSuggestions: [
    { name: "Top Hits", query: "Top Hits" },
    { name: "Lofi Beats", query: "Lofi Beats" },
    { name: "Synthwave", query: "Synthwave" },
    { name: "Chill Pop", query: "Chill Pop" },
    { name: "Rock Classics", query: "Rock Classics" },
    { name: "Piano Chill", query: "Piano Chill" }
  ]

  // ------------------------------------------------------------------
  // MPRIS Integration: Active Player Discovery
  // ------------------------------------------------------------------
  readonly property var mprisList: Mpris.players ? Mpris.players.values : []

  readonly property var activePlayer: {
    // 1. Always prioritize our ad-free mpv player instance
    for (var i = 0; i < mprisList.length; i++) {
      var p = mprisList[i]
      if (p && p.identity && p.identity.toLowerCase().indexOf("mpv") !== -1) {
        return p
      }
    }
    // 2. Fallback to any active playing player
    for (var j = 0; j < mprisList.length; j++) {
      if (mprisList[j] && mprisList[j].isPlaying) return mprisList[j]
    }
    return mprisList.length > 0 ? mprisList[0] : null
  }

  readonly property bool isPlaying: Boolean(activePlayer && activePlayer.isPlaying)
  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(isPlaying))

  readonly property string currentVideoId: {
    if (!activePlayer) return root.ytLastPlayedId
    var meta = activePlayer.metadata || {}
    var u = meta["xesam:url"] || activePlayer.url || ""
    var m = u.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/)
    if (m && m[1]) return m[1]
    return root.ytLastPlayedId
  }

  onCurrentVideoIdChanged: {
    if (currentVideoId && popupOpen) {
      fetchQueue()
    }
  }

  readonly property var currentQueueItem: {
    if (!root.currentVideoId || !root.ytQueueItems || root.ytQueueItems.length === 0) return null
    for (var i = 0; i < root.ytQueueItems.length; i++) {
      if (root.ytQueueItems[i].id === root.currentVideoId) return root.ytQueueItems[i]
    }
    return null
  }

  readonly property string rawTitle: {
    if (!activePlayer) return ""
    return (activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || "").trim()
  }

  readonly property string rawArtist: {
    if (!activePlayer) return ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    if (Array.isArray(a)) return a.join(", ")
    return String(a).trim()
  }

  readonly property string title: {
    if (currentQueueItem && currentQueueItem.title) return currentQueueItem.title
    var t = rawTitle
    if (!t || t.indexOf("watch?v=") !== -1) {
      if (root.lastPlayedTitle) return root.lastPlayedTitle
    }
    t = t.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|YouTube|YouTube Music)$/i, "")
    t = t.replace(/\.(mkv|mp4|webm|mp3|flac|wav|m4a|ogg|opus)$/i, "")
    if (rawArtist && t.toLowerCase().indexOf(rawArtist.toLowerCase() + " - ") === 0) {
      t = t.substring(rawArtist.length + 3).trim()
    }
    if (!rawArtist && t.indexOf(" - ") !== -1) {
      var parts = t.split(" - ")
      if (parts.length === 2 && parts[1].length > 1) return parts[1].trim()
    }
    return t || (root.lastPlayedTitle || "YouTube Music")
  }

  readonly property string artist: {
    if (currentQueueItem && currentQueueItem.artist) return currentQueueItem.artist
    if (rawArtist && rawArtist !== "Unknown") return rawArtist
    if (root.lastPlayedArtist) return root.lastPlayedArtist
    var t = rawTitle
    if (t && t.indexOf(" - ") !== -1) {
      var parts = t.split(" - ")
      if (parts.length === 2 && parts[0].length > 1) return parts[0].trim()
    }
    return "YouTube Music"
  }

  readonly property real trackPosition: root.livePositionSec

  readonly property real trackLength: {
    var rawLen = Number((activePlayer && activePlayer.metadata && activePlayer.metadata["mpris:length"]) || (activePlayer ? activePlayer.length : 0) || 0)
    if (rawLen > 100000) return rawLen / 1000000
    if (rawLen > 0) return rawLen
    if (currentQueueItem && currentQueueItem.duration) {
      var parts = currentQueueItem.duration.split(":")
      if (parts.length === 2) return parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10)
      if (parts.length === 3) return parseInt(parts[0], 10) * 3600 + parseInt(parts[1], 10) * 60 + parseInt(parts[2], 10)
    }
    return 0
  }

  readonly property real trackProgress: trackLength > 0 ? Math.max(0, Math.min(1, livePositionSec / trackLength)) : 0

  readonly property string artworkUrl: {
    if (currentQueueItem && currentQueueItem.thumbnail) return currentQueueItem.thumbnail
    if (root.currentCoverUrl) return root.currentCoverUrl
    if (root.currentVideoId) return "https://i.ytimg.com/vi/" + root.currentVideoId + "/hqdefault.jpg"
    if (!activePlayer) return ""
    var meta = activePlayer.metadata || {}
    var art = meta["mpris:artUrl"] || meta["xesam:artUrl"] || activePlayer.trackArtUrl || ""
    if (art) return art
    return ""
  }

  function formatTime(seconds) {
    if (!isFinite(seconds) || seconds <= 0) return "0:00"
    var m = Math.floor(seconds / 60)
    var s = Math.floor(seconds % 60)
    return m + ":" + (s < 10 ? "0" + s : s)
  }

  Process {
    id: ytSeekProc
    command: []
  }

  function seekTrack(progressRatio) {
    if (trackLength <= 0) return
    var targetSec = Math.max(0, Math.min(trackLength, progressRatio * trackLength))
    root.livePositionSec = targetSec
    seekWave.requestPaint()
    ytSeekProc.running = false
    ytSeekProc.command = ["python3", root.ytMusicScriptPath, "seek", String(Math.round(targetSec))]
    ytSeekProc.running = true
  }

  // ------------------------------------------------------------------
  // Playback Control Actions
  // ------------------------------------------------------------------
  function runAction(action) {
    if (action === "playPause") {
      if (isPlaying) {
        if (activePlayer && activePlayer.canPause) activePlayer.pause()
        else if (activePlayer && typeof activePlayer.togglePlaying === "function") activePlayer.togglePlaying()
        else {
          ytQueueOpProc.running = false
          ytQueueOpProc.command = ["python3", root.ytMusicScriptPath, "stop"]
          ytQueueOpProc.running = true
        }
      } else {
        if (activePlayer && activePlayer.canPlay) {
          activePlayer.play()
        } else if (activePlayer && activePlayer.canTogglePlaying) {
          activePlayer.togglePlaying()
        } else {
          var curIdx = 0
          if (root.ytQueueCurrentIndex >= 0) {
            curIdx = root.ytQueueCurrentIndex
          }
          playQueueIndex(curIdx)
        }
      }
    } else if (action === "next") {
      if (activePlayer && activePlayer.canGoNext) {
        activePlayer.next()
      } else {
        ytQueueOpProc.running = false
        ytQueueOpProc.command = ["python3", root.ytMusicScriptPath, "next"]
        ytQueueOpProc.running = true
      }
      Qt.callLater(function() { fetchQueue() })
    } else if (action === "previous") {
      if (activePlayer && activePlayer.canGoPrevious) {
        activePlayer.previous()
      } else {
        ytQueueOpProc.running = false
        ytQueueOpProc.command = ["python3", root.ytMusicScriptPath, "prev"]
        ytQueueOpProc.running = true
      }
      Qt.callLater(function() { fetchQueue() })
    }
  }

  // ------------------------------------------------------------------
  // PipeWire Audio Level & Equalizer Driver
  // ------------------------------------------------------------------
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var activeStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isStream && n.audio) {
        var name = (n.name || "").toLowerCase()
        if (name.indexOf("mpv") !== -1) list.push(n)
      }
    }
    if (list.length === 0) {
      for (var j = 0; j < nodes.length; j++) {
        if (nodes[j] && nodes[j].isStream && nodes[j].audio) list.push(nodes[j])
      }
    }
    return list
  }

  Instantiator {
    id: streamMonitors
    model: root.activeStreams
    delegate: PwNodePeakMonitor {
      required property var modelData
      node: modelData
      enabled: root.isPlaying
    }
  }

  readonly property real liveAudioPeak: {
    var maxP = 0
    for (var i = 0; i < streamMonitors.count; i++) {
      var obj = streamMonitors.objectAt(i)
      if (obj) maxP = Math.max(maxP, obj.peak)
    }
    return Math.max(0, Math.min(1, maxP))
  }

  property real energyFilter: 0
  readonly property real currentEnergy: isPlaying ? Math.max(0.25, Math.max(liveAudioPeak, energyFilter)) : 0

  Timer {
    interval: 50
    running: root.isPlaying
    repeat: true
    onTriggered: {
      var target = root.liveAudioPeak
      root.energyFilter = root.energyFilter * 0.7 + target * 0.3
    }
  }

  // ------------------------------------------------------------------
  // YouTube Music Search & Playback Process Handlers
  // ------------------------------------------------------------------
  function parseSearchResults(rawText) {
    root.ytSearching = false
    var cleaned = (rawText || "").trim()
    if (!cleaned) {
      root.ytSearchResults = []
      root.ytSearchError = "No response from search"
      return
    }
    try {
      var data = JSON.parse(cleaned)
      if (Array.isArray(data)) {
        root.ytSearchResults = data
        root.ytSearchError = data.length === 0 ? "No songs found" : ""
      } else if (data && data.error) {
        root.ytSearchResults = []
        root.ytSearchError = data.error
      } else {
        root.ytSearchResults = []
        root.ytSearchError = "No songs found"
      }
    } catch (e) {
      root.ytSearchResults = []
      root.ytSearchError = "Error parsing search results"
    }
  }

  Process {
    id: ytSearchProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseSearchResults(text)
      }
    }
    onExited: function(code) {
      root.ytSearching = false
      if (code !== 0 && root.ytSearchResults.length === 0 && !root.ytSearchError) {
        root.ytSearchError = "Search process exited with code " + code
      }
    }
  }

  function searchYtMusic(query) {
    var q = (query || "").trim()
    if (!q) {
      clearYtSearch()
      return
    }
    ytSearchError = ""
    ytSearching = true
    ytSearchResults = []
    ytSearchProc.running = false
    ytSearchProc.command = ["python3", root.ytMusicScriptPath, "search", q]
    ytSearchProc.running = true
  }

  Process {
    id: ytPlayProc
    command: []
  }

  function playYtMusic(item, allResults) {
    if (!item || !item.id) return
    ytLastPlayedId = item.id
    lastPlayedTitle = item.title || ""
    lastPlayedArtist = item.artist || ""
    lastPlayedThumbnail = item.thumbnail || ("https://i.ytimg.com/vi/" + item.id + "/hqdefault.jpg")
    currentCoverUrl = lastPlayedThumbnail

    // Pause all other media players so only YouTube Music plays
    for (var i = 0; i < mprisList.length; i++) {
      var other = mprisList[i]
      if (other && other.isPlaying && (!other.identity || other.identity.toLowerCase().indexOf("mpv") === -1)) {
        if (typeof other.pause === "function") other.pause()
        else if (typeof other.togglePlaying === "function") other.togglePlaying()
      }
    }

    ytPlayProc.running = false
    ytPlayProc.command = [
      "python3",
      root.ytMusicScriptPath,
      "play",
      item.id,
      item.title || "",
      item.artist || ""
    ]
    ytPlayProc.running = true

    // Schedule background queue updates
    queueRefreshTimer.restart()
  }

  function clearYtSearch() {
    ytSearchResults = []
    ytSearchError = ""
    ytSearching = false
    ytSearchProc.running = false
  }

  function openLyrics() {
    Quickshell.execDetached(["omarchy-shell", "io.github.rajesh-bandi.music-flow-lyrics", "toggle"])
  }

  // ------------------------------------------------------------------
  // Queue Management & Background Operations
  // ------------------------------------------------------------------
  function parseQueueResults(rawText) {
    root.ytQueueLoading = false
    var cleaned = (rawText || "").trim()
    if (!cleaned) return
    try {
      var data = JSON.parse(cleaned)
      if (data && Array.isArray(data.items)) {
        root.ytQueueItems = data.items
        root.ytQueueCurrentIndex = typeof data.currentIndex === "number" ? data.currentIndex : -1
      }
    } catch (e) {
      // ignore JSON parse error
    }
  }

  Process {
    id: ytQueueProc
    command: ["python3", root.ytMusicScriptPath, "get-queue"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseQueueResults(text)
      }
    }
    onExited: function(code) {
      root.ytQueueLoading = false
    }
  }

  function fetchQueue() {
    root.ytQueueLoading = true
    ytQueueProc.running = false
    ytQueueProc.running = true
  }

  Timer {
    id: queueRefreshTimer
    interval: 2200
    repeat: false
    onTriggered: root.fetchQueue()
  }

  Process {
    id: ytQueueOpProc
    command: []
    onExited: function(code) {
      root.fetchQueue()
    }
  }

  function queueYtMusic(item) {
    if (!item || !item.id) return
    ytQueueOpProc.running = false
    ytQueueOpProc.command = [
      "python3",
      root.ytMusicScriptPath,
      "queue",
      item.id,
      item.title || "",
      item.artist || "",
      item.duration || ""
    ]
    ytQueueOpProc.running = true
    root.ytQueueNotification = "Added \"" + (item.title || "Track") + "\" to queue"
    notificationTimer.restart()
  }

  function playQueueIndex(index) {
    ytQueueOpProc.running = false
    ytQueueOpProc.command = ["python3", root.ytMusicScriptPath, "play-index", String(index)]
    ytQueueOpProc.running = true
  }

  function removeQueueIndex(index) {
    ytQueueOpProc.running = false
    ytQueueOpProc.command = ["python3", root.ytMusicScriptPath, "remove-index", String(index)]
    ytQueueOpProc.running = true
  }

  function clearQueue() {
    ytQueueOpProc.running = false
    ytQueueOpProc.command = ["python3", root.ytMusicScriptPath, "clear-queue"]
    ytQueueOpProc.running = true
  }

  Timer {
    id: notificationTimer
    interval: 3200
    onTriggered: root.ytQueueNotification = ""
  }

  // ------------------------------------------------------------------
  // Bar Widget Layout & Capsule Visualizer
  // ------------------------------------------------------------------
  visible: true
  implicitWidth: pill.width + Style.space(8)
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic }
  }

  BorderSurface {
    id: pill
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    height: Math.min(parent.height - Style.space(6), Style.space(28))
    width: root.isMinimized
      ? height
      : (root.showText ? (flowRow.implicitWidth + Style.space(16)) : Style.space(110))
    radius: height / 2
    clip: true
    color: clickArea.containsMouse ? Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.06) : "transparent"
    borderSpec: Border.none()

    Behavior on width {
      NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic }
    }
    Behavior on color {
      ColorAnimation { duration: Style.duration(140) }
    }

    // Dynamic Multi-Mode Soundwave Canvas
    Canvas {
      id: waveCanvas
      anchors.fill: parent
      anchors.margins: Style.space(2)
      visible: !root.isMinimized

      property real phase: 0

      FrameAnimation {
        running: root.isPlaying
        readonly property real baseRate: (Math.PI * 2) / 2.2
        onTriggered: {
          if (frameTime <= 0 || frameTime > 1) return
          var speed = baseRate * (0.5 + root.currentEnergy * 1.5)
          var next = waveCanvas.phase + speed * frameTime
          waveCanvas.phase = next >= Math.PI * 2 ? next - Math.PI * 2 : next
        }
      }

      onPhaseChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) return

        var midY = height / 2
        var energy = root.currentEnergy
        var mode = root.visualizerMode
        var accentCol = Color.accent

        var bassPulse = Math.pow(Math.abs(Math.sin(phase * 2.5)), 3) * energy
        var swell = (0.5 + 0.5 * Math.sin(phase * 0.35)) * energy
        var intensity = 0.2 + (bassPulse * 0.5 + swell * 0.3) * energy

        if (mode === "wave") {
          var amp = height * (0.08 + energy * (0.24 + intensity * 0.16))
          ctx.lineWidth = 1.3 + bassPulse * 0.8
          ctx.strokeStyle = energy > 0.3 ? accentCol : Util.alpha(accentCol, 0.45)
          ctx.beginPath()
          for (var x = 0; x <= width; x += 3) {
            var k = (x / width) * Math.PI * 4
            var y = midY + Math.sin(k + phase * (0.8 + energy * 0.4)) * Math.cos(k * 0.5 + phase * 0.6) * amp
            if (x === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()
        } else if (mode === "bars") {
          var numBars = root.showText ? 16 : 22
          var barW = (width / numBars) * 0.45
          var gap = (width / numBars) * 0.55
          ctx.fillStyle = energy > 0.3 ? accentCol : Util.alpha(accentCol, 0.45)
          for (var b = 0; b < numBars; b++) {
            var barFreq = Math.abs(Math.sin(phase * 2.0 + b * 0.75) * Math.cos(phase * 1.2 + b * 0.35))
            var bh = (barFreq * (height * (0.15 + energy * (0.3 + intensity * 0.35))) + 2)
            var bx = b * (barW + gap) + gap / 2
            var by = midY - bh / 2
            ctx.fillRect(bx, by, barW, bh)
          }
        } else if (mode === "dots") {
          var numDots = root.showText ? 14 : 18
          var step = width / (numDots + 1)
          ctx.fillStyle = energy > 0.3 ? accentCol : Util.alpha(accentCol, 0.45)
          for (var d = 1; d <= numDots; d++) {
            var dx = d * step
            var dotOsc = Math.sin(phase * 2.0 + d * 0.6)
            var dy = midY + dotOsc * (height * (0.08 + energy * (0.18 + intensity * 0.16)))
            var r = (1.5 + (bassPulse * 1.0) + (energy * 0.8))
            ctx.beginPath()
            ctx.arc(dx, dy, r, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "particles") {
          var numParts = root.showText ? 12 : 16
          for (var pIdx = 0; pIdx < numParts; pIdx++) {
            var px = ((pIdx * 28 + (phase / (Math.PI * 2)) * width * (0.6 + energy * 0.6)) % width)
            var py = midY + Math.sin(px * 0.08 + phase + pIdx) * (height * (0.08 + energy * (0.2 + intensity * 0.15)))
            ctx.fillStyle = (pIdx % 2 === 0) ? (energy > 0.3 ? accentCol : Util.alpha(accentCol, 0.45)) : (root.bar ? root.bar.barForeground : Color.foreground)
            ctx.beginPath()
            ctx.arc(px, py, 1.4 + energy * 0.8 + bassPulse * 0.6, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "pulse") {
          var pulseScale = 0.25 + energy * (0.35 + intensity * 0.4)
          var grad = ctx.createRadialGradient(width / 2, midY, 2, width / 2, midY, (width / 2) * pulseScale)
          grad.addColorStop(0, energy > 0.3 ? accentCol : Util.alpha(accentCol, 0.3))
          grad.addColorStop(1, "transparent")
          ctx.fillStyle = grad
          ctx.fillRect(0, 0, width, height)
        }
      }
    }

    // Minimized View
    Item {
      anchors.fill: parent
      visible: root.isMinimized

      Text {
        anchors.centerIn: parent
        text: "󰗃"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }

    // Pure Visualizer View
    Item {
      anchors.fill: parent
      visible: !root.isMinimized && !root.showText

      Text {
        anchors.centerIn: parent
        text: "󰗃"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }

    // Expanded View: YouTube Music icon + Song title
    Row {
      id: flowRow
      anchors.centerIn: parent
      spacing: Style.space(7)
      visible: !root.isMinimized && root.showText

      Text {
        id: barIcon
        anchors.verticalCenter: parent.verticalCenter
        text: "󰗃"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Item {
        id: scrollClip
        width: root.hasMedia ? Math.min(Style.space(200), titleRow.implicitWidth) : idleLabel.implicitWidth
        height: Math.max(barIcon.implicitHeight, Style.space(16))
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.bar || !root.bar.vertical

        Text {
          id: idleLabel
          visible: !root.hasMedia
          text: "YT Music"
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: titleRow
          visible: root.hasMedia
          spacing: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter

          readonly property bool needsScroll: implicitWidth > scrollClip.width

          Text {
            id: mainText
            text: root.title + (root.artist ? " — " + root.artist : "")
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            visible: titleRow.needsScroll
            text: mainText.text
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          NumberAnimation on x {
            id: marqueeAnimation
            running: titleRow.needsScroll && !root.popupOpen && root.hasMedia && !root.isMinimized && root.showText
            from: 0
            to: -(mainText.implicitWidth + titleRow.spacing)
            duration: Math.max(2500, mainText.implicitWidth * 32)
            loops: Animation.Infinite
          }
        }
      }
    }

    // Bar capsule interaction area
    MouseArea {
      id: clickArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

      onClicked: function(mouse) {
        if (mouse.button === Qt.LeftButton) {
          root.popupOpen = !root.popupOpen
        } else if (mouse.button === Qt.MiddleButton) {
          root.runAction("playPause")
        } else if (mouse.button === Qt.RightButton) {
          root.showText = !root.showText
        }
      }

      onWheel: function(wheel) {
        if (wheel.angleDelta.y > 0) root.runAction("previous")
        else if (wheel.angleDelta.y < 0) root.runAction("next")
      }

      onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? (root.title + (root.artist ? " — " + root.artist : "")) : "YouTube Music (Ad-free)")
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  // ------------------------------------------------------------------
  // Floating YouTube Music Player & Queue Window
  // ------------------------------------------------------------------
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    centerOnBar: false
    focusTarget: searchInput
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(mainCol.implicitHeight)

    Column {
      id: mainCol
      anchors.fill: parent
      spacing: Style.space(12)

      // Top Row: Album Cover Artwork & Track Metadata
      Row {
        spacing: Style.space(12)
        width: parent.width

        BorderSurface {
          width: Style.space(88)
          height: Style.space(88)
          radius: Style.spacing.labelGap
          color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)
          borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)

          Image {
            id: artworkImg
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            autoTransform: true
            sourceSize.width: Style.space(176)
            sourceSize.height: Style.space(176)
            source: root.artworkUrl
            visible: source !== "" && status === Image.Ready
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
          }

          Text {
            anchors.centerIn: parent
            visible: artworkImg.status !== Image.Ready
            text: "󰗃"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(3)
          width: parent.width - Style.space(100)
          anchors.verticalCenter: parent.verticalCenter

          // YouTube Music & Ad-Free Badge
          Row {
            spacing: Style.space(6)
            anchors.left: parent.left

            Text {
              text: "󰗃"
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: "YOUTUBE MUSIC"
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            BorderSurface {
              radius: Style.space(3)
              color: Util.alpha(Color.accent, 0.14)
              width: noAdsTxt.implicitWidth + Style.space(8)
              height: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: noAdsTxt
                anchors.centerIn: parent
                text: "NO ADS"
                textFormat: Text.PlainText
                color: Color.accent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption - 2
                font.bold: true
              }
            }
          }

          Text {
            text: root.title || "Ready to play"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.artist || "Search any song or album below"
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }

      // Playback Controls
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)

        Button {
          iconText: "󰒮"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer || (root.ytQueueItems && root.ytQueueItems.length > 0))
          onClicked: root.runAction("previous")
        }

        Button {
          iconText: root.isPlaying ? "󰏤" : "󰐊"
          foreground: Color.accent
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: Boolean(root.activePlayer || (root.ytQueueItems && root.ytQueueItems.length > 0))
          onClicked: root.runAction("playPause")
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer || (root.ytQueueItems && root.ytQueueItems.length > 0))
          onClicked: root.runAction("next")
        }

        Button {
          iconText: "󰏉"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer && root.title)
          onClicked: root.openLyrics()
        }
      }

      // Interactive Waveform Seek Control
      Column {
        width: parent.width
        spacing: Style.space(3)
        visible: root.hasMedia

        Item {
          width: parent.width
          height: Style.space(16)
          Text {
            text: root.formatTime(root.livePositionSec)
            anchors.left: parent.left
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            text: root.trackLength > 0 ? ("-" + root.formatTime(Math.max(0, root.trackLength - root.livePositionSec))) : "--:--"
            anchors.right: parent.right
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Canvas {
          id: seekWave
          width: parent.width
          height: Style.space(22)
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var bars = 48
            var gap = width / bars
            for (var i = 0; i < bars; i++) {
              var level = 0.2 + 0.8 * Math.abs(Math.sin(i * 1.73 + 0.6))
              var h = height * (0.2 + level * 0.65)
              ctx.fillStyle = i / bars <= root.trackProgress
                ? Color.accent
                : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.22)
              ctx.fillRect(i * gap, (height - h) / 2, Math.max(1, gap - 1), h)
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) {
              root.seekTrack(Math.max(0, Math.min(1, mouse.x / width)))
            }
          }
        }

        Connections {
          target: root
          function onTrackProgressChanged() { seekWave.requestPaint() }
        }
      }

      // Visualizer Flow & Words Mode Switcher
      Flow {
        width: parent.width
        spacing: Style.space(6)

        Row {
          spacing: Style.space(4)
          Repeater {
            model: [
              { id: "wave", name: "Wave", icon: "󰎆" },
              { id: "bars", name: "Bars", icon: "󰝛" },
              { id: "dots", name: "Dots", icon: "󰄰" },
              { id: "particles", name: "Sparks", icon: "󰠱" },
              { id: "pulse", name: "Pulse", icon: "󰓎" }
            ]

            BorderSurface {
              id: modeBtn
              required property var modelData
              readonly property bool isSelected: root.visualizerMode === modelData.id
              property bool hovered: false

              width: modeBtnLabel.implicitWidth + Style.space(16)
              height: Style.space(24)
              radius: Style.spacing.labelGap
              color: isSelected
                ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : (modeBtn.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
              borderSpec: isSelected
                ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : Border.none()

              Row {
                id: modeBtnLabel
                anchors.centerIn: parent
                spacing: Style.space(2)
                Text {
                  text: modeBtn.modelData.icon
                  textFormat: Text.PlainText
                  color: modeBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: modeBtn.modelData.name
                  textFormat: Text.PlainText
                  color: modeBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: modeBtn.isSelected
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: modeBtn.hovered = true
                onExited: modeBtn.hovered = false
                onClicked: {
                  root.visualizerMode = modeBtn.modelData.id
                  waveCanvas.requestPaint()
                }
              }
            }
          }
        }

        BorderSurface {
          id: textToggleBtn
          width: textToggleLabel.implicitWidth + Style.space(16)
          height: Style.space(24)
          radius: Style.spacing.labelGap
          color: root.showText
            ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : (toggleMouse.containsMouse ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
          borderSpec: root.showText
            ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : Border.none()

          Row {
            id: textToggleLabel
            anchors.centerIn: parent
            spacing: Style.space(3)
            Text {
              text: root.showText ? "󰈈" : "󰈉"
              textFormat: Text.PlainText
              color: root.showText ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.showText ? "Words ON" : "Pure Flow"
              textFormat: Text.PlainText
              color: root.showText ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: root.showText
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            id: toggleMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showText = !root.showText
          }
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      // ----------------------------------------------------------------
      // Tab Selector: [ 󰍉 Search ] vs [ 󰒭 Up Next (Queue) ]
      // ----------------------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(8)

        BorderSurface {
          id: searchTabBtn
          width: (parent.width - Style.space(8)) / 2
          height: Style.space(28)
          radius: Style.spacing.labelGap
          readonly property bool isSelected: root.activeTab === "search"
          property bool hovered: false

          color: isSelected
            ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : (hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
          borderSpec: isSelected
            ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : Border.none()

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)
            Text {
              text: "󰍉"
              textFormat: Text.PlainText
              color: searchTabBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "Search"
              textFormat: Text.PlainText
              color: searchTabBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: searchTabBtn.isSelected
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: searchTabBtn.hovered = true
            onExited: searchTabBtn.hovered = false
            onClicked: {
              root.activeTab = "search"
              Qt.callLater(function() {
                if (typeof searchInput !== "undefined" && searchInput) {
                  searchInput.forceActiveFocus()
                }
              })
            }
          }
        }

        BorderSurface {
          id: queueTabBtn
          width: (parent.width - Style.space(8)) / 2
          height: Style.space(28)
          radius: Style.spacing.labelGap
          readonly property bool isSelected: root.activeTab === "queue"
          property bool hovered: false

          color: isSelected
            ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : (hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
          borderSpec: isSelected
            ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
            : Border.none()

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)
            Text {
              text: "󰒭"
              textFormat: Text.PlainText
              color: queueTabBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "Up Next" + (root.ytQueueItems.length > 0 ? " (" + root.ytQueueItems.length + ")" : "")
              textFormat: Text.PlainText
              color: queueTabBtn.isSelected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: queueTabBtn.isSelected
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: queueTabBtn.hovered = true
            onExited: queueTabBtn.hovered = false
            onClicked: {
              root.activeTab = "queue"
              root.fetchQueue()
            }
          }
        }
      }

      // Notification / Queue Banner Toast
      BorderSurface {
        width: parent.width
        height: Style.space(26)
        radius: Style.spacing.labelGap
        color: Util.alpha(Color.accent, 0.14)
        borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
        visible: root.ytQueueNotification !== ""

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "󰄬"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.ytQueueNotification
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "• View Up Next"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.underline: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.activeTab = "queue"
            root.fetchQueue()
            root.ytQueueNotification = ""
          }
        }
      }

      // ----------------------------------------------------------------
      // VIEW A: YouTube Music Search
      // ----------------------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.activeTab === "search"

        // Search Section Header
        Item {
          width: parent.width
          height: searchLabelRow.implicitHeight

          Row {
            id: searchLabelRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              text: "󰍉"
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: "SEARCH YOUTUBE MUSIC"
              textFormat: Text.PlainText
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Clear Button
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.ytSearchResults.length > 0 || searchInput.text !== ""
            text: "󰅖 Clear"
            textFormat: Text.PlainText
            color: clearMouse.containsMouse ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption

            MouseArea {
              id: clearMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                searchInput.text = ""
                root.clearYtSearch()
              }
            }
          }
        }

        // Search Bar Input Field & Action Button
        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: searchInput
            width: parent.width - searchSubmitBtn.width - Style.space(6)
            placeholderText: "Search songs, artists, or paste YouTube link..."
            foreground: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            selectByMouse: true
            focus: true
            anchors.verticalCenter: parent.verticalCenter
            onAccepted: {
              var q = text.trim()
              if (!q) q = "Top Hits"
              root.searchYtMusic(q)
            }
          }

          Button {
            id: searchSubmitBtn
            iconText: root.ytSearching ? "󰑮" : "󰍉"
            foreground: Color.accent
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            enabled: !root.ytSearching
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
              var q = searchInput.text.trim()
              if (!q) q = "Top Hits"
              root.searchYtMusic(q)
            }
          }
        }

        // Quick Vibe Chips (when idle or search results empty)
        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.ytSearchResults.length === 0 && !root.ytSearching

          Repeater {
            model: root.vibeSuggestions

            BorderSurface {
              id: vibeChip
              required property var modelData
              required property int index
              property bool hovered: false

              width: chipTxt.implicitWidth + Style.space(16)
              height: Style.space(24)
              radius: Style.spacing.labelGap
              color: vibeChip.hovered
                ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.06)
              borderSpec: vibeChip.hovered
                ? Border.controlSpec("hover-cursor", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : Border.none()

              Text {
                id: chipTxt
                anchors.centerIn: parent
                text: (vibeChip.modelData && vibeChip.modelData.name) || ""
                textFormat: Text.PlainText
                color: vibeChip.hovered ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.25)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: vibeChip.hovered = true
                onExited: vibeChip.hovered = false
                onClicked: {
                  var q = vibeChip.modelData.query || vibeChip.modelData.name
                  searchInput.text = q
                  searchInput.forceActiveFocus()
                  root.searchYtMusic(q)
                }
              }
            }
          }
        }

        // Searching Spinner / Status
        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.ytSearching

          Text {
            text: "󰑮"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 900
              loops: Animation.Infinite
              running: root.ytSearching
            }
          }

          Text {
            text: "Searching ad-free YouTube Music..."
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Search Error Message
        Text {
          visible: !root.ytSearching && root.ytSearchError !== ""
          text: root.ytSearchError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
        }

        // Search Results List
        Column {
          id: resultsCol
          width: parent.width
          spacing: Style.space(4)
          visible: root.ytSearchResults.length > 0

          Repeater {
            model: root.ytSearchResults

            BorderSurface {
              id: resCard
              required property var modelData
              required property int index

              readonly property bool isCurrent: root.ytLastPlayedId === modelData.id && root.isPlaying
              property bool hovered: false

              width: parent.width
              height: Style.space(44)
              radius: Style.spacing.labelGap
              color: isCurrent
                ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : (resCard.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
              borderSpec: isCurrent
                ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : (resCard.hovered ? Border.controlSpec("hover-cursor", root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Border.none())

              Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                // Track Thumbnail
                BorderSurface {
                  width: Style.space(32)
                  height: Style.space(32)
                  radius: Style.space(4)
                  clip: true
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)

                  Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    source: resCard.modelData.thumbnail || ""
                    asynchronous: true
                    sourceSize.width: Style.space(64)
                    sourceSize.height: Style.space(64)
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !resCard.modelData.thumbnail
                    text: "󰗃"
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // Title & Artist
                Column {
                  width: parent.width - Style.space(110)
                  spacing: Style.space(1)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: resCard.modelData.title || ""
                    textFormat: Text.PlainText
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: resCard.isCurrent
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    text: (resCard.modelData.artist || "YouTube") + (resCard.modelData.duration ? " • " + resCard.modelData.duration : "")
                    textFormat: Text.PlainText
                    color: resCard.isCurrent ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                // Action Buttons: [ + Queue ] and [ Play ]
                Row {
                  spacing: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter

                  // Add to Queue Button
                  BorderSurface {
                    id: addQueueBtn
                    width: Style.space(26)
                    height: Style.space(26)
                    radius: Style.space(13)
                    property bool btnHovered: false
                    color: btnHovered ? Util.alpha(Color.accent, 0.22) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)

                    Text {
                      anchors.centerIn: parent
                      text: "󰐕"
                      textFormat: Text.PlainText
                      color: addQueueBtn.btnHovered ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: addQueueBtn.btnHovered = true
                      onExited: addQueueBtn.btnHovered = false
                      onClicked: {
                        root.queueYtMusic(resCard.modelData)
                      }
                    }
                  }

                  // Play Button Icon
                  BorderSurface {
                    id: playCardBtn
                    width: Style.space(26)
                    height: Style.space(26)
                    radius: Style.space(13)
                    property bool playHovered: false
                    color: playHovered ? Util.alpha(Color.accent, 0.22) : (resCard.isCurrent ? Util.alpha(Color.accent, 0.16) : "transparent")

                    Text {
                      anchors.centerIn: parent
                      text: resCard.isCurrent ? "󰏤" : "󰐊"
                      textFormat: Text.PlainText
                      color: resCard.isCurrent ? Color.accent : (playCardBtn.playHovered ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4))
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: playCardBtn.playHovered = true
                      onExited: playCardBtn.playHovered = false
                      onClicked: {
                        if (resCard.isCurrent) {
                          root.runAction("playPause")
                        } else {
                          root.playYtMusic(resCard.modelData, root.ytSearchResults)
                        }
                      }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                z: -1
                onEntered: resCard.hovered = true
                onExited: resCard.hovered = false
                onClicked: {
                  if (resCard.isCurrent) {
                    root.runAction("playPause")
                  } else {
                    root.playYtMusic(resCard.modelData, root.ytSearchResults)
                  }
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------------------
      // VIEW B: Up Next (Queue / YouTube Music Radio Automix)
      // ----------------------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.activeTab === "queue"

        // Queue Header Controls
        Item {
          width: parent.width
          height: queueHeaderRow.implicitHeight

          Row {
            id: queueHeaderRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              text: "󰒭"
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: "UP NEXT (AUTOMIX RADIO)"
              textFormat: Text.PlainText
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            // Refresh Queue Button
            Text {
              text: root.ytQueueLoading ? "󰑮 Refreshing..." : "󰑐 Refresh"
              textFormat: Text.PlainText
              color: refreshQueueMouse.containsMouse ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption

              MouseArea {
                id: refreshQueueMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.fetchQueue()
              }
            }

            // Clear Queue Button
            Text {
              visible: root.ytQueueItems.length > 1
              text: "󰅖 Clear Queue"
              textFormat: Text.PlainText
              color: clearQueueMouse.containsMouse ? Color.accent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption

              MouseArea {
                id: clearQueueMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clearQueue()
              }
            }
          }
        }

        // Empty Queue State
        Item {
          width: parent.width
          height: Style.space(80)
          visible: !root.ytQueueLoading && root.ytQueueItems.length === 0

          Column {
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰒭"
              textFormat: Text.PlainText
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.space(22)
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Queue is empty. Play or search a song to start radio."
              textFormat: Text.PlainText
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Queue Items List
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.ytQueueItems.length > 0

          Repeater {
            model: root.ytQueueItems

            BorderSurface {
              id: queueCard
              required property var modelData
              required property int index

              readonly property bool isCurrent: Boolean(queueCard.modelData && queueCard.modelData.current)
              property bool hovered: false

              width: parent.width
              height: Style.space(44)
              radius: Style.spacing.labelGap
              color: isCurrent
                ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : (queueCard.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
              borderSpec: isCurrent
                ? Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                : (queueCard.hovered ? Border.controlSpec("hover-cursor", root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Border.none())

              Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                // Index or Current Playing Indicator
                Item {
                  width: Style.space(20)
                  height: Style.space(20)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    anchors.centerIn: parent
                    visible: !queueCard.isCurrent
                    text: String(queueCard.index + 1)
                    textFormat: Text.PlainText
                    color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: queueCard.isCurrent
                    text: root.isPlaying ? "󰏤" : "󰐊"
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // Thumbnail
                BorderSurface {
                  width: Style.space(32)
                  height: Style.space(32)
                  radius: Style.space(4)
                  clip: true
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)

                  Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    source: queueCard.modelData.thumbnail || ""
                    asynchronous: true
                    sourceSize.width: Style.space(64)
                    sourceSize.height: Style.space(64)
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !queueCard.modelData.thumbnail
                    text: "󰗃"
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // Title & Artist
                Column {
                  width: parent.width - Style.space(110)
                  spacing: Style.space(1)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: queueCard.modelData.title || ""
                    textFormat: Text.PlainText
                    color: queueCard.isCurrent ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: queueCard.isCurrent
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    text: (queueCard.modelData.artist || "YouTube Music") + (queueCard.modelData.duration ? " • " + queueCard.modelData.duration : "")
                    textFormat: Text.PlainText
                    color: queueCard.isCurrent ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                // Status or Remove Button
                Item {
                  width: Style.space(44)
                  height: Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter

                  // "NOW PLAYING" badge if current
                  BorderSurface {
                    anchors.centerIn: parent
                    visible: queueCard.isCurrent
                    radius: Style.space(3)
                    color: Util.alpha(Color.accent, 0.16)
                    width: nowPlayingTxt.implicitWidth + Style.space(8)
                    height: Style.space(16)

                    Text {
                      id: nowPlayingTxt
                      anchors.centerIn: parent
                      text: "PLAYING"
                      textFormat: Text.PlainText
                      color: Color.accent
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption - 3
                      font.bold: true
                    }
                  }

                  // Remove from queue button (when not current)
                  BorderSurface {
                    id: removeQueueBtn
                    anchors.centerIn: parent
                    visible: !queueCard.isCurrent && queueCard.hovered
                    width: Style.space(24)
                    height: Style.space(24)
                    radius: Style.space(12)
                    property bool removeHovered: false
                    color: removeHovered ? Util.alpha(Color.urgent, 0.2) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)

                    Text {
                      anchors.centerIn: parent
                      text: "󰅖"
                      textFormat: Text.PlainText
                      color: removeQueueBtn.removeHovered ? Color.urgent : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: removeQueueBtn.removeHovered = true
                      onExited: removeQueueBtn.removeHovered = false
                      onClicked: {
                        root.removeQueueIndex(queueCard.modelData.index)
                      }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                z: -1
                onEntered: queueCard.hovered = true
                onExited: queueCard.hovered = false
                onClicked: {
                  if (queueCard.isCurrent) {
                    root.runAction("playPause")
                  } else {
                    root.playQueueIndex(queueCard.modelData.index)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
