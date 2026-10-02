import QtQuick
import Quickshell
import qs.Commons

// Pop-out ECA chat: a regular toplevel window (title "ECA"), so it can be
// tiled, floated or moved between workspaces like any app. Opened from the
// popup's pop-out button, a middle-click on the bar icon, or
// `omarchy-shell eca toggleWindow`.
FloatingWindow {
  id: win
  property var service: null

  title: "ECA" + (service && service.session ? " · " + service.session.name : "")
  implicitWidth: 760
  implicitHeight: 900
  color: Color.popups.background
  visible: true

  onVisibleChanged: if (!visible && service) service.chatWindowOpen = false

  ChatView {
    id: chatView
    anchors.fill: parent
    anchors.margins: Style.space(14)
    service: win.service
    inWindow: true
    foreground: Color.popups.text
    onCloseRequested: if (win.service) win.service.chatWindowOpen = false
    Component.onCompleted: Qt.callLater(chatView.focusComposer)
  }
}
