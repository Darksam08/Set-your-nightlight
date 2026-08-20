// Temperatures below the identity point count as night light. Keep in sync
// with bin/omarchy-toggle-nightlight, which applies the same threshold.
var IDENTITY_TEMPERATURE = 6000

function temperatureFromOutput(output) {
  var match = String(output === undefined || output === null ? "" : output).match(/[0-9]+/)
  return match ? Number(match[0]) : null
}

function isNightlight(temperature) {
  return temperature !== null && temperature !== undefined && temperature < IDENTITY_TEMPERATURE
}

// ---- Automatic scheduling (fixed period or sunrise/sunset) ---------------

function pad2(n) {
  var v = Math.floor(n)
  return (v < 10 ? "0" : "") + v
}

// "HH:MM" -> minutes since midnight, or null if unparseable.
function minutesOfDay(hhmm) {
  var match = String(hhmm === undefined || hhmm === null ? "" : hhmm).match(/^([0-2]?[0-9]):([0-5][0-9])$/)
  if (!match) return null
  var hour = Number(match[1])
  if (hour > 23) return null
  return hour * 60 + Number(match[2])
}

// Minutes since midnight -> "HH:MM", wrapping into a single day.
function formatMinutes(totalMinutes) {
  var wrapped = ((Math.round(totalMinutes) % 1440) + 1440) % 1440
  return pad2(Math.floor(wrapped / 60)) + ":" + pad2(wrapped % 60)
}

// Loose "H:M"/"HH:MM" text (as typed into a masked HH:mm field, where each
// half can be any 1-2 digit number) -> a clamped, zero-padded "HH:MM", or
// null when the text isn't two colon-separated numbers at all (e.g. the
// mask's blank placeholders are still showing). Unlike minutesOfDay, this
// clamps out-of-range input (25:99 -> 23:59) instead of rejecting it, since
// it's validating a field the user is actively typing into.
function clampTimeText(text) {
  var match = String(text || "").match(/^(\d{1,2}):(\d{1,2})$/)
  if (!match) return null
  var hour = Math.max(0, Math.min(23, parseInt(match[1], 10)))
  var minute = Math.max(0, Math.min(59, parseInt(match[2], 10)))
  return formatMinutes(hour * 60 + minute)
}

// Whether `nowMin` falls in [startMin, endMin), wrapping past midnight when
// startMin > endMin (e.g. 20:00 -> 07:00 covers the overnight stretch).
function inFixedWindow(nowMin, startMin, endMin) {
  if (startMin === endMin) return false
  if (startMin < endMin) return nowMin >= startMin && nowMin < endMin
  return nowMin >= startMin || nowMin < endMin
}

function lerp(a, b, t) {
  var clamped = Math.max(0, Math.min(1, t))
  return a + (b - a) * clamped
}

// Target temperature for a night window whose start and/or end can each
// independently be a hard cut (startRamp/endRamp false) or a sunrise/sunset
// -style ramp (true) — the merged fixed-period/sun-based model, where each
// edge of the period is set separately to a fixed clock time or "linked" to
// the sun. A ramp starts exactly at its edge's time and runs `transitionMin`
// minutes; a non-ramped edge switches instantly. `startMin`/`endMin` are
// already resolved to the right clock time for the edge (the fixed time, or
// today's sunset/sunrise) by the caller.
function windowTargetTemperature(nowMin, startMin, endMin, startRamp, endRamp, transitionMin, dayTemp, nightTemp) {
  var span = Math.max(0, transitionMin)

  function elapsedSince(edgeMin) {
    return ((nowMin - edgeMin) + 1440) % 1440
  }

  if (startRamp && span > 0 && elapsedSince(startMin) < span)
    return lerp(dayTemp, nightTemp, elapsedSince(startMin) / span)
  if (endRamp && span > 0 && elapsedSince(endMin) < span)
    return lerp(nightTemp, dayTemp, elapsedSince(endMin) / span)

  // Past both ramps (or no ramp at all): the window is [start, end) with a
  // ramped start's zone stretched past its own transition.
  var effectiveStart = startRamp ? (startMin + span) % 1440 : startMin
  return inFixedWindow(nowMin, effectiveStart, endMin) ? nightTemp : dayTemp
}

// Open-Meteo forecast response (daily=sunrise,sunset&timezone=auto) ->
// {sunriseMinutes, sunsetMinutes}. Reads the HH:MM directly out of the
// ISO-ish local timestamp rather than parsing it as a Date, so no timezone
// conversion happens between the API's "local to the coordinates" time and
// the system clock the panel compares it against.
function parseSunTimes(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var daily = data && data.daily
    if (!daily || !daily.sunrise || !daily.sunrise[0] || !daily.sunset || !daily.sunset[0]) return null
    var sunrise = minutesOfDay(String(daily.sunrise[0]).slice(11, 16))
    var sunset = minutesOfDay(String(daily.sunset[0]).slice(11, 16))
    if (sunrise === null || sunset === null) return null
    return { sunriseMinutes: sunrise, sunsetMinutes: sunset }
  } catch (e) {
    return null
  }
}

// weather.json (owned by omarchy-weather-location) -> {latitude, longitude},
// nulls when unset so sun mode can prompt for a location instead of guessing.
function parseLocationCoords(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var lat = parseFloat(data && data.latitude)
    var lon = parseFloat(data && data.longitude)
    if (isNaN(lat) || isNaN(lon)) return { latitude: null, longitude: null }
    return { latitude: lat, longitude: lon }
  } catch (e) {
    return { latitude: null, longitude: null }
  }
}

// Finds this plugin's own config entry in shell.json — a bar-layout slot
// once it's on the bar, falling back to the top-level plugins entry
// (pre-placement, or if it's ever removed from the bar but kept enabled).
function findPluginEntry(shellConfig, pluginId) {
  if (!shellConfig) return {}
  var layout = shellConfig.bar && shellConfig.bar.layout ? shellConfig.bar.layout : {}
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var arr = layout[sections[s]]
    if (!Array.isArray(arr)) continue
    for (var i = 0; i < arr.length; i++) {
      if (arr[i] && arr[i].id === pluginId) return arr[i]
    }
  }
  var plugins = Array.isArray(shellConfig.plugins) ? shellConfig.plugins : []
  for (var j = 0; j < plugins.length; j++) {
    if (plugins[j] && plugins[j].id === pluginId) return plugins[j]
  }
  return {}
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10)
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    IDENTITY_TEMPERATURE: IDENTITY_TEMPERATURE,
    temperatureFromOutput: temperatureFromOutput,
    isNightlight: isNightlight,
    minutesOfDay: minutesOfDay,
    formatMinutes: formatMinutes,
    clampTimeText: clampTimeText,
    inFixedWindow: inFixedWindow,
    lerp: lerp,
    windowTargetTemperature: windowTargetTemperature,
    parseSunTimes: parseSunTimes,
    parseLocationCoords: parseLocationCoords,
    findPluginEntry: findPluginEntry,
    clampInt: clampInt
  }
}
