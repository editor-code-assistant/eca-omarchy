# ECA for Omarchy

A native [ECA (Editor Code Assistant)](https://eca.dev) client for the
[Omarchy](https://omarchy.org) shell. Like eca-emacs or eca-vscode, it starts
`eca server` itself and speaks the [ECA protocol](https://eca.dev/protocol/)
directly, so you can chat with ECA from the bar without an editor.

## Features

- One `eca server` per workspace folder, started on demand and shut down cleanly.
  Several workspaces can run at once.
- Streaming chat with markdown rendering, collapsible reasoning, and tool-call
  cards showing arguments, output and timing. File edits show a coloured diff
  with +/− counts, and the task tool shows its plan inline.
- Tool approval: Approve, Approve for session, or Reject, from the chat or over
  IPC (`omarchy-shell eca approve`). Approvals from other chats and subagents
  are listed in a strip above the composer.
- Server questions (`chat/askQuestion`, e.g. `/login` flows): pick an option,
  type an answer, or cancel.
- Chat history (`chat/list` / `chat/open`): resume, delete, start a new chat.
- Model, agent (code / plan / custom), variant and trust selectors.
- Server-side `/commands` (`/login`, `/init`, `/compact`, `/doctor`, …) work
  because the prompt goes straight to the server.
- Usage and cost in the status line, plus server start-up progress.
- Bar icon lights up while ECA is working and pulses when it needs you. A
  desktop notification goes out for approvals, questions and errors.
- Pop-out chat window (title `ECA · <workspace>`, class `org.quickshell`) that
  tiles like any app.

## Install

Requirements: Omarchy shell and the `eca` binary (`eca` on `PATH`, the copy
eca-emacs downloads, or configured in the widget settings).

`bb` (Babashka) is **not required** — the plugin ships a pre-built `bin/bb`
binary committed by CI on every release.

### From git (recommended)

```bash
omarchy plugin add https://github.com/<user>/omarchy-eca.git --enable
```

That's it. Omarchy clones the repo, validates the manifest, and enables the bar
widget. The bundled `bin/bb` is included in the clone so no system-wide `bb` is
needed.

To update later:

```bash
omarchy plugin update eca
```

### Manual / development install

```bash
./install.sh          # symlink checkout → plugins/eca (default, best for dev)
./install.sh --copy   # copy files instead (for deployment or if symlink fails)
./install.sh --link   # force (re)create the symlink
```

**Symlink mode** (default) points `~/.config/omarchy/plugins/eca` directly at the
checkout — edits are live immediately with no copy step. The shell hot-reloads
most changes on `rescanPlugins`; changes to `IpcHandler` functions need
`omarchy-restart-shell`.

**Copy mode** copies all files into the plugins folder. Use this when you want
a stable installed copy independent of the checkout, or if you hit a validation
issue with the symlink.

`bin/bb` is copied alongside the plugin files if present in copy mode. In symlink
mode it is used directly from the checkout. If absent (fresh checkout before a CI
release) a system `bb` is used as a fallback.

### Releasing a new version

```bash
# Bump the version in manifest.json, then:
git tag v0.2.0 && git push --tags
```

The GitHub Actions workflow (`.github/workflows/release.yml`) will:
1. Resolve the latest stable Babashka release.
2. Download the static `linux-amd64` binary and verify its SHA-256 checksum.
3. Smoke-test both `.bb` scripts.
4. Commit the binary to `bin/bb` in the repo.
5. Create a GitHub release with `bin/bb` attached as an asset.

Changes to the `IpcHandler` functions need `omarchy-restart-shell` to show up,
because Quickshell keeps the first registration of an IPC target.

## Use

- Click the sparkles icon (󰙴) to open the popup. Choose a workspace (recent ECA
  workspaces, git repos under `~/Work`, `~/Projects`, …, or type a path) and chat.
- Enter sends, Shift+Enter adds a new line, Esc closes pickers or the popup.
- Middle-click the icon to toggle the pop-out window.

IPC (handy for Hyprland bindings):

```bash
omarchy-shell eca open ~/Work/project   # start/switch workspace
omarchy-shell eca prompt "explain src/core.clj"
omarchy-shell eca approve               # approve the oldest pending tool call
omarchy-shell eca reject
omarchy-shell eca stopPrompt
omarchy-shell eca newChat
omarchy-shell eca toggleWindow
omarchy-shell eca stop ~/Work/project
omarchy-shell eca status                # JSON
```

## Settings (bar widget)

| key | default | |
|---|---|---|
| `autoStart` | `false` | reconnect to the last workspace when the shell starts |
| `notifications` | `true` | desktop notifications for approvals, questions, errors |
| `panelWidth` / `panelHeight` | `560` / `720` | popup size |
| `ecaBinary` | auto | path to `eca` |
| `projectRoots` | | extra colon-separated folders to scan for projects |

ECA itself is configured as usual (`~/.config/eca/config.json`, `/login`); see
the [ECA docs](https://eca.dev/config/introduction/).

## How it works

```
Panel.qml / ChatWindow.qml ── ChatView.qml (UI)
        │ bar.shell.serviceFor("eca")
Service.qml (singleton) ── Session.qml per workspace
        │ Quickshell Process, newline-delimited JSON
eca_bridge.bb ── Content-Length framed JSON-RPC ── eca server
```

- `eca_bridge.bb` converts between line-delimited JSON (all Quickshell's
  `Process` can parse) and ECA's LSP-style framing. It sets `processId` so the
  server exits with it, and on EOF it sends shutdown/exit. Server stderr goes to
  `~/.cache/omarchy-eca/server.log`.
- `Session.qml` is the protocol client: initialize/initialized,
  `chat/prompt`, `chat/contentReceived` (text, reasoning, tool calls, usage,
  metadata, progress, hooks, images, URLs, flags), `chat/statusChanged`,
  `chat/opened|cleared|deleted`, `config/updated` (chat-scoped and
  session-wide), `$/progress`, `$/showMessage`, and the `chat/askQuestion`
  server request. Each chat is a `ListModel` updated in place while streaming.
- `eca_workspaces.bb` maps ECA's cache dirs (`~/.cache/eca/<name>_<hash>`) back
  to folders by recomputing ECA's workspace hash, so the picker can offer
  workspaces with history.
