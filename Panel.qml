pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ProviderIcons.js" as ProviderIcons

// OmaUsage: OMP subscription limits in the bar and a panel. Forked from
// Mirceone/omarchy-omp-usage. The bar draws each provider's own mark with
// its percentage (every account, or only the one with the least left); the
// panel lists every limit. Usage math lives in Model.js, marks in
// ProviderIcons.js as vector paths so they tint with the theme.
Panel {
  id: root
  moduleName: "io.github.terrifiedbug.omausage"
  ipcTarget: "io.github.terrifiedbug.omausage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int refreshIntervalSec: Math.max(30, Number(settings && settings.refreshIntervalSec || 300))
  // "all" = every account with usage; "most-used" = only the one with the least left.
  readonly property string barDisplay: Model.normalizeDisplay(setting("barDisplay", "all"))
  // "left" = headroom; "used" = consumption. Applies to bar, tooltip, and panel.
  readonly property string percentShown: Model.normalizePercent(setting("percentShown", "left"))

  property var reports: []
  property string errorText: ""
  property double nowMs: Date.now()

  property var history: ({})
  property var knownProviders: []
  property double lastFullAt: 0
  property var pending: null
  property var slowNextAt: ({})
  property var slowBackoffMs: ({})
  // Exact plan / access type per account, from plans.py.
  property var plans: ({})
  // Account keys in the order the user dragged them into (persisted).
  property var savedOrder: []
  property string dragKey: ""
  property int dropIndex: -1

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/omausage.json"
  readonly property string credentialStore: Quickshell.env("HOME") + "/.omp/agent/agent.db"
  // Identity of every enabled OMP credential (no secrets); a change means an
  // account was logged in or out. null until the first read.
  property var accountsSignature: null
  // Re-run discovery as soon as the in-flight usage pass finishes.
  property bool rediscoverQueued: false

  readonly property var displayReports: {
    var list = reports.map(withHistory)
    var rank = {}
    for (var i = 0; i < savedOrder.length; i++) rank[savedOrder[i]] = i
    var position = {}
    for (var j = 0; j < list.length; j++) position[reportKey(list[j])] = j
    return list.slice().sort(function(a, b) {
      var ka = reportKey(a), kb = reportKey(b)
      var ra = rank[ka] === undefined ? savedOrder.length + position[ka] : rank[ka]
      var rb = rank[kb] === undefined ? savedOrder.length + position[kb] : rank[kb]
      return ra - rb
    })
  }

  readonly property var reportsByKey: {
    var map = {}
    for (var i = 0; i < displayReports.length; i++) map[reportKey(displayReports[i])] = displayReports[i]
    return map
  }

  onDisplayReportsChanged: syncSections()

  // Bring sectionModel to the displayReports order with moves/inserts/removes
  // only, so existing section delegates are kept rather than recreated.
  function syncSections() {
    var keys = displayReports.map(reportKey)
    for (var i = 0; i < keys.length; i++) {
      if (i < sectionModel.count && sectionModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < sectionModel.count; j++)
        if (sectionModel.get(j).key === keys[i]) { found = j; break }
      if (found >= 0) sectionModel.move(found, i, 1)
      else sectionModel.insert(i, { key: keys[i] })
    }
    while (sectionModel.count > keys.length) sectionModel.remove(sectionModel.count - 1)
  }

  ListModel { id: sectionModel }

  // Every account with a live figure (tooltip), and what the bar draws.
  readonly property var allEntries: Model.barEntries(displayReports, "all", nowMs)
  readonly property var shownEntries: barDisplay === "all" ? allEntries : Model.barEntries(displayReports, barDisplay, nowMs)
  readonly property string barTooltip: Model.tooltipText(allEntries, percentShown)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function providerName(id) { return Model.providerName(id) }

  function formatPlanName(value) {
    return String(value).split(/[-_ ]+/).map(function(part) {
      return part ? part[0].toUpperCase() + part.slice(1).toLowerCase() : ""
    }).join(" ")
  }

  // Exact plan when any source knows it ("Plus plan", "Pro plan"), otherwise
  // the universal access type ("Subscription" / "API key").
  function planText(report) {
    if (!report) return ""
    var metadata = report.metadata || {}
    var exact = metadata.planType || metadata.plan || metadata.currentTierName
    if (exact) return formatPlanName(exact) + " plan"
    var known = plans[reportKey(report)] || plans[report.provider + "|" + (metadata.email || "")]
      || plans[report.provider + "|*"]
    if (known && known.plan) return known.plan + " plan"
    if (known && known.access) return known.access
    if (report.noUsage) return report.credentialType === "api_key" ? "API key" : "Subscription"
    if (String(metadata.endpoint || "").indexOf("/oauth/") >= 0) return "Subscription"
    return ""
  }

  // Clear drag state before reordering: the reorder moves the very section
  // whose mouse handler is calling this.
  function finishDrag(commit) {
    var key = dragKey
    var index = dropIndex
    dragKey = ""
    dropIndex = -1
    if (commit && key !== "" && index >= 0) Qt.callLater(function() { root.moveReport(key, index) })
  }

  function moveReport(key, toIndex) {
    var order = displayReports.map(reportKey)
    var from = order.indexOf(key)
    if (from < 0 || toIndex < 0) return
    order.splice(from, 1)
    order.splice(toIndex > from ? toIndex - 1 : toIndex, 0, key)
    // Keep positions of accounts that are not logged in right now.
    for (var i = 0; i < savedOrder.length; i++)
      if (order.indexOf(savedOrder[i]) < 0) order.push(savedOrder[i])
    savedOrder = order
    stateFile.setText(JSON.stringify({ order: order }, null, 2) + "\n")
  }

  function loadState(text) {
    try {
      var state = JSON.parse(String(text || "{}"))
      savedOrder = Array.isArray(state.order) ? state.order : []
    } catch (error) {
      savedOrder = []
    }
  }

  function usedFraction(limit) { return Model.usedFraction(limit) }

  function formatQuantity(value, unit) {
    if (unit === "usd") return "$" + Number(value).toFixed(2)
    var formatted = Number(value).toLocaleString(Qt.locale("en_US"), "f", Number(value) % 1 === 0 ? 0 : 1)
    return unit && unit !== "unknown" ? formatted + " " + unit : formatted
  }

  // Absolute figures: "$8.40 of $20.00" beside a bar, or the whole reading
  // ("$12.34 used", "$5.00 left") when there is no allowance to draw a bar from.
  function amountText(limit) {
    var amount = limit && limit.amount ? limit.amount : {}
    if (amount.unit === "percent") return ""
    if (amount.used !== undefined && Number(amount.limit) > 0)
      return formatQuantity(amount.used, amount.unit) + " of " + formatQuantity(amount.limit, amount.unit)
    if (amount.used !== undefined) return formatQuantity(amount.used, amount.unit) + " used"
    if (amount.remaining !== undefined) return formatQuantity(amount.remaining, amount.unit) + " left"
    return ""
  }

  function detailText(limit, hasBar) {
    var parts = []
    var amount = hasBar ? amountText(limit) : ""
    if (amount && !windowExpired(limit)) parts.push(amount)
    var reset = resetText(limit)
    if (reset) parts.push(reset)
    return parts.join(" · ")
  }

  // Providers whose usage endpoint is throttled hard (Anthropic limits
  // /api/oauth/usage per IP). They are polled live at most once a minute,
  // backing off while they answer with a rate limit; OMP's own recorded
  // usage (from normal model responses) fills the gap.
  readonly property var slowProviders: ({ "anthropic": true })
  readonly property int slowIntervalMs: 60000
  readonly property int slowMaxBackoffMs: 15 * 60000
  // Full `omp usage --json` pass: discovers accounts (including ones
  // without usage) and doubles as a slow-provider poll.
  readonly property int discoveryIntervalMs: 15 * 60000

  function refresh() {
    if (usageProcess.running) return
    var now = Date.now()
    var allSlowDue = true
    var providers = []
    for (var i = 0; i < knownProviders.length; i++) {
      var id = knownProviders[i]
      if (!slowProviders[id]) providers.push(id)
      else if (now >= Number(slowNextAt[id] || 0)) providers.push(id)
      else allSlowDue = false
    }
    // Rediscover periodically, but never while a slow provider is backing off.
    var full = lastFullAt === 0 || (allSlowDue && now - lastFullAt >= discoveryIntervalMs)
    pending = { full: full, providers: full ? knownProviders.slice() : providers, startedAt: now }
    usageProcess.command = ["bash", "-c", batchScript, "omp-usage"].concat(full ? ["--all"] : providers)
    usageProcess.running = true
  }

  // A full pass replaces the account list, so logins and logouts show up
  // (and removed accounts disappear) without waiting for periodic discovery.
  function rediscover() {
    if (usageProcess.running) {
      rediscoverQueued = true
      return
    }
    rediscoverQueued = false
    lastFullAt = 0
    refresh()
  }

  function checkAccounts(text) {
    var out = String(text || "")
    // No "ok" line: store missing, locked, or sqlite3 failed. Keep the current view.
    if (out.indexOf("ok") !== 0) return
    var signature = out.slice(2).trim()
    if (signature === accountsSignature) return
    var first = accountsSignature === null
    accountsSignature = signature
    if (!first) rediscover()
  }

  // Runs the requested OMP calls in parallel plus the local history read,
  // emitting each JSON document followed by an ASCII record separator.
  readonly property string batchScript: "tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT\n"
    + "if [ \"$1\" = --all ]; then omp usage --json > \"$tmp/0\" &\n"
    + "else i=0; for p in \"$@\"; do i=$((i+1)); omp usage --json --provider \"$p\" > \"$tmp/$i\" & done; fi\n"
    + "omp usage --history --json --days 1 > \"$tmp/h\" &\n"
    + "wait\n"
    + "for f in \"$tmp\"/*; do cat \"$f\"; printf '\\036'; done\n"

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function resetText(limit) {
    if (windowExpired(limit)) return "Window reset · waiting for fresh data"
    var resetAt = Number(limit && limit.window && limit.window.resetsAt)
    return resetAt > 0 ? "Resets in " + formatDuration(resetAt - nowMs) : ""
  }

  function windowExpired(limit) { return Model.windowExpired(limit, nowMs) }

  function reportKey(report) { return Model.reportKey(report) }

  // Logged-in accounts OMP has no usage endpoint (or no data) for.
  function accountWithoutUsage(account) {
    return {
      provider: account.provider,
      noUsage: true,
      credentialType: account.type,
      metadata: { email: account.email, accountId: account.accountId },
      limits: []
    }
  }

  // Latest recorded snapshot per account limit from `omp usage --history`.
  function indexHistory(entries) {
    var latest = {}
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var key = e.provider + "|" + (e.accountId || e.email || "") + "|" + e.limitId
      if (!latest[key] || latest[key].recordedAt < e.recordedAt) latest[key] = e
    }
    return latest
  }

  // Replace limits in a report that OMP has recorded more recently than the
  // report itself was fetched (e.g. a rate-limited provider's cached report).
  function withHistory(report) {
    if (!report || report.noUsage || !Array.isArray(report.limits)) return report
    var fetchedAt = Number(report.fetchedAt) || 0
    var asOf = fetchedAt
    var prefix = reportKey(report) + "|"
    var limits = []
    for (var i = 0; i < report.limits.length; i++) {
      var limit = report.limits[i]
      var h = history[prefix + limit.id]
      if (!h || !(h.recordedAt > fetchedAt) || h.usedFraction === undefined || h.usedFraction === null) {
        limits.push(limit)
        continue
      }
      var amount = Object.assign({}, limit.amount, {
        usedFraction: h.usedFraction,
        remainingFraction: Math.max(0, 1 - h.usedFraction)
      })
      if (Number(amount.limit) > 0) {
        amount.used = amount.limit * h.usedFraction
        amount.remaining = Math.max(0, amount.limit - amount.used)
      } else if (amount.unit === "percent") {
        amount.used = h.usedFraction * 100
      }
      var windowInfo = Object.assign({}, limit.window)
      if (h.resetsAt) windowInfo.resetsAt = h.resetsAt
      else delete windowInfo.resetsAt
      limits.push(Object.assign({}, limit, { amount: amount, window: windowInfo }))
      asOf = Math.max(asOf, h.recordedAt)
    }
    return Object.assign({}, report, { limits: limits, asOf: asOf })
  }

  function staleText(report) {
    var at = Number(report && (report.asOf || report.fetchedAt))
    if (!(at > 0)) return ""
    var age = nowMs - at
    if (age >= 2 * 3600000) return "Provider unreachable · last update " + formatDuration(age) + " ago"
    // Only once a scheduled poll has been missed; data this old is expected otherwise.
    if (age >= refreshIntervalSec * 1000 + 60000) return "Updated " + formatDuration(age) + " ago"
    return ""
  }

  function staleUrgent(report) {
    var at = Number(report && (report.asOf || report.fetchedAt))
    return at > 0 && nowMs - at >= 2 * 3600000
  }

  function limitTitle(limit) {
    var title = String(limit && (limit.label || limit.window && limit.window.label) || "Usage")
    var scope = limit && limit.scope ? limit.scope : null
    if (scope && scope.modelId) title += " · " + scope.modelId
    return title
  }

  function parseBatch(text) {
    var request = pending || { full: true, providers: [], startedAt: Date.now() }
    pending = null
    var docs = String(text || "").split("\u001e")
    var incoming = []
    var sawReports = false
    for (var d = 0; d < docs.length; d++) {
      var chunk = docs[d].trim()
      if (chunk === "") continue
      var parsed
      try {
        parsed = JSON.parse(chunk)
      } catch (error) {
        console.warn("omp-usage", error)
        continue
      }
      if (Array.isArray(parsed.entries)) {
        history = indexHistory(parsed.entries)
        continue
      }
      sawReports = true
      if (Array.isArray(parsed.reports)) incoming = incoming.concat(parsed.reports)
      var unreported = Array.isArray(parsed.accountsWithoutUsage) ? parsed.accountsWithoutUsage : []
      for (var k = 0; k < unreported.length; k++) incoming.push(accountWithoutUsage(unreported[k]))
    }
    nowMs = Date.now()
    if (!sawReports && (request.full || request.providers.length > 0)) {
      errorText = "Could not read OMP usage data"
      return
    }

    // Never replace a newer report with an older cached one.
    var previous = {}
    for (var i = 0; i < reports.length; i++) previous[reportKey(reports[i])] = reports[i]
    var incomingKeys = {}
    var merged = []
    for (var j = 0; j < incoming.length; j++) {
      var key = reportKey(incoming[j])
      var known = previous[key]
      incomingKeys[key] = true
      merged.push(known && !known.noUsage && Number(known.fetchedAt) > Number(incoming[j].fetchedAt) ? known : incoming[j])
    }
    // A partial pass only covers some providers; keep everything else.
    if (!request.full)
      for (var p = 0; p < reports.length; p++)
        if (!incomingKeys[reportKey(reports[p])]) merged.push(reports[p])

    if (request.full) {
      lastFullAt = request.startedAt
      var seen = {}
      var ids = []
      for (var m = 0; m < merged.length; m++)
        if (!merged[m].noUsage && !seen[merged[m].provider]) { seen[merged[m].provider] = true; ids.push(merged[m].provider) }
      knownProviders = ids
    }
    scheduleSlowProviders(request, incoming)

    // Keep a stable account order across partial passes.
    var order = {}
    for (var o = 0; o < reports.length; o++) order[reportKey(reports[o])] = o
    merged.sort(function(a, b) {
      var ia = order[reportKey(a)], ib = order[reportKey(b)]
      return (ia === undefined ? 1e9 : ia) - (ib === undefined ? 1e9 : ib)
    })
    reports = merged
    errorText = ""
  }

  // A slow provider that returned a report fetched during this pass is
  // healthy; one that handed back an older cached report is rate-limited.
  function scheduleSlowProviders(request, incoming) {
    var next = Object.assign({}, slowNextAt)
    var backoff = Object.assign({}, slowBackoffMs)
    var polled = request.full ? knownProviders : request.providers
    for (var i = 0; i < polled.length; i++) {
      var id = polled[i]
      if (!slowProviders[id]) continue
      var fresh = false
      for (var j = 0; j < incoming.length; j++)
        if (incoming[j].provider === id && Number(incoming[j].fetchedAt) >= request.startedAt - 5000) fresh = true
      backoff[id] = fresh ? slowIntervalMs : Math.min(slowMaxBackoffMs, Math.max(slowIntervalMs, Number(backoff[id] || 0)) * 2)
      next[id] = Date.now() + backoff[id]
    }
    slowNextAt = next
    slowBackoffMs = backoff
  }

  // Insertion index (0..count) for a drag at `y` in column coordinates.
  function dropIndexAt(y) {
    for (var i = 0; i < sectionRepeater.count; i++) {
      var item = sectionRepeater.itemAt(i)
      if (item && y < item.y + item.height / 2) return i
    }
    return sectionRepeater.count
  }

  function dropLineY(index) {
    var count = sectionRepeater.count
    if (index < 0 || count === 0) return 0
    if (index < count) {
      var item = sectionRepeater.itemAt(index)
      return item ? item.y - column.spacing / 2 : 0
    }
    var last = sectionRepeater.itemAt(count - 1)
    return last ? last.y + last.height + column.spacing / 2 : 0
  }

  // Plans change rarely: look them up at start, then at most hourly on open.
  property double plansFetchedAt: 0
  function refreshPlans() {
    if (planProcess.running) return
    plansFetchedAt = Date.now()
    planProcess.running = true
  }

  Component.onCompleted: {
    refresh()
    refreshPlans()
  }
  // Opening the panel is the moment fresh numbers matter: refresh now and
  // start the periodic interval over from here.
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    refresh()
    usageTimer.restart()
    checkAccountsNow()
    if (nowMs - plansFetchedAt > 3600000) refreshPlans()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Usage is polled only at the configured pace (default 5 minutes), open or
  // closed. Slow providers still join a pass only when their schedule is due.
  Timer {
    id: usageTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Open: keep "Resets in" / "Updated ago" ticking. Clock only, no processes.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: usageProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseBatch(text)
        if (root.rediscoverQueued) Qt.callLater(root.rediscover)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage", text.trim())
    }
  }

  Process {
    id: planProcess
    command: ["python3", Qt.resolvedUrl("plans.py").toString().replace(/^file:\/\//, "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (parsed && typeof parsed === "object") root.plans = parsed
        } catch (error) {
          console.warn("omp-usage plans", error)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage plans", text.trim())
    }
  }

  // Enabled credentials in OMP's store, read-only. Credential rows change on
  // login and logout (and token refresh, which leaves this signature alone).
  Process {
    id: accountsProcess
    command: ["sqlite3", "-readonly", "-noheader", "-cmd", ".timeout 1000", root.credentialStore,
      "select 'ok' || coalesce(group_concat(id || ':' || provider || ':' || credential_type || ':' || coalesce(identity_key, ''), ' '), '')"
      + " from (select id, provider, credential_type, identity_key from auth_credentials where disabled_cause is null order by id)"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checkAccounts(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omp-usage accounts", text.trim())
    }
  }

  function checkAccountsNow() {
    if (!accountsProcess.running) accountsProcess.running = true
  }

  // One tiny read-only query; logins and logouts show up within this interval.
  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkAccountsNow()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // Nothing reports usage yet: OMP's π as plain text. Otherwise one reading
  // (provider mark + percentage) per shown account, side by side on a
  // horizontal bar and stacked on a vertical one.
  WidgetButton {
    id: button
    readonly property bool hasReadings: root.shownEntries.length > 0
    anchors.fill: parent
    bar: root.bar
    text: hasReadings ? "" : "π"
    hasVisualContent: true
    fixedWidth: hasReadings && !vertical ? readings.implicitWidth + scaledHorizontalMargin * 2 : -1
    fixedHeight: hasReadings && vertical ? readings.implicitHeight + scaledVerticalPadding * 2 : -1
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) { root.toggle() }

    Grid {
      id: readings
      anchors.centerIn: parent
      visible: button.hasReadings
      columns: button.vertical ? 1 : Math.max(1, root.shownEntries.length)
      columnSpacing: Style.space(10)
      rowSpacing: Style.space(8)
      Repeater {
        model: root.shownEntries
        BarReading {}
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height,
          panelFlick.contentY + dy * Style.space(56)))
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Where a dragged account will land.
        Rectangle {
          z: 2
          visible: root.dragKey !== "" && root.dropIndex >= 0
          x: 0
          width: panelFlick.width
          height: Math.max(2, Style.space(2))
          radius: height / 2
          color: Color.accent
          y: root.dropLineY(root.dropIndex) - height / 2
        }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "OmaUsage"
            meta: root.reports.length === 1 ? "Oh My Pi · 1 account" : "Oh My Pi · " + root.reports.length + " accounts"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "π"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }
            }
          }

          // Keyed model: sections survive refreshes (a plain JS-array
          // model would rebuild them all, killing any drag in progress).
          Repeater {
            id: sectionRepeater
            model: sectionModel
            ProviderSection {
              required property string key
              width: parent.width
              accountKey: key
              report: root.reportsByKey[key] || null
            }
          }

          Text {
            visible: root.reports.length === 0 && root.errorText === ""
            width: parent.width
            text: "No accounts logged in to Oh My Pi. Run omp and use /login."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Updates on open and every " + root.formatDuration(root.refreshIntervalSec * 1000) + " · drag a name to reorder"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component ProviderSection: Column {
    id: section
    property var report: null
    property string accountKey: ""
    readonly property bool dragging: root.dragKey !== "" && root.dragKey === accountKey
    // Follows the pointer while dragging; the drop line shows the landing spot.
    property real dragOffset: 0
    z: dragging ? 10 : 0
    opacity: dragging ? 0.6 : 1
    transform: Translate { y: section.dragging ? section.dragOffset : 0 }
    readonly property int resetCount: report && report.resetCredits ? Number(report.resetCredits.availableCount) || 0 : 0
    spacing: Style.space(10)

    PanelSeparator { width: parent.width; foreground: root.foreground }

    Item {
      width: parent.width
      implicitHeight: Math.max(name.implicitHeight, icon.height)

      // Press and drag the header to move this account up or down.
      MouseArea {
        anchors.fill: parent
        z: 1
        preventStealing: true
        cursorShape: section.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real pressY: 0
        onPressed: function(mouse) {
          pressY = mapToItem(column, mouse.x, mouse.y).y
          section.dragOffset = 0
        }
        onPositionChanged: function(mouse) {
          var y = mapToItem(column, mouse.x, mouse.y).y
          // Small threshold so a plain click is not a drag.
          if (!section.dragging) {
            if (Math.abs(y - pressY) < Style.space(4)) return
            root.dragKey = section.accountKey
          }
          section.dragOffset = y - pressY
          root.dropIndex = root.dropIndexAt(y)
        }
        onReleased: root.finishDrag(true)
        onCanceled: root.finishDrag(false)
      }

      ProviderMark {
        id: icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.body * 1.25
        height: width
        provider: section.report ? section.report.provider : ""
      }
      Text {
        textFormat: Text.PlainText
        id: name
        anchors.left: icon.right
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: section.report ? root.providerName(section.report.provider) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        anchors.left: name.right
        anchors.leftMargin: Style.spacing.sm
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.planText(section.report)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
      }
    }

    Repeater {
      model: section.report && Array.isArray(section.report.limits) ? section.report.limits : []
      LimitRow {
        required property var modelData
        width: section.width
        limit: modelData
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: !!(section.report && section.report.noUsage)
      width: parent.width
      text: section.report ? "Logged in, but " + root.providerName(section.report.provider) + " doesn't report usage to Oh My Pi." : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: section.resetCount > 0
      width: parent.width
      text: section.resetCount + " saved reset" + (section.resetCount === 1 ? "" : "s")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      text: root.staleText(section.report)
      color: root.staleUrgent(section.report) ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  component LimitRow: Column {
    id: limitRow
    property var limit: null
    readonly property bool expired: root.windowExpired(limit)
    readonly property var rawFraction: root.usedFraction(limit)
    readonly property bool hasBar: rawFraction !== undefined && !isNaN(rawFraction)
    readonly property bool live: hasBar && !expired
    // The meter fills with what is left or what is used, per percentShown.
    readonly property real fill: live ? Model.shownFraction(rawFraction, root.percentShown) : 0
    readonly property bool alarming: live && rawFraction >= Model.ALARM_USED
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(label.implicitHeight, value.implicitHeight)
      Text {
        textFormat: Text.PlainText
        id: label
        anchors.left: parent.left
        anchors.right: value.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: root.limitTitle(limitRow.limit)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        id: value
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: limitRow.expired ? "—" : limitRow.hasBar ? Model.percentLabel(limitRow.rawFraction, root.percentShown) : root.amountText(limitRow.limit)
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      visible: limitRow.hasBar
      width: parent.width
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track
      Rectangle {
        width: parent.width * limitRow.fill
        height: parent.height
        radius: height / 2
        color: limitRow.alarming ? root.urgent : Color.accent
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      text: root.detailText(limitRow.limit, limitRow.hasBar)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One account in the bar: its mark, then its percentage. On a vertical bar
  // the percentage sits under the mark and drops "%" to fit the narrow column.
  component BarReading: Grid {
    id: reading
    required property var modelData
    readonly property color tint: modelData.alarming ? button.activeColor : button.foreground
    columns: button.vertical ? 1 : 2
    columnSpacing: Style.space(4)
    rowSpacing: Style.space(2)
    horizontalItemAlignment: Grid.AlignHCenter
    verticalItemAlignment: Grid.AlignVCenter

    ProviderMark {
      width: Style.bar.iconFont
      height: width
      provider: reading.modelData.provider
      color: reading.tint
      fontFamily: button.fontFamily
    }
    Text {
      textFormat: Text.PlainText
      text: Model.percentValue(reading.modelData.used, root.percentShown) + (button.vertical ? "" : "%")
      color: reading.tint
      font.family: button.fontFamily
      font.pixelSize: button.vertical ? Style.font.caption : button.fontSize
      renderType: Text.NativeRendering
    }
  }

  // A provider's brand mark as a vector path, tinted like text. Providers
  // without a bundled mark get their initial instead.
  component ProviderMark: Item {
    id: mark
    property string provider: ""
    property color color: root.foreground
    property string fontFamily: root.fontFamily
    readonly property string path: ProviderIcons.providerPath(provider)

    Shape {
      anchors.fill: parent
      visible: mark.path !== ""
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: mark.color
        fillRule: ShapePath.OddEvenFill
        strokeWidth: -1
        scale: Qt.size(mark.width / ProviderIcons.VIEWBOX, mark.height / ProviderIcons.VIEWBOX)
        PathSvg { path: mark.path }
      }
    }
    Text {
      anchors.centerIn: parent
      visible: mark.path === ""
      textFormat: Text.PlainText
      text: Model.providerName(mark.provider).charAt(0)
      color: mark.color
      font.family: mark.fontFamily
      font.pixelSize: mark.height
      font.bold: true
    }
  }
}
