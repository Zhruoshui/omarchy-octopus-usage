import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Octopus usage dashboard. One entry point: a bar pill showing today's
// spend, which opens a panel with today/total stats, per-key breakdown, and
// a 14-day cost chart. All HTTP goes through curl child processes — the
// shell process itself never makes network connections — and credentials
// live in ~/.local/state/omarchy/settings/octopus-usage.json (mode 600).
Panel {
  id: root
  moduleName: "io.github.zhruoshui.octopus-usage"
  ipcTarget: "io.github.zhruoshui.octopus-usage"
  manageIpc: false

  property var anchorItem: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- configuration -------------------------------------------------------

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/settings"
  readonly property string configPath: stateDir + "/octopus-usage.json"

  property var config: ({ baseUrl: "", username: "", password: "", refreshMinutes: 5, token: "", tokenDate: "" })
  readonly property bool configured: config.baseUrl !== "" && config.username !== "" && config.password !== ""
  readonly property int refreshMinutes: config.refreshMinutes

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
  }

  function applyConfig(raw) {
    config = Model.parseConfigFile(raw)
    // A hand edit re-arms the refresh cycle; if a fetch is already in
    // flight the values will be picked up on the next cycle anyway.
    if (!fetchProc.running && root.configured) Qt.callLater(refresh)
  }

  // ---- fetched state -------------------------------------------------------

  property var today: null
  property var total: null
  property var apiKeys: []       // [{id, name, enabled}] from /apikey/list
  property var keyStats: []      // raw metrics rows from /stats/apikey
  property var daily: []
  property string fetchError: ""
  property string lastUpdated: ""
  property double nowMs: Date.now()

  readonly property var todayMetric: Model.metric(today)
  readonly property var todayTotals: Model.metricTotal(todayMetric)
  readonly property var totalMetric: Model.metric(total)
  readonly property var totalTotals: Model.metricTotal(totalMetric)
  readonly property var chartDays: Model.recentDays(daily, 14)

  // Per-key rows joined by id, richest cost first.
  readonly property var keyRows: {
    var byId = {}
    var rows = []
    for (var i = 0; i < keyStats.length; i++) {
      var stat = keyStats[i] || {}
      byId[stat.api_key_id] = stat
    }
    for (var j = 0; j < apiKeys.length; j++) {
      var key = apiKeys[j] || {}
      var m = Model.metric(byId[key.id])
      rows.push({
        name: String(key.name || ("#" + key.id)),
        enabled: key.enabled !== false,
        metric: m,
        totals: Model.metricTotal(m)
      })
    }
    rows.sort(function(a, b) { return b.totals.cost - a.totals.cost })
    return rows
  }

  readonly property string label: {
    if (!configured) return ""
    if (fetchError !== "") return "!"
    if (!today) return "…"
    return Model.formatMoney(todayTotals.cost)
  }

  // ---- HTTP ----------------------------------------------------------------

  // Fetch chain: today -> total -> keys -> keyStats -> daily. Chaining one
  // process instead of five in parallel keeps the 401 path simple: any
  // unauthorized response logs in once and reruns the chain from the top.
  Process {
    id: fetchProc
    running: false
    property string stage: ""
    property int lastExitCode: 0
    command: []
    onExited: function(exitCode, exitStatus) { lastExitCode = exitCode }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleFetchResult(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("octopus-usage", text.trim())
    }
  }

  Process {
    id: loginProc
    running: false
    property int lastExitCode: 0
    command: []
    onExited: function(exitCode, exitStatus) { lastExitCode = exitCode }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleLoginResult(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("octopus-usage login", text.trim())
    }
  }

  // Token persistence goes through jq so the password never has to round-trip
  // through QML command lines.
  Process {
    id: writeConfigProc
    running: false
    command: []
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("octopus-usage save", text.trim())
    }
  }

  property bool reloginPending: false

  function refresh() {
    if (!configured || fetchProc.running || loginProc.running) return
    fetchError = ""
    runFetchStage("today")
  }

  function runFetchStage(stage) {
    var paths = {
      today: "/api/v1/stats/today",
      total: "/api/v1/stats/total",
      apikeys: "/api/v1/apikey/list",
      keystats: "/api/v1/stats/apikey",
      daily: "/api/v1/stats/daily"
    }
    var path = paths[stage]
    if (!path) {
      finishFetchCycle()
      return
    }
    fetchProc.stage = stage
    fetchProc.command = ["curl", "-fsS", "--max-time", "10"].concat(
      config.token !== "" ? ["-H", "Cookie: auth=" + config.token] : [],
      [config.baseUrl + path])
    fetchProc.running = true
  }

  function handleFetchResult(raw) {
    var stage = fetchProc.stage
    var data = Model.envelopeData(raw)
    if (data === null) {
      // curl -f yields empty stdout on HTTP errors. 22 is an HTTP status
      // failure (401 with a stale token, or a gateway 5xx); anything else
      // is a connection problem, where re-logging-in is pointless.
      if (fetchProc.lastExitCode === 22 && !reloginPending && config.username !== "") {
        reloginPending = true
        runLogin()
      } else if (fetchProc.lastExitCode !== 22) {
        fetchError = "Cannot reach " + config.baseUrl
        scheduleRetry()
      } else {
        fetchError = "Login failed — check credentials"
        reloginPending = false
        scheduleRetry()
      }
      return
    }
    if (stage === "today") {
      today = data
      runFetchStage("total")
    } else if (stage === "total") {
      total = data
      runFetchStage("apikeys")
    } else if (stage === "apikeys") {
      apiKeys = Array.isArray(data) ? data : []
      runFetchStage("keystats")
    } else if (stage === "keystats") {
      keyStats = Array.isArray(data) ? data : []
      runFetchStage("daily")
    } else if (stage === "daily") {
      daily = Array.isArray(data.items) ? data.items : []
      finishFetchCycle()
    }
  }

  function finishFetchCycle() {
    consecutiveFailures = 0
    fetchError = ""
    reloginPending = false
    lastUpdated = new Date().toLocaleTimeString(Qt.locale(), "HH:mm")
    nowMs = Date.now()
  }

  function runLogin() {
    loginProc.command = ["curl", "-fsS", "--max-time", "10",
      "-H", "Content-Type: application/json",
      "-X", "POST", "-d",
      JSON.stringify({ username: config.username, password: config.password, expire: -1 }),
      "-w", "\\n%header{set-cookie}",
      config.baseUrl + "/api/v1/user/login"]
    loginProc.running = true
  }

  function handleLoginResult(raw) {
    // Body is the JSON envelope; the trailing -w line carries set-cookie.
    var lines = String(raw || "").split("\n")
    var cookieLine = lines.length > 0 ? lines[lines.length - 1] : ""
    var body = lines.length > 1 ? lines.slice(0, -1).join("\n") : ""
    if (Model.envelopeData(body) === null) {
      reloginPending = false
      fetchError = loginProc.lastExitCode === 22
        ? "Login failed — check username/password"
        : "Cannot reach " + config.baseUrl
      scheduleRetry()
      return
    }
    var match = cookieLine.match(/auth=([^;\s]+)/)
    if (!match) {
      reloginPending = false
      fetchError = "Login succeeded but no auth cookie returned"
      scheduleRetry()
      return
    }
    config.token = match[1]
    config.tokenDate = Model.todayKey(Date.now())
    persistToken(match[1])
    reloginPending = false
    runFetchStage("today")
  }

  function persistToken(token) {
    writeConfigProc.command = ["bash", "-c",
      'set -e; umask 077; f="$1"; [ -f "$f" ] || exit 0; ' +
      'tmp="$(mktemp)"; jq --arg t "$2" --arg d "$3" \'.token=$t | .tokenDate=$d\' "$f" > "$tmp"; mv "$tmp" "$f"',
      "bash", configPath, token, Model.todayKey(Date.now())]
    writeConfigProc.running = true
  }

  // ---- retry / polling -----------------------------------------------------

  property int consecutiveFailures: 0

  // 30s -> 1m -> 2m -> 4m -> capped at 10m, so an unreachable gateway or a
  // rejected login doesn't get hammered in the background.
  function scheduleRetry() {
    consecutiveFailures++
    retryTimer.interval = Math.min(600000, 30000 * Math.pow(2, consecutiveFailures - 1))
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    interval: 30000
    onTriggered: if (root.configured) root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: Math.max(60, refreshMinutes * 60000)
    running: configured
    repeat: true
    onTriggered: root.refresh()
  }

  // Keep "today" honest across midnight while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Component.onCompleted: if (configured) Qt.callLater(refresh)

  // ---- lifecycle ------------------------------------------------------------

  // open/close/toggle/opened come from the Panel base; open() is overridden
  // to pull fresh numbers at the same time.
  function open() {
    controller.show()
    refresh()
  }
  function openFromHotkey() { open() }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ---- bar pill ------------------------------------------------------------

  visible: label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    slotSize: Style.bar.statusSlot
    active: root.fetchError !== ""
    tooltipText: root.fetchError

    onPressed: function(b) {
      if (b === Qt.RightButton && root.config.baseUrl !== "")
        root.bar.run("xdg-open " + root.config.baseUrl)
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---- panel ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem || button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.refresh()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

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

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Octopus"
            meta: root.lastUpdated !== "" ? "Updated " + root.lastUpdated : "AI gateway usage"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: "󱙺"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.fetchError !== ""
            width: parent.width
            text: root.fetchError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // ---- Today ----

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "TODAY"; foreground: root.foreground; fontFamily: root.fontFamily }

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.spacing.md
            rowSpacing: Style.spacing.sm

            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Cost"
              value: Model.formatMoney(root.todayTotals.cost)
            }
            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Requests"
              value: Model.formatNumber(root.todayTotals.requests)
              detail: root.todayTotals.requests > 0
                ? Math.round(root.todayTotals.successRate * 100) + "% ok" : ""
            }
            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Input tokens"
              value: Model.formatTokenCount(root.todayMetric.inputToken)
            }
            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Output tokens"
              value: Model.formatTokenCount(root.todayMetric.outputToken)
            }
          }

          // ---- All time ----

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "ALL TIME"; foreground: root.foreground; fontFamily: root.fontFamily }

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.spacing.md
            rowSpacing: Style.spacing.sm

            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Cost"
              value: Model.formatMoney(root.totalTotals.cost)
            }
            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Requests"
              value: Model.formatNumber(root.totalTotals.requests)
            }
            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Tokens"
              value: Model.formatTokenCount(root.totalTotals.tokens)
            }
            StatCell {
              Layout.fillWidth: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              title: "Wait time"
              value: Model.formatDuration(root.totalMetric.waitTime)
            }
          }

          // ---- Last 14 days chart ----

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "LAST 14 DAYS · COST"; foreground: root.foreground; fontFamily: root.fontFamily }

          Item {
            id: chartRoot
            width: parent.width
            height: Style.space(72)
            visible: root.chartDays.length > 0

            readonly property real peakCost: {
              var peak = 0
              for (var i = 0; i < root.chartDays.length; i++)
                peak = Math.max(peak, Model.dayCost(root.chartDays[i]))
              return peak
            }
            readonly property real barWidth: root.chartDays.length > 0
              ? (width - (root.chartDays.length - 1) * row.spacing) / root.chartDays.length : 0
            readonly property string todayKey: Model.todayKey(root.nowMs)

            Row {
              id: row
              anchors.fill: parent

              Repeater {
                model: root.chartDays

                delegate: Item {
                  required property var modelData
                  width: chartRoot.barWidth
                  height: parent.height

                  readonly property real dayCost: Model.dayCost(modelData)
                  readonly property bool isToday: String(modelData.date || "") === chartRoot.todayKey
                  readonly property real barHeight: chartRoot.peakCost > 0
                    ? Math.max(2, (dayCost / chartRoot.peakCost) * (height - Style.space(14))) : 2

                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(2, parent.width - Style.space(2))
                    height: parent.barHeight
                    radius: Math.min(2, width / 2)
                    color: parent.isToday ? root.urgent : Qt.darker(root.foreground, 1.8)
                  }

                  Text {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Model.dayName(modelData.date).slice(0, 1)
                    color: parent.isToday ? root.foreground : Qt.darker(root.foreground, 1.8)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---- Per-key breakdown ----

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "BY API KEY"; foreground: root.foreground; fontFamily: root.fontFamily }

          Column {
            width: parent.width
            spacing: Style.spacing.xs
            visible: root.keyRows.length > 0

            Repeater {
              model: root.keyRows

              delegate: Row {
                required property var modelData
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  width: Style.space(96)
                  text: modelData.name
                  color: modelData.enabled ? root.foreground : Qt.darker(root.foreground, 1.8)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width - Style.space(96) - Style.space(76) - parent.spacing * 2
                  text: Model.formatTokenCount(modelData.totals.tokens) + " tok · "
                    + Model.formatNumber(modelData.totals.requests) + " req"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  width: Style.space(76)
                  text: Model.formatMoney(modelData.totals.cost)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignRight
                }
              }
            }
          }

          Text {
            visible: root.keyRows.length === 0 && root.fetchError === ""
            width: parent.width
            text: "No API keys yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  component StatCell: Column {
    id: cell
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    property string title: ""
    property string value: ""
    property string detail: ""
    spacing: 1

    Text {
      text: cell.title
      color: Qt.darker(cell.foreground, 1.4)
      font.family: cell.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      text: cell.value
      color: cell.foreground
      font.family: cell.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
    Text {
      visible: cell.detail !== ""
      text: cell.detail
      color: Qt.darker(cell.foreground, 1.4)
      font.family: cell.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
