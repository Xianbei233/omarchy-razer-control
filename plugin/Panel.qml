import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "xianbei233.razer-control"
  ipcTarget: "xianbei233.razer-control"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string diagnosticTag: "unassigned"
  property var diagnosticCounts: ({})
  property var status: ({})
  // Reversible layout bisection: empty, fan-only, performance-only,
  // lighting-only, Logo sub-stages, keyboard sub-stages, full-layout-only, or full.
  // Only full permits backend requests; full-layout-only is the safe UI pass.
  property string diagnosticStage: "full"
  readonly property bool diagnosticEmptyPanel: diagnosticStage === "empty"
  readonly property bool diagnosticFanOnly: diagnosticStage === "fan-only"
  readonly property bool diagnosticPerformanceOnly: diagnosticStage === "performance-only"
  readonly property bool diagnosticLightingOnly: diagnosticStage === "lighting-only"
  readonly property bool diagnosticLogoOnly: diagnosticStage === "logo-only"
  readonly property bool diagnosticLogoReadoutOnly: diagnosticStage === "logo-readout-only"
  readonly property bool diagnosticLogoControlsOnly: diagnosticStage === "logo-controls-only"
  readonly property bool diagnosticKeyboardOnly: diagnosticStage === "keyboard-only"
  readonly property bool diagnosticKeyboardReadoutOnly: diagnosticStage === "keyboard-readout-only"
  readonly property bool diagnosticKeyboardHeadingOnly: diagnosticStage === "keyboard-heading-only"
  readonly property bool diagnosticKeyboardModeOnly: diagnosticStage === "keyboard-mode-text-only"
  readonly property bool diagnosticKeyboardEffectsOnly: diagnosticStage === "keyboard-effects-only"
  readonly property bool diagnosticKeyboardColorsOnly: diagnosticStage === "keyboard-colors-only"
  readonly property bool diagnosticKeyboardBrightnessOnly: diagnosticStage === "keyboard-brightness-only"
  readonly property bool diagnosticKeyboardPage: diagnosticKeyboardOnly || diagnosticKeyboardReadoutOnly ||
    diagnosticKeyboardHeadingOnly || diagnosticKeyboardModeOnly ||
    diagnosticKeyboardEffectsOnly || diagnosticKeyboardColorsOnly || diagnosticKeyboardBrightnessOnly
  readonly property bool diagnosticFullLayoutOnly: diagnosticStage === "full-layout-only"
  readonly property bool diagnosticFull: diagnosticStage === "full"
  property string errorText: ""
  property string resultText: ""
  property var pendingArgs: []
  property bool busy: false
  // Retained for the isolated fan-only diagnostic component.
  property int cpuRpm: 5400
  property int gpuRpm: 5400
  property int fanTargetRpm: 5400
  property int brightness: 100
  property int red: 255
  property int green: 255
  property int blue: 255
  property int speed: 1
  property int direction: 1

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color mutedFg: Qt.darker(fg, 1.45)
  readonly property color accent: Color.accent
  readonly property color errorColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function diagnosticBegin(event, detail) {
    var count = Number(diagnosticCounts[event] || 0)
    if (count >= 5) return 0
    diagnosticCounts[event] = count + 1
    console.info("[razer-diag] instance=" + diagnosticTag + " panel." + event + "#" + (count + 1) + " begin " + detail)
    return count + 1
  }
  function diagnosticEnd(event, sequence, detail) {
    if (!sequence) return
    console.info("[razer-diag] instance=" + diagnosticTag + " panel." + event + "#" + sequence + " end " + detail)
  }

  function field(name) {
    var fields = status && status.fields ? status.fields : null
    var entry = fields ? fields[name] : null
    return entry && entry.ok === true ? entry.value : null
  }
  function fieldError(name) {
    var entry = status && status.fields ? status.fields[name] : null
    return entry && entry.ok === false ? String(entry.error || "此功能不可用") : ""
  }
  function currentPerformanceLevel(device) {
    var value = field(String(device) + "_performance")
    if (!value || !Number.isFinite(Number(value.level))) return -1
    var level = Number(value.level), max = device === "cpu" ? 3 : 2
    return Number.isInteger(level) && level >= 0 && level <= max ? level : -1
  }
  function currentLogoChoice() {
    var value = field("logo")
    if (!value) return ""
    if (value.enabled === false) return "off"
    return Number(value.mode) === 2 ? "breathing" : Number(value.mode) === 0 ? "static" : ""
  }
  function keyboardEffectFromStatus() {
    var value = field("keyboard")
    if (!value) return ""
    return ({0:"off",1:"wave",2:"reactive",4:"spectrum",6:"static",7:"starlight",25:"starlight"})[Number(value.mode)] || ""
  }
  readonly property string displayedLogoChoice: currentLogoChoice()
  readonly property string displayedEffect: keyboardEffectFromStatus()
  readonly property bool keyboardColorSupported: ["reactive", "static", "starlight"].indexOf(displayedEffect) >= 0
  function canWrite(name) { return !busy && !process.running && status && status.ok === true && field(name) !== null }
  function request(args) {
    if (!diagnosticFull || busy || !Array.isArray(args) || args.length === 0) return
    if (process.running) {
      errorText = "前一次操作仍在结束；请稍候，确认状态后再操作。"
      return
    }
    // Keep the shell program constant and pass every backend argument as a
    // separate positional parameter; no UI value is ever interpolated into it.
    var words = ["/bin/sh", "-c",
      "command -v omarchy-razer-control >/dev/null 2>&1 || { printf '%s\\n' '{\"ok\":false,\"error\":\"找不到 omarchy-razer-control；请确认后端已安装且可执行。\"}'; exit 127; }; exec omarchy-razer-control \"$@\"",
      "razer-control"]
    for (var i = 0; i < args.length; i++) words.push(String(args[i]))
    errorText = ""
    resultText = ""
    pendingStdout = ""
    pendingStderr = ""
    pendingArgs = args.slice(0)
    process.command = words
    busy = true
    process.running = true
  }
  function readbackMatches(args, data) {
    var cmd = String(args[0] || "")
    var fields = data.fields || {}
    function value(name) { return fields[name] && fields[name].ok === true ? fields[name].value : null }
    if (cmd === "fan-auto") { var af = value("fan"); return !!af && af.manual === false }
    if (cmd === "fan") {
      var fan = value("fan"), cpu = value("cpu_fan"), gpu = value("gpu_fan")
      return !!fan && !!cpu && !!gpu && fan.manual === true && Number(cpu.target_rpm) === Number(args[1]) && Number(gpu.target_rpm) === Number(args[2])
    }
    if (cmd === "performance") {
      var perf = value(String(args[1]) + "_performance"), pf = value("fan")
      return !!perf && !!pf && Number(perf.level) === Number(args[2]) && pf.performance_mode === 4 && pf.manual === false && data.settings && data.settings.last_outcome === "readback_verified"
    }
    if (cmd === "logo") {
      var logo = value("logo")
      return !!logo && logo.enabled === (args[1] !== "off") && (args[1] === "off" || Number(logo.mode) === (args[1] === "breathing" ? 2 : 0))
    }
    if (cmd === "brightness") {
      var bright = value("brightness"), expected = (Number(args[1]) * 255 + 50) / 100
      return !!bright && Number(bright.byte) === Math.floor(expected)
    }
    if (cmd === "keyboard") {
      if (args[1] === "wave") return false // Firmware readback omits direction.
      var keyboard = value("keyboard"), raw = keyboard && keyboard.raw
      if (!raw) return false
      var mode = String(args[1]), expectedRaw = mode === "off" ? [0]
        : mode === "spectrum" ? [4]
        : mode === "static" ? [6, Number(args[4]), Number(args[5]), Number(args[6])]
        : mode === "reactive" ? [2, Number(args[2]), Number(args[4]), Number(args[5]), Number(args[6])]
        : [7, 1, Number(args[2]), Number(args[4]), Number(args[5]), Number(args[6])]
      for (var i = 0; i < expectedRaw.length; i++) if (Number(raw[i]) !== expectedRaw[i]) return false
      return true
    }
    return false
  }
  function parseResult(raw, exitCode) {
    var data = null
    try { data = JSON.parse(String(raw || "").trim()) } catch (e) {
      data = { ok: false, error: "后端返回了无法识别的 JSON。请检查命令输出后手动刷新。" }
    }
    if (!data || typeof data !== "object" || Array.isArray(data))
      data = { ok: false, error: "后端没有返回有效状态对象。" }
    if (exitCode !== 0 || data.ok !== true) {
      errorText = String(data.error || (exitCode === 127
        ? "找不到 omarchy-razer-control。请确认后端已安装并可从 PATH 运行。"
        : "读取或操作失败（退出码 " + exitCode + "）。"))
      // Keep last-known fields for context, but make the failure unmistakable.
      pendingArgs = []
      return
    }
    status = data
    var keyboard = field("keyboard")
    var rawKeyboard = keyboard && Array.isArray(keyboard.raw) ? keyboard.raw : []
    var colorOffset = Number(keyboard && keyboard.mode) === 6 ? 1
      : Number(keyboard && keyboard.mode) === 2 ? 2
      : (Number(keyboard && keyboard.mode) === 7 || Number(keyboard && keyboard.mode) === 25) ? 3 : -1
    var speedOffset = Number(keyboard && keyboard.mode) === 2 ? 1
      : (Number(keyboard && keyboard.mode) === 7 || Number(keyboard && keyboard.mode) === 25) ? 2 : -1
    if (speedOffset >= 0 && rawKeyboard.length > speedOffset) {
      var readSpeed = Number(rawKeyboard[speedOffset])
      if (Number.isFinite(readSpeed) && readSpeed >= 1 && readSpeed <= 15) speed = readSpeed
    }
    if (colorOffset >= 0 && rawKeyboard.length >= colorOffset + 3) {
      var readRed = Number(rawKeyboard[colorOffset]), readGreen = Number(rawKeyboard[colorOffset + 1]), readBlue = Number(rawKeyboard[colorOffset + 2])
      if ([readRed, readGreen, readBlue].every(function(value) { return Number.isFinite(value) && value >= 0 && value <= 255 })) {
        red = readRed; green = readGreen; blue = readBlue
      }
    }
    errorText = ""
    var completedArgs = pendingArgs.slice(0)
    pendingArgs = []
    if (completedArgs.length && completedArgs[0] !== "status") {
      if (readbackMatches(completedArgs, data)) resultText = "操作成功 · 设备读回已确认"
      else if (completedArgs[0] === "keyboard" && completedArgs[1] === "wave") resultText = "设备已应答，但方向无法读回确认；请观察灯效"
      else resultText = "设备已返回状态，但未能确认本次设置；请刷新核对"
    }
    var cpu = field("cpu_fan"), gpu = field("gpu_fan"), light = field("brightness")
    if (cpu && gpu && Number.isFinite(Number(cpu.target_rpm)) && Number.isFinite(Number(gpu.target_rpm)))
      fanTargetRpm = Number(cpu.target_rpm)
    if (light && Number.isFinite(Number(light.percent))) brightness = Number(light.percent)
  }
  function openFromHotkey() {
    var openSeq = diagnosticBegin("openFromHotkey", "opened=" + root.opened + " controllerOpen=" + root.controller.open)
    var showSeq = diagnosticBegin("controller.show", "openedBefore=" + root.opened + " controllerOpenBefore=" + root.controller.open)
    root.controller.show()
    diagnosticEnd("controller.show", showSeq, "openedAfter=" + root.opened + " controllerOpenAfter=" + root.controller.open)
    Qt.callLater(function() {
      var focusSeq = root.diagnosticBegin("focus.callLater", "callback opened=" + root.opened)
      if (root.opened) {
        var forceSeq = root.diagnosticBegin("focus.forceActiveFocus", "target=PanelKeyCatcher")
        keyCatcher.forceActiveFocus()
        root.diagnosticEnd("focus.forceActiveFocus", forceSeq, "activeFocus=" + keyCatcher.activeFocus)
      }
      root.diagnosticEnd("focus.callLater", focusSeq, "opened=" + root.opened + " activeFocus=" + keyCatcher.activeFocus)
    })
    if (diagnosticFull) {
      var requestSeq = diagnosticBegin("statusRequest", "command=status busy=" + busy + " processRunning=" + process.running)
      request(["status"])
      diagnosticEnd("statusRequest", requestSeq, "busy=" + busy + " processRunning=" + process.running)
    }
    // Match the native panel handoff: wait until show() has asked the bar's
    // popout coordinator to close the previous owner before setting this flag.
    Qt.callLater(function() {
      var suppressionSeq = root.diagnosticBegin("centerHover.callLater", "callback opened=" + root.opened)
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
      root.diagnosticEnd("centerHover.callLater", suppressionSeq, "opened=" + root.opened)
    })
    diagnosticEnd("openFromHotkey", openSeq, "opened=" + root.opened + " controllerOpen=" + root.controller.open)
  }
  function open() { openFromHotkey() }
  function close() {
    var seq = diagnosticBegin("close", "openedBefore=" + root.opened + " controllerOpenBefore=" + root.controller.open)
    root.setCenterHoverRevealSuppressed(false)
    root.controller.hide()
    diagnosticEnd("close", seq, "openedAfter=" + root.opened + " controllerOpenAfter=" + root.controller.open)
  }
  function toggle() { if (opened) close(); else openFromHotkey() }
  function switchPanel(directionValue) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(hostWidget || root, directionValue)
    return false
  }
  function setCenterHoverRevealSuppressed(value) {
    var before = bar && "centerHoverRevealSuppressed" in bar ? bar.centerHoverRevealSuppressed : "unavailable"
    var seq = diagnosticBegin("centerHover.set", "requested=" + value + " opened=" + root.opened + " before=" + before)
    if (bar && typeof bar.setCenterHoverRevealSuppressed === "function")
      bar.setCenterHoverRevealSuppressed(value)
    else if (bar && "centerHoverRevealSuppressed" in bar)
      bar.centerHoverRevealSuppressed = value
    var after = bar && "centerHoverRevealSuppressed" in bar ? bar.centerHoverRevealSuppressed : "unavailable"
    diagnosticEnd("centerHover.set", seq, "requested=" + value + " after=" + after)
  }
  Component.onDestruction: root.close()
  function moveKeyboardFocus(forward) {
    var current = popup.activeFocusItem || keyCatcher
    for (var i = 0; i < 80; i++) {
      current = current.nextItemInFocusChain(forward)
      if (!current || current === keyCatcher) {
        keyCatcher.forceActiveFocus()
        return
      }
      if (current.visible && current.enabled && current.activeFocusOnTab) {
        current.forceActiveFocus()
        return
      }
    }
    keyCatcher.forceActiveFocus()
  }
  function activateKeyboardFocus() {
    var current = popup.activeFocusItem
    if (current && current !== keyCatcher && current.enabled && typeof current.clicked === "function")
      current.clicked()
  }

  Process {
    id: process
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.pendingStdout = String(text || "") }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.pendingStderr = String(text || "") }
    onExited: function(exitCode) {
      if (!root.busy) return
      root.busy = false
      var raw = root.pendingStdout
      if (!String(raw || "").trim() && root.pendingStderr)
        raw = JSON.stringify({ ok: false, error: root.pendingStderr.trim() })
      root.pendingStdout = ""
      root.pendingStderr = ""
      root.parseResult(raw, exitCode)
    }
  }
  Timer {
    id: commandTimeout
    interval: 18000
    repeat: false
    running: root.busy
    onTriggered: {
      if (!root.busy) return
      root.errorText = "后端运行超时；操作结果未知。已停止等待，不会自动重试，请手动刷新状态。"
      root.pendingArgs = []
      process.running = false
      root.busy = false
    }
  }
  property string pendingStdout: ""
  property string pendingStderr: ""

  RazerKeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    diagnosticTag: root.diagnosticTag
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: root.diagnosticEmptyPanel
      ? popup.fittedContentWidth(Style.space(240), Style.space(320))
      : popup.fittedContentWidth(Style.space(420))
    contentHeight: root.diagnosticEmptyPanel
      ? popup.fittedContentHeight(Style.space(52), Style.space(120))
      : root.diagnosticFanOnly
        ? popup.fittedContentHeight(Style.space(520), Style.space(620))
        : root.diagnosticPerformanceOnly
          ? popup.fittedContentHeight(Style.space(520), Style.space(620))
          : root.diagnosticLightingOnly
            ? popup.fittedContentHeight(Style.space(520), Style.space(620))
            : root.diagnosticLogoOnly
              ? popup.fittedContentHeight(Style.space(520), Style.space(620))
              : root.diagnosticLogoReadoutOnly || root.diagnosticLogoControlsOnly
                ? popup.fittedContentHeight(Style.space(520), Style.space(620))
              : root.diagnosticKeyboardPage
                ? popup.fittedContentHeight(Style.space(520), Style.space(620))
        : popup.fittedContentHeight(fullContentLoader.item ? fullContentLoader.item.implicitHeight : 0, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(d) { root.moveKeyboardFocus(d > 0) }
      onMoveRequested: function(dx, dy) { root.moveKeyboardFocus(dx > 0 || dy > 0) }
      onActivateRequested: root.activateKeyboardFocus()

      Text {
        anchors.centerIn: parent
        width: parent.width
        visible: root.diagnosticEmptyPanel
        text: "空面板诊断"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Loader {
        id: fullContentLoader
        anchors.fill: parent
        active: root.diagnosticFull || root.diagnosticFullLayoutOnly
        sourceComponent: fullPanelContent
      }

      Loader {
        id: fanOnlyLoader
        anchors.fill: parent
        active: root.diagnosticFanOnly
        sourceComponent: fanPageComponent
      }

      Loader {
        id: performanceOnlyLoader
        anchors.fill: parent
        active: root.diagnosticPerformanceOnly
        sourceComponent: performancePageComponent
      }

      Loader {
        id: lightingOnlyLoader
        anchors.fill: parent
        active: root.diagnosticLightingOnly
        sourceComponent: lightingPageComponent
      }

      Loader {
        id: logoOnlyLoader
        anchors.fill: parent
        active: root.diagnosticLogoOnly || root.diagnosticLogoReadoutOnly || root.diagnosticLogoControlsOnly
        sourceComponent: logoOnlyComponent
      }

      Loader {
        id: keyboardOnlyLoader
        anchors.fill: parent
        active: root.diagnosticKeyboardPage
        sourceComponent: keyboardOnlyComponent
      }

      Component {
        id: fanPageComponent

        Item {
          width: parent.width
          implicitHeight: fanColumn.implicitHeight
          enabled: root.diagnosticFull

          Flickable {
            id: fanScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: fanColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: fanColumn
              width: fanScroll.width
              spacing: Style.space(12)

              Text {
                visible: root.diagnosticFanOnly
                text: "风扇页布局诊断"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Button {
                visible: root.diagnosticFanOnly
                text: "风扇"
                selected: true
                enabled: false
                focusable: false
                Accessible.name: "风扇页布局诊断（不可操作）"
              }

              Column {
                width: parent.width
                spacing: Style.space(10)

                Text { text: "风扇状态"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                Text {
                  width: parent.width
                  text: {
                    var f = root.field("fan")
                    if (!f) return root.fieldError("fan") || "风扇状态未知；请刷新或检查设备权限。"
                    return f.manual ? "当前为手动风扇模式" : "当前为固件自动风扇模式"
                  }
                  color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.Wrap
                }
                Text {
                  width: parent.width
                  text: {
                    var c = root.field("cpu_fan"), g = root.field("gpu_fan")
                    return "CPU / GPU 实时转速：不可用\n手动设定值：CPU " + (c ? c.target_rpm + " RPM" : "—") + " · GPU " + (g ? g.target_rpm + " RPM" : "—") + "\n设定值不是测速结果。"
                  }
                  color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap
                }
                Text { text: root.fieldError("fan") || root.fieldError("cpu_fan") || root.fieldError("gpu_fan"); visible: text !== ""; color: root.errorColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
                Button { focusable: true; text: "恢复自动风扇"; enabled: root.canWrite("fan"); onClicked: root.request(["fan-auto"]) }
                Text { text: "CPU 手动目标 · " + root.cpuRpm + " RPM"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Slider { width: parent.width; from: 4000; to: 5400; stepSize: 100; value: root.cpuRpm; enabled: root.canWrite("fan") && root.status.settings && root.status.settings.verified_fan_range; onMoved: root.cpuRpm = Math.round(value) }
                Text { text: "GPU 手动目标 · " + root.gpuRpm + " RPM"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Slider { width: parent.width; from: 4000; to: 5400; stepSize: 100; value: root.gpuRpm; enabled: root.canWrite("fan") && root.status.settings && root.status.settings.verified_fan_range; onMoved: root.gpuRpm = Math.round(value) }
                Button { focusable: true; text: "应用手动风扇"; enabled: root.canWrite("fan") && root.status.settings && root.status.settings.verified_fan_range; onClicked: root.request(["fan", root.cpuRpm, root.gpuRpm]) }
                Text { width: parent.width; text: root.status.settings && root.status.settings.verified_fan_range ? "手动范围已通过本机验证。" : "手动调速未解锁：本机尚无已验证范围。"; color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
              }
            }
          }
        }
      }

      Component {
        id: performancePageComponent

        Item {
          width: parent.width
          implicitHeight: performanceColumn.implicitHeight
          enabled: root.diagnosticFull

          Flickable {
            id: performanceScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: performanceColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: performanceColumn
              width: performanceScroll.width
              spacing: Style.space(12)

              Text {
                visible: root.diagnosticPerformanceOnly
                text: "性能页布局诊断 · CPU/GPU"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Button {
                visible: root.diagnosticPerformanceOnly
                text: "性能"
                selected: true
                enabled: false
                focusable: false
                Accessible.name: "性能页布局诊断（不可操作）"
              }

              Column {
                width: parent.width
                spacing: Style.space(10)
                Text { text: "性能档位"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                Text { width: parent.width; text: "选择档位会立即应用，并切回自动风扇。只有设备读回确认后才会显示成功。"; color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
                Repeater {
                  model: ["cpu", "gpu"]
                  Column {
                    required property string modelData
                    readonly property string device: modelData
                    width: parent.width; spacing: Style.space(5)
                    Text {
                      text: parent.device.toUpperCase() + " · " + (root.field(parent.device + "_performance") ? ["低", "中", "高", "增强"][root.field(parent.device + "_performance").level] || "未知档位" : "状态不可用")
                      color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
                    }
                    Row {
                      width: parent.width; spacing: Style.space(4)
                      Repeater {
                        model: device === "cpu" ? ["低", "中", "高", "增强"] : ["低", "中", "高"]
                        Button {
                          required property int index
                          required property string modelData
                          focusable: true
                          width: (parent.width - Style.space(12)) / (device === "cpu" ? 4 : 3)
                          text: modelData
                          enabled: root.canWrite(device === "cpu" ? "cpu_performance" : "gpu_performance")
                          onClicked: root.request(["performance", device, index])
                          Accessible.name: device.toUpperCase() + "性能档位 " + modelData
                        }
                      }
                    }
                    Text { width: parent.width; text: root.fieldError(device + "_performance"); visible: text !== ""; color: root.errorColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
                  }
                }
                Text { text: "静音 / 均衡模式尚未由后端实现。"; color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              }
            }
          }
        }
      }

      Component {
        id: lightingPageComponent

        Item {
          width: parent.width
          implicitHeight: lightingColumn.implicitHeight
          enabled: root.diagnosticFull

          Flickable {
            id: lightingScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: lightingColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: lightingColumn
              width: lightingScroll.width
              spacing: Style.space(9)

              Text {
                visible: root.diagnosticLightingOnly
                text: "灯光页布局诊断 · Logo/键盘"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Button {
                visible: root.diagnosticLightingOnly
                text: "灯光"
                selected: true
                enabled: false
                focusable: false
                Accessible.name: "灯光页布局诊断（不可操作）"
              }

              Text {
                width: parent.width
                text: "Logo"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Loader {
                width: parent.width
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: logoControlsComponent
              }
              Text {
                width: parent.width
                visible: root.displayedLogoChoice === "" && root.fieldError("logo") === ""
                  && !root.busy && root.errorText === ""
                text: "Logo 状态未知，暂无选中项。"
                color: root.mutedFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Loader {
                width: parent.width
                visible: root.fieldError("logo") !== ""
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: logoErrorComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: keyboardHeadingComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: keyboardEffectsComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: keyboardColorsComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: keyboardApplyComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticFull || root.diagnosticLightingOnly || root.diagnosticFullLayoutOnly
                sourceComponent: keyboardBrightnessComponent
              }
            }
          }
        }
      }

      Component {
        id: logoOnlyComponent

        Item {
          width: parent.width
          implicitHeight: logoOnlyColumn.implicitHeight
          enabled: root.diagnosticFull

          Flickable {
            id: logoOnlyScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: logoOnlyColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: logoOnlyColumn
              width: logoOnlyScroll.width
              spacing: Style.space(12)

              Text {
                text: root.diagnosticLogoReadoutOnly ? "Logo 状态布局诊断"
                  : root.diagnosticLogoControlsOnly ? "Logo 控件布局诊断" : "Logo 布局诊断"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Button {
                text: "Logo"
                selected: true
                enabled: false
                focusable: false
                Accessible.name: "Logo 布局诊断（不可操作）"
              }

              Column {
                width: parent.width
                spacing: Style.space(9)
                Loader {
                  width: parent.width
                  active: root.diagnosticLogoOnly || root.diagnosticLogoReadoutOnly
                  sourceComponent: logoReadoutComponent
                }
                Loader {
                  width: parent.width
                  active: root.diagnosticLogoOnly || root.diagnosticLogoControlsOnly
                  sourceComponent: logoControlsComponent
                }
              }
            }
          }
        }
      }

      Component {
        id: logoReadoutComponent
        Column {
          width: parent.width
          spacing: Style.space(9)
          Loader { width: parent.width; active: true; sourceComponent: logoStateComponent }
          Loader { width: parent.width; visible: root.fieldError("logo") !== ""; active: true; sourceComponent: logoErrorComponent }
        }
      }

      Component {
        id: logoStateComponent
        Column {
          width: parent.width
          spacing: Style.space(9)
          Text { text: "Logo 灯"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Text {
            text: {
              var v = root.field("logo")
              return v ? (v.enabled ? (v.mode === 2 ? "当前：呼吸" : "当前：常亮") : "当前：关闭") : (root.fieldError("logo") || "状态未知")
            }
            color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption
          }
        }
      }

      Component {
        id: logoErrorComponent
        Text {
          width: parent.width
          text: root.fieldError("logo")
          visible: text !== ""
          color: root.errorColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }

      Component {
        id: logoControlsComponent
        Row {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: [{label:"关闭", value:"off"}, {label:"常亮", value:"static"}, {label:"呼吸", value:"breathing"}]
            Button {
              required property var modelData
              focusable: true
              text: modelData.label; enabled: root.diagnosticFull && root.canWrite("logo")
              selected: root.displayedLogoChoice === modelData.value
              onClicked: root.request(["logo", modelData.value])
              Accessible.name: "Logo 灯" + modelData.label + "，点击立即切换"
            }
          }
        }
      }

      Component {
        id: keyboardOnlyComponent

        Item {
          width: parent.width
          implicitHeight: keyboardOnlyColumn.implicitHeight
          enabled: root.diagnosticFull

          Flickable {
            id: keyboardOnlyScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: keyboardOnlyColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: keyboardOnlyColumn
              width: keyboardOnlyScroll.width
              spacing: Style.space(12)

              Text {
                text: root.diagnosticKeyboardHeadingOnly ? "键盘标题布局诊断"
                  : root.diagnosticKeyboardModeOnly ? "键盘状态文字布局诊断"
                  : root.diagnosticKeyboardReadoutOnly ? "键盘状态布局诊断"
                  : root.diagnosticKeyboardEffectsOnly ? "键盘灯效布局诊断"
                  : root.diagnosticKeyboardColorsOnly ? "键盘颜色控件布局诊断"
                  : root.diagnosticKeyboardBrightnessOnly ? "键盘亮度布局诊断"
                  : "键盘灯光布局诊断"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Button {
                text: "键盘"
                selected: true
                enabled: false
                focusable: false
                Accessible.name: "键盘灯光布局诊断（不可操作）"
              }

              Loader {
                width: parent.width
                active: root.diagnosticKeyboardOnly || root.diagnosticKeyboardReadoutOnly || root.diagnosticKeyboardHeadingOnly
                sourceComponent: keyboardHeadingComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticKeyboardOnly || root.diagnosticKeyboardReadoutOnly || root.diagnosticKeyboardModeOnly
                sourceComponent: keyboardModeComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticKeyboardOnly || root.diagnosticKeyboardEffectsOnly
                sourceComponent: keyboardEffectsComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticKeyboardOnly || root.diagnosticKeyboardColorsOnly
                sourceComponent: keyboardColorsComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticKeyboardOnly || root.diagnosticKeyboardEffectsOnly
                sourceComponent: keyboardApplyComponent
              }
              Loader {
                width: parent.width
                active: root.diagnosticKeyboardOnly || root.diagnosticKeyboardBrightnessOnly
                sourceComponent: keyboardBrightnessComponent
              }
            }
          }
        }
      }

      Component {
        id: keyboardHeadingComponent
        Text {
          width: parent.width
          text: "键盘灯效"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Component {
        id: keyboardModeComponent
        Text {
          width: parent.width
          text: {
            var k = root.field("keyboard")
            return k ? "当前模式：" + ({0:"关闭",1:"波浪",2:"响应",4:"光谱",6:"静态",7:"星光",25:"星光"}[k.mode] || "未知模式") : (root.fieldError("keyboard") || "状态未知")
          }
          color: root.mutedFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Component {
        id: keyboardEffectsComponent
        Column {
          width: parent.width
          spacing: Style.space(9)
          Row {
            width: parent.width; spacing: Style.space(3)
            Repeater {
              model: [{label:"关",value:"off"},{label:"波浪",value:"wave"},{label:"响应",value:"reactive"},{label:"光谱",value:"spectrum"},{label:"静态",value:"static"},{label:"星光",value:"starlight"}]
              Button {
                required property var modelData
                focusable: true
                width: (parent.width - Style.space(15)) / 6
                text: modelData.label; enabled: root.diagnosticFull && root.canWrite("keyboard")
                selected: root.displayedEffect === modelData.value
                onClicked: root.request(["keyboard", modelData.value, root.speed, root.direction, root.red, root.green, root.blue])
                Accessible.name: "键盘灯效" + modelData.label + "，点击立即切换"
              }
            }
          }
          Row {
            visible: root.displayedEffect === "wave"
            spacing: Style.space(6)
            Button { focusable: true; text: "向左"; selected: false; enabled: root.diagnosticFull && root.canWrite("keyboard"); onClicked: { root.direction = 1; root.request(["keyboard", "wave", root.speed, 1, root.red, root.green, root.blue]) } }
            Button { focusable: true; text: "向右"; selected: false; enabled: root.diagnosticFull && root.canWrite("keyboard"); onClicked: { root.direction = 2; root.request(["keyboard", "wave", root.speed, 2, root.red, root.green, root.blue]) } }
          }
          Text { text: "速度 · " + root.speed; visible: ["reactive", "starlight"].indexOf(root.displayedEffect) >= 0; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Slider {
            width: parent.width; from: 1; to: 15; stepSize: 1; value: root.speed
            visible: ["reactive", "starlight"].indexOf(root.displayedEffect) >= 0
            enabled: root.diagnosticFull && root.canWrite("keyboard")
            property bool dragChanged: false
            onMoved: { root.speed = Math.round(value); dragChanged = true }
            onPressedChanged: if (!pressed && dragChanged) {
              dragChanged = false
              root.request(["keyboard", root.displayedEffect, root.speed, root.direction, root.red, root.green, root.blue])
            }
          }
        }
      }

      Component {
        id: keyboardApplyComponent
        Column {
          width: parent.width
          spacing: Style.space(9)
          Text { width: parent.width; text: "波浪方向无法读回。"; color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
        }
      }

      Component {
        id: keyboardColorsComponent
        Column {
          width: parent.width
          spacing: Style.space(5)
          Text {
            width: parent.width
            visible: !root.keyboardColorSupported && !root.busy && root.errorText === ""
            text: root.field("keyboard")
              ? (root.displayedEffect === "" ? "灯效状态未知，颜色已禁用。" : "当前灯效不支持颜色调节。")
              : (root.fieldError("keyboard") || "键盘灯效状态未知，颜色已禁用。")
            color: root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
          Row {
            width: parent.width
            spacing: Style.space(5)
            Repeater {
              model: [{name:"R", key:"red"},{name:"G", key:"green"},{name:"B", key:"blue"}]
              Column {
                required property var modelData
                width: (parent.width - Style.space(10)) / 3
                Text {
                  text: modelData.name + (root.keyboardColorSupported ? " · " + root[modelData.key] : " · —")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Slider {
                  width: parent.width; from: 0; to: 255; stepSize: 1; value: root[modelData.key]
                  enabled: root.diagnosticFull && root.keyboardColorSupported && root.canWrite("keyboard")
                  property bool dragChanged: false
                  onMoved: { root[modelData.key] = Math.round(value); dragChanged = true }
                  onPressedChanged: if (!pressed && dragChanged) {
                    dragChanged = false
                    if (root.keyboardColorSupported)
                      root.request(["keyboard", root.displayedEffect, root.speed, root.direction, root.red, root.green, root.blue])
                  }
                }
              }
            }
          }
        }
      }

      Component {
        id: keyboardBrightnessComponent
        Column {
          width: parent.width
          spacing: Style.space(9)
          Text { text: "键盘亮度 · " + (root.field("brightness") ? root.field("brightness").percent + "%" : "未知"); color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
          Text { text: root.fieldError("brightness"); visible: text !== ""; color: root.errorColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
          Slider {
            width: parent.width; from: 0; to: 100; stepSize: 1; value: root.brightness
            enabled: root.diagnosticFull && root.canWrite("brightness")
            property bool dragChanged: false
            onMoved: { root.brightness = Math.round(value); dragChanged = true }
            onPressedChanged: if (!pressed && dragChanged) {
              dragChanged = false
              root.request(["brightness", root.brightness])
            }
          }
        }
      }

      // Single-page production UI and the hardware-disabled layout diagnostic
      // share the same page tree. Only the explicit "full" stage can operate it.
      Component {
        id: fullPanelContent

        Item {
          width: parent.width
          implicitHeight: pageColumn.implicitHeight

          Flickable {
            id: pageScroll
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: pageColumn.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: pageColumn
              width: pageScroll.width
              spacing: Style.space(12)

              Text {
                visible: root.diagnosticFullLayoutOnly
                width: parent.width
                text: "布局诊断 · 操作已禁用"
                color: root.mutedFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  id: brandTitle
                  text: "Razer"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Item { width: Math.max(0, parent.width - brandTitle.width - refreshButton.width - Style.space(8)); height: 1 }
                Button {
                  id: refreshButton
                  text: "刷新"
                  focusable: true
                  enabled: root.diagnosticFull && !root.busy && !process.running
                  onClicked: root.request(["status"])
                  Accessible.name: "只读刷新设备状态"
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.busy || root.errorText !== "" || root.resultText !== ""
                Text {
                  visible: root.busy
                  text: root.pendingArgs.length && root.pendingArgs[0] === "status" ? "正在读取状态…" : "正在应用…"
                  color: root.mutedFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: root.errorText !== ""
                  width: parent.width
                  text: root.errorText
                  color: root.errorColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                Text {
                  visible: root.resultText !== ""
                  width: parent.width
                  text: root.resultText
                  color: root.resultText.indexOf("成功") === 0 ? root.accent : root.mutedFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }

              Text {
                visible: !root.busy && root.errorText === "" && root.resultText === ""
                  && (!root.status || root.status.ok !== true)
                text: root.diagnosticFullLayoutOnly ? "状态未读取" : "设备状态未知"
                color: root.mutedFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.fg; opacity: 0.12 }

              Column {
                width: parent.width
                spacing: Style.space(7)
                Text { text: "风扇"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                Row {
                  width: parent.width
                  height: Math.max(fanSlider.implicitHeight, autoFanButton.implicitHeight, fanTargetLabel.implicitHeight)
                  spacing: Style.space(6)
                  Text {
                    id: fanTargetLabel
                    text: "共同目标 · " + root.fanTargetRpm + " RPM"
                    color: root.mutedFg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Slider {
                    id: fanSlider
                    width: Math.max(0, parent.width - fanTargetLabel.width - autoFanButton.width - Style.space(12))
                    anchors.verticalCenter: parent.verticalCenter
                    from: 4000; to: 5400; stepSize: 100; value: root.fanTargetRpm
                    enabled: root.diagnosticFull && root.canWrite("fan") && root.status.settings && root.status.settings.verified_fan_range
                    property bool dragChanged: false
                    onMoved: { root.fanTargetRpm = Math.round(value); dragChanged = true }
                    onPressedChanged: {
                      if (!pressed && dragChanged) {
                        dragChanged = false
                        root.request(["fan", root.fanTargetRpm, root.fanTargetRpm])
                      }
                    }
                    Accessible.name: "CPU 与 GPU 共同手动目标转速"
                  }
                  Button {
                    id: autoFanButton
                    text: "自动"
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: root.diagnosticFull && root.canWrite("fan") && !!root.field("fan") && root.field("fan").manual === true
                    onClicked: root.request(["fan-auto"])
                    Accessible.name: "恢复自动风扇"
                  }
                }
                Text {
                  width: parent.width
                  text: {
                    var fan = root.field("fan")
                    var cpu = root.field("cpu_fan"), gpu = root.field("gpu_fan")
                    var cpuTarget = cpu && Number.isFinite(Number(cpu.target_rpm)) ? Number(cpu.target_rpm) : null
                    var gpuTarget = gpu && Number.isFinite(Number(gpu.target_rpm)) ? Number(gpu.target_rpm) : null
                    if (cpuTarget === null && gpuTarget === null)
                      return root.fieldError("cpu_fan") || root.fieldError("gpu_fan") || root.fieldError("fan") || "设备设定状态未知"
                    var mode = fan ? (fan.manual ? " · 手动" : " · 自动") : ""
                    return "设备设定 · CPU " + (cpuTarget === null ? "—" : cpuTarget)
                      + " / GPU " + (gpuTarget === null ? "—" : gpuTarget) + " RPM" + mode
                  }
                  color: root.mutedFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: root.status && root.status.ok === true && !(root.status.settings && root.status.settings.verified_fan_range)
                  text: "手动范围尚未验证，目标调节不可用。"
                  color: root.mutedFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width
                  text: [root.fieldError("fan"), root.fieldError("cpu_fan"), root.fieldError("gpu_fan")].filter(function(message) { return message !== "" }).join(" · ")
                  visible: text !== ""
                  color: root.errorColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }

              Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.fg; opacity: 0.12 }

              Column {
                width: parent.width
                spacing: Style.space(7)
                Text { text: "性能"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                Text { text: "切换档位会恢复固件自动风扇。"; color: root.mutedFg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Repeater {
                  model: ["cpu", "gpu"]
                  Column {
                    required property string modelData
                    readonly property string device: modelData
                    width: parent.width
                    spacing: Style.space(4)
                    Text {
                      text: device.toUpperCase()
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: parent.width
                      visible: root.currentPerformanceLevel(device) < 0 && !root.busy && root.errorText === ""
                      text: root.fieldError(device + "_performance") || "档位状态未知，暂无选中项。"
                      color: root.fieldError(device + "_performance") !== "" ? root.errorColor : root.mutedFg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                    }
                    Row {
                      width: parent.width
                      spacing: Style.space(4)
                      Repeater {
                        model: device === "cpu" ? ["低", "中", "高", "增强"] : ["低", "中", "高"]
                        Button {
                          required property int index
                          required property string modelData
                          width: (parent.width - Style.space(device === "cpu" ? 12 : 8)) / (device === "cpu" ? 4 : 3)
                          text: modelData
                          selected: root.currentPerformanceLevel(device) === index
                          enabled: root.diagnosticFull && root.canWrite(device + "_performance")
                            && root.currentPerformanceLevel(device) !== index
                          onClicked: root.request(["performance", device, index])
                          Accessible.name: device.toUpperCase() + "档位 " + modelData + "，点击立即切换"
                        }
                      }
                    }
                  }
                }
              }

              Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.fg; opacity: 0.12 }

              Column {
                width: parent.width
                spacing: Style.space(7)
                Text { text: "灯光"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                Loader {
                  width: parent.width
                  active: true
                  sourceComponent: lightingPageComponent
                }
              }
            }
          }
        }
      }
    }
  }
}
