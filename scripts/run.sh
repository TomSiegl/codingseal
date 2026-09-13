#!/usr/bin/env bash
# run.sh — start the coding-seal container with flexible options
set -euo pipefail

# Locate the repo so we can seed Claude's config from config/ (this script lives
# in <repo>/scripts/).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_SRC="${REPO_DIR}/config/claude-settings.json"

# ── Defaults ──────────────────────────────────────────────────────────────
GPU_FLAGS=()
PROJECT_MOUNTS=()
PROJECT_DIRS=()          # same paths as PROJECT_MOUNTS, for the glab token scan
MODE="local"            # "local"          → interactive TTY, `claude` starts immediately
                        # "remote-control" → foreground `claude remote-control`, so
                        #                     claude.ai/code + the Claude app can drive this env
                        # "ssh"            → detached; SSH / VS Code Remote-SSH into the container
                        # "auth"           → interactive `claude auth login`, saves login to the auth dir
IMAGE="${CLAUDE_IMAGE:-localhost/coding-seal:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-coding-seal}"
# Persistent auth lives in a FIXED host directory, not a podman named volume.
# Named volumes follow podman's storage root, which the VS Code snap relocates
# into its sandbox (~/snap/code/<rev>/...). That made login land in one volume
# and the next run read a different, empty one. A bind-mount to a stable $HOME
# path is identical whether run.sh is launched from a normal shell or inside the
# VS Code snap, so the login always persists. Override with CLAUDE_AUTH_DIR.
CLAUDE_AUTH_DIR="${CLAUDE_AUTH_DIR:-${HOME}/.codingseal/claude-auth}"
SSH_PORT="${SSH_PORT:-2222}"
# glab (GitLab CLI): the token for a project lives IN that project, in a file
# named GLAB_TOKEN_FILE. run.sh reads it and passes glab's config to the container,
# which writes it at start-up — so tokens stay per-project and scoped exactly as
# you issued them (e.g. read_api on one project), with nothing container-wide.
GLAB_TOKEN_FILE="${GLAB_TOKEN_FILE:-.glab-token}"

# ── 9router (https://github.com/decolua/9router) ──────────────────────────
# OPT-IN. With --9router the container starts 9router next to Claude and points
# Claude Code at it — ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN, exactly the way
# Claude Code talks to any LLM gateway. Every model request then goes to whatever
# provider you connected in 9router's dashboard instead of to Anthropic, so this
# is off unless you ask for it: it redirects ALL of your inference.
NINEROUTER_PORT="${NINEROUTER_PORT:-20128}"
# The router's state — connected providers and their OAuth tokens, the API keys
# it issues, the routing rules. A fixed HOST directory for the same reason
# CLAUDE_AUTH_DIR is one: the container runs --rm, so anything that isn't
# bind-mounted is gone the moment you quit, and you would be reconnecting
# providers by hand on every run.
NINEROUTER_DATA_DIR="${NINEROUTER_DATA_DIR:-${HOME}/.codingseal/9router}"
# The key Claude authenticates to the router with. You create it in the
# dashboard on the first run (there is nothing to set before that exists) and
# then put it in .env; see the bootstrap notice printed below.
NINEROUTER_API_KEY="${NINEROUTER_API_KEY:-}"
# Model id to request, in 9router's own namespace (e.g. kr/claude-sonnet-4.5).
# Claude Code otherwise asks for Anthropic's model ids, which only work if the
# router has an alias for them.
NINEROUTER_MODEL="${NINEROUTER_MODEL:-}"
# Model for Claude's cheap background work (session titles and similar).
# Defaults to NINEROUTER_MODEL so those calls can't 404 on an unrouted id.
NINEROUTER_SMALL_MODEL="${NINEROUTER_SMALL_MODEL:-}"
# First-login password for the dashboard. 9router's own default is 123456.
NINEROUTER_PASSWORD="${NINEROUTER_PASSWORD:-}"

# Mutually exclusive mode requests (a container runs ONE command).
want_auth=0
want_rc=0
want_ssh=0
# Not a mode — an add-on that composes with local and --ssh.
want_9router=0

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: scripts/run.sh [OPTIONS]

Options:
  --auth                One-time login: runs `claude auth login` and saves the
                        credential to the auth dir (this is the only auth method)
  --gpu-nvidia          Pass through NVIDIA GPU(s) via /dev/nvidia* devices
  --gpu-amd             Pass through AMD GPU via /dev/kfd and /dev/dri
  --no-gpu              Run without GPU (default)
  -p, --project PATH    Bind-mount a project directory (repeatable)
  --remote-control, --rc
                        Remote Control: run `claude remote-control` (detached, in the
                        background) so claude.ai/code and the Claude mobile app can
                        drive this environment; get the URL via `podman logs`
  --ssh                 Headless: container stays running for SSH / VS Code Remote-SSH
  --port PORT           SSH port on localhost, used by --ssh (default: 2222)
  --9router             Start 9router in the container and route Claude's model
                        requests through it instead of to Anthropic (see below)
  --9router-port PORT   Host port for the 9router dashboard (default: 20128)
  --name NAME           Container name (default: coding-seal)
  --image IMAGE         Image to use (default: localhost/coding-seal:latest)
  -h, --help            Show this help

Authentication:
  Log in once with `scripts/run.sh --auth`. The login is saved in the host folder
  (CLAUDE_AUTH_DIR) and reused on every run. Remote Control needs this full login —
  long-lived tokens and API keys are not supported.

GitLab CLI (glab):
  Put the project's token in a file inside the project itself:

      echo glpat-xxxxxxxxxxxx > ~/projects/myapp/.glab-token   # and gitignore it

  Every run scans the -p directories for that file and builds a glab config for
  the container (host taken from the project's `origin` remote), so `glab` inside
  is authenticated for that project only — keep the token scoped to it. The config
  is written inside the container, never on the host, so parallel runs on
  different projects stay independent.

9router (--9router):
  9router is a local AI router. Started with --9router it runs inside the
  container and Claude Code is pointed at it, so model requests go to a provider
  you connected in 9router's dashboard rather than to Anthropic. Its dashboard is
  published on http://localhost:20128 (loopback only).

  First run — there is no API key to configure yet, so start it empty:

      scripts/run.sh --9router -p ~/projects/myapp

  Open http://localhost:20128, connect a provider, create an API key, then put
  that key and a model id in .env and run again:

      NINEROUTER_API_KEY=sk-...
      NINEROUTER_MODEL=kr/claude-sonnet-4.5     # 9router's id, not Anthropic's

  Until NINEROUTER_API_KEY is set, Claude keeps using your normal claude.ai
  login and only the router is started — so the first run is still a usable
  session. The router's state lives in ~/.codingseal/9router on the host.

  --9router cannot be combined with --remote-control: Claude Code disables
  Remote Control whenever a gateway credential or a non-Anthropic base URL is
  active. Use --9router with the default mode or with --ssh.

Environment variables (set these before running):
  SSH_PUBLIC_KEY           Public key injected into the container's authorized_keys (--ssh)
  CLAUDE_AUTH_DIR          Host dir for persistent login (default: ~/.codingseal/claude-auth)
  GLAB_TOKEN_FILE          Token filename looked for in each -p dir (default: .glab-token)
  GITLAB_HOST              Fallback GitLab host when a project has no `origin` remote
  NINEROUTER_API_KEY       9router API key Claude authenticates with (--9router)
  NINEROUTER_MODEL         Model id to request from 9router, in its namespace
  NINEROUTER_SMALL_MODEL   Model for Claude's background tasks (default: NINEROUTER_MODEL)
  NINEROUTER_PASSWORD      First-login password for the dashboard (9router default: 123456)
  NINEROUTER_DATA_DIR      Host dir for 9router's database (default: ~/.codingseal/9router)
  NINEROUTER_PORT          Dashboard/API port (default: 20128)
  SSH_PORT, CONTAINER_NAME, CLAUDE_IMAGE  Override defaults

Examples:
  # First-time: log in once, saved to ~/.codingseal/claude-auth
  scripts/run.sh --auth

  # Interactive session with one project
  scripts/run.sh -p ~/projects/myapp

  # Multiple projects
  scripts/run.sh -p ~/projects/myapp -p ~/projects/infra

  # Remote Control — drive this container from claude.ai/code or the Claude app
  scripts/run.sh --rc -p ~/projects/myapp

  # Headless SSH / VS Code Remote-SSH
  scripts/run.sh --ssh -p ~/projects/myapp

  # Both ways at once: start with --ssh, then SSH in and run `claude remote-control`
  scripts/run.sh --ssh -p ~/projects/myapp

  # With NVIDIA GPU
  scripts/run.sh --gpu-nvidia -p ~/projects/ml

  # Route Claude through 9router (dashboard on http://localhost:20128)
  scripts/run.sh --9router -p ~/projects/myapp
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-nvidia)
            GPU_FLAGS=(
                "--device" "/dev/nvidia0"
                "--device" "/dev/nvidiactl"
                "--device" "/dev/nvidia-uvm"
                "--device" "/dev/nvidia-modeset"
                "--device" "/dev/nvidia-uvm-tools"
            )
            shift ;;
        --gpu-amd)
            GPU_FLAGS=(
                "--device" "/dev/kfd"
                "--device" "/dev/dri"
                "--group-add" "keep-groups"
            )
            shift ;;
        --no-gpu)
            GPU_FLAGS=()
            shift ;;
        -p|--project)
            [[ -z "${2:-}" ]] && { echo "Error: -p requires a path" >&2; exit 1; }
            ABSPATH=$(realpath "$2")
            # :Z = private SELinux label (no-op when SELinux is disabled, correct on Fedora/RHEL)
            PROJECT_MOUNTS+=("--volume" "${ABSPATH}:${ABSPATH}:Z")
            PROJECT_DIRS+=("${ABSPATH}")
            # Start Claude inside the FIRST project so it opens in your code,
            # not the empty /home/coder. Extra -p dirs stay accessible by path.
            [[ -z "${FIRST_PROJECT:-}" ]] && FIRST_PROJECT="${ABSPATH}"
            shift 2 ;;
        --auth)
            want_auth=1
            shift ;;
        --remote-control|--rc)
            want_rc=1
            shift ;;
        --ssh)
            want_ssh=1
            shift ;;
        --9router)
            want_9router=1
            shift ;;
        --9router-port)
            [[ -z "${2:-}" ]] && { echo "Error: --9router-port requires a port" >&2; exit 1; }
            NINEROUTER_PORT="$2"
            shift 2 ;;
        --port)
            SSH_PORT="$2"
            shift 2 ;;
        --name)
            CONTAINER_NAME="$2"
            shift 2 ;;
        --image)
            IMAGE="$2"
            shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# ── Resolve the (exclusive) mode ───────────────────────────────────────────
# --ssh and --rc can't be combined: a container runs ONE command. To reach one
# container both ways, start with --ssh and run `claude remote-control` yourself
# inside the SSH session — it works over SSH (outbound HTTPS, reads the volume
# login, config dir set via sshd SetEnv).
if (( want_ssh && want_rc )); then
    echo "Error: --ssh and --remote-control can't be combined (a container runs one command)." >&2
    echo "  To use both, start with --ssh, then:" >&2
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 coder@localhost" >&2
    echo "    claude remote-control      # run this inside the SSH session" >&2
    exit 1
fi
if (( want_auth + want_rc + want_ssh > 1 )); then
    echo "Error: choose only one of --auth, --remote-control, --ssh." >&2
    exit 1
fi
(( want_auth )) && MODE="auth"
(( want_rc ))   && MODE="remote-control"
(( want_ssh ))  && MODE="ssh"

# --9router is an add-on, not a mode, but it does not compose with every mode.
#
# Remote Control needs a claude.ai identity to pair the session with your
# account, and Claude Code disables it outright when a gateway credential is
# active OR when ANTHROPIC_BASE_URL points somewhere that isn't Anthropic —
# which --9router does both of. The combination would start, then fail to pair.
if (( want_9router && want_rc )); then
    echo "Error: --9router and --remote-control can't be combined." >&2
    echo "  Claude Code disables Remote Control while a gateway credential or a" >&2
    echo "  non-Anthropic ANTHROPIC_BASE_URL is active, which --9router sets." >&2
    echo "  Use --9router on its own, or with --ssh." >&2
    exit 1
fi
# --auth logs in to claude.ai. That login is exactly what a router credential
# replaces, so starting the router here would only slow the login down.
if (( want_9router && want_auth )); then
    echo "ℹ️  --auth logs in to claude.ai; skipping 9router for this run." >&2
    want_9router=0
fi

# Fail fast on missing prerequisites before touching the auth dir.
if [[ "${MODE}" == "ssh" && -z "${SSH_PUBLIC_KEY:-}" ]]; then
    echo "Error: --ssh needs SSH_PUBLIC_KEY set (your ~/.ssh/id_ed25519.pub contents)." >&2
    echo "  Add it to .env, then: set -a && source .env && set +a" >&2
    exit 1
fi

# ── Seed the persistent auth dir (host-side; no container entrypoint) ──────
# A real host directory (not a named volume) so the location never depends on
# podman's storage root — see CLAUDE_AUTH_DIR note above. We seed it from the
# host because this dir is bind-mounted over /home/coder/.claude and would
# otherwise shadow anything baked into the image:
#   • settings.json — policy (bypassPermissions, allow list, theme/tui). Always
#     refreshed from config/, so the suppression flags are guaranteed active.
#   • .claude.json  — onboarding + trust state, seeded only if absent so a fresh
#     dir never shows the theme picker or "trust this folder?" dialog. Claude
#     maintains the file afterward (it never clears these flags).
mkdir -p "${CLAUDE_AUTH_DIR}"
[[ -f "${SETTINGS_SRC}" ]] || { echo "Error: missing ${SETTINGS_SRC}" >&2; exit 1; }
cp "${SETTINGS_SRC}" "${CLAUDE_AUTH_DIR}/settings.json"
if [[ ! -f "${CLAUDE_AUTH_DIR}/.claude.json" ]]; then
    printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{"/":{"hasTrustDialogAccepted":true}}}' \
        > "${CLAUDE_AUTH_DIR}/.claude.json"
fi

# ── Point Claude Code at 9router (settings.json `env` block) ───────────────
# Claude Code reads `env` from settings.json and applies it to every session, in
# every mode. That is what makes this work over SSH too: sshd drops the
# container's environment (see config/sshd_config), so passing these as podman
# --env would reach `claude` in the default mode and silently not in --ssh.
#
# Written here rather than into config/claude-settings.json because it is
# per-run state: the key comes from your .env, and a run without --9router must
# leave no trace of it behind (settings.json is re-copied from config/ above on
# every run, so dropping the flag really does revert Claude to Anthropic).
#
#   ANTHROPIC_BASE_URL    where to send /v1/messages. 127.0.0.1, not localhost:
#                         localhost can resolve to ::1 first while the router
#                         listens on IPv4.
#   ANTHROPIC_AUTH_TOKEN  sent as `Authorization: Bearer`, which is the header
#                         9router reads. It takes precedence over a saved
#                         claude.ai login immediately and with no prompt —
#                         ANTHROPIC_API_KEY would need interactive approval and
#                         so would hang a headless run.
#   ANTHROPIC_MODEL and the three DEFAULT_* pins: Claude Code otherwise requests
#                         Anthropic's own model ids, which 9router only serves
#                         if you aliased them. All three picker slots point at
#                         the same router model so that switching model in /model
#                         can't land on an unrouted id.
#   ..._HAIKU_MODEL       also moves Claude's cheap background work (session
#                         titles and the like) onto a model the router knows.
#   ..._MODEL_DISCOVERY   asks the router for its model list at start-up and adds
#                         it to /model, so you can see what you actually have.
if (( want_9router )) && [[ -n "${NINEROUTER_API_KEY}" ]]; then
    if command -v python3 >/dev/null 2>&1; then
        NR_BASE_URL="http://127.0.0.1:${NINEROUTER_PORT}" \
        NR_API_KEY="${NINEROUTER_API_KEY}" \
        NR_MODEL="${NINEROUTER_MODEL}" \
        NR_SMALL_MODEL="${NINEROUTER_SMALL_MODEL:-${NINEROUTER_MODEL}}" \
        python3 - "${CLAUDE_AUTH_DIR}/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

env = data.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = os.environ["NR_BASE_URL"]
env["ANTHROPIC_AUTH_TOKEN"] = os.environ["NR_API_KEY"]
env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"

model = os.environ.get("NR_MODEL", "").strip()
small = os.environ.get("NR_SMALL_MODEL", "").strip() or model
if model:
    env["ANTHROPIC_MODEL"] = model
    env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
    env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
if small:
    env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = small

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
        chmod 600 "${CLAUDE_AUTH_DIR}/settings.json"
    else
        echo "⚠️  python3 not found on host — can't point Claude at 9router." >&2
        echo "    Claude will keep using your claude.ai login this run." >&2
    fi
fi

# ── Register the built-in MCP servers (user scope) ─────────────────────────
# Merge into the seeded .claude.json's top-level `mcpServers` (user scope) so
# they load in every project and every mode (local / --rc / manual claude over
# --ssh) with no approval prompt. Idempotent: existing keys are preserved.
#   context7            — up-to-date library docs (stdio, baked in the image)
#   sequential-thinking — reasoning scaffold (stdio, baked in the image)
#   github              — remote endpoint, added ONLY when a PAT is provided
# Optional credentials come from the environment (i.e. your .env):
#   CONTEXT7_API_KEY                higher Context7 rate limits (works without it)
#   GITHUB_PERSONAL_ACCESS_TOKEN    enables the GitHub MCP server (Bearer header)
if command -v python3 >/dev/null 2>&1; then
    CONTEXT7_API_KEY="${CONTEXT7_API_KEY:-}" \
    GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}" \
    python3 - "${CLAUDE_AUTH_DIR}/.claude.json" <<'PY'
import json, os, sys
path = sys.argv[1]
ctx_key = os.environ.get("CONTEXT7_API_KEY", "").strip()
gh_pat  = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN", "").strip()

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}

servers = data.setdefault("mcpServers", {})

ctx_args = ["-y", "@upstash/context7-mcp"]
if ctx_key:
    ctx_args += ["--api-key", ctx_key]
servers["context7"] = {"command": "npx", "args": ctx_args}

servers["sequential-thinking"] = {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"],
}

if gh_pat:
    servers["github"] = {
        "type": "http",
        "url": "https://api.githubcopilot.com/mcp/",
        "headers": {"Authorization": "Bearer " + gh_pat},
    }
else:
    servers.pop("github", None)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
else
    echo "⚠️  python3 not found on host — skipping MCP server setup." >&2
    echo "    Add them yourself inside the container, e.g.:" >&2
    echo "      claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp" >&2
fi

# ── glab: per-project GitLab tokens ───────────────────────────────────────
# The token for a project lives IN that project: <project>/.glab-token, holding
# nothing but the token (gitignore it). For every -p directory that has one we add
# a `hosts:` entry to a glab config.yml — the host taken from that project's
# `origin` remote, so a self-managed instance needs no extra configuration.
#
# The config is never written to the host: it is handed to the container in
# CODINGSEAL_GLAB_CONFIG and materialised there by `codingseal-glab-init` (see the
# Containerfile). A shared host file would make two parallel runs on different
# projects overwrite each other's tokens; this way each container holds only the
# tokens of the projects IT was given, and they vanish with it.
GLAB_CONFIG_YAML=""
GLAB_SUMMARY=()

# The GitLab host from a project's `origin` remote. Three URL shapes occur:
# scp-like (git@host:group/proj.git), ssh:// (where the port is SSH's, not the
# API's, so it must go) and https:// (where a port IS part of the API host).
glab_host_for() {
    local dir="$1" url host
    url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
    case "${url}" in
        ssh://*) host="${url#ssh://}"; host="${host#*@}"; host="${host%%/*}"; host="${host%%:*}" ;;
        *://*)   host="${url#*://}";   host="${host#*@}"; host="${host%%/*}" ;;
        *@*:*)   host="${url#*@}";     host="${host%%:*}" ;;
        *)       host="" ;;
    esac
    # No GitLab remote (or not a repo): fall back to GITLAB_HOST from your .env,
    # then to gitlab.com.
    printf '%s' "${host:-${GITLAB_HOST:-gitlab.com}}"
}

if [[ ${#PROJECT_DIRS[@]} -gt 0 ]]; then
    declare -A GLAB_HOST_SEEN=()
    GLAB_HOSTS_YAML=""
    for dir in "${PROJECT_DIRS[@]}"; do
        TOKEN_FILE="${dir}/${GLAB_TOKEN_FILE}"
        [[ -r "${TOKEN_FILE}" ]] || continue
        # tr drops the trailing newline plus any stray whitespace or CR — a token
        # pasted through a browser or a Windows editor otherwise fails as a 401
        # that looks like a bad token.
        TOKEN="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
        if [[ -z "${TOKEN}" ]]; then
            echo "⚠️  ${TOKEN_FILE} is empty — ignoring it." >&2
            continue
        fi
        GLAB_HOST="$(glab_host_for "${dir}")"
        # config.yml holds ONE token per host, so two projects on the same
        # instance can't both be authenticated — exactly the case per-project
        # scoping is for. First -p wins; the rest are reported, not silently lost.
        if [[ -n "${GLAB_HOST_SEEN[${GLAB_HOST}]:-}" ]]; then
            echo "⚠️  $(basename "${dir}"): ${GLAB_HOST} already has the token from" \
                 "${GLAB_HOST_SEEN[${GLAB_HOST}]} — ignoring this one." >&2
            echo "    glab keeps one token per host; run one project at a time." >&2
            continue
        fi
        GLAB_HOST_SEEN[${GLAB_HOST}]="$(basename "${dir}")"
        # Quoted keys/values: a self-managed instance reachable on a non-default
        # port keeps the port in the host, and an unquoted colon in a YAML key is
        # asking for trouble.
        GLAB_HOSTS_YAML+="  \"${GLAB_HOST}\":
    token: \"${TOKEN}\"
    api_host: \"${GLAB_HOST}\"
    api_protocol: https
"
        GLAB_SUMMARY+=("$(basename "${dir}") → ${GLAB_HOST}")
    done

    if [[ -n "${GLAB_HOSTS_YAML}" ]]; then
        GLAB_CONFIG_YAML="# Written at start-up by codingseal-glab-init, from each project's
# ${GLAB_TOKEN_FILE} file. Edit those, not this — it is rebuilt on every run.
hosts:
${GLAB_HOSTS_YAML}"
    fi
fi

# ── Build base flags ──────────────────────────────────────────────────────
PODMAN_FLAGS=(
    "--name"    "${CONTAINER_NAME}"
    "--rm"
    # Map your host user onto the container's `coder` user (uid/gid 1000) so
    # bind-mounted project files stay owned by you and the seeded config dir is
    # writable. The explicit uid=/gid= is REQUIRED: bare keep-id passes your host
    # uid through unchanged, so on a host where you aren't uid 1000 the container
    # runs as a uid that doesn't exist in the image and can't even traverse
    # /home/coder (mode 750, owned by coder) — login then fails to write
    # .credentials.json, silently, after the OAuth flow reports success.
    # The container runs AS coder — no root, so Claude's bypass-permissions mode
    # runs with no prompt and no IS_SANDBOX trick. Only --ssh adds `--user 0`
    # (below), because sshd needs root to start.
    "--userns=keep-id:uid=1000,gid=1000"
    # Persistent login + seeded config. :Z applies a private SELinux label
    # (no-op on Ubuntu, correct on Fedora/RHEL).
    "--volume"  "${CLAUDE_AUTH_DIR}:/home/coder/.claude:Z"
)

# Append GPU flags (array may be empty)
if [[ ${#GPU_FLAGS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${GPU_FLAGS[@]}")
fi

# Append project mounts (array may be empty)
if [[ ${#PROJECT_MOUNTS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${PROJECT_MOUNTS[@]}")
fi

# Open Claude in the first project directory (falls back to /home/coder if no -p)
if [[ -n "${FIRST_PROJECT:-}" ]]; then
    PODMAN_FLAGS+=("--workdir" "${FIRST_PROJECT}")
fi

# ── Mode-specific flags and command ───────────────────────────────────────
if [[ "${MODE}" == "local" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude")
elif [[ "${MODE}" == "auth" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("claude" "auth" "login")
elif [[ "${MODE}" == "remote-control" ]]; then
    # Remote Control: expose THIS container's environment to claude.ai/code and
    # the Claude mobile app. Outbound HTTPS only — Claude registers with the API
    # and polls for work — so there's NO inbound port and no --publish.
    #
    # Run DETACHED with no TTY: `claude remote-control` is a server ("no local
    # interactive session"), and the start prompts ("really start?" / "same dir?")
    # only appear when it's attached to a TTY. Headless + `--spawn same-dir` makes
    # it start straight away with no prompts. The session URL goes to the logs
    # (podman logs) and the session is listed by --name at claude.ai/code.
    RC_NAME="${CONTAINER_NAME}"
    [[ -n "${FIRST_PROJECT:-}" ]] && RC_NAME="$(basename -- "${FIRST_PROJECT}")"
    PODMAN_FLAGS+=("--detach")
    CMD=("claude" "remote-control" "--spawn" "same-dir" "--name" "${RC_NAME}")
else
    # MODE == "ssh": detached, container stays running; you SSH in (as coder,
    # with your own key) and start claude. sshd needs root, so override keep-id's
    # default user with --user 0 here only — the SSH *login* is still coder. Your
    # public key (validated above) is bind-mounted to authorized_keys; host keys
    # are baked into the image.
    SSH_KEY_FILE="$(dirname -- "${CLAUDE_AUTH_DIR}")/authorized_keys"
    printf '%s\n' "${SSH_PUBLIC_KEY}" > "${SSH_KEY_FILE}"
    chmod 600 "${SSH_KEY_FILE}"
    PODMAN_FLAGS+=(
        "--user"    "0"
        "--detach"
        "--publish" "127.0.0.1:${SSH_PORT}:2222"
        "--volume"  "${SSH_KEY_FILE}:/home/coder/.ssh/authorized_keys:ro,Z"
    )
    CMD=("/usr/sbin/sshd" "-D" "-e")
fi

# ── Hand the glab config to the container (no host file) ───────────────────
# Only when a project actually shipped a token: with nothing to write, the
# container runs its command directly, exactly as before.
if [[ -n "${GLAB_CONFIG_YAML}" ]]; then
    PODMAN_FLAGS+=("--env" "CODINGSEAL_GLAB_CONFIG=${GLAB_CONFIG_YAML}")
    CMD=("codingseal-glab-init" "${CMD[@]}")
fi

# ── Start 9router alongside the container's command ────────────────────────
# Wrapped OUTSIDE codingseal-glab-init (both shims exec "$@", so they chain):
# the router has to be answering before Claude sends its first request, and
# glab's config is only needed once a command actually runs.
#
# The dashboard is published to 127.0.0.1 ONLY. Inside the container 9router
# binds 0.0.0.0 — it has to, since podman's port forwarding connects to the
# container's own address rather than its loopback — so the host-side bind is
# what keeps the router (and the provider credentials in it) off the network.
if (( want_9router )); then
    mkdir -p "${NINEROUTER_DATA_DIR}"
    PODMAN_FLAGS+=(
        "--env"     "CODINGSEAL_9ROUTER=1"
        "--env"     "CODINGSEAL_9ROUTER_PORT=${NINEROUTER_PORT}"
        "--publish" "127.0.0.1:${NINEROUTER_PORT}:${NINEROUTER_PORT}"
        "--volume"  "${NINEROUTER_DATA_DIR}:/home/coder/.9router:Z"
    )
    # Read by 9router on first launch only, to set the dashboard password.
    # codingseal-9router-init unsets it before running the container's command.
    [[ -n "${NINEROUTER_PASSWORD}" ]] && \
        PODMAN_FLAGS+=("--env" "INITIAL_PASSWORD=${NINEROUTER_PASSWORD}")
    CMD=("codingseal-9router-init" "${CMD[@]}")
fi

# ── Print summary ─────────────────────────────────────────────────────────
echo "Starting container '${CONTAINER_NAME}' from image '${IMAGE}'..."
if [[ ${#GLAB_SUMMARY[@]} -gt 0 ]]; then
    echo "  glab: token loaded from ${GLAB_TOKEN_FILE} for ${GLAB_SUMMARY[*]}"
fi
if (( want_9router )); then
    echo "  9router: dashboard on http://localhost:${NINEROUTER_PORT} (state: ${NINEROUTER_DATA_DIR})"
    if [[ -n "${NINEROUTER_API_KEY}" ]]; then
        echo "           Claude routes through it${NINEROUTER_MODEL:+ as ${NINEROUTER_MODEL}}"
        if [[ -z "${NINEROUTER_MODEL}" ]]; then
            echo ""
            echo "  ⚠️  NINEROUTER_MODEL is not set, so Claude will ask 9router for"
            echo "      Anthropic's own model ids (claude-opus-…). That only works if you"
            echo "      aliased them in the dashboard; otherwise set one of 9router's ids:"
            echo "        NINEROUTER_MODEL=kr/claude-sonnet-4.5"
        fi
    else
        # Deliberately not fatal: on the very first run the key cannot exist yet,
        # because you create it in the dashboard this run is about to start.
        echo ""
        echo "  ℹ️  NINEROUTER_API_KEY is not set — starting the router only."
        echo "      Claude keeps using your claude.ai login, so this session still works."
        echo "      To route Claude through 9router:"
        echo "        1. open http://localhost:${NINEROUTER_PORT} and log in"
        echo "           (first login password: ${NINEROUTER_PASSWORD:-123456})"
        echo "        2. connect a provider, then create an API key"
        echo "        3. put it in .env, with a model id from that provider:"
        echo "             NINEROUTER_API_KEY=sk-..."
        echo "             NINEROUTER_MODEL=kr/claude-sonnet-4.5"
        echo "        4. re-run with --9router"
    fi
    echo ""
fi
if [[ "${MODE}" == "auth" ]]; then
    echo ""
    echo "  A URL will appear below. Open it in your browser, complete the login,"
    echo "  then paste the code back into this terminal."
    echo "  Your login will be saved to: ${CLAUDE_AUTH_DIR}"
    echo ""
fi
if [[ "${MODE}" == "remote-control" ]]; then
    echo ""
    echo "  Remote Control — drive this environment from claude.ai/code or the Claude app."
    echo "  The container runs in the BACKGROUND; this terminal returns to you."
    if [[ ! -f "${CLAUDE_AUTH_DIR}/.credentials.json" ]]; then
        echo ""
        echo "  ⚠️  No login found at ${CLAUDE_AUTH_DIR}/.credentials.json."
        echo "     Remote Control needs a full claude.ai login. Run this once first:"
        echo "       scripts/run.sh --auth"
    fi
    echo ""
fi
if [[ "${MODE}" == "ssh" ]]; then
    echo ""
    echo "  SSH into the container (your own key, the coder account):"
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 coder@localhost"
    echo ""
    echo "  Then start Claude:        claude"
    echo "  …or drive it from the web: claude remote-control"
    echo ""
    echo "  Stop the container:"
    echo "    podman stop ${CONTAINER_NAME}"
    echo ""
fi

# ── Run ───────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "auth" ]]; then
    # Don't exec — after login we verify the credential file actually landed in
    # the auth dir, so you get immediate confirmation instead of finding out next
    # session that nothing was saved.
    podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
    echo ""
    # On Linux, Claude has no OS keychain: it stores the login as a plaintext
    # file ".credentials.json" inside CLAUDE_CONFIG_DIR — which is this host dir.
    if [[ -f "${CLAUDE_AUTH_DIR}/.credentials.json" ]]; then
        echo "✅ Login saved to ${CLAUDE_AUTH_DIR}/.credentials.json"
        echo "   Future runs stay logged in — just: scripts/run.sh -p ~/your/project"
    else
        echo "⚠️  No .credentials.json was written to ${CLAUDE_AUTH_DIR}"
        echo "   The login did not complete. Re-run 'scripts/run.sh --auth' and make sure"
        echo "   you paste the code from the browser back into the terminal when prompted."
    fi
    exit 0
fi

if [[ "${MODE}" == "remote-control" ]]; then
    # Detached: podman prints the container ID and returns. Tell the user how to
    # reach the session (the URL is in the logs once Claude connects).
    podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
    echo ""
    echo "✅ '${CONTAINER_NAME}' is running in the background."
    echo "   Session URL / status:  podman logs -f ${CONTAINER_NAME}"
    echo "   …or open claude.ai/code and pick the session named '${RC_NAME}'."
    echo "   Stop it:               podman stop ${CONTAINER_NAME}"
    exit 0
fi

exec podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
