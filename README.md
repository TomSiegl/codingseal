<div align="center">
  <img src="codingseal.png" alt="CodingSeal" width="180">

  # CodingSeal — Claude Code in a Podman Container

  *Give Claude Code unrestricted tool access inside a rootless Podman container.
  Your host stays completely isolated. Connect via terminal, VS Code, from a remote machine,
  or drive it live from claude.ai/code and the Claude app with Remote Control.*
</div>

---

**What you get:**
- Claude Code with full permissions inside a container — `rm -rf /` can only hurt the container, never your host
- Zero-prompt startup — authenticate once, then every run drops straight into Claude (no theme picker, trust dialog, or re-login)
- VS Code Remote-SSH support — Claude's bash commands run inside the container, not on your host
- Remote Control — expose the container to claude.ai/code and the Claude mobile app, then steer it from your phone or browser (outbound HTTPS only, no inbound port)
- Built-in MCP servers — Context7 (up-to-date library docs) and Sequential Thinking are baked in; the GitHub MCP server turns on when you add a token
- GitLab CLI (`glab`) with per-project auth — drop a `.glab-token` in a project and only that project's token reaches the container, so a `read_api`-scoped token stays scoped
- Selectable project directories — only the folders you explicitly pass with `-p` are visible to Claude
- Optional GPU passthrough — NVIDIA and AMD both supported
- `--model` / `--advisor` flags — pin the session's model and pair it with a stronger advisor model at launch

---

```
┌──────────────────────────────────────────────────────────────┐
│                       HOST MACHINE                           │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                PODMAN CONTAINER                        │  │
│  │                                                        │  │
│  │   claude ──► /home/you/projects/myapp     ◄── ─ ─ ┐   │  │
│  │      │       /home/you/projects/lib       ◄── ─ ─ ┤   │  │
│  │      │       /home/you/datasets/          ◄── ─ ─ ┘   │  │
│  │      │                                               │  │  │
│  │   sshd (port 2222) ◄── VS Code Remote-SSH           │  │  │
│  └────────────────────────────────────────────────────────┘  │
│       bind-mounts ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘                 │
│       host dir: ~/.codingseal/claude-auth → ~/.claude/ (login)│
└──────────────────────────────────────────────────────────────┘
```

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Quick Start](#2-quick-start)
3. [Security Model](#3-security-model)
4. [First-Time Authentication](#4-first-time-authentication)
5. [Mounting Multiple Projects](#5-mounting-multiple-projects)
6. [Connection Modes](#6-connection-modes)
   - [Mode A: Local Interactive Terminal](#mode-a-local-interactive-terminal)
   - [Mode B: VS Code Remote-SSH](#mode-b-vs-code-remote-ssh)
   - [Mode C: Access from a Remote Machine](#mode-c-access-from-a-remote-machine)
   - [Mode D: Remote Control — drive from claude.ai/code](#mode-d-remote-control--drive-from-claudeaicode)
   - [SSH Agent Forwarding — git push with your host keys](#ssh-agent-forwarding--git-push-with-your-host-keys)
7. [MCP Servers](#7-mcp-servers)
8. [GitLab CLI (glab)](#8-gitlab-cli-glab)
9. [GPU Support](#9-gpu-support)
10. [Advanced: Sharing Host Python Packages](#10-advanced-sharing-host-python-packages)
11. [LaTeX](#11-latex)
    - [Fonts and pandoc](#fonts-and-pandoc)
12. [Updating the Image](#12-updating-the-image)
13. [Troubleshooting](#13-troubleshooting)
14. [Selecting a Model & Advisor](#14-selecting-a-model--advisor)

---

## 1. Prerequisites

| Requirement | How to check |
|---|---|
| **Podman >= 4.3** | `podman --version` — install: [podman.io](https://podman.io/docs/installation) |
| **Anthropic account** | [console.anthropic.com](https://console.anthropic.com) |
| **SSH key pair** | `ls ~/.ssh/id_*.pub` — generate: `ssh-keygen -t ed25519` |
| **VS Code** *(optional)* | With [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension |
| **NVIDIA drivers** *(optional)* | Required only for `--gpu-nvidia` — see [Section 9](#9-gpu-support) |

---

## 2. Quick Start

### First time (do this once)

```bash
# 1. Clone and configure
git clone https://github.com/TorbenGl/codingseal.git
cd codingseal
cp .env.example .env
#    Edit .env — set SSH_PUBLIC_KEY to the contents of ~/.ssh/id_ed25519.pub

# 2. Build the image (~5 minutes)
podman build -t coding-seal:latest .

# 3. Log in once (see Section 4). A URL is printed → open it, log in, paste the
#    code back. The login is saved to ~/.codingseal/claude-auth and reused forever.
scripts/run.sh --auth

# 4. Start working — drops straight into Claude, no prompts
set -a && source .env && set +a
scripts/run.sh -p ~/projects/myproject
```

### Every time after that

```bash
set -a && source .env && set +a
scripts/run.sh -p ~/projects/myproject
# Claude starts immediately — no auth prompt, permissions pre-configured
```

---

## 3. Security Model

### Why full permissions are safe here

Claude Code normally prompts before every file write, shell command, and web request. Those prompts are disabled inside this container. This is intentional and safe because:

- Claude can only see directories you explicitly pass with `-p`. Nothing else on your drive is mounted.
- Even if Claude runs `rm -rf /`, it destroys only the container's writable layer. The container exits. Start a new one.
- The container shares your kernel but has no access to host processes, network interfaces beyond the published ports, or the rest of your filesystem.

**The container is the security boundary. Claude's own permission system is redundant here.**

### What Claude cannot do

| Cannot do | Why |
|---|---|
| Read files outside `-p` mounts | Not mounted |
| Access other users' data | User-namespace isolation |
| Touch anything on the **host** outside project mounts and the auth volume | Only mounted paths are shared; the rest of the container's filesystem is a separate namespace regardless of container lifecycle |
| Reach the host's running processes | PID namespace is separate |

### Container lifecycle (containers are no longer auto-removed)

`run.sh` intentionally does **not** pass `--rm` to `podman run`. When a container exits (you quit `claude`, or `podman stop`), it stays around in an **Exited** state instead of being deleted — so you can resume the same container (keeping anything Claude installed or wrote outside the mounted project/auth volumes, e.g. `apt-get`/`pip` packages) or inspect its logs after a crash, rather than always starting completely fresh.

```bash
podman ps -a                    # exited containers are still listed
podman start -ai coding-seal    # resume the same container, re-attaching your terminal
podman logs coding-seal         # read output from a container that already exited
podman rm coding-seal           # fully delete it (only then does a fresh `run.sh` start clean)
```

**Gotcha:** because the container isn't deleted, running `scripts/run.sh` again with the same `--name` (the default is always `coding-seal`) after a previous session exited will fail — see [Troubleshooting](#13-troubleshooting). Either `podman start -ai coding-seal` to resume it, or `podman rm coding-seal` first to start clean.

---

## 4. First-Time Authentication

Auth is **login-only**: you log in once and the credential is saved to a fixed host folder
(`~/.codingseal/claude-auth`), then reused on every run. After this, **every run drops you
straight into Claude — no theme picker, no "trust this folder?" prompt, no re-login.**

> **Why login-only (no token or API key)?** [Remote Control](#mode-d-remote-control--drive-from-claudeaicode)
> (`scripts/run.sh --rc`) requires a full claude.ai login — long-lived `--setup-token` tokens and
> `ANTHROPIC_API_KEY` are inference-only and are rejected by it. Standardizing on the login keeps
> a single auth path that works in every mode.

> **Why a host folder and not a podman named volume?** A named volume lives under podman's storage root, and the VS Code snap relocates that root into its sandbox (`~/snap/code/<rev>/…`). Logging in from one place and restarting from another then hits two different, empty volumes — so the login "vanishes". A bind-mounted host folder is the same path everywhere, snap or not.

### Log in once

```bash
scripts/run.sh --auth
# A URL is printed → open it in your host browser → log in → paste the code back → container exits
```

On Linux there is no OS keychain, so Claude saves the login as a plaintext file —
`.credentials.json` (mode 600) — inside `CLAUDE_CONFIG_DIR`, which is the host
folder below. `--auth` verifies the file landed and prints `✅ Login saved…` on
success (or a `⚠️` with next steps if the browser step wasn't completed).

The login is saved in a plain host folder:
```
~/.codingseal/claude-auth/.credentials.json
```
It is user-scoped on your host (mode 600, only you can read it) and reused automatically on every subsequent run — from a normal terminal, the VS Code snap, or an SSH session alike (sshd hands sessions the same `CLAUDE_CONFIG_DIR`). Override the location with `CLAUDE_AUTH_DIR`.

Remove the saved login with:
```bash
rm -rf ~/.codingseal/claude-auth
```

### Why there are no setup prompts

`scripts/run.sh` seeds the auth folder on every run — it copies the policy `settings.json` from
[config/claude-settings.json](config/claude-settings.json) into it, and writes a minimal
`.claude.json` (onboarding + trust) the first time. The container itself needs no startup script.
Together these mean Claude never stops to ask:

| Prompt you would normally see | How it's suppressed |
|---|---|
| Theme / color picker | `hasCompletedOnboarding: true` seeded in `.claude.json` |
| "Do you trust the files in this folder?" | `projects["/"].hasTrustDialogAccepted: true` — trust inherits down to every mounted dir |
| Bypass-permissions mode (no per-tool prompts) | `permissions.defaultMode: bypassPermissions` in settings.json |
| "Yes, I accept bypass mode" warning | `skipDangerousModePermissionPrompt: true` in settings.json |
| "Cannot skip permissions as root" | Claude runs as the **non-root `coder` user** — the guard only triggers for root, so the check never fires |
| "Try the new fullscreen renderer?" | `tui: "default"` pinned in settings.json — any explicit `tui` value suppresses the upsell (use `"fullscreen"` if you prefer the flicker-free alt-screen UI) |
| Re-login on every run | `CLAUDE_CONFIG_DIR` (= the persistent host auth folder) holds `.credentials.json` |
| Prompts/login over **SSH / VS Code** | `config/sshd_config` sets a static `SetEnv CLAUDE_CONFIG_DIR=/home/coder/.claude`, so SSH sessions read the same login + settings as a local run |

These are applied automatically by [scripts/run.sh](scripts/run.sh) and [config/claude-settings.json](config/claude-settings.json) — you don't need to do anything.

---

## 5. Mounting Multiple Projects

Pass `-p` once per directory. Use it as many times as you need:

```bash
scripts/run.sh \
  -p ~/projects/myapp \
  -p ~/projects/shared-lib \
  -p ~/projects/infra \
  -p ~/datasets/training-data
```

Claude **opens in the first `-p` directory** (its working directory), so it starts right in your code instead of the empty `/home/coder` home. The other `-p` directories stay fully accessible by their paths.

Each directory is mounted at the **same absolute path** inside the container. If your project is at `/home/alice/projects/myapp` on the host, Claude sees it at `/home/alice/projects/myapp` inside too. This means:

- `git` history, branches, and remotes all work
- Relative imports across your projects work
- Symlinks resolve correctly
- You can open the same directory in VS Code on the host and in the container simultaneously

Claude can read and write all mounted directories. It cannot access anything else.

> **SELinux note (Fedora / RHEL):** The `:Z` label in `run.sh` is already set for you. Never omit it on SELinux-enforcing hosts — you will get `Permission denied` errors on mounts with no obvious cause.

---

## 6. Connection Modes

### Mode A: Local Interactive Terminal

The default. A TTY is allocated and Claude starts immediately.

```bash
set -a && source .env && set +a
scripts/run.sh -p ~/projects/myproject
```

You land directly in `claude`. Type your task. Claude's bash commands run in the container.

`lazygit` is installed too — a terminal UI over the git repo in whatever project you mounted with `-p` (staging hunks, branches, rebases, log). It uses your normal git config, and pushes go over SSH with your forwarded agent like any other git command.

`tmux` is installed in the image, which is mostly useful over SSH (Modes B–C): start work inside `tmux`, and a dropped connection leaves the session running — reattach with `tmux attach`. Note that it does **not** survive the container itself: `run.sh` uses `--rm`, so exiting the container discards every tmux session with it.

To get a plain shell instead (bare `--userns=keep-id` runs you as the non-root `coder` user — no `--user 0`, which is only needed for the `--ssh` mode's sshd):
```bash
podman run -it --rm \
  --userns=keep-id \
  --volume ~/.codingseal/claude-auth:/home/coder/.claude:Z \
  --volume ~/projects/myproject:~/projects/myproject:Z \
  localhost/coding-seal:latest \
  bash
```

---

### Mode B: VS Code Remote-SSH

This is the most powerful mode. VS Code connects into the running container over SSH. **Everything in VS Code — the terminal, extensions, language servers, and Claude Code itself — runs inside the container.**

#### Why this is important

When VS Code's Remote-SSH connects to the container, it installs **VS Code Server** inside the container. From that point on:

| VS Code feature | Where it runs |
|---|---|
| Integrated terminal | Container bash |
| Claude Code extension | Inside the container |
| Claude's Bash tool | Container process — **not your host** |
| File operations Claude performs | Your mounted project dirs only |
| Language servers (Pylance, etc.) | Inside the container |

This is exactly what you want: Claude operates in a sandboxed environment with no ability to affect your host.

#### Step-by-step setup

**Step 1 — Start the container in SSH mode**

```bash
set -a && source .env && set +a
scripts/run.sh --ssh -p ~/projects/myproject
```

Output:
```
Starting container 'coding-seal'...

  SSH into the container:
    ssh -p 2222 -i ~/.ssh/id_ed25519 coder@localhost

  Then start Claude:
    claude

  Stop the container:
    podman stop coding-seal
```

**Step 2 — Add the container to your SSH config**

```bash
cat >> ~/.ssh/config << 'EOF'

Host claude-container
    HostName 127.0.0.1
    Port 2222
    User coder
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
```

> `StrictHostKeyChecking no` is safe here because the connection is loopback-only. The host keys are now baked into the image (`ssh-keygen -A` at build time), so they stay stable across container restarts — you can drop this line if you prefer normal host-key checking; rebuilding the image rotates the keys.

**Step 3 — Connect with VS Code**

1. Open the Command Palette: `Ctrl+Shift+P` (Linux/Windows) or `Cmd+Shift+P` (Mac)
2. Run: **Remote-SSH: Connect to Host...**
3. Select **claude-container**
4. VS Code opens a new window. On the first connection it installs VS Code Server inside the container — this takes about 30 seconds.

**Step 4 — Install Claude Code on the remote**

In the new VS Code window (which is now running inside the container):
1. Open the Extensions panel (`Ctrl+Shift+X`)
2. Search for **Claude Code**
3. Click **Install in SSH: claude-container**

On subsequent connections, the extension is already installed.

**Step 5 — Verify you are inside the container**

Open the integrated terminal (`` Ctrl+` ``):

```bash
# These confirm you are in the container, not on your host:
hostname          # prints a short container ID hash
which claude      # /usr/local/bin/claude — the container's installation
ls ~/projects/    # your mounted project directories
```

**Step 6 — Start Claude**

From the VS Code integrated terminal:

```bash
claude
# or if you want to be explicit:
claude
```

From this point on, every bash command Claude runs executes as a container process. Claude cannot touch your host filesystem beyond what is mounted.

**Step 7 — Stop the container when done**

```bash
podman stop coding-seal
```

---

### Mode C: Access from a Remote Machine

The SSH port is bound to `127.0.0.1` only — it is not reachable directly from other machines. To connect from a separate computer, tunnel through the host first.

**Option 1 — SSH tunnel (two terminals)**

On your local machine:
```bash
# Terminal 1: keep this running — it forwards local port 2222 to the container
ssh -N -L 2222:localhost:2222 youruser@your-workstation-ip

# Terminal 2: connect to the container through the tunnel
ssh -p 2222 -i ~/.ssh/id_ed25519 coder@localhost
```

**Option 2 — ProxyJump (one step, works with VS Code)**

Add to your local `~/.ssh/config`:

```
Host your-workstation
    HostName your-workstation-ip
    User youruser

Host claude-remote
    HostName 127.0.0.1
    Port 2222
    User coder
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump your-workstation
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Then in VS Code's Remote-SSH: connect to `claude-remote`. VS Code hops through your workstation into the container transparently.

---

### Mode D: Remote Control — drive from claude.ai/code

Instead of connecting *into* the container (SSH/VS Code), Remote Control runs Claude **inside the container** and exposes that session to [claude.ai/code](https://claude.ai/code) and the Claude mobile app. You drive the container from your phone or any browser; all work still happens in the container, against your mounted projects.

The container makes **outbound HTTPS only** — it registers with the Anthropic API and polls for work, so it opens **no inbound port** and needs no SSH or tunnel. This is the easiest way to reach the container from another machine.

```bash
set -a && source .env && set +a
scripts/run.sh --rc -p ~/projects/myproject     # --rc is short for --remote-control
```

This starts the container **detached, in the background** (your terminal returns immediately) and runs `claude remote-control --spawn same-dir` as a headless server — no startup prompts, all remote sessions open in your mounted project directory. To reach it:

```bash
podman logs -f coding-seal      # prints the session URL once Claude connects
```

Open that URL — or just go to [claude.ai/code](https://claude.ai/code) / the Claude app and pick the session named after your project. Drive it from there; the container keeps running in the background until you stop it:

```bash
podman stop coding-seal
```

> **This mode needs the login from [Section 4](#4-first-time-authentication).** Remote Control requires a full claude.ai login (`scripts/run.sh --auth`), stored as `~/.codingseal/claude-auth/.credentials.json`. That's the only auth method this project uses anyway — `--rc` warns and points you to `--auth` if no login is found.

| Requirement | Notes |
|---|---|
| **Plan** | Pro, Max, Team, or Enterprise. API keys are not supported. On Team/Enterprise an Owner must enable the **Remote Control** toggle in [Claude Code admin settings](https://claude.ai/admin-settings/claude-code). |
| **Login** | A full claude.ai session login (`--auth`). |
| **Claude Code version** | The image installs the latest CLI; Remote Control server mode needs v2.1.51+ — rebuild the image if yours is older. |

Because nothing inbound is exposed, this works through NAT and firewalls with no port forwarding — a simpler alternative to [Mode C](#mode-c-access-from-a-remote-machine) when you just want to reach the container from elsewhere.

> **Want both SSH *and* web control on one container?** They can't auto-start together (a container runs one command), but you don't need them to: start with **`--ssh`**, connect, and run **`claude remote-control`** yourself inside that session. You then have VS Code/SSH *and* the web/mobile session against the same container. (`scripts/run.sh --ssh --rc` is rejected with this same tip.)

---

### SSH Agent Forwarding — git push with your host keys

No private key is ever baked into the image or copied into the container. To let Claude `git push`, `git pull` from a private repo, or sign commits, forward your **host** SSH agent instead: the container gets the *ability to use* your keys for the lifetime of the session, never the key material.

#### Over SSH (Modes B–C)

Add `ForwardAgent yes` to the host block you created in Mode B:

```
Host claude-container
    HostName 127.0.0.1
    Port 2222
    User coder
    IdentityFile ~/.ssh/id_ed25519
    ForwardAgent yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

…or pass `-A` per connection: `ssh -A -p 2222 -i ~/.ssh/id_ed25519 coder@localhost`.

Nothing to change on the container side — `config/sshd_config` doesn't touch `AllowAgentForwarding`, and OpenSSH defaults it to `yes`. VS Code's Remote-SSH reads the same `~/.ssh/config` block, so the integrated terminal (and therefore Claude Code running in it) gets the agent too.

Verify inside the container:
```bash
ssh-add -l                 # lists your host keys → the forwarded agent is reachable
ssh -T git@github.com      # "Hi <user>! You've successfully authenticated…"
git -C ~/projects/myproject push
```

#### Limits

The image appends an auto-detection block to `/home/coder/.bashrc`: when `ssh-add -l` gets no answer, it probes the existing `/tmp/ssh-*/agent.*` sockets newest-first and exports the first one that responds, so a new interactive shell picks up the live agent on its own. Two limits worth knowing:

- **Interactive shells only.** Ubuntu's skel `.bashrc` returns early for non-interactive shells, so a bare `bash -c` never reaches the block. In practice this is fine: you start `claude` from an interactive shell and it inherits that shell's corrected `SSH_AUTH_SOCK`, which Claude's own bash commands then inherit in turn.
- **Pre-existing tmux panes** keep the stale value, since they don't re-read `.bashrc`. Open a new window/pane, or run `source ~/.bashrc` in the old one.

> An agent that *is* reachable but holds **no keys** also fails `ssh-add -l`, so the probe runs anyway — harmless, but if pushes still fail, check `ssh-add -l` on your **host** first: an empty agent needs `ssh-add ~/.ssh/id_ed25519`.

---

## 7. MCP Servers

The container ships with [MCP](https://modelcontextprotocol.io) servers so Claude has better tools out of the box. They're registered at **user scope** — `run.sh` writes them into the auth folder's `.claude.json` on every run — so they load in **every** project and every mode (local, `--rc`, and a manual `claude` over `--ssh`) with **no approval prompt**.

| Server | What it does | Enabled | Auth |
|---|---|---|---|
| **context7** | Up-to-date, version-specific library/API docs pulled on demand | Always | Optional `CONTEXT7_API_KEY` (higher rate limits) |
| **sequential-thinking** | A step-by-step reasoning scaffold for harder problems | Always | None |
| **playwright** | A headless Chromium browser Claude can drive — navigate, click, read the DOM/console, screenshot — useful for a debug loop against a local dev server | Always | None |
| **github** | Issues, PRs, and repos via the GitHub API | Only when `GITHUB_PERSONAL_ACCESS_TOKEN` is set | Your token, sent as a Bearer header |

`context7`, `sequential-thinking` and `playwright` run **inside the container** as stdio servers (their npm packages are baked into the image). `github` is GitHub's **remote** endpoint (`https://api.githubcopilot.com/mcp/`) — nothing is baked for it; it's added only when you provide a token.

`playwright` always runs `--headless` — this container has no display, and Chromium's own headless mode needs none (no Xvfb/X11 required). It also runs `--browser chromium` (plus `PLAYWRIGHT_MCP_BROWSER=chromium` in the image): Playwright MCP otherwise defaults to real Google Chrome, which the image doesn't ship.

**Turn on / configure** (optional) in `.env`:
```bash
CONTEXT7_API_KEY=ctx7sk-...              # free key from context7.com/dashboard — higher limits
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_...     # enables the GitHub MCP server
```

**Verify** inside the container:
```bash
claude mcp list        # context7 ✓, sequential-thinking ✓, playwright ✓ (github ✓ only with a token)
# or run /mcp inside an interactive Claude session to see each server's tools
```
Then ask, e.g., *"use context7 to get the current Next.js App Router docs."*

**Remove one**: delete its key from `mcpServers` in `~/.codingseal/claude-auth/.claude.json` (and, for `github`, unset the token so `run.sh` doesn't re-add it).

> Context7's stdio server still reaches Context7's cloud for the actual doc content, so the container needs outbound network. It works anonymously (rate-limited) without a key.

### Plugins

[Matt Pocock's skills](https://github.com/mattpocock/skills) (`mattpocock-skills`, from Claude Code's official marketplace) are installed at **user scope**: grilling, TDD, spec/ticket flows, code review, domain modelling and more, invoked as `/mattpocock-skills:<skill>` (e.g. `/mattpocock-skills:tdd`). Run `/mattpocock-skills:setup-matt-pocock-skills` once per project.

`config/claude-settings.json` enables the plugin, but enabling doesn't download it — so on a run where the auth folder doesn't have it yet, `run.sh` installs it with a short one-shot container before starting yours. That happens once; afterwards the plugin lives in `~/.codingseal/claude-auth/plugins/` and updates itself. If the install fails (e.g. offline), the container starts without it and the next run retries.

**Verify** inside the container: `claude plugin list` (should show `mattpocock-skills@claude-plugins-official … ✔ enabled`).

**Remove it**: delete its line from `enabledPlugins` in `config/claude-settings.json` (and from `CLAUDE_PLUGINS` in `run.sh`, which would otherwise keep installing it).

---

## 8. GitLab CLI (glab)

The [GitLab CLI](https://gitlab.com/gitlab-org/cli) (`glab`) is baked into the image — issues, MRs, pipelines, `glab api`. What is *not* baked in is a token: **the token belongs to the project, not to the container.**

That is deliberate. A token scoped to `read_api` on a single project is only useful if it stays with that project, so `run.sh` reads it out of the project you mount and hands glab exactly that one.

**Set it up** — one file per project, inside the project:

```bash
echo glpat-xxxxxxxxxxxxxxxxxxxx > ~/projects/myapp/.glab-token
chmod 600 ~/projects/myapp/.glab-token
echo '.glab-token' >> ~/projects/myapp/.gitignore     # do not commit it
```

Then just run as usual — the token file rides along with the project's own bind-mount:

```bash
scripts/run.sh -p ~/projects/myapp
# Starting container 'coding-seal' from image 'localhost/coding-seal:latest'...
#   glab: token loaded from .glab-token for myapp → gitlab.example.org
```

Inside the container:

```bash
glab auth status          # ✓ Token found in configuration file
glab mr list
glab api projects/:id     # read_api is enough for everything read-only
```

**What `run.sh` does with the file:**

1. Scans every `-p` directory for `.glab-token` (override the name with `GLAB_TOKEN_FILE`).
2. Takes the GitLab **host** from that project's `origin` remote — SSH, `ssh://` and HTTPS remote URLs are all understood, so a self-managed instance needs no extra setup. A project with no GitLab remote falls back to `GITLAB_HOST` from your `.env`, then `gitlab.com`.
3. Passes the resulting config to the container, where `codingseal-glab-init` writes it (mode `600`) to `/home/coder/.config/glab-cli/config.yml` before starting your command. That is glab's **default** config location, so it applies in every mode — including SSH sessions, which never see the container's environment.

| Detail | Behaviour |
|---|---|
| **Nothing on the host** | The config exists only inside the container and dies with it. Two containers on different projects therefore never share or overwrite each other's tokens — run as many in parallel as you like. |
| **Scope stays yours** | A container only ever holds tokens for the projects you passed it with `-p`. Nothing container-wide, nothing in `.env`, no file left behind. |
| **One token per host** | glab stores one token per hostname. Two projects on the same instance can't both be authenticated: the first `-p` wins and `run.sh` warns about the rest. Run one project at a time, which is what per-project scoping means anyway. |
| **Plaintext, by design** | `glab auth status` suggests moving the token into an OS keyring. There is no keyring in a container; the file is `600` in a container-private directory. |
| **Token missing?** | Nothing breaks — glab is simply unauthenticated, and the container starts exactly as it did before. Add the file and restart. |

> `glab` uses the token only for **API** calls. `git push`/`pull` still go over SSH with your forwarded agent — see [SSH Agent Forwarding](#ssh-agent-forwarding--git-push-with-your-host-keys).

---

## 9. GPU Support

### NVIDIA

Requirements: NVIDIA drivers installed on the host. No additional container toolkit needed.

```bash
scripts/run.sh --gpu-nvidia -p ~/projects/ml-project
```

This passes `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-modeset`, `/dev/nvidia-uvm-tools` into the container.

> `/dev/nvidia-caps/` files are **not** needed for compute workloads (only for MIG mode).

To verify GPU access inside the container:
```bash
# Inside the container:
apt-get install -y nvidia-utils-550   # match your driver version
nvidia-smi
```

**CDI (future-proof, Podman 5.0+)**

If you have `/etc/cdi/nvidia.yaml` (from `nvidia-ctk cdi generate`), add this to `~/.config/containers/containers.conf`:

```toml
[engine]
cdi_spec_dirs = ["/etc/cdi"]
```

Then use `--device nvidia.com/gpu=all` instead of `--gpu-nvidia`. This is the preferred interface going forward.

### AMD

Requirements: ROCm-compatible AMD GPU and drivers.

```bash
scripts/run.sh --gpu-amd -p ~/projects/ml-project
```

Passes `--device /dev/kfd --device /dev/dri` with `--group-add keep-groups` so the container inherits your host user's `render` and `video` group memberships.

To verify:
```bash
# Inside the container:
apt-get install -y rocm-smi
rocm-smi
```

### No GPU

Default — no flag needed:
```bash
scripts/run.sh -p ~/projects/myproject
```

---

## 10. Advanced: Sharing Host Python Packages

If you have a large Python environment on your host and want to avoid reinstalling packages in the container, mount your host's site-packages read-only.

> This works reliably only when the host and container use the **same OS and Python version**. This repo uses `ubuntu:24.04` as the base — if your host is also Ubuntu 24.04, native `.so` extensions are ABI-compatible.

```bash
# Find your host site-packages paths
python3 -c "import site; print('\n'.join(site.getsitepackages()))"

# Add to the run command (bare --userns=keep-id runs as the coder user)
podman run -it --rm \
  --userns=keep-id \
  --volume ~/.codingseal/claude-auth:/home/coder/.claude:Z \
  --volume ~/projects/myproject:~/projects/myproject:Z \
  --volume /usr/lib/python3/dist-packages:/mnt/host-python/dist-packages:ro,Z \
  --volume ~/.local/lib/python3.12/site-packages:/mnt/host-python/user-packages:ro,Z \
  --env PYTHONPATH=/mnt/host-python/dist-packages:/mnt/host-python/user-packages \
  localhost/coding-seal:latest \
  claude
```

Packages installed with `uv pip install` inside the container go into the container's own layer and don't affect your host.

---

## 11. LaTeX

TeX Live is **baked into the image**: `pdflatex`, `xelatex`, `lualatex`, `latexmk`, `biber`, `bibtex`, `makeindex`, EPS includes, `pdfcrop`, and the `dvips`/`ps2pdf` route all work out of the box.

Nothing is bind-mounted from the host, so **your host needs no TeX Live at all** and LaTeX behaves identically everywhere. The trade is image size — TeX Live is large — so the package set is a build argument:

| `LATEX_SCHEME` | Image size | Build time | Engines | Use when |
|---|---|---|---|---|
| `curated` **(default)** | 4.19 GB | ~19 min | pdflatex, xelatex, lualatex, latex | Ordinary documents: papers, reports, theses |
| `full` | ~8.3 GB * | ~32 min * | all of the above | You want every package Debian ships |
| `minimal` | 1.66 GB | ~6 min | pdflatex, lualatex, latex (no xelatex) | Simple documents; no tikz, no biber |
| `none` | 1.34 GB | ~3 min | — | You don't want LaTeX in the image |

> Sizes are the whole image, and every one of them includes the ~300 MB of fonts and pandoc
> below, which are installed regardless of scheme (the base with neither LaTeX nor
> fonts/pandoc is 1.03 GB). These builds are slow — mostly download plus format generation
> — and changing `LATEX_SCHEME` re-runs all of it.
>
> \* `full` numbers are estimates — `curated`, `minimal` and `none` were built and tested;
> `full` was not. See [`LATEX.md`](LATEX.md).

```bash
podman build -t coding-seal:latest .                                    # curated (default)
podman build --build-arg LATEX_SCHEME=full -t coding-seal:latex-full .  # everything
podman build --build-arg LATEX_SCHEME=none -t coding-seal:nolatex .     # opt out
```

Then just use it — no extra flags, no mounts:

```bash
scripts/run.sh -p ~/projects/paper
# inside: latexmk -pdf thesis.tex
```

`curated` covers the usual macro territory (`tikz`/`pgfplots`, `amsmath`, `booktabs`, `microtype`, `biblatex`, `algorithm2e`, `siunitx`, …) with German and English hyphenation. It leaves out 2.3 GB of offline PDF manuals, the other language trees, ConTeXt, and specialist collections. If a document needs one more package, add it to the `curated` list in the `Containerfile` and rebuild — that is much cheaper than switching to `full`.

**Smoke tests run during the build**: a one-page `pdflatex` document must compile, and so must the font and pandoc checks below, or the build fails — so a broken package set is caught at build time rather than by your first document.

### Fonts and pandoc

Independent of `LATEX_SCHEME`, the image also carries **real system fonts** and **pandoc**:

| | |
|---|---|
| **Microsoft core fonts** | Arial, Times New Roman, Courier New, Georgia, Verdana, Trebuchet MS, Comic Sans MS, Impact, Andale Mono — so `\setmainfont{Arial}` just works under xelatex/lualatex |
| **Metric clones** | Liberation (Arial/Times/Courier), Carlito (Calibri), Caladea (Cambria) |
| **General coverage** | DejaVu, FreeFont, Noto Core (Greek, Cyrillic, Hebrew, Arabic, … — no CJK) |
| **pandoc** | 3.1.3. Markdown/HTML/docx/odt/epub/LaTeX conversion, and PDF output through the LaTeX above (`--pdf-engine=pdflatex\|xelatex\|lualatex`) |

With `LATEX_SCHEME=minimal`, pandoc's PDF output works via `pdflatex` only; with `none` it converts everything except PDF. Everything else in the table is present in every scheme.

The `texlive-fonts-*` packages do **not** cover this: they populate the texmf tree for pdflatex's NFSS names, but install almost nothing that fontconfig can see — and fontconfig is how `fontspec` finds fonts. Nor do the metric clones alone suffice: `fc-match Arial` happily answers `Liberation Sans` via fontconfig aliasing, while `\setmainfont{Arial}` still fails, because `fontspec` matches on the family's own name. Only the real fonts fix it.

These sit in a layer **after** the TeX Live layers, so adding a font or bumping pandoc never re-runs the ~17-minute LaTeX install.

The Microsoft fonts come from `ttf-mscorefonts-installer`, which needs a EULA (preseeded for you) and downloads from SourceForge at build time. Drop them if you'd rather not take that dependency:

```bash
podman build --build-arg MSCOREFONTS=false -t coding-seal:latest .
```

That saves ~2 minutes of build time but only ~20 MB, so it is a licensing and
build-reliability choice, not a size one. The cost is that `\setmainfont{Arial}` no longer works.

The build-time smoke test covers all of this too: a `fontspec` document must compile with Arial (or Liberation Sans when `MSCOREFONTS=false`), and `pandoc` must produce a PDF.

> **See [`LATEX.md`](LATEX.md)** for the exact package lists, what each scheme omits, why `ghostscript` and the `fonts-texgyre`/`fonts-lmodern` packages are named explicitly, the font-resolution trap in detail, and the trade-offs against the alternative approach (mounting the host's TeX Live instead, on the `latex-host-mount` branch).

---

## 12. Updating the Image

**When do you need to rebuild?**

| You changed… | Rebuild needed? |
|---|---|
| `Containerfile`, `config/sshd_config` (e.g. the `coder` user, sshd options, baked host keys) | **Yes** — these are baked into the image: `podman build -t coding-seal:latest .` |
| `scripts/run.sh`, `config/claude-settings.json`, `.env` (mounts, GPU flags, auth dir, the seeded settings) | No — `run.sh` re-seeds `settings.json` from `config/` into the auth folder on every run, so changes take effect immediately |

**Full update** (base OS + Node.js + Claude Code + uv):
```bash
podman build --pull=newer -t coding-seal:latest .
```

**Custom Python version:**
```bash
podman build --build-arg PYTHON_VERSION=3.11 -t coding-seal:py311 .
CLAUDE_IMAGE=localhost/coding-seal:py311 scripts/run.sh -p ~/projects/myproject
```

**Custom LaTeX package set** (see [Section 11](#11-latex)):
```bash
podman build --build-arg LATEX_SCHEME=full -t coding-seal:latex-full .
CLAUDE_IMAGE=localhost/coding-seal:latex-full scripts/run.sh -p ~/projects/paper
```

> The LaTeX layer sits early in the `Containerfile`, so it stays cached when you change
> the Node/uv/Claude layers below it. Changing `LATEX_SCHEME` rebuilds it (and everything
> after) — that is a multi-GB download for `full`.

---

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Theme picker / trust prompt / login appears | Image built before these fixes | Rebuild: `podman build -t coding-seal:latest .` (seeds the wizard-suppression state) |
| `claude` asks to authenticate on every run | No saved login, or the `--auth` browser step was never completed | Run `scripts/run.sh --auth`, confirm it printed `✅ Login saved…`; verify with `ls -l ~/.codingseal/claude-auth/.credentials.json` |
| `--auth` says it saved, but the next run still asks to log in | Older versions stored auth in a podman **named volume**, whose location follows podman's storage root — and the VS Code snap relocates that root into its sandbox (`~/snap/code/<rev>/…`), so login and restart hit different empty volumes | Fixed: `run.sh` now bind-mounts a fixed host folder (`~/.codingseal/claude-auth`) that's identical in every context. Just `scripts/run.sh --auth` once more. (You can delete the stale `claude-auth` named volume: `podman volume rm claude-auth`.) |
| `--auth` login doesn't stick | Browser code not pasted back, or `~/.codingseal/claude-auth` was deleted between runs | Re-run `scripts/run.sh --auth`, paste the code when prompted, and confirm `~/.codingseal/claude-auth/.credentials.json` exists |
| `--dangerously-skip-permissions cannot be used with root` | Old image that ran as root | Rebuild — the image now runs Claude as the non-root `coder` user; confirm with `podman exec coding-seal whoami` (should print `coder` for the Claude process) |
| `Invalid API key` / auth errors | Expired or incomplete login | Re-run `scripts/run.sh --auth` to refresh the login in `~/.codingseal/claude-auth` |
| `rootlessport listen tcp 127.0.0.1:2222: bind: address already in use` | Another container already holds the SSH port | Only `--ssh` publishes 2222, so `local` and `--rc` runs no longer collide. If you still see it, an `--ssh` container is up — `podman ps`, then `podman stop coding-seal` (or `--port 2223` for a second one). A container started from a normal terminal may be invisible to `podman ps` run inside the VS Code snap (different storage root) — stop it from the terminal you started it in |
| `ssh: connect to host localhost port 2222: Connection refused` | Container not running or sshd didn't start | `podman ps`; `podman logs coding-seal` for sshd errors |
| `Permission denied (publickey)` via SSH | Wrong key or key not injected | Check `SSH_PUBLIC_KEY` is set; `podman exec --user coder coding-seal cat /home/coder/.ssh/authorized_keys` |
| VS Code says "Cannot connect to remote" | Container not running | Start with `scripts/run.sh --ssh -p ...` first |
| Claude Code extension runs on local, not inside container | Extension not installed on the remote | Extensions panel → Claude Code → "Install in SSH: claude-container" |
| Claude's bash commands run on your host | VS Code not connected to container | Check VS Code title bar shows `[SSH: claude-container]` |
| `claude: command not found` | PATH issue | `which claude` inside container; rebuild if missing |
| Project files owned by the wrong UID / not writable | `--userns=keep-id` not applied | `run.sh` sets it so your host user maps to `coder`; verify files you create inside appear owned by you on the host |
| `Permission denied` on project files | SELinux denying the mount | The `:Z` flag in `run.sh` handles this — verify you are using `run.sh` not a manual command |
| NVIDIA GPU not visible inside container | Devices not passed through | Use `--gpu-nvidia`; verify `ls -l /dev/nvidia*` on host shows your devices |
| AMD GPU not visible | Group membership issue | `--gpu-amd` includes `--group-add keep-groups`; check `/dev/kfd` exists on host |
| `claude auth login` URL doesn't open a browser | Container has no display | This is expected — copy the URL, paste it into your **host** browser |
| VS Code keeps disconnecting | Missing SSH keepalive | `sshd_config` already sets `ClientAliveInterval 30`; check your local `~/.ssh/config` too |
| `git push` inside the container: `Permission denied (publickey)` | No agent forwarded — the container holds no private keys by design | Reconnect with `ForwardAgent yes` / `ssh -A` — see [SSH Agent Forwarding](#ssh-agent-forwarding--git-push-with-your-host-keys). Check with `ssh-add -l` inside *and* on the host |
| `ssh-add -l`: "Could not open a connection to your authentication agent" in a `podman exec` shell or an old tmux pane | `SSH_AUTH_SOCK` is unset (exec) or points at a closed session's socket (reconnect) | The `.bashrc` auto-detection fixes any **new** interactive shell; in an existing pane run `source ~/.bashrc`. Rebuild if the image predates the fix |
| `--rc`: "Remote Control requires a full-scope login token" | No claude.ai login in the auth folder (e.g. you deleted it) | Run `scripts/run.sh --auth` once to save a full claude.ai login, then `scripts/run.sh --rc`. The login in `~/.codingseal/claude-auth/.credentials.json` is what Remote Control uses |
| `--rc`: "Remote Control requires a claude.ai subscription" / "not yet enabled" | No claude.ai login, or feature not rolled out to your account | `scripts/run.sh --auth` to log in; confirm your plan supports it (Pro/Max/Team/Enterprise). On Team/Enterprise an Owner must enable the Remote Control toggle in admin settings |
| `--rc`: no session URL appears / `claude: command not found` for `remote-control` | Image predates Remote Control (needs Claude Code v2.1.51+) | Rebuild: `podman build --pull=newer -t coding-seal:latest .` |
| `glab`: "no token provided" / `401 Unauthorized` | No `.glab-token` in the mounted project, or the token is expired/revoked | Watch for the `glab: token loaded …` line when `run.sh` starts; inside, check `glab auth status` and `cat ~/.config/glab-cli/config.yml`. The config is built at start-up, so add the token file and restart the container |
| `glab`: authenticated against the wrong host | The project's `origin` remote isn't the GitLab instance the token is for (or there is no remote, so `GITLAB_HOST`/`gitlab.com` was used) | Check `git -C <project> remote get-url origin`; set `GITLAB_HOST` in `.env` for a project without a GitLab remote |
| `glab`: second project on the same instance is unauthenticated | glab stores one token per hostname — `run.sh` warns and keeps the first `-p` project's token | Intended with per-project scopes: run one project at a time, or issue one token covering both |
| `glab`: `403 Forbidden` on a write (`glab mr create`, `glab issue note`) | The token is scoped `read_api` | Expected — `read_api` is read-only. Use a token with `api` scope if you need writes |
| `pdflatex: command not found` | Image built with `LATEX_SCHEME=none`, or predates LaTeX support | Rebuild: `podman build -t coding-seal:latest .` |
| `lazygit: command not found` | Image predates lazygit | Rebuild: `podman build -t coding-seal:latest .` (pin another release with `--build-arg LAZYGIT_VERSION=0.65.1`) |
| Playwright MCP fails to launch the browser (`Executable doesn't exist` or similar) | Image predates the Playwright MCP server, or `PLAYWRIGHT_BROWSERS_PATH` wasn't readable | Rebuild: `podman build -t coding-seal:latest .`; check with `claude mcp list` (should show `playwright ✓`) |
| Playwright MCP fails with `Chromium distribution 'chrome' is not found at /opt/google/chrome/chrome` | Server registered without `--browser chromium` by an older `run.sh`, on an image without `PLAYWRIGHT_MCP_BROWSER` | Restart the container with the current `run.sh` (it rewrites the `playwright` entry), or rebuild the image |
| `xelatex` missing, `biber` missing, or `tikz.sty not found` | Image built with `LATEX_SCHEME=minimal` — it has pdflatex/lualatex/latex but no xelatex, no biber and no tikz | Rebuild with the default (`curated`) or `full` — see [Section 11](#11-latex) |
| `pdfcrop`/`texcount` not found but every `.sty` is present | Style files and executables come from *different* packages — these binaries live in `texlive-extra-utils` | Present in `curated` and `full`; add `texlive-extra-utils` if you customised the list |
| `LaTeX Error: File 'foo.sty' not found` | The package isn't in the scheme you built | Add the owning `texlive-*` package to the `curated` list in the `Containerfile` and rebuild, or build `LATEX_SCHEME=full`. Find the owner via [packages.ubuntu.com](https://packages.ubuntu.com) |
| `fontspec error: The font "…" cannot be found` | Only Type 1 faces present, not OpenType | `curated` and `full` install `fonts-texgyre`/`fonts-lmodern` for exactly this; `minimal` has no `fontspec` at all. Check with `podman run --rm --entrypoint fc-match coding-seal:latest "TeX Gyre Pagella"` |
| `…-eps-converted-to.pdf not found` on `\includegraphics{x.eps}` | Ghostscript or `repstopdf` missing | All schemes except `none` install `ghostscript`; verify with `podman run --rm --entrypoint gs coding-seal:latest --version` |
| Build fails at `pdflatex smoke test FAILED` | The chosen `LATEX_SCHEME` is genuinely broken | This is the build-time guard doing its job — the failing `pdflatex` log is printed above the error |
| Image is much bigger than expected | `LATEX_SCHEME=full` adds ~7.4 GB (incl. 2.3 GB of manuals it cannot drop) | Use the default `curated` (~2.9 GB) or `none`; check with `podman images` |
| `Error: creating container storage: the container name "coding-seal" is already in use by ... You have to remove that container to be able to reuse that name` | Containers aren't auto-removed on exit (no `--rm` — see [Container lifecycle](#container-lifecycle-containers-are-no-longer-auto-removed)); a previous session's exited container still holds the name | Resume it: `podman start -ai coding-seal` — or delete it first: `podman rm coding-seal`, then re-run `scripts/run.sh` |

---

## 14. Selecting a Model & Advisor

`run.sh` can pin the session's model and, optionally, pair it with a stronger **advisor model** that Claude consults mid-task (before committing to an approach, on a recurring error, or before declaring a task done) — both are passed straight through to the real `claude --model` / `claude --advisor` flags.

```bash
scripts/run.sh -p ~/projects/myproject --model sonnet              # pin the model
scripts/run.sh -p ~/projects/myproject --model sonnet --advisor    # + advisor, defaults to opus
scripts/run.sh -p ~/projects/myproject --model haiku --advisor opus  # explicit advisor override
```

Only applies to `local` sessions and `--rc`/`--remote-control`; it's ignored (with a warning) for `--auth` and `--ssh`, since neither actually starts a `claude` session for the flag to attach to.

**`--model VALUE`** — accepts `sonnet`, `opus`, `haiku`, `fable`, `default`, `best`, `opusplan`, `sonnet[1m]`, `opus[1m]`, or a full model ID (`claude-sonnet-5`). Casual forms like `sonnet5`/`opus5` are normalized automatically to what `claude` actually accepts.

**`--advisor [VALUE]`** — bare `--advisor` defaults to `opus`; `--advisor VALUE` overrides (`opus`, `sonnet`, `fable`, or a full model ID). The advisor is an [experimental Claude Code feature](https://code.claude.com/docs/en/advisor.md):

- Requires the **Anthropic API** — not available on Bedrock, Claude Platform on AWS, Google Cloud's Agent Platform, or Microsoft Foundry.
- The advisor must be at least as capable as the main model (e.g. a `sonnet` main can pair with `opus`/`sonnet`, but not a weaker model) — `claude` itself validates this and errors if the pairing isn't accepted; `run.sh` doesn't duplicate that check.
- `fable` is currently rejected as an advisor value pending an Anthropic rollout (it works fine as the *main* `--model`) — `run.sh` prints a heads-up but still passes it through.
- Once running, change it mid-session with `/advisor <model>` or `/advisor off`, or see `/advisor` for the full picker.

---

## Repository layout

```
codingseal/
├── codingseal.png            ← Project logo
├── README.md                 ← This tutorial
├── LATEX.md                  ← LaTeX package sets, what each scheme omits, trade-offs (§11)
├── Containerfile             ← ubuntu:24.04 + Node LTS + Claude Code + uv + Python + TeX Live + glab + sshd + tmux + lazygit (tini as PID 1, no entrypoint script)
├── .env.example              ← Copy to .env; set SSH_PUBLIC_KEY for --ssh
├── scripts/
│   └── run.sh                ← Wrapper: seeds config (incl. glab tokens from the -p dirs) + runs --auth / --rc /
│                                --ssh / -p PATH / --gpu-nvidia|amd / --model / --advisor. No --rm: containers
│                                persist (Exited) after exit — see Section 3, "Container lifecycle"
└── config/
    ├── sshd_config           ← Port 2222, key-only auth, static SetEnv CLAUDE_CONFIG_DIR, VS Code keepalive
    └── claude-settings.json  ← bypassPermissions + full allow list + enabled plugins (seeded into the auth folder by run.sh)
```
