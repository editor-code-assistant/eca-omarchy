import QtQuick
import Quickshell
import Quickshell.Io

// One ECA client session: an `eca server` (spawned through eca_bridge.bb)
// for one workspace folder, speaking the ECA protocol (https://eca.dev/protocol/)
// the same way eca-emacs does: initialize/initialized, chat/prompt with
// streamed chat/contentReceived, tool-call approval, chat history, model and
// agent selection, and server-initiated questions (chat/askQuestion).
//
// Each chat's transcript is a ListModel whose rows are updated in place while
// content streams in, so views only re-render the row that changed.
Item {
  id: session
  visible: false

  // ---- configuration (set by Service.qml) ---------------------------------
  property string workspace: ""
  property string ecaBinary: ""
  property string bridgeScript: ""
  property string pluginDir: ""       // set to Service.pluginDir so bin/bb is found
  property string clientVersion: "0.1.0"

  readonly property string name: {
    var p = String(workspace || "").replace(/\/+$/, "")
    return p.substring(p.lastIndexOf("/") + 1) || p
  }

  // ---- connection state ---------------------------------------------------
  // stopped | starting | ready | stopping | exited | error
  property string status: "stopped"
  property string error: ""
  property string welcomeMessage: ""
  property string serverLog: ""
  property var progressTasks: ({})      // taskId -> title, while initialising
  readonly property string progressText: {
    var titles = []
    for (var k in progressTasks) titles.push(progressTasks[k])
    return titles.join(" · ")
  }
  property var toolServers: ({})        // MCP/native tool servers: name -> {status, tools}

  // ---- selection ----------------------------------------------------------
  property var models: []
  property var agents: []
  property var variants: []
  property string selectedModel: ""
  property string selectedAgent: "code"
  property string selectedVariant: ""
  property bool trust: false

  // ---- chats --------------------------------------------------------------
  // chatList: summaries for the picker (server chat/list merged with chats
  // created in this session). chats: id -> record (see ensureChat), kept as
  // a plain JS object; `revision` is bumped whenever record metadata changes.
  property var chatList: []
  property string currentChatId: ""
  property var chats: ({})
  property int revision: 0
  property var pendingApprovals: []     // [{chatId, toolCallId, name, summary, argsText, detailsJson}]
  property var pendingQuestion: null    // {rpcId, chatId, question, options, allowFreeform}

  readonly property var currentChat: { revision; return chats[currentChatId] || null }
  // QtObject-typed so views only see a change when the chat actually switches,
  // not on every metadata `revision` bump (which would reset a ListView).
  readonly property QtObject currentModel: currentChat ? currentChat.model : null
  readonly property int runningCount: {
    revision
    var n = 0
    for (var id in chats) if (!chats[id].subagent && chats[id].status === "running") n++
    return n
  }

  signal message(string type, string text)
  signal chatActivity(string chatId)

  property var _pending: ({})
  property int _nextId: 1

  // ---- lifecycle ----------------------------------------------------------

  function start() {
    if (proc.running) return
    status = "starting"
    error = ""
    progressTasks = ({})
    // Prefer the bb binary bundled in <pluginDir>/bin/bb (committed by CI so
    // that bb does not need to be installed on the host).  Falls back to the
    // system bb found via PATH + ~/.local/bin.
    var dir = pluginDir || bridgeScript.replace(/\/[^\/]+$/, "")
    var sh = 'b="$0/bin/bb"; [ -x "$b" ] || b="bb"; ' +
             'PATH="$HOME/.local/bin:$PATH"; exec "$b" "$1" "${@:2}"'
    var cmd = ["sh", "-c", sh, dir, bridgeScript, "--workspace", workspace]
    if (ecaBinary !== "") cmd.push("--eca", ecaBinary)
    proc.command = cmd
    proc.running = true
  }

  function stop() {
    if (!proc.running) { status = "stopped"; return }
    status = "stopping"
    request("shutdown", null, function() { notify("exit", null) })
    stopTimer.restart()
  }

  function restart() {
    if (proc.running) { _restartAfterExit = true; stop() }
    else start()
  }
  property bool _restartAfterExit: false

  // ---- JSON-RPC -----------------------------------------------------------

  function _send(msg) {
    if (!proc.running) return false
    proc.write(JSON.stringify(msg) + "\n")
    return true
  }

  function request(method, params, onResult, onError) {
    var id = _nextId++
    _pending[id] = { method: method, onResult: onResult || null, onError: onError || null }
    var msg = { jsonrpc: "2.0", id: id, method: method }
    if (params !== null && params !== undefined) msg.params = params
    if (!_send(msg)) {
      delete _pending[id]
      if (onError) onError({ message: "ECA server is not running" })
    }
    return id
  }

  function notify(method, params) {
    var msg = { jsonrpc: "2.0", method: method }
    if (params !== null && params !== undefined) msg.params = params
    _send(msg)
  }

  function respond(id, result) { _send({ jsonrpc: "2.0", id: id, result: result }) }
  function respondError(id, code, text) { _send({ jsonrpc: "2.0", id: id, error: { code: code, message: text } }) }

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { console.warn("eca: bad line from bridge:", line); return }

    if (msg.bridge) return handleBridge(msg)

    if (msg.method !== undefined && msg.id !== undefined) return handleServerRequest(msg)
    if (msg.method !== undefined) return handleNotification(msg.method, msg.params || {})

    var pending = _pending[msg.id]
    if (!pending) return
    delete _pending[msg.id]
    if (msg.error) {
      if (pending.onError) pending.onError(msg.error)
      else session.message("error", pending.method + ": " + (msg.error.message || "request failed"))
    } else if (pending.onResult) {
      pending.onResult(msg.result)
    }
  }

  function handleBridge(msg) {
    if (msg.bridge === "started") {
      serverLog = msg.log || ""
      initialize()
    } else if (msg.bridge === "error") {
      error = msg.message || "bridge error"
      session.message("error", error)
    } else if (msg.bridge === "exited") {
      if (status !== "stopping") {
        status = "exited"
        if (msg.code) error = "eca server exited with code " + msg.code + (serverLog ? " (see " + serverLog + ")" : "")
      }
    }
  }

  function initialize() {
    request("initialize", {
      clientInfo: { name: "omarchy", version: clientVersion },
      capabilities: { codeAssistant: { chat: true, chatCapabilities: { askQuestion: true } } },
      initializationOptions: { chatAgent: selectedAgent || "code" },
      workspaceFolders: [{ uri: "file://" + encodeURI(workspace), name: name }]
    }, function(result) {
      welcomeMessage = (result && result.chatWelcomeMessage) || ""
      notify("initialized", {})
      status = "ready"
      refreshChatList()
    }, function(err) {
      status = "error"
      error = "initialize failed: " + (err.message || "unknown error")
    })
  }

  // ---- server -> client ---------------------------------------------------

  function handleServerRequest(msg) {
    var p = msg.params || {}
    if (msg.method === "chat/askQuestion") {
      pendingQuestion = {
        rpcId: msg.id, chatId: p.chatId || "", question: p.question || "",
        options: p.options || [], allowFreeform: p.allowFreeform !== false, toolCallId: p.toolCallId || ""
      }
      ensureChat(p.chatId)
      session.chatActivity(p.chatId || "")
      session.message("question", p.question || "")
    } else {
      // We don't advertise editor/* capabilities, but never leave the server waiting.
      respondError(msg.id, -32601, "Method not supported by the Omarchy client: " + msg.method)
    }
  }

  function answerQuestion(answer) {
    var q = pendingQuestion
    if (!q) return
    pendingQuestion = null
    respond(q.rpcId, answer === null ? { answer: null, cancelled: true } : { answer: String(answer), cancelled: false })
  }

  function handleNotification(method, p) {
    switch (method) {
    case "chat/contentReceived": return handleContent(p)
    case "chat/statusChanged": {
      var c = ensureChat(p.chatId)
      c.status = p.status || "idle"
      if (c.status !== "running") c.progress = ""
      _touchList(p.chatId, { status: c.status })
      revision++
      if (c.status === "idle") session.chatActivity(p.chatId)
      return
    }
    case "chat/opened": {
      var oc = ensureChat(p.chatId)
      if (p.title) { oc.title = p.title; _touchList(p.chatId, { title: p.title }) }
      revision++
      return
    }
    case "chat/cleared": {
      var cc = chats[p.chatId]
      if (cc && p.messages !== false) { cc.model.clear(); cc.index = ({}) ; cc.lastTextRow = -1 }
      revision++
      return
    }
    case "chat/deleted": return _forgetChat(p.chatId)
    case "config/updated": return handleConfig(p)
    case "tool/serverUpdated": {
      var ts = Object.assign({}, toolServers)
      ts[p.name] = { status: p.status, tools: (p.tools || []).length, type: p.type }
      toolServers = ts
      return
    }
    case "tool/serverRemoved": {
      var tr = Object.assign({}, toolServers)
      delete tr[p.name]
      toolServers = tr
      return
    }
    case "$/progress": {
      var pt = Object.assign({}, progressTasks)
      if (p.type === "start") pt[p.taskId] = p.title
      else delete pt[p.taskId]
      progressTasks = pt
      return
    }
    case "$/showMessage":
      session.message(p.type || "info", p.message || "")
      return
    }
  }

  function handleConfig(p) {
    var chat = p.chat || {}
    if (chat.models) models = chat.models
    if (chat.agents) agents = chat.agents
    if (chat.welcomeMessage) welcomeMessage = chat.welcomeMessage
    var scoped = p.chatId ? ensureChat(p.chatId) : null
    // Scoped updates realign one chat; unscoped ones apply session-wide.
    if (scoped) {
      if (chat.selectModel) scoped.selection.model = chat.selectModel
      if (chat.selectAgent) scoped.selection.agent = chat.selectAgent
      if (chat.selectVariant !== undefined) scoped.selection.variant = chat.selectVariant || ""
      if (chat.selectTrust !== undefined) scoped.selection.trust = !!chat.selectTrust
      if (chat.variants) scoped.selection.variants = chat.variants
      if (p.chatId === currentChatId) applySelection(scoped.selection)
      revision++
      return
    }
    if (chat.variants) variants = chat.variants
    if (chat.selectModel) selectedModel = chat.selectModel
    else if (!selectedModel && chat.defaultModel) selectedModel = chat.defaultModel
    if (chat.selectAgent) selectedAgent = chat.selectAgent
    if (chat.selectVariant !== undefined) selectedVariant = chat.selectVariant || ""
    if (chat.selectTrust !== undefined) trust = !!chat.selectTrust
  }

  function applySelection(sel) {
    if (!sel) return
    if (sel.model) selectedModel = sel.model
    if (sel.agent) selectedAgent = sel.agent
    if (sel.variants) variants = sel.variants
    if (sel.variant !== undefined) selectedVariant = sel.variant || ""
    if (sel.trust !== undefined) trust = !!sel.trust
  }

  // ---- chat records -------------------------------------------------------

  Component { id: chatModelComponent; ListModel {} }

  function ensureChat(chatId) {
    if (!chatId) return null
    var c = chats[chatId]
    if (c) return c
    c = {
      id: chatId,
      title: "",
      status: "idle",
      progress: "",
      usage: null,
      subagent: chatId.indexOf("subagent-") === 0,
      parentChatId: "",
      model: chatModelComponent.createObject(session),
      index: ({}),           // item id (tool call / reason / hook) -> row
      lastTextRow: -1,       // row of the assistant/system text being streamed
      loaded: true,
      selection: ({})
    }
    chats[chatId] = c
    revision++
    return c
  }

  function _row(over) {
    var r = { kind: "", role: "", text: "", itemId: "", name: "", server: "", summary: "", status: "",
              argsText: "", output: "", detailsJson: "", durationMs: 0, isError: false,
              manualApproval: false, mediaType: "", base64: "", url: "" }
    for (var k in over) r[k] = over[k]
    return r
  }

  function _append(c, over) {
    c.model.append(_row(over))
    return c.model.count - 1
  }

  function _set(c, row, values) {
    for (var k in values) c.model.setProperty(row, k, values[k])
  }

  function _details(content) { return content.details ? JSON.stringify(content.details) : "" }

  function _argsText(args) {
    try { return args ? JSON.stringify(args, null, 2) : "" } catch (e) { return String(args) }
  }

  function _toolRow(c, content, status) {
    var row = c.index[content.id]
    if (row === undefined) {
      row = _append(c, { kind: "tool", itemId: content.id, name: content.name || "", server: content.server || "",
                         summary: content.summary || content.name || "", status: status })
      c.index[content.id] = row
    }
    c.lastTextRow = -1
    return row
  }

  function handleContent(p) {
    var c = ensureChat(p.chatId)
    if (!c) return
    if (p.parentChatId) c.parentChatId = p.parentChatId
    var content = p.content || {}
    var role = p.role || "assistant"
    var row

    switch (content.type) {
    case "text":
      if (role === "user") {
        _append(c, { kind: "user", role: role, text: content.text || "", itemId: content.contentId || "" })
        c.lastTextRow = -1
      } else if (c.lastTextRow >= 0 && c.lastTextRow === c.model.count - 1 && c.model.get(c.lastTextRow).role === role) {
        _set(c, c.lastTextRow, { text: c.model.get(c.lastTextRow).text + (content.text || "") })
      } else {
        c.lastTextRow = _append(c, { kind: "text", role: role, text: content.text || "" })
      }
      break
    case "url":
      _append(c, { kind: "url", role: role, text: content.title || content.url || "", url: content.url || "" })
      c.lastTextRow = -1
      break
    case "image":
      _append(c, { kind: "image", role: role, mediaType: content.mediaType || "image/png", base64: content.base64 || "" })
      c.lastTextRow = -1
      break
    case "progress":
      c.progress = content.state === "running" ? (content.text || "Working…") : ""
      revision++
      return
    case "usage":
      c.usage = content
      revision++
      return
    case "metadata":
      if (content.title) { c.title = content.title; _touchList(p.chatId, { title: content.title }) }
      revision++
      return
    case "reasonStarted":
      c.index[content.id] = _append(c, { kind: "reason", role: role, itemId: content.id, status: "running" })
      c.lastTextRow = -1
      break
    case "reasonText":
      row = c.index[content.id]
      if (row === undefined) row = c.index[content.id] = _append(c, { kind: "reason", role: role, itemId: content.id, status: "running" })
      _set(c, row, { text: c.model.get(row).text + (content.text || "") })
      break
    case "reasonFinished":
      row = c.index[content.id]
      if (row !== undefined) _set(c, row, { status: "done", durationMs: content.totalTimeMs || 0 })
      break
    case "hookActionStarted":
      c.index["hook:" + content.id] = _append(c, { kind: "hook", role: role, itemId: content.id, name: content.name || "", status: "running" })
      c.lastTextRow = -1
      break
    case "hookActionFinished":
      row = c.index["hook:" + content.id]
      if (row === undefined) row = c.index["hook:" + content.id] = _append(c, { kind: "hook", role: role, itemId: content.id, name: content.name || "" })
      _set(c, row, { status: content.status === 0 ? "done" : "error", isError: content.status !== 0,
                     output: [content.output || "", content.error || ""].filter(function(s) { return s }).join("\n") })
      break
    case "toolCallPrepare":
      row = _toolRow(c, content, "preparing")
      _set(c, row, { argsText: c.model.get(row).argsText + (content.argumentsText || ""),
                     summary: content.summary || c.model.get(row).summary })
      if (content.details) _set(c, row, { detailsJson: _details(content) })
      break
    case "toolCallRun":
      row = _toolRow(c, content, "queued")
      _set(c, row, { status: content.manualApproval ? "approval" : "queued", manualApproval: !!content.manualApproval,
                     argsText: _argsText(content.arguments), summary: content.summary || content.name || "",
                     detailsJson: _details(content) })
      if (content.manualApproval) {
        _addApproval({ chatId: p.chatId, toolCallId: content.id, name: content.name || "", server: content.server || "",
                       summary: content.summary || content.name || "", argsText: _argsText(content.arguments),
                       detailsJson: _details(content) })
        session.chatActivity(p.chatId)
        session.message("approval", (content.summary || content.name) + " needs approval")
      }
      break
    case "toolCallRunning":
      row = _toolRow(c, content, "running")
      _set(c, row, { status: "running", summary: content.summary || c.model.get(row).summary })
      if (content.details) _set(c, row, { detailsJson: _details(content) })
      _removeApproval(content.id)
      break
    case "toolCalled":
      row = _toolRow(c, content, "done")
      _set(c, row, { status: content.error ? "error" : "done", isError: !!content.error,
                     durationMs: content.totalTimeMs || 0, summary: content.summary || c.model.get(row).summary,
                     output: (content.outputs || []).map(function(o) { return o.text || "" }).join("\n") })
      if (content.details) _set(c, row, { detailsJson: _details(content) })
      if (content.arguments && c.model.get(row).argsText === "") _set(c, row, { argsText: _argsText(content.arguments) })
      _removeApproval(content.id)
      break
    case "toolCallRejected":
      row = _toolRow(c, content, "rejected")
      _set(c, row, { status: "rejected", output: "Rejected (" + (content.reason || "user") + ")",
                     summary: content.summary || c.model.get(row).summary })
      _removeApproval(content.id)
      break
    case "flag":
      _append(c, { kind: "flag", role: role, text: content.text || "", itemId: content.contentId || "" })
      c.lastTextRow = -1
      break
    default:
      return
    }
    session.chatActivity(p.chatId)
  }

  function _addApproval(a) {
    var list = pendingApprovals.filter(function(x) { return x.toolCallId !== a.toolCallId })
    list.push(a)
    pendingApprovals = list
  }

  function _removeApproval(toolCallId) {
    if (!pendingApprovals.some(function(x) { return x.toolCallId === toolCallId })) return
    pendingApprovals = pendingApprovals.filter(function(x) { return x.toolCallId !== toolCallId })
  }

  function _touchList(chatId, values) {
    var found = false
    var list = chatList.map(function(s) {
      if (s.id !== chatId) return s
      found = true
      var copy = Object.assign({}, s, values)
      copy.updatedAt = Date.now()
      return copy
    })
    if (!found) {
      var c = chats[chatId]
      if (!c || c.subagent) return
      list.unshift(Object.assign({ id: chatId, title: c.title || "", status: c.status, updatedAt: Date.now() }, values))
    }
    chatList = list
  }

  function _forgetChat(chatId) {
    var c = chats[chatId]
    if (c) {
      if (c.model) c.model.destroy()
      delete chats[chatId]
    }
    chatList = chatList.filter(function(s) { return s.id !== chatId })
    pendingApprovals = pendingApprovals.filter(function(a) { return a.chatId !== chatId })
    if (currentChatId === chatId) currentChatId = ""
    revision++
  }

  // ---- client -> server: chat ---------------------------------------------

  function uuid() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(ch) {
      var r = Math.random() * 16 | 0
      return (ch === "x" ? r : (r & 0x3 | 0x8)).toString(16)
    })
  }

  function newChat() {
    currentChatId = ""
    revision++
  }

  function selectChat(chatId) {
    if (!chatId) return newChat()
    var c = chats[chatId]
    currentChatId = chatId
    if (c && c.loaded && c.model.count > 0) {
      applySelection(c.selection)
      revision++
      return
    }
    c = ensureChat(chatId)
    c.loaded = false
    revision++
    request("chat/open", { chatId: chatId }, function(res) {
      c.loaded = true
      if (!res || res.found === false) {
        session.message("warning", "ECA could not open that chat")
      } else {
        if (res.title) c.title = res.title
        if (res.selection) {
          c.selection = res.selection
          if (chatId === currentChatId) applySelection(res.selection)
        }
      }
      revision++
    }, function(err) {
      c.loaded = true
      session.message("error", "chat/open: " + (err.message || "failed"))
      revision++
    })
  }

  function sendPrompt(text) {
    var message = String(text || "")
    if (message.trim() === "" || status !== "ready") return false
    if (!currentChatId) {
      currentChatId = uuid()
      ensureChat(currentChatId)
      _touchList(currentChatId, { title: message.split("\n")[0].substring(0, 60) })
    }
    var chatId = currentChatId
    var params = { chatId: chatId, message: message, contexts: [] }
    if (selectedModel) params.model = selectedModel
    if (selectedAgent) params.agent = selectedAgent
    if (selectedVariant) params.variant = selectedVariant
    if (trust) params.trust = true
    var c = ensureChat(chatId)
    c.status = "running"
    revision++
    request("chat/prompt", params, function(res) {
      if (res && res.status === "login") session.message("info", "ECA needs a provider login: follow the instructions in the chat")
    }, function(err) {
      c.status = "idle"
      _append(c, { kind: "text", role: "system", text: "**Error:** " + (err.message || "prompt failed"), isError: true })
      c.lastTextRow = -1
      revision++
    })
    return true
  }

  function stopPrompt(chatId) {
    var id = chatId || currentChatId
    if (id) notify("chat/promptStop", { chatId: id })
  }

  function approveToolCall(chatId, toolCallId, remember) {
    var params = { chatId: chatId, toolCallId: toolCallId }
    if (remember) params.save = "session"
    notify("chat/toolCallApprove", params)
    _removeApproval(toolCallId)
  }

  function rejectToolCall(chatId, toolCallId) {
    notify("chat/toolCallReject", { chatId: chatId, toolCallId: toolCallId })
    _removeApproval(toolCallId)
  }

  function refreshChatList() {
    request("chat/list", { limit: 50 }, function(res) {
      var server = (res && res.chats) || []
      var seen = {}
      server.forEach(function(s) { seen[s.id] = true })
      // Keep chats created in this session that the server hasn't listed yet.
      var local = chatList.filter(function(s) { return !seen[s.id] })
      chatList = local.concat(server.filter(function(s) { return s.id && s.kind !== "inline" }))
    })
  }

  function deleteChat(chatId) {
    request("chat/delete", { chatId: chatId }, function() { _forgetChat(chatId) })
  }

  function renameChat(chatId, title) {
    request("chat/update", { chatId: chatId, title: title }, function() {
      var c = chats[chatId]
      if (c) c.title = title
      _touchList(chatId, { title: title })
      revision++
    })
  }

  function clearChat(chatId) {
    request("chat/clear", { chatId: chatId || currentChatId, messages: true })
  }

  function selectModel(model) {
    selectedModel = model
    var params = { model: model }
    if (currentChatId) params.chatId = currentChatId
    if (selectedVariant) params.variant = selectedVariant
    notify("chat/selectedModelChanged", params)
  }

  function selectAgent(agent) {
    selectedAgent = agent
    var params = { agent: agent }
    if (currentChatId) params.chatId = currentChatId
    notify("chat/selectedAgentChanged", params)
  }

  function selectVariant(variant) { selectedVariant = variant || "" }
  function setTrust(on) { trust = !!on }

  // ---- process ------------------------------------------------------------

  Process {
    id: proc
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { session.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("eca-bridge:", line) }
    }
    onExited: function(exitCode) {
      stopTimer.stop()
      session._pending = ({})
      if (session.status === "stopping" || session.status === "ready" || session.status === "starting") {
        session.status = session.status === "stopping" ? "stopped" : "exited"
      }
      for (var id in session.chats) if (session.chats[id].status === "running") session.chats[id].status = "idle"
      session.pendingApprovals = []
      session.pendingQuestion = null
      session.revision++
      if (session._restartAfterExit) { session._restartAfterExit = false; Qt.callLater(session.start) }
    }
  }

  // Fallback if the server ignores shutdown.
  Timer {
    id: stopTimer
    interval: 4000
    onTriggered: if (proc.running) proc.running = false
  }

  Component.onDestruction: if (proc.running) proc.running = false
}
