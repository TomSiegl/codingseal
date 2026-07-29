FROM ubuntu:24.04

# Use ARG so DEBIAN_FRONTEND doesn't leak into the running container's environment
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# ── System packages ────────────────────────────────────────────────────────
# util-linux (provides setpriv, used to drop to the coder user) is already in base.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-server \
        tini \
        procps \
    && rm -rf /var/lib/apt/lists/*

# ── LaTeX (self-contained in the image) ────────────────────────────────────
# A complete TeX Live install baked into the image. It is deliberately INDEPENDENT
# of whatever TeX Live the host may or may not have: nothing is bind-mounted, so
# the image works on any host and its LaTeX behaviour is reproducible from this
# file alone.
#
# The cost is real — TeX Live is big — so the package set is selectable. The sizes
# below are RESULTING IMAGE sizes, measured from built images (see LATEX.md):
#
#   LATEX_SCHEME=curated  3.86 GB  DEFAULT, ~17 min to build. All four engines,
#                                  latexmk+biber, the recommended+extra macro/
#                                  font/graphics trees, science/pictures/bibtex,
#                                  German+English hyphenation. Covers ordinary
#                                  documents; tikz/beamer/biblatex/minted all work.
#   LATEX_SCHEME=full      ~8 GB   texlive-full — every package Debian ships,
#                                  every language, plus 2.3 GB of PDF manuals it
#                                  cannot drop. Use when you need guaranteed
#                                  coverage. Also drags in a Qt5+xterm GUI stack.
#                                  NOTE: size/time are ESTIMATES — this is the one
#                                  scheme not built and tested here (see LATEX.md).
#   LATEX_SCHEME=minimal  1.32 GB  ~4 min. pdflatex, lualatex and latex — but NOT
#                                  xelatex, and no biber and no tikz. `.eps`
#                                  includes work. For simple documents.
#   LATEX_SCHEME=none     1.03 GB  Skip LaTeX entirely.
#
# Build a variant with:  podman build --build-arg LATEX_SCHEME=full -t coding-seal:latex-full .
#
# Notes on the package selection:
#   • --no-install-recommends throughout, per the rest of this file. That matters
#     here: it keeps default-jre (a texlive-latex-extra recommendation) out.
#   • ghostscript is NOT optional in practice — graphicx shells out to epstopdf
#     for .eps includes, pdfcrop drives gs, and ps2pdf needs it. It is already a
#     dependency of texlive-full; the smaller schemes name it explicitly.
#   • texlive-font-utils and texlive-extra-utils carry BINARIES that the macro
#     packages do not: epstopdf + repstopdf (the restricted variant graphicx
#     actually shells out to for .eps) live in font-utils, and pdfcrop, texcount,
#     latexpand live in extra-utils. Omitting them leaves every .sty in place
#     while \includegraphics{x.eps} still fails — the styles are not the problem.
#   • fonts-lmodern / fonts-texgyre / fonts-texgyre-math are named explicitly
#     because they, not the texlive-* packages, ship both the OpenType faces and
#     the /etc/fonts snippets that let fontspec resolve "Latin Modern Roman" and
#     "TeX Gyre Pagella" under xelatex/lualatex. `tex-gyre` does NOT depend on
#     them, and --no-install-recommends will not pull them in.
#   • texlive-latex-extra depends on python3, so apt's /usr/bin/python3 gets
#     installed. Harmless: /usr/local/bin precedes /usr/bin in PATH, so the
#     uv-managed interpreter installed below still wins.
#   • Installing texlive-latex-base runs fmtutil-sys, which compiles the .fmt
#     formats into /var/lib/texmf at BUILD time. That is the slow part of the
#     build, and it is exactly what makes the image self-contained at run time.
ARG LATEX_SCHEME=curated
RUN set -eu; \
    # Small but load-bearing for every scheme:
    #   ghostscript      — epstopdf/pdfcrop drive gs; ps2pdf is part of it
    #   fontconfig       — fc-match/fc-list, the only way to debug font lookup
    #   fonts-dejavu-core— ONE real system font, so \setmainfont{DejaVu Sans} and
    #                      other non-texmf font requests resolve. The texlive-*
    #                      packages ship no general-purpose system fonts at all.
    COMMON="ghostscript fontconfig fonts-dejavu-core"; \
    case "${LATEX_SCHEME}" in \
      none) \
        echo "LATEX_SCHEME=none — skipping LaTeX"; \
        exit 0 ;; \
      minimal) \
        PKGS="texlive-latex-base texlive-latex-recommended texlive-fonts-recommended \
              texlive-font-utils latexmk" ;; \
      curated) \
        PKGS="texlive-latex-base texlive-latex-recommended texlive-latex-extra \
              texlive-fonts-recommended texlive-fonts-extra \
              texlive-science texlive-pictures texlive-bibtex-extra texlive-plain-generic \
              texlive-xetex texlive-luatex \
              texlive-font-utils texlive-extra-utils \
              texlive-lang-german texlive-lang-english \
              latexmk biber \
              lmodern fonts-lmodern tex-gyre fonts-texgyre fonts-texgyre-math" ;; \
      full) \
        PKGS="texlive-full" ;; \
      *) \
        echo "Error: unknown LATEX_SCHEME='${LATEX_SCHEME}' (want: none|minimal|curated|full)" >&2; \
        exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ${PKGS} ${COMMON}; \
    rm -rf /var/lib/apt/lists/*

# Fail the build, not the user's first compile, if the scheme is broken. Also
# confirms fmtutil actually produced the formats during the install above.
# (ARG stays in scope for the rest of the stage, so it is not redeclared here.)
# Note the `if`: with `set -e`, a bare `[ x = y ] && { exit 0; }` would abort the
# build whenever the test is FALSE, because the failed && is the last status.
RUN set -eu; \
    if [ "${LATEX_SCHEME}" = "none" ]; then echo "LaTeX skipped — no smoke test"; exit 0; fi; \
    printf '%s\n' \
        '\documentclass{article}' \
        '\usepackage{amsmath}' \
        '\begin{document}' \
        'Smoke test: $e^{i\pi}+1=0$' \
        '\end{document}' > /tmp/smoke.tex; \
    cd /tmp; \
    pdflatex -interaction=nonstopmode -halt-on-error smoke.tex >/tmp/smoke.log 2>&1 \
        || { echo "=== pdflatex smoke test FAILED ==="; tail -25 /tmp/smoke.log; exit 1; }; \
    [ -s /tmp/smoke.pdf ] || { echo "smoke test produced no PDF"; exit 1; }; \
    echo "LaTeX smoke test OK (scheme=${LATEX_SCHEME}): $(pdflatex --version | head -1)"; \
    rm -f /tmp/smoke.*

# ── Non-root user ──────────────────────────────────────────────────────────
# Claude Code's bypass-permissions mode refuses to run as root. Running as a
# normal user is the canonical fix: the guard (getuid()===0) never fires.
# uid/gid 1000 matches a typical host user; combined with `--userns=keep-id`
# in run.sh it keeps bind-mounted project files owned by you and writable.
# (ubuntu:24.04 ships a default `ubuntu` user at uid/gid 1000 — remove it first.)
# `-p '*'` leaves the account password-less but UNLOCKED: useradd's default `!`
# marks it locked, and with `UsePAM no` sshd refuses key login to locked accounts.
# Password login stays impossible (PasswordAuthentication no in sshd_config).
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g 1000 coder && \
    useradd -m -u 1000 -g 1000 -s /bin/bash -p '*' coder

# ── Node.js LTS (via NodeSource) ──────────────────────────────────────────
# ubuntu:24.04 ships Node 18; NodeSource gives Node 22 (current LTS).
# Claude Code requires Node >= 18.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI (global, world-readable — usable by any user) ──────────
RUN npm install -g @anthropic-ai/claude-code

# ── Baked-in MCP servers (stdio) ───────────────────────────────────────────
# Installed globally so `npx -y <pkg>` resolves them offline/instantly at
# runtime. run.sh registers these as user-scope MCP servers in ~/.claude.json:
#   @upstash/context7-mcp                          → up-to-date library docs (Context7)
#   @modelcontextprotocol/server-sequential-thinking → step-by-step reasoning scaffold
# (The GitHub MCP server is remote — https://api.githubcopilot.com/mcp/ — so it
# needs nothing baked here; run.sh adds it only when a PAT is provided.)
RUN npm install -g @upstash/context7-mcp @modelcontextprotocol/server-sequential-thinking

# ── uv + Python in SHARED locations (reachable by the non-root user) ───────
# The default installer drops uv under /root (mode 700); coder couldn't read it.
# Install uv into /usr/local/bin and the managed Python into /opt/uv/python,
# both world-readable, so coder uses the same toolchain.
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ARG PYTHON_VERSION=3.12
RUN uv python install ${PYTHON_VERSION} && \
    UV_PYTHON=$(uv python find ${PYTHON_VERSION}) && \
    ln -sf "${UV_PYTHON}" /usr/local/bin/python3 && \
    ln -sf /usr/local/bin/python3 /usr/local/bin/python && \
    chmod -R a+rX /opt/uv

# ── SSH server setup ───────────────────────────────────────────────────────
# Bake the host keys at build time — stable across container starts, so no
# "host key changed" warnings — and pre-create coder's .ssh dir (mode 700). In
# --ssh mode, run.sh bind-mounts your public key to authorized_keys inside it.
RUN mkdir -p /run/sshd && chmod 0755 /run/sshd && \
    ssh-keygen -A && \
    install -d -m 700 -o coder -g coder /home/coder/.ssh

# ── Claude Code config ─────────────────────────────────────────────────────
# CLAUDE_CONFIG_DIR makes Claude store ALL of its state — settings.json,
# .claude.json (onboarding/trust/projects), credentials, and sessions — in this
# single directory. run.sh bind-mounts the host folder ~/.codingseal/claude-auth
# here at runtime AND seeds settings.json + .claude.json into it, so every run is
# wizard-free and stays logged in. Nothing config-related is baked into the image
# (the bind-mount would shadow it anyway) — run.sh is the single source of truth.
ENV HOME=/home/coder \
    CLAUDE_CONFIG_DIR=/home/coder/.claude
RUN install -d -o coder -g coder /home/coder/.claude

# ── Copy runtime files ─────────────────────────────────────────────────────
COPY config/sshd_config       /etc/ssh/sshd_config
RUN chown -R coder:coder /home/coder

# ── Workspace ──────────────────────────────────────────────────────────────
WORKDIR /home/coder

EXPOSE 2222

# tini as PID 1 (reaps zombies; runs sshd as root in --ssh mode). run.sh supplies
# the per-mode command (claude / claude remote-control / sshd) and the user: the
# default is `coder` (uid 1000) via --userns=keep-id, and --ssh overrides with
# --user 0 so sshd can start (the SSH *login* is still the coder user).
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["claude"]
