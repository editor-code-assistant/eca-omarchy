import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// ECA bar widget: a sparkles icon that lights up while ECA is working or waiting
// on you (tool approval / question), and opens a chat popup. The chat itself
// is a direct client of `eca server` — see Service.qml / Session.qml — so no
// editor is involved. Middle-click toggles the pop-out chat window.
Panel {
  id: root
  moduleName: "eca"
  ipcTarget: "eca-panel"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("eca") : null
  readonly property var session: service ? service.session : null

  readonly property string iconGlyph: String.fromCodePoint(0xF0674) // nf-md-creation (sparkles)
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int running: service ? service.runningCount : 0
  readonly property int waiting: service ? service.approvalCount + service.questionCount : 0

  function pushSettings() {
    if (!service) return
    service.configure({
      ecaBinary: String(root.setting("ecaBinary", "") || "").trim(),
      projectRoots: String(root.setting("projectRoots", "") || "").trim(),
      notifications: root.setting("notifications", true) !== false,
      autoStart: root.setting("autoStart", false) === true
    })
  }

  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  onOpenedChanged: if (opened) {
    pushSettings()
    // Reconnect to the last workspace the first time the chat is opened.
    if (service && !service.session && service.currentWorkspace !== "") service.openWorkspace(service.currentWorkspace)
    if (service && service.workspaces.length === 0) service.refreshWorkspaces()
    Qt.callLater(chatView.focusComposer)
  }

  function tooltip() {
    if (!service) return "ECA: service not loaded (enable the eca plugin)"
    if (!session) return "ECA: no workspace open"
    var bits = ["ECA · " + session.name + " (" + session.status + ")"]
    if (running > 0) bits.push(running + " working")
    if (service.approvalCount > 0) bits.push(service.approvalCount + " awaiting approval")
    if (service.questionCount > 0) bits.push("question waiting")
    return bits.join(" · ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    active: root.running > 0 || root.waiting > 0
    tooltipText: root.tooltip()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.service) root.service.chatWindowOpen = !root.service.chatWindowOpen
      else root.toggle()
    }

    // Pulse while waiting on the user.
    SequentialAnimation on opacity {
      running: root.waiting > 0
      loops: Animation.Infinite
      NumberAnimation { to: 0.4; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
      onRunningChanged: if (!running) button.opacity = 1.0
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: chatView
    contentWidth: panel.fittedContentWidth(Style.space(Number(root.setting("panelWidth", 560))))
    contentHeight: panel.fittedContentHeight(Style.space(Number(root.setting("panelHeight", 720))))

    ChatView {
      id: chatView
      anchors.fill: parent
      service: root.service
      foreground: root.foreground
      urgent: root.urgent
      fontFamily: root.fontFamily
      onCloseRequested: root.close()
      onPopOutRequested: {
        if (root.service) root.service.chatWindowOpen = true
        root.close()
      }
    }
  }
}
