// Formatting and parsing helpers for the Octopus usage plugin. Kept free of
// QML item state so BarWidget.qml stays about layout and lifecycle.

// State file shape (owned by octopus-usage-config):
//   { "baseUrl": "...", "username": "...", "password": "...",
//     "refreshMinutes": 5, "token": "...", "tokenDate": "20260901" }
// Missing, blank, or unparseable means unconfigured.

function parseConfigFile(raw) {
  var unset = { baseUrl: "", username: "", password: "", refreshMinutes: 5, token: "", tokenDate: "" }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset
    var minutes = parseInt(data.refreshMinutes, 10)
    return {
      baseUrl: typeof data.baseUrl === "string" ? data.baseUrl.replace(/\/+$/, "") : "",
      username: typeof data.username === "string" ? data.username : "",
      password: typeof data.password === "string" ? data.password : "",
      refreshMinutes: isFinite(minutes) && minutes >= 1 ? minutes : 5,
      token: typeof data.token === "string" ? data.token : "",
      tokenDate: typeof data.tokenDate === "string" ? data.tokenDate : ""
    }
  } catch (e) {
    return unset
  }
}

// Unwrap Octopus's `{code, message, data}` envelope. Returns null for
// anything that isn't a successful payload.
function envelopeData(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (parsed && typeof parsed === "object" && parsed.code === 200) return parsed.data
  } catch (e) {}
  return null
}

// stats endpoints return the metrics object (or list of them) directly.
// Numbers arrive as JSON numbers; coerce defensively anyway.
function metric(entry) {
  var e = entry || {}
  return {
    inputToken: Number(e.input_token) || 0,
    outputToken: Number(e.output_token) || 0,
    inputCost: Number(e.input_cost) || 0,
    outputCost: Number(e.output_cost) || 0,
    waitTime: Number(e.wait_time) || 0,
    requestSuccess: Number(e.request_success) || 0,
    requestFailed: Number(e.request_failed) || 0
  }
}

function metricTotal(m) {
  return {
    tokens: m.inputToken + m.outputToken,
    cost: m.inputCost + m.outputCost,
    requests: m.requestSuccess + m.requestFailed,
    successRate: (m.requestSuccess + m.requestFailed) > 0
      ? m.requestSuccess / (m.requestSuccess + m.requestFailed) : 0
  }
}

function formatMoney(value) {
  var amount = Number(value)
  if (!isFinite(amount)) amount = 0
  if (amount >= 100) return "$" + amount.toFixed(0)
  if (amount >= 10) return "$" + amount.toFixed(1)
  return "$" + amount.toFixed(2)
}

// 21896566 -> "21.9M", 226403 -> "226K"
function formatTokenCount(value) {
  var n = Number(value)
  if (!isFinite(n)) n = 0
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return (n / 1e3).toFixed(0) + "K"
  return String(Math.round(n))
}

function formatNumber(value) {
  var n = Number(value)
  if (!isFinite(n)) return "0"
  return n.toLocaleString(Qt.locale(), "f", 0)
}

// wait_time is cumulative milliseconds across requests (~20s each for LLM
// calls); formatDuration takes seconds.
function formatDuration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  if (s < 60) return s + "s"
  var minutes = Math.floor(s / 60)
  if (minutes < 60) return minutes + "m " + (s % 60) + "s"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h " + (minutes % 60) + "m"
  var days = Math.floor(hours / 24)
  return days + "d " + (hours % 24) + "h"
}

// "20260901" -> "2026-09-01"; passes through anything unparseable.
function normalizeDate(dateString) {
  var text = String(dateString || "")
  if (/^\d{8}$/.test(text)) return text.slice(0, 4) + "-" + text.slice(4, 6) + "-" + text.slice(6, 8)
  return text
}

// "20260902" -> "2": day of month without leading zero, for chart axis
// labels where weekday letters are ambiguous and two digits still fit.
function dayOfMonth(dateString) {
  var text = String(dateString || "")
  if (!/^\d{8}$/.test(text)) return ""
  return String(parseInt(text.slice(6, 8), 10))
}

// Last `count` daily entries, oldest first, for a bar chart.
function recentDays(daily, count) {
  var items = []
  var list = Array.isArray(daily) ? daily : []
  var start = Math.max(0, list.length - count)
  for (var i = start; i < list.length; i++) items.push(list[i])
  return items
}

function dayCost(entry) {
  var m = metric(entry)
  return m.inputCost + m.outputCost
}

// Local calendar date as Octopus's yyyymmdd key.
function todayKey(nowMs) {
  var now = new Date(nowMs)
  return String(now.getFullYear())
    + String(now.getMonth() + 1).padStart(2, "0")
    + String(now.getDate()).padStart(2, "0")
}
