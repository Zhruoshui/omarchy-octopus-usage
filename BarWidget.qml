import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Octopus usage dashboard. One entry point: a bar pill showing today's
// token usage, which opens a panel with today/total stats and a 14-day
// cost chart. All HTTP goes through curl child processes — the
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
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- configuration -------------------------------------------------------

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/settings"
  readonly property string configPath: stateDir + "/octopus-usage.json"

  property var config: ({ baseUrl: "", username: "", password: "", refreshMinutes: 5, token: "", tokenDate: "", barMetric: "tokens", chartMetric: "cost" })
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
  property var daily: []
  property string fetchError: ""
  property string lastUpdated: ""
  property bool settingsOpen: false
  property double nowMs: Date.now()

  readonly property var todayMetric: Model.metric(today)
  readonly property var todayTotals: Model.metricTotal(todayMetric)
  readonly property var totalMetric: Model.metric(total)
  readonly property var totalTotals: Model.metricTotal(totalMetric)
  readonly property var chartDays: Model.recentDays(daily, 14)

  readonly property string label: {
    if (!configured) return ""
    if (fetchError !== "") return "!"
    if (!today) return "…"
    return Model.formatBarMetric(todayTotals, config.barMetric)
  }

  // ---- HTTP ----------------------------------------------------------------

  // Fetch chain: hourly -> total -> daily (0.13.x replaced /stats/today
  // with per-hour /stats/hourly rows). Chaining one process instead of
  // three in parallel keeps the 401 path simple: any unauthorized response
  // logs in once and reruns the chain from the top.
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
    runFetchStage("hourly")
  }

  function runFetchStage(stage) {
    var paths = {
      hourly: "/api/v1/stats/hourly",
      total: "/api/v1/stats/total",
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
    if (stage === "hourly") {
      today = Model.hourlyTotal(data)
      runFetchStage("total")
    } else if (stage === "total") {
      total = data
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
    runFetchStage("hourly")
  }

  function persistToken(token) {
    writeConfigProc.command = ["bash", "-c",
      'set -e; umask 077; f="$1"; [ -f "$f" ] || exit 0; ' +
      'tmp="$(mktemp)"; jq --arg t "$2" --arg d "$3" \'.token=$t | .tokenDate=$d\' "$f" > "$tmp"; mv "$tmp" "$f"',
      "bash", configPath, token, Model.todayKey(Date.now())]
    writeConfigProc.running = true
  }

  // Display preferences round-trip through jq like the token: values go into
  // the state file without ever touching a QML command line. The FileView's
  // change watcher then re-reads the file, so `config` converges on disk.
  Process {
    id: writePrefsProc
    running: false
    command: []
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("octopus-usage prefs", text.trim())
    }
  }

  function setBarMetric(metric) {
    if (config.barMetric === metric) return
    var next = Object.assign({}, config, { barMetric: metric })
    config = next
    persistPrefs()
  }

  function setChartMetric(metric) {
    if (config.chartMetric === metric) return
    var next = Object.assign({}, config, { chartMetric: metric })
    config = next
    persistPrefs()
  }

  function persistPrefs() {
    writePrefsProc.command = ["bash", "-c",
      'set -e; umask 077; f="$1"; [ -f "$f" ] || exit 0; ' +
      'tmp="$(mktemp)"; jq --arg b "$2" --arg c "$3" \'.barMetric=$b | .chartMetric=$c\' "$f" > "$tmp"; mv "$tmp" "$f"',
      "bash", configPath, config.barMetric, config.chartMetric]
    writePrefsProc.running = true
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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    horizontalMargin: 6
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
              value: Model.formatDuration(root.totalMetric.waitTime / 1000)
            }
          }

          // ---- Last 14 days chart ----

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader {
            text: "LAST 14 DAYS · " + (root.chartMetric === "tokens" ? "TOKENS" : "COST")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item {
            id: chartRoot
            width: parent.width
            height: Style.space(72)
            visible: root.chartDays.length > 0

            readonly property real peakValue: {
              var peak = 0
              for (var i = 0; i < root.chartDays.length; i++)
                peak = Math.max(peak, Model.chartValue(root.chartDays[i], root.chartMetric))
              return peak
            }
            readonly property real barWidth: root.chartDays.length > 0
              ? (width - (root.chartDays.length - 1) * row.spacing) / root.chartDays.length : 0
            readonly property string todayKey: Model.todayKey(root.nowMs)
            // Space reserved below the axis line for the date labels.
            readonly property real labelHeight: Style.space(14)
            // Hover state: which day is focused and where its bar sits,
            // so the floating label can follow the bar top.
            property int hoveredIndex: -1
            property real hoveredCenterX: 0
            readonly property real hoveredBarTop: {
              if (hoveredIndex < 0) return 0
              var value = Model.chartValue(root.chartDays[hoveredIndex], root.chartMetric)
              var h = peakValue > 0 ? Math.max(2, (value / peakValue) * (height - labelHeight)) : 2
              return height - labelHeight - h
            }

            Row {
              id: row
              anchors.fill: parent

              Repeater {
                model: root.chartDays

                delegate: Item {
                  id: barDelegate

                  required property var modelData
                  required property int index
                  width: chartRoot.barWidth
                  height: parent.height

                  readonly property real dayValue: Model.chartValue(modelData, root.chartMetric)
                  readonly property bool isToday: String(modelData.date || "") === chartRoot.todayKey
                  readonly property real barHeight: chartRoot.peakValue > 0
                    ? Math.max(2, (dayValue / chartRoot.peakValue) * (height - chartRoot.labelHeight)) : 2

                  HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: {
                      if (hovered) {
                        chartRoot.hoveredIndex = barDelegate.index
                        chartRoot.hoveredCenterX = barDelegate.x + barDelegate.width / 2
                      } else if (chartRoot.hoveredIndex === barDelegate.index) {
                        chartRoot.hoveredIndex = -1
                      }
                    }
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: chartRoot.labelHeight
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(2, parent.width - Style.space(2))
                    height: parent.barHeight
                    radius: Math.min(2, width / 2)
                    color: barDelegate.hovered
                      ? root.foreground
                      : (barDelegate.isToday ? root.urgent : Qt.darker(root.foreground, 1.8))
                    // Pop the hovered bar up from its base and dim the rest.
                    scale: barDelegate.hovered ? 1.18 : 1
                    transformOrigin: Item.Bottom
                    opacity: chartRoot.hoveredIndex >= 0 && !barDelegate.hovered ? 0.4 : 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                  }

                  Text {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Model.dayOfMonth(modelData.date)
                    color: barDelegate.hovered || barDelegate.isToday
                      ? root.foreground : Qt.darker(root.foreground, 1.8)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    Behavior on color { ColorAnimation { duration: 120 } }
                  }
                }
              }
            }

            // Axis line separating bars from date labels.
            Rectangle {
              anchors.bottom: parent.bottom
              anchors.bottomMargin: chartRoot.labelHeight
              width: parent.width
              height: 1
              color: Qt.darker(root.foreground, 1.8)
            }

            // Floating label for the hovered day, gliding along bar tops.
            Rectangle {
              id: hoverTip
              readonly property bool shown: chartRoot.hoveredIndex >= 0
              opacity: shown ? 1 : 0
              visible: opacity > 0
              y: Math.max(0, chartRoot.hoveredBarTop - height - Style.space(4))
              x: Math.max(0, Math.min(chartRoot.width - width, chartRoot.hoveredCenterX - width / 2))
              width: hoverTipText.implicitWidth + Style.space(14)
              height: hoverTipText.implicitHeight + Style.space(6)
              radius: height / 2
              color: Color.tooltip.background
              border.width: 1
              border.color: Color.tooltip.border
              Behavior on opacity { NumberAnimation { duration: 120 } }
              Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
              Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

              Text {
                id: hoverTipText
                anchors.centerIn: parent
                text: {
                  var day = hoverTip.shown ? root.chartDays[chartRoot.hoveredIndex] : null
                  if (!day) return ""
                  var m = Model.metric(day)
                  // Lead with the metric the chart is measuring; the other one
                  // stays visible so no information is lost on switch.
                  var main = root.chartMetric === "tokens"
                    ? Model.formatTokenCount(m.inputToken + m.outputToken) + " tok"
                    : Model.formatMoney(m.inputCost + m.outputCost)
                  var other = root.chartMetric === "tokens"
                    ? Model.formatMoney(m.inputCost + m.outputCost)
                    : Model.formatTokenCount(m.inputToken + m.outputToken) + " tok"
                  return Model.shortDate(day.date) + " · " + main + " · " + other
                }
                color: Color.tooltip.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Display ----
          //
          // Collapsed-by-default box: clicking the header reveals chip rows
          // that pick what the bar pill shows and what the chart measures.
          // Both choices persist into the state file (jq write, like the
          // token) and survive panel restarts.

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              id: displayHeader
              width: parent.width
              height: displayHeaderRow.height

              RowLayout {
                id: displayHeaderRow
                width: parent.width

                Text {
                  text: "DISPLAY"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  // Same overshoot reservation as PanelSectionHeader.
                  topPadding: Math.ceil(font.pixelSize * 0.15)
                }

                Item { Layout.fillWidth: true }

                Text {
                  text: root.settingsOpen ? "▾" : "▸"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.settingsOpen = !root.settingsOpen
              }
            }

            Item {
              width: parent.width
              height: root.settingsOpen ? prefsContent.implicitHeight : 0
              clip: true

              Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

              Column {
                id: prefsContent
                width: parent.width
                spacing: Style.space(8)

                PrefsRow {
                  width: parent.width
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  label: "Bar pill shows"
                  options: [["tokens", "Tokens"], ["cost", "Cost"], ["requests", "Requests"]]
                  current: root.config.barMetric
                  onPicked: function(key) { root.setBarMetric(key) }
                }

                PrefsRow {
                  width: parent.width
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  label: "Chart shows"
                  options: [["cost", "Cost"], ["tokens", "Tokens"]]
                  current: root.config.chartMetric
                  onPicked: function(key) { root.setChartMetric(key) }
                }
              }
            }
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

  // Caption label + a run of mutually exclusive chips. `options` is an array
  // of [key, label] pairs; `current` marks the selected key and clicking a
  // chip emits `picked(key)`.
  component PrefsRow: Column {
    id: prefsRow
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    property string label: ""
    property var options: []
    property string current: ""
    signal picked(string key)

    spacing: Style.spacing.sm

    Text {
      text: prefsRow.label
      color: Qt.darker(prefsRow.foreground, 1.4)
      font.family: prefsRow.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      spacing: Style.spacing.sm

      Repeater {
        model: prefsRow.options

        delegate: OptionChip {
          required property var modelData
          text: modelData[1]
          checked: prefsRow.current === modelData[0]
          foreground: prefsRow.foreground
          fontFamily: prefsRow.fontFamily
          onClicked: prefsRow.picked(modelData[0])
        }
      }
    }
  }

  // Small pill button used by PrefsRow; `checked` is the selected state.
  component OptionChip: Rectangle {
    id: chip
    property string text: ""
    property bool checked: false
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    signal clicked()

    readonly property real padX: Style.space(12)
    readonly property real padY: Style.space(5)
    width: chipText.implicitWidth + padX * 2
    height: chipText.implicitHeight + padY * 2
    radius: height / 2
    color: checked ? foreground : "transparent"
    border.width: 1
    border.color: checked ? foreground : Qt.darker(foreground, 1.8)

    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.text
      color: chip.checked ? Color.background : Qt.darker(chip.foreground, 1.4)
      font.family: chip.fontFamily
      font.pixelSize: Style.font.caption

      Behavior on color { ColorAnimation { duration: 120 } }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }
}
