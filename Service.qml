import QtQuick
import Quickshell
import Quickshell.Io

// Headless ECA client service: owns one Session (one `eca server`) per
// workspace folder, shared by every bar on every monitor. Bar widgets reach it
// with bar.shell.serviceFor("eca").
Item {
  id: root
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string home: Quickshell.env("HOME")
  // The folder this file lives in, so the helper scripts are found wherever
  // the plugin is installed (or run from a checkout for development).
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")

  // Build a command that runs a .bb script, preferring the bb binary bundled
  // in bin/ (committed by CI so bb need not be installed on the host machine).
  // Falls back to system bb found via PATH, the same way the original code did.
  //
  //   bbCmd(script, args...)  ->  string[]  suitable for Process.command
  //
  // The bundled binary path is:  <pluginDir>/bin/bb
  // The fallback shell incantation adds ~/.local/bin to PATH first.
  function bbCmd(script /*, ...args */) {
    var extra = Array.prototype.slice.call(arguments, 1)
    // Use the inline shell trick to test -x and pick the right binary.
    // $0 = pluginDir, $1 = script path, $@ = extra args.
    var sh = 'b="$0/bin/bb"; [ -x "$b" ] || b="bb"; ' +
             'PATH="$HOME/.local/bin:$PATH"; exec "$b" "$1" "${@:2}"'
    return ["sh", "-c", sh, pluginDir, script].concat(extra)
  }
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy-eca"
  readonly property string version: manifest && manifest.version ? manifest.version : "0.1.0"

  // Settings pushed by the bar widget (configure()).
  property string ecaBinary: ""
  property string projectRoots: ""
  property bool notifications: true
  property bool autoStart: false
  property bool _stateLoaded: false

  property var sessions: ({})          // workspace path -> Session
  property int sessionsRevision: 0
  property string currentWorkspace: ""
  readonly property var session: { sessionsRevision; return sessions[currentWorkspace] || null }

  property var workspaces: []          // [{path, name, chats, updatedAt}] from eca_workspaces.bb
  property var recent: []              // workspace paths, most recent first (persisted)
  property bool chatWindowOpen: false

  readonly property var sessionList: {
    sessionsRevision
    var out = []
    for (var k in sessions) out.push(sessions[k])
    return out
  }

  // Aggregates for the bar icon.
  readonly property int runningCount: {
    var n = 0
    for (var i = 0; i < sessionList.length; i++) n += sessionList[i].runningCount
    return n
  }
  readonly property int approvalCount: {
    var n = 0
    for (var i = 0; i < sessionList.length; i++) n += sessionList[i].pendingApprovals.length
    return n
  }
  readonly property int questionCount: {
    var n = 0
    for (var i = 0; i < sessionList.length; i++) if (sessionList[i].pendingQuestion) n++
    return n
  }
  readonly property int liveCount: {
    var n = 0
    for (var i = 0; i < sessionList.length; i++) if (sessionList[i].status === "ready") n++
    return n
  }

  signal attentionRequested(string workspace, string chatId)

  function configure(opts) {
    if (!opts) return
    if (opts.ecaBinary !== undefined) ecaBinary = String(opts.ecaBinary || "")
    if (opts.projectRoots !== undefined && String(opts.projectRoots || "") !== projectRoots) {
      projectRoots = String(opts.projectRoots || "")
      refreshWorkspaces()
    }
    if (opts.notifications !== undefined) notifications = !!opts.notifications
    if (opts.autoStart !== undefined) {
      autoStart = !!opts.autoStart
      maybeAutoStart()
    }
  }

  // With autoStart on, reconnect to the last workspace as soon as both the
  // persisted state and the widget settings are known.
  function maybeAutoStart() {
    if (autoStart && _stateLoaded && !session && currentWorkspace !== "") openWorkspace(currentWorkspace)
  }

  // ---- sessions -----------------------------------------------------------

  Component {
    id: sessionComponent
    Session {}
  }

  function normalize(path) {
    var p = String(path || "").trim()
    if (p.indexOf("~") === 0) p = home + p.substring(1)
    return p.length > 1 ? p.replace(/\/+$/, "") : p
  }

  function sessionFor(path, create) {
    var ws = normalize(path)
    if (ws === "") return null
    var s = sessions[ws]
    if (!s && create) {
      s = sessionComponent.createObject(root, {
        workspace: ws,
        ecaBinary: root.ecaBinary,
        pluginDir: root.pluginDir,
        bridgeScript: root.pluginDir + "/eca_bridge.bb",
        clientVersion: root.version
      })
      s.message.connect(function(type, text) { root.onSessionMessage(s, type, text) })
      sessions[ws] = s
      sessionsRevision++
    }
    return s || null
  }

  function openWorkspace(path) {
    var ws = normalize(path)
    if (ws === "") return null
    var s = sessionFor(ws, true)
    s.ecaBinary = root.ecaBinary
    if (s.status === "stopped" || s.status === "exited" || s.status === "error") s.start()
    currentWorkspace = ws
    remember(ws)
    return s
  }

  function stopWorkspace(path) {
    var s = sessions[normalize(path)]
    if (s) s.stop()
  }

  function closeWorkspace(path) {
    var ws = normalize(path)
    var s = sessions[ws]
    if (!s) return
    s.stop()
    delete sessions[ws]
    sessionsRevision++
    if (currentWorkspace === ws) currentWorkspace = ""
    // Let the shutdown finish before the object (and its Process) goes away.
    destroyLater.createObject(root, { target: s })
  }

  Component {
    id: destroyLater
    Timer {
      property var target: null
      interval: 5000
      running: true
      onTriggered: { if (target) target.destroy(); destroy() }
    }
  }

  function onSessionMessage(s, type, text) {
    if (!notifications || text === "") return
    if (type === "info" && text.indexOf("login") === -1) return
    // Normal urgency with a timeout: approvals are also shown in the chat and
    // by the pulsing bar icon, so stale notifications shouldn't pile up.
    Quickshell.execDetached(["notify-send", "-a", "ECA", "-u", "normal", "-t", type === "error" ? "10000" : "6000",
      "ECA · " + s.name, text])
    if (type === "approval" || type === "question") attentionRequested(s.workspace, s.currentChatId)
  }

  // ---- workspace discovery and persistence --------------------------------

  function refreshWorkspaces() {
    if (wsProc.running) return
    var args = []
    if (projectRoots !== "") args.push("--roots", projectRoots)
    if (ecaBinary !== "") args.push("--eca-bin", ecaBinary)
    wsProc.command = bbCmd.apply(root, [pluginDir + "/eca_workspaces.bb"].concat(args))
    wsProc.running = true
  }

  Process {
    id: wsProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "").trim() || "{}")
          root.workspaces = data.workspaces || []
        } catch (e) {
          console.warn("eca: could not parse eca_workspaces.bb output", e)
        }
      }
    }
  }

  function remember(ws) {
    var list = [ws].concat(recent.filter(function(p) { return p !== ws })).slice(0, 15)
    recent = list
    saveState()
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ recent: recent, currentWorkspace: currentWorkspace }, null, 2) + "\n")
  }

  Process {
    id: mkStateDir
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: stateFile.reload()
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text() || "{}")
        root.recent = s.recent || []
        if (!root.currentWorkspace && s.currentWorkspace) root.currentWorkspace = s.currentWorkspace
      } catch (e) {}
      root._stateLoaded = true
      root.maybeAutoStart()
    }
    onLoadFailed: { root._stateLoaded = true }
  }

  LazyLoader {
    active: root.chatWindowOpen
    component: ChatWindow { service: root }
  }

  Timer {
    interval: 120000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshWorkspaces()
  }

  Component.onDestruction: {
    for (var k in sessions) sessions[k].stop()
  }

  IpcHandler {
    target: "eca"
    function status(): string {
      var out = { currentWorkspace: root.currentWorkspace, running: root.runningCount, approvals: root.approvalCount, sessions: [] }
      for (var k in root.sessions) {
        var s = root.sessions[k]
        out.sessions.push({ workspace: k, status: s.status, error: s.error, model: s.selectedModel, agent: s.selectedAgent,
                            chats: s.chatList.length, running: s.runningCount, approvals: s.pendingApprovals.length })
      }
      return JSON.stringify(out)
    }
    function open(path: string): string { var s = root.openWorkspace(path); return s ? "opening " + s.workspace : "no workspace" }
    function stop(path: string): string { root.stopWorkspace(path || root.currentWorkspace); return "ok" }
    function prompt(text: string): string {
      var s = root.session
      if (!s) return "no workspace open"
      return s.sendPrompt(text) ? "sent" : "not ready (" + s.status + ")"
    }
    function newChat(): string { if (root.session) root.session.newChat(); return "ok" }
    // Act on the oldest pending tool approval in the current workspace,
    // e.g. from a Hyprland keybinding: omarchy-shell eca approve
    function approve(): string {
      var s = root.session
      var a = s && s.pendingApprovals.length ? s.pendingApprovals[0] : null
      if (!a) return "nothing to approve"
      s.approveToolCall(a.chatId, a.toolCallId, false)
      return "approved " + (a.summary || a.name)
    }
    function reject(): string {
      var s = root.session
      var a = s && s.pendingApprovals.length ? s.pendingApprovals[0] : null
      if (!a) return "nothing to reject"
      s.rejectToolCall(a.chatId, a.toolCallId)
      return "rejected " + (a.summary || a.name)
    }
    function stopPrompt(): string { if (root.session) root.session.stopPrompt(); return "ok" }
    function toggleWindow(): void { root.chatWindowOpen = !root.chatWindowOpen }
  }
}
