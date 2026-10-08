import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The ECA chat UI, shared by the bar popup (Panel.qml) and the pop-out window
// (ChatWindow.qml). Everything it shows comes from the shared Service: the
// current Session's chat transcript (a ListModel), pending tool approvals and
// questions, model/agent selection and the chat history list.
Item {
  id: view

  property var service: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool inWindow: false
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.07)
  readonly property color faintBorder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
  readonly property color addColor: "#8fbf7f"
  readonly property color delColor: "#d07a7a"

  readonly property var session: service ? service.session : null
  readonly property var chat: session ? session.currentChat : null
  readonly property bool ready: !!session && session.status === "ready"
  readonly property bool working: !!chat && (chat.status === "running" || chat.status === "stopping")
  readonly property var approvals: session ? session.pendingApprovals : []
  readonly property var question: session ? session.pendingQuestion : null

  // "" | "workspaces" | "chats" | "models" | "agents" | "variants"
  property string picker: ""

  signal closeRequested()
  signal popOutRequested()

  function focusComposer() { composer.forceActiveFocus() }

  // Hosts (KeyboardPanel's focusTarget) focus the view; hand it to the composer.
  onActiveFocusChanged: if (activeFocus && picker === "") Qt.callLater(focusComposer)

  function togglePicker(name) { picker = picker === name ? "" : name; if (picker === "") focusComposer() }

  function send() {
    if (!session) return
    var text = composer.text
    if (text.trim() === "") return
    if (session.sendPrompt(text)) {
      composer.text = ""
      transcript.stick = true
    }
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["xdg-open", String(url)])
  }

  // Pipe text to wl-copy via stdin — content never appears in argv
  // (and therefore not in /proc/<pid>/cmdline).
  Process {
    id: clipProc
    command: ["wl-copy"]
    stdinEnabled: true
  }

  function copy(text) {
    clipProc.running = true
    clipProc.write(String(text || ""))
    clipProc.closeStdin()
  }

  function shortModel(m) {
    if (!m) return "no model"
    var i = String(m).indexOf("/")
    return i >= 0 ? String(m).substring(i + 1) : String(m)
  }

  function ago(ms) {
    if (!ms) return ""
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000))
    if (s < 60) return "just now"
    var m = Math.round(s / 60); if (m < 60) return m + "m ago"
    var h = Math.round(m / 60); if (h < 24) return h + "h ago"
    var d = Math.round(h / 24); if (d < 30) return d + "d ago"
    return Qt.formatDate(new Date(ms), "d MMM yyyy")
  }

  function prettyPath(p) {
    var home = Quickshell.env("HOME")
    return p && String(p).indexOf(home) === 0 ? "~" + String(p).substring(home.length) : String(p || "")
  }

  function tokens(n) {
    if (!n) return "0"
    return n >= 1000 ? (Math.round(n / 100) / 10) + "k" : String(n)
  }

  function usageText() {
    if (!chat || !chat.usage) return ""
    var u = chat.usage
    var bits = []
    if (u.sessionTokens) bits.push(tokens(u.sessionTokens) + (u.limit && u.limit.context ? " / " + tokens(u.limit.context) : "") + " tokens")
    if (u.sessionCost) bits.push("$" + u.sessionCost)
    return bits.join(" · ")
  }

  function statusText() {
    if (!service) return "ECA service unavailable"
    // Show install / update progress before a session is active.
    var inst = service.ecaInstallStatus
    if (!session || session.status === "stopped") {
      if (inst === "checking" || inst === "installing")
        return service.ecaInstallMessage || "Checking for ECA…"
      if (inst === "failed")
        return "ECA setup failed — " + (service.ecaInstallError || "unknown error")
              + " · see ~/.cache/omarchy-eca/setup.log"
    }
    if (!session) return "Pick a workspace to start ECA"
    if (session.status === "starting") return session.progressText || "Starting ECA server…"
    if (session.status === "stopping") return "Stopping…"
    if (session.status === "stopped")  return "Server stopped"
    if (session.status === "exited" || session.status === "error") {
      // Surface install error in place of the generic "binary not found" message.
      if (inst === "failed" && service.ecaInstallError)
        return "ECA install error: " + service.ecaInstallError
      return session.error || "Server exited"
    }
    if (chat && chat.progress) return chat.progress
    if (working) return "Working…"
    if (session.progressText) return session.progressText
    return ""
  }

  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // Unified diff -> coloured monospace HTML.
  function diffHtml(diff) {
    var lines = String(diff || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length && i < 400; i++) {
      var l = lines[i]
      var color = l.indexOf("+") === 0 && l.indexOf("+++") !== 0 ? addColor
        : (l.indexOf("-") === 0 && l.indexOf("---") !== 0 ? delColor
        : (l.indexOf("@@") === 0 ? accent : dim))
      out.push("<span style=\"color:" + color + "\">" + (escapeHtml(l) || "&nbsp;") + "</span>")
    }
    if (lines.length > 400) out.push("<span style=\"color:" + dim + "\">… " + (lines.length - 400) + " more lines</span>")
    return "<pre style=\"white-space:pre-wrap\">" + out.join("<br/>") + "</pre>"
  }

  function clip(s, n) {
    s = String(s || "")
    return s.length > n ? s.substring(0, n) + "\n… (" + (s.length - n) + " more characters)" : s
  }

  Keys.onEscapePressed: {
    if (picker !== "") { picker = ""; focusComposer() }
    else view.closeRequested()
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(8)

    // ---- header -----------------------------------------------------------
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Text {
        text: String.fromCodePoint(0xF0674) // nf-md-creation (sparkles), same as the bar icon
        color: view.working ? view.urgent : view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.iconLarge
        Layout.alignment: Qt.AlignVCenter
      }

      Chip {
        text: (view.session ? view.session.name : "Workspace") + "  ▾"
        tooltip: view.session ? view.prettyPath(view.session.workspace) : "Choose a workspace"
        highlighted: view.picker === "workspaces"
        onClicked: view.togglePicker("workspaces")
      }

      Chip {
        visible: !!view.session
        Layout.fillWidth: true
        Layout.maximumWidth: implicitWidth
        text: (view.chat && view.chat.title ? view.chat.title : (view.session && view.session.currentChatId ? "Chat" : "New chat")) + "  ▾"
        tooltip: "Chat history"
        highlighted: view.picker === "chats"
        onClicked: {
          if (view.picker !== "chats" && view.session && view.ready) view.session.refreshChatList()
          view.togglePicker("chats")
        }
      }

      Item { Layout.fillWidth: true }

      PanelActionButton {
        visible: !!view.session
        iconText: "󰐕"
        tooltipText: "New chat"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: { view.session.newChat(); view.picker = ""; view.focusComposer() }
      }

      PanelActionButton {
        visible: !view.inWindow
        iconText: "󰁌"
        tooltipText: "Open in a window"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.popOutRequested()
      }

      PanelActionButton {
        visible: !!view.session || (view.service && view.service.ecaInstallStatus === "failed")
        iconText: view.session && (view.session.status === "ready" || view.session.status === "starting") ? "󰓛"
                  : (view.service && view.service.ecaInstallStatus === "failed") ? "󰑐" : "󰐊"
        tooltipText: view.session && (view.session.status === "ready" || view.session.status === "starting")
          ? "Stop the ECA server for this workspace"
          : (view.service && view.service.ecaInstallStatus === "failed")
            ? "Retry ECA download" : "Start the ECA server"
        foreground: (view.service && view.service.ecaInstallStatus === "failed") ? view.urgent : view.foreground
        fontFamily: view.fontFamily
        onClicked: {
          var s = view.session
          if (s && (s.status === "ready" || s.status === "starting")) {
            s.stop()
          } else if (view.service && view.service.ecaInstallStatus === "failed") {
            // Setup failed — retry the download rather than trying to start the session.
            view.service.retrySetup()
          } else if (view.service && view.service.currentWorkspace) {
            // Always go through openWorkspace so the _setupDone guard is respected.
            view.service.openWorkspace(view.service.currentWorkspace)
          } else if (s) {
            s.start()
          }
        }
      }
    }

    // ---- pickers (replace the transcript while open) ----------------------
    Picker {
      id: pickerView
      visible: view.picker !== ""
      Layout.fillWidth: true
      Layout.fillHeight: true
    }

    // ---- transcript -------------------------------------------------------
    ListView {
      id: transcript
      visible: view.picker === ""
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      spacing: Style.space(8)
      model: view.session && view.session.currentModel ? view.session.currentModel : null
      boundsBehavior: Flickable.StopAtBounds
      cacheBuffer: 2000
      property bool stick: true
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      onMovementEnded: stick = atYEnd
      onContentHeightChanged: if (stick) Qt.callLater(positionViewAtEnd)
      onCountChanged: if (stick) Qt.callLater(positionViewAtEnd)
      onModelChanged: { stick = true; Qt.callLater(positionViewAtEnd) }

      delegate: Loader {
        id: rowLoader
        required property var model
        required property int index
        width: ListView.view.width
        sourceComponent: {
          switch (model.kind) {
          case "user": return userRow
          case "text": return textRow
          case "reason": return reasonRow
          case "tool": return toolRow
          case "hook": return hookRow
          case "url": return urlRow
          case "image": return imageRow
          case "flag": return flagRow
          default: return null
          }
        }
        onLoaded: item.row = Qt.binding(function() { return rowLoader.model })
      }

      // Empty state: ECA's welcome message.
      Flickable {
        anchors.fill: parent
        visible: transcript.count === 0
        contentHeight: welcome.implicitHeight
        clip: true
        TextEdit {
          id: welcome
          width: parent.width
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.MarkdownText
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          text: {
            if (!view.session) return "### ECA — Editor Code Assistant\n\nChoose a workspace above to start an ECA server for that folder, then chat with it here.\n\nDocs: [eca.dev](https://eca.dev)"
            if (view.session.currentChatId && view.chat && !view.chat.loaded) return "Loading chat…"
            return view.session.welcomeMessage || "Starting ECA…"
          }
          onLinkActivated: function(link) { view.openUrl(link) }
        }
      }
    }

    // ---- approvals --------------------------------------------------------
    // Approvals for the visible chat are shown on their tool card; this strip
    // surfaces the ones from other chats and subagents so nothing gets stuck.
    Repeater {
      model: view.picker === "" ? view.approvals.filter(function(a) {
        return !view.session || a.chatId !== view.session.currentChatId
      }) : []
      delegate: Rectangle {
        required property var modelData
        Layout.fillWidth: true
        implicitHeight: approvalCol.implicitHeight + Style.space(12)
        radius: Style.space(6)
        color: Qt.rgba(view.urgent.r, view.urgent.g, view.urgent.b, 0.12)
        border.color: view.urgent
        border.width: 1

        ColumnLayout {
          id: approvalCol
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: Style.space(4)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "󰀦  Allow " + (modelData.summary || modelData.name) + "?"
              + (String(modelData.chatId).indexOf("subagent-") === 0 ? "  (subagent)" : "  (other chat)")
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Text {
            Layout.fillWidth: true
            visible: text !== ""
            textFormat: Text.PlainText
            text: view.clip(modelData.argsText, 600)
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 8
            elide: Text.ElideRight
          }

          RowLayout {
            spacing: Style.space(6)
            Chip { text: "Approve"; highlighted: true; onClicked: view.session.approveToolCall(modelData.chatId, modelData.toolCallId, false) }
            Chip { text: "Approve for session"; onClicked: view.session.approveToolCall(modelData.chatId, modelData.toolCallId, true) }
            Chip { text: "Reject"; onClicked: view.session.rejectToolCall(modelData.chatId, modelData.toolCallId) }
          }
        }
      }
    }

    // ---- question from the server -----------------------------------------
    Rectangle {
      visible: !!view.question && view.picker === ""
      Layout.fillWidth: true
      implicitHeight: visible ? questionCol.implicitHeight + Style.space(12) : 0
      radius: Style.space(6)
      color: view.faint
      border.color: view.accent
      border.width: 1

      ColumnLayout {
        id: questionCol
        anchors.fill: parent
        anchors.margins: Style.space(6)
        spacing: Style.space(6)

        TextEdit {
          Layout.fillWidth: true
          readOnly: true
          selectByMouse: true
          textFormat: TextEdit.MarkdownText
          wrapMode: TextEdit.Wrap
          text: view.question ? "󰘥  " + view.question.question : ""
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          onLinkActivated: function(link) { view.openUrl(link) }
        }

        Flow {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Repeater {
            model: view.question ? view.question.options : []
            Chip {
              required property var modelData
              text: modelData.label
              tooltip: modelData.description || ""
              onClicked: { view.session.answerQuestion(modelData.label); view.focusComposer() }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: !!view.question && view.question.allowFreeform
          spacing: Style.space(6)
          TextField {
            id: answerField
            Layout.fillWidth: true
            foreground: view.foreground
            placeholderText: "Type an answer…"
            onAccepted: if (text.trim() !== "") { view.session.answerQuestion(text); text = ""; view.focusComposer() }
          }
          Chip { text: "Answer"; highlighted: true; enabled: answerField.text.trim() !== ""; onClicked: answerField.accepted() }
        }

        Chip { text: "Cancel"; onClicked: { view.session.answerQuestion(null); view.focusComposer() } }
      }
    }

    // ---- status line ------------------------------------------------------
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      visible: view.statusText() !== "" || view.usageText() !== ""

      Text {
        id: statusGlyph
        visible: view.working
                 || (view.session && view.session.status === "starting")
                 || (view.service && (view.service.ecaInstallStatus === "checking"
                                     || view.service.ecaInstallStatus === "installing"))
        text: "󰔟"
        color: view.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        SequentialAnimation on opacity {
          running: statusGlyph.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0.3; duration: 600 }
          NumberAnimation { to: 1.0; duration: 600 }
        }
      }

      Text {
        id: statusMsg
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: view.statusText()
        color: view.session && (view.session.status === "exited" || view.session.status === "error") ? view.urgent : view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Retry button — shown when setup failed so the user can re-trigger the
      // download without restarting the shell.
      PanelActionButton {
        visible: !!(view.service && view.service.ecaInstallStatus === "failed")
        iconText: "󰑐"
        tooltipText: "Retry ECA download"
        foreground: view.urgent
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (view.service) view.service.retrySetup()
      }

      // Copy-to-clipboard button — visible on session error/exited so the
      // log path can be grabbed easily.
      PanelActionButton {
        visible: !!(view.session &&
                    (view.session.status === "exited" || view.session.status === "error") &&
                    view.statusText() !== "")
        iconText: "󰆏"
        tooltipText: "Copy error / log path to clipboard"
        foreground: view.urgent
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: view.copy(view.statusText())
      }

      Text {
        textFormat: Text.PlainText
        text: view.usageText()
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ---- composer ---------------------------------------------------------
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: Math.min(Style.space(180), Math.max(Style.space(44), composer.implicitHeight + Style.space(10)))
      radius: Style.space(6)
      color: view.faint
      border.color: composer.activeFocus ? view.accent : view.faintBorder
      border.width: 1

      ScrollView {
        id: composerScroll
        anchors.fill: parent
        anchors.margins: Style.space(5)
        anchors.rightMargin: sendButton.width + Style.space(10)
        clip: true

        TextArea {
          id: composer
          wrapMode: TextArea.Wrap
          color: view.foreground
          selectionColor: Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.35)
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: !view.session ? "Choose a workspace first"
            : (view.ready ? "Ask ECA…  (Enter to send, Shift+Enter for a new line, / for commands)" : "Waiting for the ECA server…")
          placeholderTextColor: view.dim
          background: null
          enabled: !!view.session
          Keys.onPressed: function(event) {
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
              event.accepted = true
              view.send()
            } else if (event.key === Qt.Key_Escape) {
              event.accepted = true
              if (view.picker !== "") view.picker = ""
              else view.closeRequested()
            }
          }
        }
      }

      PanelActionButton {
        id: sendButton
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(5)
        iconText: view.working ? "󰓛" : "󰒊"
        tooltipText: view.working ? "Stop" : "Send (Enter)"
        foreground: view.working ? view.urgent : view.foreground
        fontFamily: view.fontFamily
        enabled: view.working || (view.ready && composer.text.trim() !== "")
        onClicked: view.working ? view.session.stopPrompt() : view.send()
      }
    }

    // ---- selectors --------------------------------------------------------
    Flow {
      Layout.fillWidth: true
      spacing: Style.space(6)
      visible: !!view.session

      Chip {
        text: "󰚩 " + (view.session ? view.session.selectedAgent : "")
        tooltip: "Agent"
        highlighted: view.picker === "agents"
        enabled: view.ready
        onClicked: view.togglePicker("agents")
      }
      Chip {
        text: "󰧑 " + view.shortModel(view.session ? view.session.selectedModel : "")
        tooltip: view.session ? view.session.selectedModel : ""
        highlighted: view.picker === "models"
        enabled: view.ready
        onClicked: view.togglePicker("models")
      }
      Chip {
        visible: !!view.session && view.session.variants.length > 0
        text: "󰓅 " + (view.session && view.session.selectedVariant ? view.session.selectedVariant : "default")
        tooltip: "Variant"
        highlighted: view.picker === "variants"
        onClicked: view.togglePicker("variants")
      }
      Chip {
        text: view.session && view.session.trust ? "󰈸 trust on" : "󰒃 ask before tools"
        tooltip: view.session && view.session.trust
          ? "Tool calls that need approval are auto-accepted (deny rules still apply)"
          : "Tool calls that need approval will ask first"
        highlighted: !!view.session && view.session.trust
        onClicked: view.session.setTrust(!view.session.trust)
      }
    }
  }

  // ---- reusable bits ------------------------------------------------------

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property string tooltip: ""
    property bool highlighted: false
    signal clicked()
    implicitWidth: chipLabel.implicitWidth + Style.space(14)
    implicitHeight: chipLabel.implicitHeight + Style.space(8)
    radius: Style.space(5)
    opacity: enabled ? 1.0 : 0.45
    color: highlighted ? Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.22)
      : (chipMouse.containsMouse ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.12) : view.faint)
    border.color: highlighted ? view.accent : view.faintBorder
    border.width: 1

    Text {
      id: chipLabel
      anchors.centerIn: parent
      width: Math.min(implicitWidth, chip.width - Style.space(14))
      textFormat: Text.PlainText
      text: chip.text
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }

    ToolTip.visible: chip.tooltip !== "" && chipMouse.containsMouse
    ToolTip.delay: 600
    ToolTip.text: chip.tooltip
  }

  component Picker: Item {
    id: pk
    readonly property var items: {
      var s = view.session
      switch (view.picker) {
      case "workspaces": {
        var seen = {}
        var out = []
        var svc = view.service
        if (svc) {
          svc.sessionList.forEach(function(x) {
            seen[x.workspace] = true
            out.push({ key: x.workspace, label: x.name, detail: view.prettyPath(x.workspace) + " · " + x.status
              + (x.runningCount > 0 ? " · working" : "") + (x.pendingApprovals.length > 0 ? " · needs approval" : ""),
              current: x === s, live: true })
          })
          svc.recent.forEach(function(p) {
            if (seen[p]) return
            seen[p] = true
            out.push({ key: p, label: p.substring(p.lastIndexOf("/") + 1), detail: view.prettyPath(p) + " · recent" })
          })
          svc.workspaces.forEach(function(w) {
            if (seen[w.path]) return
            seen[w.path] = true
            out.push({ key: w.path, label: w.name, detail: view.prettyPath(w.path)
              + (w.chatCount > 0 ? " · " + w.chatCount + " chat" + (w.chatCount === 1 ? "" : "s") + " · " + view.ago(w.updatedAt) : "") })
          })
        }
        return out
      }
      case "chats":
        return s ? s.chatList.map(function(c) {
          return { key: c.id, label: c.title || "Untitled chat",
                   detail: [c.status === "running" ? "working" : "", view.shortModel(c.model || ""),
                            c.messageCount ? c.messageCount + " messages" : "", view.ago(c.updatedAt)].filter(function(x) { return x }).join(" · "),
                   current: c.id === s.currentChatId, deletable: true }
        }) : []
      case "models":
        return s ? s.models.map(function(m) { return { key: m, label: m, current: m === s.selectedModel } }) : []
      case "agents":
        return s ? s.agents.map(function(a) { return { key: a, label: a, current: a === s.selectedAgent } }) : []
      case "variants":
        return s ? [{ key: "", label: "default", current: !s.selectedVariant }].concat(
          s.variants.map(function(v) { return { key: v, label: v, current: v === s.selectedVariant } })) : []
      }
      return []
    }
    readonly property var filtered: {
      var q = filterField.text.trim().toLowerCase()
      if (q === "") return items
      return items.filter(function(i) { return (i.label + " " + (i.detail || "")).toLowerCase().indexOf(q) !== -1 })
    }

    function choose(item) {
      var s = view.session
      switch (view.picker) {
      case "workspaces": view.service.openWorkspace(item.key); break
      case "chats": s.selectChat(item.key); transcript.stick = true; break
      case "models": s.selectModel(item.key); break
      case "agents": s.selectAgent(item.key); break
      case "variants": s.selectVariant(item.key); break
      }
      view.picker = ""
      filterField.text = ""
      view.focusComposer()
    }

    onVisibleChanged: if (visible) { filterField.text = ""; filterField.forceActiveFocus() }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(6)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        TextField {
          id: filterField
          Layout.fillWidth: true
          foreground: view.foreground
          placeholderText: view.picker === "workspaces" ? "Filter, or type a folder path and press Enter" : "Filter…"
          Keys.onEscapePressed: { view.picker = ""; view.focusComposer() }
          Keys.onDownPressed: pickerList.incrementCurrentIndex()
          Keys.onUpPressed: pickerList.decrementCurrentIndex()
          onAccepted: {
            var t = text.trim()
            if (view.picker === "workspaces" && (t.indexOf("/") === 0 || t.indexOf("~") === 0)) {
              view.service.openWorkspace(t)
              view.picker = ""
              text = ""
              view.focusComposer()
            } else if (pk.filtered.length > 0) {
              pk.choose(pk.filtered[Math.max(0, pickerList.currentIndex)])
            }
          }
        }
        Chip {
          visible: view.picker === "chats"
          text: "󰐕 New chat"
          onClicked: { view.session.newChat(); view.picker = ""; view.focusComposer() }
        }
        Chip {
          visible: view.picker === "workspaces"
          text: "󰑐"
          tooltip: "Rescan project folders"
          onClicked: view.service.refreshWorkspaces()
        }
      }

      ListView {
        id: pickerList
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: pk.filtered
        currentIndex: 0
        spacing: Style.space(2)
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: CursorSurface {
          id: pickRow
          required property var modelData
          required property int index
          width: ListView.view.width
          foreground: view.foreground
          current: !!modelData.current
          hasCursor: pickMouse.containsMouse || pickerList.currentIndex === index
          implicitHeight: pickCol.implicitHeight + Style.space(10)

          MouseArea {
            id: pickMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pk.choose(pickRow.modelData)
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(6)

            ColumnLayout {
              id: pickCol
              Layout.fillWidth: true
              spacing: 0
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: (pickRow.modelData.current ? "󰄬  " : (pickRow.modelData.live ? "󰐊  " : "")) + pickRow.modelData.label
                color: view.foreground
                font.family: view.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                visible: !!pickRow.modelData.detail
                textFormat: Text.PlainText
                text: pickRow.modelData.detail || ""
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }

            PanelActionButton {
              visible: !!pickRow.modelData.deletable
              iconText: "󰆴"
              tooltipText: "Delete chat"
              foreground: view.dim
              fontFamily: view.fontFamily
              onClicked: view.session.deleteChat(pickRow.modelData.key)
            }

            PanelActionButton {
              visible: view.picker === "workspaces" && !!pickRow.modelData.live
              iconText: "󰅖"
              tooltipText: "Stop and close this session"
              foreground: view.dim
              fontFamily: view.fontFamily
              onClicked: view.service.closeWorkspace(pickRow.modelData.key)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: pickerList.count === 0
          text: view.picker === "chats" ? "No chats yet" : "Nothing found"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  // ---- transcript rows ----------------------------------------------------

  Component {
    id: userRow
    Item {
      property var row: null
      implicitHeight: userBubble.height
      // Natural (unwrapped) width of the message, to size the bubble.
      Text {
        id: userMeasure
        visible: false
        textFormat: Text.PlainText
        text: userText.text
        font: userText.font
      }
      Rectangle {
        id: userBubble
        anchors.right: parent.right
        width: Math.min(parent.width * 0.92, userMeasure.implicitWidth + Style.space(22))
        height: userText.implicitHeight + Style.space(12)
        radius: Style.space(6)
        color: Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.14)
        border.color: Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.35)
        border.width: 1
        TextEdit {
          id: userText
          anchors.fill: parent
          anchors.margins: Style.space(6)
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.PlainText
          text: row ? String(row.text).trim() : ""
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  Component {
    id: textRow
    TextEdit {
      property var row: null
      readOnly: true
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.MarkdownText
      text: row ? String(row.text).replace(/^\n+/, "") : ""
      color: row && row.role === "system" ? (row.isError ? view.urgent : view.dim) : view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      selectionColor: Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.35)
      onLinkActivated: function(link) { view.openUrl(link) }
    }
  }

  Component {
    id: reasonRow
    Column {
      id: reason
      property var row: null
      property bool expanded: false
      spacing: Style.space(2)

      Text {
        id: reasonHead
        textFormat: Text.PlainText
        text: (reason.expanded ? "▾ " : "▸ ") + (row && row.status === "running" ? "Thinking…"
          : "Thought" + (row && row.durationMs ? " for " + (Math.round(row.durationMs / 100) / 10) + "s" : ""))
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: reason.expanded = !reason.expanded }
      }

      TextEdit {
        visible: reason.expanded
        width: parent.width
        leftPadding: Style.space(12)
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.MarkdownText
        text: row ? row.text : ""
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: toolRow
    Rectangle {
      id: tool
      property var row: null
      property bool expanded: false
      readonly property var details: {
        if (!row || !row.detailsJson) return null
        try { return JSON.parse(row.detailsJson) } catch (e) { return null }
      }
      readonly property bool busy: !!row && (row.status === "preparing" || row.status === "running" || row.status === "queued")
      readonly property bool waiting: !!row && row.status === "approval"
      readonly property bool failed: !!row && (row.status === "error" || row.status === "rejected")

      implicitHeight: toolCol.implicitHeight + Style.space(10)
      radius: Style.space(5)
      color: view.faint
      border.color: waiting ? view.urgent : view.faintBorder
      border.width: 1

      ColumnLayout {
        id: toolCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(5)
        anchors.leftMargin: Style.space(8)
        spacing: Style.space(4)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            id: toolGlyph
            text: tool.waiting ? "󰀦" : (tool.busy ? "󰔟" : (tool.failed ? "󰅖" : "󰄬"))
            color: tool.waiting || tool.failed ? view.urgent : (tool.busy ? view.foreground : view.addColor)
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            SequentialAnimation on opacity {
              running: tool.busy
              loops: Animation.Infinite
              NumberAnimation { to: 0.3; duration: 600 }
              NumberAnimation { to: 1.0; duration: 600 }
              onRunningChanged: if (!running) toolGlyph.opacity = 1.0
            }
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: row ? (row.summary || row.name) : ""
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            visible: !!tool.details && tool.details.type === "fileChange"
            textFormat: Text.RichText
            text: tool.details && tool.details.type === "fileChange"
              ? "<span style=\"color:" + view.addColor + "\">+" + tool.details.linesAdded + "</span> <span style=\"color:" + view.delColor + "\">-" + tool.details.linesRemoved + "</span>"
              : ""
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: (row && row.durationMs ? (row.durationMs < 1000 ? row.durationMs + "ms" : (Math.round(row.durationMs / 100) / 10) + "s") + "  " : "")
              + (tool.expanded ? "▾" : "▸")
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Task-list tool: show the plan inline.
        Column {
          Layout.fillWidth: true
          visible: !!tool.details && tool.details.type === "task"
          spacing: 1
          Repeater {
            model: tool.details && tool.details.type === "task" ? tool.details.tasks : []
            Text {
              required property var modelData
              width: parent ? parent.width : 0
              textFormat: Text.PlainText
              text: (modelData.status === "done" ? "󰄬 " : (modelData.status === "in-progress" ? "󰔟 " : "󰄰 ")) + modelData.subject
              color: modelData.status === "done" ? view.dim : view.foreground
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.strikeout: modelData.status === "done"
              elide: Text.ElideRight
            }
          }
        }

        TextEdit {
          Layout.fillWidth: true
          visible: tool.expanded && !!tool.details && tool.details.type === "fileChange"
          readOnly: true
          selectByMouse: true
          textFormat: TextEdit.RichText
          wrapMode: TextEdit.WrapAnywhere
          text: visible ? (view.escapeHtml(tool.details.path) + view.diffHtml(tool.details.diff)) : ""
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        TextEdit {
          Layout.fillWidth: true
          visible: tool.expanded && !!row && row.argsText !== "" && !(tool.details && tool.details.type === "fileChange")
          readOnly: true
          selectByMouse: true
          textFormat: TextEdit.PlainText
          wrapMode: TextEdit.WrapAnywhere
          text: visible ? view.clip(row.argsText, 4000) : ""
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          Layout.fillWidth: true
          visible: tool.expanded && !!row && row.output !== ""
          implicitHeight: outputText.implicitHeight + Style.space(8)
          color: Qt.rgba(0, 0, 0, 0.18)
          radius: Style.space(4)
          TextEdit {
            id: outputText
            anchors.fill: parent
            anchors.margins: Style.space(4)
            readOnly: true
            selectByMouse: true
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAnywhere
            text: parent.visible ? view.clip(row.output, 6000) : ""
            color: tool.failed ? view.urgent : view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        RowLayout {
          visible: tool.waiting
          spacing: Style.space(6)
          Chip { text: "Approve"; highlighted: true; onClicked: view.session.approveToolCall(view.session.currentChatId, row.itemId, false) }
          Chip { text: "For session"; onClicked: view.session.approveToolCall(view.session.currentChatId, row.itemId, true) }
          Chip { text: "Reject"; onClicked: view.session.rejectToolCall(view.session.currentChatId, row.itemId) }
        }
      }

      MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Style.space(24)
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) view.copy(row.output || row.argsText)
          else tool.expanded = !tool.expanded
        }
      }
    }
  }

  Component {
    id: hookRow
    Text {
      property var row: null
      textFormat: Text.PlainText
      text: row ? "󱐋 hook " + row.name + (row.status === "running" ? "…" : (row.isError ? " failed" : " ran")) + (row.output ? ": " + row.output : "") : ""
      color: row && row.isError ? view.urgent : view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }
  }

  Component {
    id: urlRow
    Text {
      property var row: null
      textFormat: Text.StyledText
      text: row ? "󰌹 <a href=\"" + row.url + "\">" + view.escapeHtml(row.text) + "</a>" : ""
      color: view.foreground
      linkColor: view.accent
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
      onLinkActivated: function(link) { view.openUrl(link) }
    }
  }

  Component {
    id: imageRow
    Image {
      property var row: null
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      sourceSize.width: Style.space(480)
      height: status === Image.Ready ? Math.min(implicitHeight, Style.space(320)) : Style.space(24)
      source: row && row.base64 ? "data:" + row.mediaType + ";base64," + row.base64 : ""
    }
  }

  Component {
    id: flagRow
    Text {
      property var row: null
      textFormat: Text.PlainText
      text: row ? "⚑ " + row.text : ""
      color: view.accent
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
