import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "xianbei233.razer-control"

  readonly property string diagnosticTag: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10)
  property var diagnosticCounts: ({})

  function diagnosticBegin(event, detail) {
    var count = Number(diagnosticCounts[event] || 0)
    if (count >= 5) return 0
    diagnosticCounts[event] = count + 1
    console.info("[razer-diag] instance=" + diagnosticTag + " bar." + event + "#" + (count + 1) + " begin " + detail)
    return count + 1
  }
  function diagnosticEnd(event, sequence, detail) {
    if (!sequence) return
    console.info("[razer-diag] instance=" + diagnosticTag + " bar." + event + "#" + sequence + " end " + detail)
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.diagnosticTag = root.diagnosticTag
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  function open() {
    var seq = diagnosticBegin("open", "opened=" + opened + " panelLoaded=" + !!panelLoader.item)
    if (panelLoader.item) panelLoader.item.openFromHotkey()
    diagnosticEnd("open", seq, "opened=" + opened)
  }
  function close() {
    var seq = diagnosticBegin("close", "opened=" + opened + " panelLoaded=" + !!panelLoader.item)
    if (panelLoader.item) panelLoader.item.close()
    diagnosticEnd("close", seq, "opened=" + opened)
  }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  // KeyboardPanel coordinates popout ownership on this outer bar widget, not
  // the nested Panel item. Forward the close handoff state so a switched-away
  // full-screen layer releases input immediately instead of fading over peers.
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    var seq = diagnosticBegin("closeForPopoutSwitch", "opened=" + opened + " panelLoaded=" + !!panelLoader.item)
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
    else close()
    diagnosticEnd("closeForPopoutSwitch", seq, "opened=" + opened + " popoutSwitchClosing=" + popoutSwitchClosing)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    tooltipText: "Razer Control · 点击查看设备状态与控制"
    active: root.opened
    onPressed: function(b) {
      var seq = root.diagnosticBegin("click", "button=" + b + " openedBefore=" + root.opened + " panelLoaded=" + !!panelLoader.item)
      if (b === Qt.LeftButton) root.toggle()
      root.diagnosticEnd("click", seq, "button=" + b + " openedAfter=" + root.opened)
    }
  }
}
