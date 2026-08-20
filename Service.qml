import QtQuick
import Quickshell
import Quickshell.Io
import "NightlightModel.js" as NightlightModel

Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  // Keep in sync with bin/omarchy-toggle-nightlight, which sets the same
  // temperatures for callers outside the shell (keybindings, menu, ssh).
  readonly property int nightTemperature: 4000
  readonly property int dayTemperature: 6500

  property bool stateLoaded: false
  property var temperature: null
  readonly property bool enabled: stateLoaded && NightlightModel.isNightlight(temperature)

  property bool hasPendingTemperature: false
  property int pendingTemperature: 0

  // ---- Automatic scheduling. Config lives in this plugin's own shell.json
  // entry (the bar-layout slot once it's on the bar), so the bar-widget
  // panel edits it with the same updateEntryInline path every other panel
  // uses, and this service — which keeps running whether or not the panel
  // is open — just reads it back out.
  //
  // There's no separate "manual" mode any more: the night window's start
  // and end are each independently either a fixed clock time or "linked" to
  // sunset/sunrise (with a shared ramp duration for whichever edges are
  // linked), and that window always governs the temperature. The
  // Turn on/off button doesn't bypass it — it sets a temporary
  // override (forceOverride) that this same window logic still owns:
  // applySchedule() keeps re-asserting the override until the window's own
  // raw day/night state changes underneath it, at which point the override
  // is stale (the schedule moved on) and gets cleared automatically.
  readonly property var pluginEntry: NightlightModel.findPluginEntry(shell ? shell.shellConfig : null, "darksamen.nightlight")
  readonly property string scheduleStart: typeof pluginEntry.scheduleStart === "string" ? pluginEntry.scheduleStart : "20:00"
  readonly property string scheduleEnd: typeof pluginEntry.scheduleEnd === "string" ? pluginEntry.scheduleEnd : "07:00"
  readonly property bool startLinkedToSun: pluginEntry.startLinkedToSun === true
  readonly property bool endLinkedToSun: pluginEntry.endLinkedToSun === true
  readonly property int sunTransitionMinutes: NightlightModel.clampInt(pluginEntry.sunTransitionMinutes, 30, 0, 180)
  readonly property string forceOverride: pluginEntry.forceOverride === "night" || pluginEntry.forceOverride === "day" ? pluginEntry.forceOverride : ""
  readonly property bool forceBaselineNight: pluginEntry.forceBaselineNight === true

  // Reused from the weather widget's own location so sun-linked edges don't
  // ask the user to configure a place twice.
  property var location: ({ latitude: null, longitude: null })
  readonly property bool hasLocation: location.latitude !== null && location.longitude !== null
  readonly property bool needsSunTimes: startLinkedToSun || endLinkedToSun
  property var sunTimes: null
  property string sunTimesDateKey: ""
  readonly property string sunriseLabel: sunTimes ? NightlightModel.formatMinutes(sunTimes.sunriseMinutes) : "--:--"
  readonly property string sunsetLabel: sunTimes ? NightlightModel.formatMinutes(sunTimes.sunsetMinutes) : "--:--"

  function nowMinutes() {
    var d = new Date()
    return d.getHours() * 60 + d.getMinutes()
  }

  function ensureSunTimes() {
    if (!needsSunTimes || !hasLocation) return
    var todayKey = Qt.formatDate(new Date(), "yyyy-MM-dd")
    if (sunTimesDateKey === todayKey && sunTimes) return
    if (sunProcess.running) return
    sunProcess.command = ["curl", "-fsS", "--max-time", "6",
      "https://api.open-meteo.com/v1/forecast?latitude=" + encodeURIComponent(String(location.latitude)) +
      "&longitude=" + encodeURIComponent(String(location.longitude)) +
      "&daily=sunrise,sunset&forecast_days=1&timezone=auto"]
    sunProcess.running = true
  }

  function handleSunResponse(raw) {
    var parsed = NightlightModel.parseSunTimes(raw)
    if (!parsed) return
    root.sunTimes = parsed
    root.sunTimesDateKey = Qt.formatDate(new Date(), "yyyy-MM-dd")
    root.applySchedule()
  }

  // Each edge resolved to today's actual clock-time minutes: the fixed
  // setting, or today's sunset/sunrise when linked. null while a needed sun
  // time hasn't arrived yet. Takes an explicit `entry` (a single snapshot of
  // pluginEntry) rather than reading the individual startLinkedToSun/
  // scheduleStart/etc. properties directly — those are separate reactive
  // properties all derived from pluginEntry, and reading them independently
  // inside the same computation risked a torn read: on the tick where
  // pluginEntry changes, one of them could still reflect its old value while
  // another already has the new one, since QML re-evaluates and fires each
  // property's own changed signal independently rather than atomically as a
  // group. Reading everything off one `entry` object read once avoids that.
  function windowMinutesFor(entry) {
    return {
      startLinked: entry.startLinkedToSun === true,
      endLinked: entry.endLinkedToSun === true,
      startMin: entry.startLinkedToSun === true
        ? (root.sunTimes ? root.sunTimes.sunsetMinutes : null)
        : NightlightModel.minutesOfDay(typeof entry.scheduleStart === "string" ? entry.scheduleStart : "20:00"),
      endMin: entry.endLinkedToSun === true
        ? (root.sunTimes ? root.sunTimes.sunriseMinutes : null)
        : NightlightModel.minutesOfDay(typeof entry.scheduleEnd === "string" ? entry.scheduleEnd : "07:00")
    }
  }

  // Raw night/day state the window calls for right now, ignoring any ramp
  // blending and any active override — used only to tell whether the
  // schedule has moved past the point where an override was set.
  function scheduleIsNightFor(entry) {
    var w = root.windowMinutesFor(entry)
    if (w.startMin === null || w.endMin === null) return root.enabled
    return NightlightModel.inFixedWindow(root.nowMinutes(), w.startMin, w.endMin)
  }

  function persistPluginEntry(values) {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") return
    var entry = { id: "darksamen.nightlight" }
    for (var k in root.pluginEntry) if (k !== "id") entry[k] = root.pluginEntry[k]
    for (var vk in values) entry[vk] = values[vk]
    root.shell.updateEntryInline("darksamen.nightlight", entry)
  }

  function clearForce() {
    if (root.forceOverride === "") return
    root.persistPluginEntry({ forceOverride: "" })
  }

  // Applies whatever the current state calls for right now — the active
  // override if the schedule hasn't moved on since it was set, otherwise
  // the window's own (possibly ramping) target. Skips the hyprctl
  // round-trip when the target is within a few Kelvin of what's already
  // set, so the 20s poll doesn't spam it outside of an active ramp.
  function applySchedule() {
    var entry = root.pluginEntry
    var forceOverride = entry.forceOverride === "night" || entry.forceOverride === "day" ? entry.forceOverride : ""
    var forceBaselineNight = entry.forceBaselineNight === true

    if (forceOverride !== "") {
      if (root.scheduleIsNightFor(entry) !== forceBaselineNight) {
        root.clearForce()
      } else {
        var forced = forceOverride === "night" ? root.nightTemperature : root.dayTemperature
        if (root.temperature === null || Math.abs(root.temperature - forced) >= 5) root.applyTemperature(forced)
        return
      }
    }

    root.ensureSunTimes()
    var w = root.windowMinutesFor(entry)
    if (w.startMin === null || w.endMin === null) return
    var target = NightlightModel.windowTargetTemperature(root.nowMinutes(), w.startMin, w.endMin,
      w.startLinked, w.endLinked, root.sunTransitionMinutes, root.dayTemperature, root.nightTemperature)
    var rounded = Math.round(target)
    if (root.temperature === null || Math.abs(root.temperature - rounded) >= 5) root.applyTemperature(rounded)
  }

  // Single reactive trigger: pluginEntry is one atomic snapshot (a fresh
  // object on every shell.json change), so re-running here whenever it
  // changes — rather than hanging separate onXChanged handlers off each
  // derived property — is what makes applySchedule()'s reads consistent.
  //
  // Deferred via Qt.callLater rather than called straight from the signal
  // handler: applySchedule() can itself write shellConfig back out (clearing
  // a stale override), and pluginEntry is derived from shellConfig — doing
  // that write synchronously, still inside pluginEntry's own change
  // notification, is a genuine binding loop. Qt's loop guard then discards
  // the reentrant write, so the clear silently never lands and the override
  // gets stuck. Running on the next event-loop tick is a normal write.
  onPluginEntryChanged: Qt.callLater(root.reactToPluginEntryChange)

  function reactToPluginEntryChange() {
    root.ensureSunTimes()
    root.applySchedule()
  }

  Timer {
    id: scheduleTimer
    interval: 20000
    repeat: true
    triggeredOnStart: true
    running: true
    onTriggered: root.applySchedule()
  }

  Process {
    id: sunProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSunResponse(text)
    }
  }

  FileView {
    id: locationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.location = NightlightModel.parseLocationCoords(text())
      root.sunTimesDateKey = ""
      root.ensureSunTimes()
    }
  }

  function refresh() {
    if (!statusProbe.running) statusProbe.running = true
  }

  // Sets a temporary override rather than applying the temperature outright
  // — otherwise the next scheduler tick would immediately recompute the
  // window's own target and undo it. The override sticks until the window's
  // raw day/night state changes (see applySchedule/clearForce).
  function setNightlight(value) {
    root.persistPluginEntry({ forceOverride: value ? "night" : "day", forceBaselineNight: root.scheduleIsNightFor(root.pluginEntry) })
    applyTemperature(value ? nightTemperature : dayTemperature)
  }

  function toggle() {
    setNightlight(!enabled)
  }

  function applyTemperature(temp) {
    root.temperature = temp
    root.stateLoaded = true

    if (applyProcess.running) {
      root.pendingTemperature = temp
      root.hasPendingTemperature = true
      return
    }

    runApply(temp)
  }

  function runApply(temp) {
    applyProcess.command = ["bash", "-lc",
      "pgrep -x hyprsunset >/dev/null || { setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & sleep 1; }; " +
      "hyprctl hyprsunset temperature " + Number(temp)]
    applyProcess.running = true
  }

  Process {
    id: statusProbe
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.temperature = NightlightModel.temperatureFromOutput(text)
        root.stateLoaded = true
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.temperature = null
        root.stateLoaded = true
      }
    }
  }

  Process {
    id: applyProcess
    onExited: function() {
      if (root.hasPendingTemperature) {
        root.hasPendingTemperature = false
        root.runApply(root.pendingTemperature)
        return
      }

      root.refresh()
    }
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "darksamen.nightlight"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        temperature: root.temperature,
        forceOverride: root.forceOverride,
        startLinkedToSun: root.startLinkedToSun,
        endLinkedToSun: root.endLinkedToSun
      })
    }

    function refresh(): void {
      root.refresh()
    }

    function enable(): string {
      root.setNightlight(true)
      return "enabled"
    }

    function disable(): string {
      root.setNightlight(false)
      return "disabled"
    }

    function toggle(): string {
      var enabling = !root.enabled
      root.setNightlight(enabling)
      return enabling ? "enabled" : "disabled"
    }
  }
}
