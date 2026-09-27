// Pure usage math for OmaUsage: reading OMP limits, picking what the bar
// shows, and formatting percentages as left or used. Qt-free so node --test
// can load it; Panel.qml delegates to these in one line each.

// A limit at or past this used fraction is drawn in the urgent colour.
var ALARM_USED = 0.9

// Short names for OMP provider ids; anything else is title-cased the way OMP
// itself prints ids ("github-copilot" -> "Github Copilot").
var PROVIDER_NAMES = {
  "anthropic": "Claude",
  "openai-codex": "Codex",
  "codex": "Codex",
  "openai": "OpenAI",
  "cursor": "Cursor",
  "github-copilot": "Copilot",
  "google-gemini-cli": "Gemini",
  "google-antigravity": "Antigravity",
  "xai": "Grok",
  "xai-oauth": "Grok",
  "zai": "Z.ai",
  "zhipu-coding-plan": "Z.ai",
  "kimi-code": "Kimi",
  "openrouter": "OpenRouter",
  "kilo": "Kilo"
}

function providerName(id) {
  if (PROVIDER_NAMES[id]) return PROVIDER_NAMES[id]
  return String(id || "Unknown provider").split(/[-_]/).map(function(part) {
    return part ? part[0].toUpperCase() + part.slice(1) : ""
  }).join(" ")
}

function reportKey(report) {
  var metadata = report && report.metadata ? report.metadata : {}
  return String(report && report.provider) + "|" + String(metadata.accountId || metadata.email || "")
}

// Mirrors OMP's resolveUsedFraction: explicit fraction > used/limit >
// percent-unit used > inverted remaining. undefined = no quota to draw.
function usedFraction(limit) {
  var amount = limit && limit.amount ? limit.amount : {}
  if (amount.usedFraction !== undefined) return Number(amount.usedFraction)
  if (amount.used !== undefined && Number(amount.limit) > 0) return amount.used / amount.limit
  if (amount.unit === "percent" && amount.used !== undefined) return amount.used / 100
  if (amount.remainingFraction !== undefined) return Math.max(0, 1 - amount.remainingFraction)
  return undefined
}

// OMP falls back to its last cached report (however old) when a provider
// rate-limits the usage endpoint. A window whose reset has passed carries no
// valid usage figure.
function windowExpired(limit, nowMs) {
  var resetAt = Number(limit && limit.window && limit.window.resetsAt)
  return resetAt > 0 && resetAt <= nowMs
}

// Highest used fraction across an account's live limits: the limit that will
// stop you first. undefined when no limit has a figure to draw.
function worstUsed(report, nowMs) {
  if (!report || report.noUsage) return undefined
  var worst
  var limits = report.limits || []
  for (var i = 0; i < limits.length; i++) {
    if (windowExpired(limits[i], nowMs)) continue
    var used = usedFraction(limits[i])
    if (used === undefined || isNaN(used)) continue
    worst = worst === undefined ? used : Math.max(worst, used)
  }
  return worst
}

function normalizeDisplay(value) {
  return value === "most-used" ? "most-used" : "all"
}

function normalizePercent(value) {
  return value === "used" ? "used" : "left"
}

// Fraction a meter fills for a used fraction: headroom when showing "left".
function shownFraction(used, percentMode) {
  var clamped = Math.max(0, Math.min(1, Number(used) || 0))
  return percentMode === "used" ? clamped : 1 - clamped
}

function percentValue(used, percentMode) {
  return Math.round(shownFraction(used, percentMode) * 100)
}

function percentLabel(used, percentMode) {
  return percentValue(used, percentMode) + "% " + (percentMode === "used" ? "used" : "left")
}

// What the bar draws, in panel order: one reading per account with a live
// limit. "most-used" keeps only the account with the least left; a tie goes
// to the account the user dragged higher.
function barEntries(reports, display, nowMs) {
  var list = []
  for (var i = 0; i < (reports || []).length; i++) {
    var used = worstUsed(reports[i], nowMs)
    if (used === undefined) continue
    list.push({
      key: reportKey(reports[i]),
      provider: reports[i].provider,
      name: providerName(reports[i].provider),
      used: used,
      alarming: used >= ALARM_USED
    })
  }
  if (normalizeDisplay(display) !== "most-used" || list.length < 2) return list
  var worst = list[0]
  for (var j = 1; j < list.length; j++)
    if (list[j].used > worst.used) worst = list[j]
  return [worst]
}

function tooltipText(entries, percentMode) {
  if (!entries || entries.length === 0) return "OmaUsage"
  return entries.map(function(entry) {
    return entry.name + " " + percentLabel(entry.used, percentMode)
  }).join(" · ")
}

if (typeof module !== "undefined") module.exports = {
  ALARM_USED: ALARM_USED,
  providerName: providerName,
  reportKey: reportKey,
  usedFraction: usedFraction,
  windowExpired: windowExpired,
  worstUsed: worstUsed,
  normalizeDisplay: normalizeDisplay,
  normalizePercent: normalizePercent,
  shownFraction: shownFraction,
  percentValue: percentValue,
  percentLabel: percentLabel,
  barEntries: barEntries,
  tooltipText: tooltipText
}
