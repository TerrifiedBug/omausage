const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")
const ProviderIcons = require("../ProviderIcons.js")

const NOW = 1_000_000

function limit(usedFraction, resetsAt) {
  return { amount: { usedFraction }, window: resetsAt ? { resetsAt } : {} }
}

function report(provider, accountId, ...limits) {
  return { provider, metadata: { accountId }, limits }
}

const codex = report("openai-codex", "c", limit(0.08, NOW + 1000))
const claude = report("anthropic", "a", limit(0.2, NOW + 1000), limit(0.55, NOW + 1000))
const grok = report("xai-oauth", "x", limit(0.01, NOW + 1000))

test("worstUsed takes the tightest live limit", () => {
  assert.equal(Model.worstUsed(claude, NOW), 0.55)
})

test("worstUsed ignores windows that have already reset", () => {
  const stale = report("anthropic", "a", limit(0.95, NOW - 1), limit(0.1, NOW + 1000))
  assert.equal(Model.worstUsed(stale, NOW), 0.1)
})

test("worstUsed has no figure for an account without usage", () => {
  assert.equal(Model.worstUsed({ provider: "cursor", noUsage: true, limits: [] }, NOW), undefined)
})

test("usedFraction falls back to used/limit, then percent, then remaining", () => {
  assert.equal(Model.usedFraction({ amount: { used: 5, limit: 20 } }), 0.25)
  assert.equal(Model.usedFraction({ amount: { used: 30, unit: "percent" } }), 0.3)
  assert.equal(Model.usedFraction({ amount: { remainingFraction: 0.75 } }), 0.25)
  assert.equal(Model.usedFraction({ amount: { remaining: 4, unit: "usd" } }), undefined)
})

test("barEntries in all mode keeps panel order and skips accounts without a figure", () => {
  const none = { provider: "cursor", noUsage: true, metadata: {}, limits: [] }
  const entries = Model.barEntries([codex, none, claude, grok], "all", NOW)
  assert.deepEqual(entries.map((e) => e.provider), ["openai-codex", "anthropic", "xai-oauth"])
})

test("barEntries in most-used mode shows only the account with the least left", () => {
  const entries = Model.barEntries([codex, claude, grok], "most-used", NOW)
  assert.deepEqual(entries.map((e) => e.name), ["Claude"])
})

test("barEntries in most-used mode breaks a tie by panel order", () => {
  const a = report("openai-codex", "c", limit(0.4, NOW + 1000))
  const b = report("anthropic", "a", limit(0.4, NOW + 1000))
  assert.equal(Model.barEntries([b, a], "most-used", NOW)[0].provider, "anthropic")
})

test("barEntries flags accounts at the alarm threshold", () => {
  const hot = report("anthropic", "a", limit(0.9, NOW + 1000))
  assert.equal(Model.barEntries([hot, codex], "all", NOW)[0].alarming, true)
  assert.equal(Model.barEntries([hot, codex], "all", NOW)[1].alarming, false)
})

test("unknown display and percent settings fall back to the defaults", () => {
  assert.equal(Model.normalizeDisplay("bogus"), "all")
  assert.equal(Model.normalizePercent(undefined), "left")
})

test("percentages read as left or used and stay within 0..100", () => {
  assert.equal(Model.percentLabel(0.08, "left"), "92% left")
  assert.equal(Model.percentLabel(0.08, "used"), "8% used")
  assert.equal(Model.percentValue(1.3, "used"), 100)
  assert.equal(Model.percentValue(1.3, "left"), 0)
})

test("tooltip lists every account in the chosen percent mode", () => {
  const entries = Model.barEntries([codex, grok], "all", NOW)
  assert.equal(Model.tooltipText(entries, "used"), "Codex 8% used · Grok 1% used")
})

test("providerName title-cases ids it has no short name for", () => {
  assert.equal(Model.providerName("some-new_provider"), "Some New Provider")
})

test("every mapped provider resolves to bundled path data", () => {
  for (const id of Object.keys(ProviderIcons.PROVIDER_MARKS))
    assert.match(ProviderIcons.providerPath(id), /^M/, id)
  assert.equal(ProviderIcons.providerPath("unknown"), "")
})
