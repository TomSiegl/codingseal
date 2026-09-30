FROM ubuntu:24.04

# Use ARG so DEBIAN_FRONTEND doesn't leak into the running container's environment
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# ── System packages ────────────────────────────────────────────────────────
# util-linux (provides setpriv, used to drop to the coder user) is already in base.
# build-essential brings gcc, g++, make and libc6-dev — a C/C++ toolchain for
# native Node/Python addons and for compiling code directly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-server \
        tini \
        procps \
        tmux \
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

# ── System fonts + pandoc ──────────────────────────────────────────────────
# Deliberately placed AFTER the LaTeX layers: editing this section never
# invalidates the (slow) TeX Live install above.
#
# WHY THIS IS SEPARATE FROM texlive-fonts-*: the texlive-* packages ship fonts
# into the texmf tree for pdflatex's NFSS names (\usepackage{helvet}). They
# install almost nothing that fontconfig can see, so under xelatex/lualatex
# every `\setmainfont{<a normal font name>}` fails. fontspec looks fonts up by
# FAMILY NAME via fontconfig, and — importantly — it does NOT honour
# fontconfig's metric-substitution aliases: with only fonts-liberation present,
# `fc-match Arial` happily answers "Liberation Sans" while
# `\setmainfont{Arial}` still dies with "The font "Arial" cannot be found".
# Metric-compatible clones are therefore not a substitute for the real families;
# a font is usable from fontspec only if its own name is installed.
#
#   ttf-mscorefonts-installer  the actual Microsoft core fonts — Arial, Times
#                              New Roman, Courier New, Georgia, Verdana,
#                              Trebuchet MS, Comic Sans MS, Impact, Andale Mono,
#                              Webdings. 5.5 MB of fonts. This is what makes
#                              \setmainfont{Arial} work.
#   fonts-liberation{,2}       Arial/Times/Courier metric clones. Worth having
#                              even with the real fonts present: they are what
#                              fontconfig substitutes for an Arial request that
#                              never reaches fontspec (pandoc's HTML/docx output,
#                              pdflatex), and they are the fallback the smoke
#                              test uses when MSCOREFONTS=false.
#   fonts-crosextra-carlito    Calibri metric clone (name: "Carlito")
#   fonts-crosextra-caladea    Cambria metric clone (name: "Caladea")
#   fonts-dejavu{,-extra}      supersedes the fonts-dejavu-core above
#   fonts-freefont-ttf         URW Free{Serif,Sans,Mono}, wide coverage
#   fonts-noto-core            Greek/Cyrillic/Hebrew/Arabic/… so xelatex can set
#                              non-Latin scripts at all (no CJK — that is 200 MB+)
#   fontconfig, lmodern        not fonts as such; see the notes at the RUN below
#   pandoc                     3.1.3 from Ubuntu. ~250 MB, most of it the static
#                              Haskell binary. It has no PDF machinery of its own
#                              and drives the LaTeX above: under curated/full all
#                              of --pdf-engine=pdflatex|xelatex|lualatex work,
#                              under minimal only pdflatex (see the lmodern note),
#                              and under none every conversion works except PDF.
#
# Two caveats on ttf-mscorefonts-installer, both unavoidable:
#   • It is the only step in this file needing a EULA accepted, preseeded via
#     debconf-set-selections below, and its postinst fetches the fonts from
#     SourceForge one file at a time — slow, and the least reliable network
#     dependency in the build (~2 min of the total).
#   • It hard-Depends on update-notifier-common (that is the download mechanism
#     it uses), which drags in python3-apt and ubuntu-pro-client: ~35 MB of
#     machinery that is useless in a container. --no-install-recommends does not
#     help, these are Depends. Purging them afterwards would delete the fonts.
# Set --build-arg MSCOREFONTS=false to drop all of it; everything else here still
# installs, and Arial then resolves only through fontconfig substitution (usable
# from pdflatex/`fc-match`, NOT from \setmainfont).
ARG MSCOREFONTS=true
RUN set -eu; \
    # fontconfig is named here as well as in the LaTeX block's COMMON: with
    # LATEX_SCHEME=none that block exits before installing anything, so relying
    # on it would leave this layer calling a non-existent fc-cache. apt makes the
    # duplicate a no-op in every other scheme.
    FONTS="fontconfig \
           fonts-liberation fonts-liberation2 \
           fonts-crosextra-carlito fonts-crosextra-caladea \
           fonts-dejavu fonts-dejavu-extra fonts-freefont-ttf fonts-noto-core"; \
    # pandoc's default LaTeX template does \usepackage{lmodern}, which the
    # `minimal` scheme does not ship — so `pandoc -o x.pdf` failed there with
    # "File `lmodern.sty' not found" while every other pandoc output worked.
    # Adding it HERE rather than to the minimal PKGS list is deliberate: it keeps
    # the slow LaTeX layers untouched. `curated` already has it, so apt no-ops.
    # Skipped for `none`, which has no TeX at all and should stay that way.
    if [ "${LATEX_SCHEME}" != "none" ]; then FONTS="${FONTS} lmodern"; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ${FONTS} pandoc; \
    if [ "${MSCOREFONTS}" = "true" ]; then \
        echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
            | debconf-set-selections; \
        apt-get install -y --no-install-recommends ttf-mscorefonts-installer; \
    else \
        echo "MSCOREFONTS=false — skipping the Microsoft core fonts"; \
    fi; \
    rm -rf /var/lib/apt/lists/* /var/lib/update-notifier/package-data-downloads/partial; \
    # Bake the system-wide fontconfig cache into the image so the first xelatex
    # run as `coder` doesn't have to build one.
    fc-cache -fs

# Same reasoning as the LaTeX smoke test: prove the font lookup and pandoc work
# now, in the build, rather than in the user's first document.
RUN set -eu; \
    if [ "${MSCOREFONTS}" = "true" ]; then \
        fc-match Arial | grep -q '"Arial"' \
            || { echo "Arial is not installed as a family: $(fc-match Arial)"; exit 1; }; \
    fi; \
    echo "pandoc OK: $(pandoc --version | head -1)"; \
    if [ "${LATEX_SCHEME}" = "none" ]; then \
        echo "scheme=none has no TeX — skipping the fontspec and PDF tests"; \
        exit 0; \
    fi; \
    cd /tmp; \
    # The fontspec test needs xelatex, which `minimal` does not ship. The
    # pandoc->PDF test only needs pdflatex, so it runs in every scheme but `none`.
    if [ "${LATEX_SCHEME}" = "minimal" ]; then \
        echo "scheme=minimal has no xelatex — skipping the fontspec test only"; \
    else \
        if [ "${MSCOREFONTS}" = "true" ]; then \
            MAIN="Arial"; ALT="Times New Roman"; \
        else \
            MAIN="Liberation Sans"; ALT="Liberation Serif"; \
        fi; \
        # fontspec errors out (it does not silently substitute) when a family is
        # missing, so -halt-on-error here really does test the lookup.
        # printf, not echo: /bin/sh is dash, whose echo turns \b and \a into
        # control characters — \begin and \alt would be mangled.
        printf '%s\n' \
            '\documentclass{article}' \
            '\usepackage{fontspec}' \
            "\\setmainfont{${MAIN}}" \
            "\\newfontfamily\\alt{${ALT}}" \
            '\newfontfamily\clone{Carlito}' \
            '\begin{document}' \
            'Sans. {\alt Serif.} {\clone Clone.}' \
            '\end{document}' > fonts.tex; \
        xelatex -interaction=nonstopmode -halt-on-error fonts.tex >/tmp/fonts.log 2>&1 \
            || { echo "=== xelatex/fontspec smoke test FAILED ==="; tail -30 /tmp/fonts.log; exit 1; }; \
        [ -s /tmp/fonts.pdf ] || { echo "fontspec test produced no PDF"; exit 1; }; \
        echo "xelatex/fontspec smoke test OK (mscorefonts=${MSCOREFONTS})"; \
    fi; \
    printf '%s\n' '# Pandoc' '' 'Math $e^{i\pi}+1=0$.' > pandoc.md; \
    pandoc pandoc.md -o pandoc.pdf --pdf-engine=pdflatex >/tmp/pandoc.log 2>&1 \
        || { echo "=== pandoc -> PDF FAILED ==="; cat /tmp/pandoc.log; exit 1; }; \
    [ -s /tmp/pandoc.pdf ] || { echo "pandoc produced no PDF"; exit 1; }; \
    echo "pandoc -> PDF smoke test OK (scheme=${LATEX_SCHEME})"; \
    rm -f /tmp/fonts.* /tmp/pandoc.*

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

# ── Playwright MCP (headless browser for Claude's debug loop) ─────────────
# Lets Claude drive an actual browser from inside the container: navigate to a
# page it's serving (e.g. a local dev server), read the DOM/console, click
# through a flow, take a screenshot — all via MCP tool calls, registered by
# run.sh like the servers above. No display is needed: Chromium's own headless
# mode renders without Xvfb/X11, which is what makes this work on a headless host
# (run.sh passes --headless when it registers the server).
#
# PLAYWRIGHT_BROWSERS_PATH, like UV_PYTHON_INSTALL_DIR above, moves the browser
# out of the default (root-only, mode 700) cache dir into one `coder` can read.
# `install-deps` apt-installs Chromium's system libraries (fonts, graphics
# stack) — there is no way to skip this; the browser will not render without
# them. Both the "chromium" and "chromium-headless-shell" builds are installed
# (no `--no-shell`): launching with `headless: true` resolves to the SEPARATE
# headless-shell binary, not full Chromium run with a flag — confirmed by
# testing `--no-shell` here first, which reliably fails with "Executable
# doesn't exist at .../chromium_headless_shell-.../chrome-headless-shell".
#
# The installer is invoked as `node .../playwright-core/cli.js`, NOT as
# `npx playwright-core` (Microsoft's own docs show the latter for their
# Playwright MCP Docker image, but that resolves and downloads a SEPARATE,
# unpinned playwright-core from the registry — its "latest" browser revision
# does not necessarily match the revision @playwright/mcp's own nested
# playwright-core dependency expects, and a mismatch is a hard failure at
# runtime ("Executable doesn't exist"), also confirmed by testing here first.
# Running the exact playwright-core that @playwright/mcp already depends on
# guarantees the installed browser revision is the one it will actually ask for.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npm install -g @playwright/mcp \
    && PW_CORE="$(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js" \
    && node "${PW_CORE}" install-deps chromium \
    && node "${PW_CORE}" install chromium \
    && rm -rf /var/lib/apt/lists/* \
    && chmod -R a+rX /opt/playwright-browsers

# ── uv + Python in SHARED locations (reachable by the non-root user) ───────
# The default installer drops uv under /root (mode 700); coder couldn't read it.
# Install uv into /usr/local/bin and the managed Python into /opt/uv/python,
# both world-readable, so coder uses the same toolchain.
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ARG PYTHON_VERSION=3.13
RUN uv python install ${PYTHON_VERSION} && \
    UV_PYTHON=$(uv python find ${PYTHON_VERSION}) && \
    ln -sf "${UV_PYTHON}" /usr/local/bin/python3 && \
    ln -sf /usr/local/bin/python3 /usr/local/bin/python && \
    chmod -R a+rX /opt/uv

# ── GitLab CLI (glab) ──────────────────────────────────────────────────────
# Not in Ubuntu 24.04's archive, so take GitLab's own .deb from that release's
# generic package registry: arch-aware, version-pinned, and checksum-verified
# against the checksums.txt published with the same release. `dpkg -i`, not apt:
# the package has no dependencies, so no apt lists are needed.
#
# No token is baked in. glab reads its tokens from ~/.config/glab-cli/config.yml,
# and run.sh bind-mounts a host directory there, generated from the `.glab-token`
# file found in the project you pass with -p. Because that is glab's DEFAULT
# config location, it works in every mode — including SSH sessions, which never
# see the container's environment (sshd drops it; see config/sshd_config).
ARG GLAB_VERSION=1.120.0
RUN set -eu; \
    ARCH="$(dpkg --print-architecture)"; \
    case "${ARCH}" in \
      amd64|arm64) ;; \
      *) echo "Error: no glab .deb for architecture '${ARCH}'" >&2; exit 1 ;; \
    esac; \
    BASE="https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/packages/generic/glab/${GLAB_VERSION}"; \
    DEB="glab_${GLAB_VERSION}_linux_${ARCH}.deb"; \
    cd /tmp; \
    curl -fsSL -o "${DEB}" "${BASE}/${DEB}"; \
    curl -fsSL -o checksums.txt "${BASE}/checksums.txt"; \
    grep " ${DEB}\$" checksums.txt | sha256sum -c -; \
    dpkg -i "./${DEB}"; \
    rm -f "${DEB}" checksums.txt; \
    echo "glab OK: $(glab --version)"

# Pre-created and owned by coder: in --ssh mode the container starts as root, and
# a root-owned /home/coder/.config would break every other tool that writes there.
RUN install -d -o coder -g coder -m 700 /home/coder/.config /home/coder/.config/glab-cli

# The glab config is materialised at start-up, in the container, by this shim:
# run.sh prepends it to whatever command the container runs. Deliberately NOT a
# host file — two parallel runs on different projects would overwrite each other's
# tokens — and deliberately a file rather than a GITLAB_TOKEN in the environment,
# because SSH sessions get none of the container's environment (sshd drops it).
RUN printf '%s\n' \
    '#!/bin/sh' \
    '# codingseal-glab-init — write glab'"'"'s config, then exec the real command.' \
    '# $CODINGSEAL_GLAB_CONFIG is built by run.sh from the .glab-token file in each' \
    '# project passed with -p. It lives only in this container, and dies with it.' \
    'set -eu' \
    'if [ -n "${CODINGSEAL_GLAB_CONFIG:-}" ]; then' \
    '    umask 077' \
    '    mkdir -p /home/coder/.config/glab-cli' \
    '    printf "%s" "${CODINGSEAL_GLAB_CONFIG}" > /home/coder/.config/glab-cli/config.yml' \
    '    # --ssh starts as root (sshd needs it); every other mode is already coder.' \
    '    if [ "$(id -u)" = 0 ]; then chown -R coder:coder /home/coder/.config/glab-cli; fi' \
    '    unset CODINGSEAL_GLAB_CONFIG   # keep the token out of the command'"'"'s environment' \
    'fi' \
    'exec "$@"' \
    > /usr/local/bin/codingseal-glab-init \
    && chmod 0755 /usr/local/bin/codingseal-glab-init

# ── lazygit (git TUI) ──────────────────────────────────────────────────────
# Ubuntu 24.04 ships no lazygit package (`apt-cache policy lazygit` is empty), so
# take the upstream release tarball: a single static Go binary, arch-aware,
# version-pinned, and checksum-verified against the checksums.txt published with
# the same release — same approach as glab above.
#
# It needs nothing else: `git` is already installed, and lazygit reads the repo
# in the mounted project plus your normal git config. Pushing over SSH uses the
# forwarded agent like any other git command.
ARG LAZYGIT_VERSION=0.65.1
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) LG_ARCH="x86_64" ;; \
      arm64) LG_ARCH="arm64" ;; \
      *) echo "Error: no lazygit build for architecture '$(dpkg --print-architecture)'" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}"; \
    TGZ="lazygit_${LAZYGIT_VERSION}_linux_${LG_ARCH}.tar.gz"; \
    cd /tmp; \
    curl -fsSL -o "${TGZ}" "${BASE}/${TGZ}"; \
    curl -fsSL -o checksums.txt "${BASE}/checksums.txt"; \
    grep " ${TGZ}\$" checksums.txt | sha256sum -c -; \
    # The tarball also carries LICENSE/README.md; only the binary is wanted.
    tar -xzf "${TGZ}" lazygit; \
    install -m 0755 lazygit /usr/local/bin/lazygit; \
    rm -f "${TGZ}" checksums.txt lazygit; \
    echo "lazygit OK: $(lazygit --version)"

# ── SSH server setup ───────────────────────────────────────────────────────
# Bake the host keys at build time — stable across container starts, so no
# "host key changed" warnings — and pre-create coder's .ssh dir (mode 700). In
# --ssh mode, run.sh bind-mounts your public key to authorized_keys inside it.
RUN mkdir -p /run/sshd && chmod 0755 /run/sshd && \
    ssh-keygen -A && \
    install -d -m 700 -o coder -g coder /home/coder/.ssh

# ── Forwarded SSH agent auto-detection (coder's .bashrc) ───────────────────
# With `ssh -A` into the container, sshd creates a FRESH /tmp/ssh-*/agent.*
# socket per connection and exports SSH_AUTH_SOCK for that session only. Two
# cases leave the variable useless: a `podman exec` shell inherits nothing, and
# a reconnect can leave an inherited/stale value pointing at a closed session's
# socket. Both make git push over SSH fail with "Permission denied (publickey)".
# So: if the current agent doesn't answer, probe the existing sockets
# newest-first and adopt the first live one.
RUN printf '%s\n' \
    '' \
    '# Pick up a forwarded SSH agent socket if the current one is missing or stale.' \
    '# sshd creates a fresh /tmp/ssh-*/agent.* socket per connection when' \
    '# ForwardAgent/-A is used, so reconnects can leave SSH_AUTH_SOCK pointing' \
    '# at a socket from a closed session.' \
    'if ! ssh-add -l >/dev/null 2>&1; then' \
    '    for sock in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null); do' \
    '        if SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1; then' \
    '            export SSH_AUTH_SOCK="$sock"' \
    '            break' \
    '        fi' \
    '    done' \
    'fi' \
    >> /home/coder/.bashrc

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
