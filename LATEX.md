# LaTeX in the Image

TeX Live is installed **into the image**, fully independent of the host. Nothing is
bind-mounted: the container carries its own engines, macro packages, fonts and
precompiled formats, so LaTeX behaves identically on any host — including one with no
TeX Live at all — and is reproducible from the `Containerfile` alone.

The price is image size. TeX Live is genuinely large, so the package set is selectable
via a build argument.

---

## 1. Schemes

```bash
podman build -t coding-seal:latest .                                  # curated (default)
podman build --build-arg LATEX_SCHEME=full    -t coding-seal:latex-full .
podman build --build-arg LATEX_SCHEME=minimal -t coding-seal:latex-min .
podman build --build-arg LATEX_SCHEME=none    -t coding-seal:nolatex .
```

| `LATEX_SCHEME` | Image | Build | Engines | Use when |
|---|---|---|---|---|
| `curated` **(default)** | **3.86 GB** | ~17 min | pdflatex, xelatex, lualatex, latex | Ordinary documents: papers, reports, theses |
| `full` | ~8 GB ᵉ | ~30 min ᵉ | all of the above | You want every package Debian ships and can't predict what a document needs |
| `minimal` | **1.32 GB** | ~4 min | pdflatex, lualatex, latex (**no xelatex**) | Simple documents; no tikz, no bibliography tooling |
| `none` | **1.03 GB** | ~1 min | — | You don't want LaTeX in the image |

Bold sizes are measured from built images; the LaTeX-free base is 1.03 GB. Build times are
end-to-end on a warm apt cache and are dominated by download plus format generation.

ᵉ `full` figures are **estimates extrapolated from the package archive, not measured** —
it is the one scheme that has not been built here. It resolves to plain `texlive-full`
plus the three common packages, so the risk is low, but treat its numbers as approximate
until you build it yourself.

### What `curated` contains

```
texlive-latex-base texlive-latex-recommended texlive-latex-extra
texlive-fonts-recommended texlive-fonts-extra
texlive-science texlive-pictures texlive-bibtex-extra texlive-plain-generic
texlive-xetex texlive-luatex
texlive-font-utils texlive-extra-utils
texlive-lang-german texlive-lang-english
latexmk biber
lmodern fonts-lmodern tex-gyre fonts-texgyre fonts-texgyre-math
+ ghostscript fontconfig fonts-dejavu-core   (added to every scheme except `none`)
```

That is all four engines, `latexmk`, `biber`, `bibtex`, `makeindex`, EPS handling via
`epstopdf`/`repstopdf`, `pdfcrop`, `texcount`, the `dvips`→`ps2pdf` route, and the usual
macro territory.

Macro coverage is broad. Every one of these resolved in the built image:
`article` `beamer` `scrartcl` `memoir` `standalone` · `hyperref` `geometry` `xcolor`
`graphicx` `caption` `subcaption` · `tikz` `pgfplots` `tcolorbox` · `listings` `minted` ·
`biblatex` `csquotes` `natbib` · `siunitx` `algorithm2e` `algorithmicx` `cleveref` ·
`glossaries` `todonotes` `enumitem` `titlesec` `fancyhdr` `setspace` `multirow` `wrapfig` ·
`amsmath` `microtype` `booktabs` · `fontspec` `unicode-math` `babel` `polyglossia`.

### What `curated` deliberately leaves out

| Omitted | Size | Consequence |
|---|---|---|
| All `texlive-*-doc` packages | 2.3 GB | No offline PDF manuals. `texdoc` won't find local docs; the packages themselves work fine |
| Most `texlive-lang-*` trees | 1.1 GB | Hyphenation for German and English only. Add e.g. `texlive-lang-french` if needed |
| `context` | 157 MB | ConTeXt documents won't build (this is not LaTeX) |
| `texlive-humanities`, `-music`, `-games`, `-pstricks`, `-publishers`, `-formats-extra` | ~250 MB | Specialist classes absent — some journal classes live in `-publishers` |
| `asymptote`, `chktex`, `dvipng`, `latexdiff`, `psutils`, `xindy` | small | Auxiliary tools, not needed to compile. Add any of them to the scheme list if you use them |

Only general-purpose system font is DejaVu. The `texlive-*` packages ship **no**
general-purpose system fonts, so a bare install cannot resolve
`\setmainfont{DejaVu Sans}` — or anything else outside the texmf tree — under
xelatex/lualatex. `fonts-dejavu-core` is installed to give fontspec one font that
always works; add more `fonts-*` packages if your documents name specific families.
(Microsoft's Arial/Times etc. need `ttf-mscorefonts-installer`, which is in `multiverse`,
prompts for a EULA via debconf, and downloads from SourceForge at build time.)

`full` includes all of the above. Note it also drags in a **Qt5 + xterm** GUI stack
(via `vprerex`), which is dead weight in a headless container but unavoidable given
`texlive-full`'s dependencies.

### What `minimal` actually gives you

Verified on the built image, because the boundaries are not the obvious ones:

| Works | Absent |
|---|---|
| `pdflatex`, `latex`, **`lualatex`** | **`xelatex`** |
| `latexmk`, `makeindex`, `bibtex` | `biber`, `biblatex.sty` |
| `dvips` → `ps2pdf`, `.eps` includes via `epstopdf` | `pdfcrop`, `texcount` |
| `amsmath`, `fontspec.sty` (usable under lualatex only) | `tikz`, `pgfplots` |

So `minimal` is not "pdflatex only" — `lualatex` comes along because the engine binaries
live in `texlive-binaries` and a `lualatex` format is generated. But there is no `xelatex`
and no `biber`, so biblatex workflows and XeTeX documents need `curated`.

### Adding a single package

Cheaper than jumping to `full`: add it to the `curated` list in the `Containerfile` and
rebuild. Only the LaTeX layer and those after it are redone.

```dockerfile
      curated) \
        PKGS="… texlive-publishers texlive-lang-french" ;; \
```

Find which package owns a missing file with `apt-file search foo.sty` on a host, or
search <https://packages.ubuntu.com>.

---

## 2. Why the package list looks the way it does

Five things in it are non-obvious and each was chosen for a reason. Three of them were
found by testing a built image, not by reading package descriptions.

1. **`ghostscript` is not optional.** `graphicx` shells out to `epstopdf` (really
   `repstopdf`, the restricted variant) to convert `.eps` includes under pdflatex;
   `pdfcrop` drives `gs`; `ps2pdf` is part of it. Leave it out and `\includegraphics`
   of an EPS fails with `…-eps-converted-to.pdf not found`. It is already a dependency
   of `texlive-full`, so only the smaller schemes name it.

2. **`texlive-font-utils` and `texlive-extra-utils` carry binaries no macro package
   ships.** `epstopdf` *and* `repstopdf` come from font-utils; `pdfcrop`, `texcount` and
   `latexpand` from extra-utils. This is an easy gap to miss because it does not look
   like a missing package: every `.sty` is present and `kpsewhich epstopdf.sty` succeeds,
   yet EPS includes still fail and `pdfcrop` is simply not found. Style files and
   executables are shipped by different packages.

3. **`fonts-lmodern` / `fonts-texgyre` / `fonts-texgyre-math` are named explicitly.**
   These, not the `texlive-*` packages, ship both the OpenType faces and the
   `/etc/fonts/conf.d` snippets that register them with fontconfig. Without them
   `\setmainfont{TeX Gyre Pagella}` fails under xelatex/lualatex even though the Type 1
   versions are present. `tex-gyre` does **not** depend on them, and
   `--no-install-recommends` will not pull them in.

   `fonts-dejavu-core` is there for the complementary reason: TeX Live ships no
   general-purpose system fonts, so without it fontspec cannot resolve any family
   outside the texmf tree.

4. **`--no-install-recommends` is load-bearing.** `texlive-latex-extra` *recommends*
   `default-jre`; without the flag every image would carry a JRE.

5. **The doc packages cannot be dropped from `full`.** They are hard `Depends:` of
   `texlive-full`, not `Recommends:`, so `--no-install-recommends` does not exclude
   them. Avoiding the 2.3 GB of manuals is precisely why `curated` names sub-packages
   instead.

### Build-time behaviour

- **This is a slow build.** `curated` takes roughly **17 minutes** end to end on a warm
  apt cache — about 1.2 GB of downloads plus format generation. `full` is worse (~3.9 GB
  of downloads). Budget for it, and expect the same again whenever you change
  `LATEX_SCHEME` or the package list, since that invalidates the layer.
- The LaTeX block sits **early** in the `Containerfile`, before the Node/uv/Claude layers,
  so editing those does not invalidate a multi-GB layer. The reverse is not true: changing
  the scheme rebuilds everything after it (a few extra minutes of npm/uv work).
- An **invalid `LATEX_SCHEME` fails the build immediately** with
  `unknown LATEX_SCHEME='…' (want: none|minimal|curated|full)`, rather than silently
  producing an image with no LaTeX.
- Installing `texlive-latex-base` runs `fmtutil-sys`, which **compiles the `.fmt`
  formats into `/var/lib/texmf` during the build**. This is a large part of that time,
  and it is what makes the image self-contained: no format generation on first compile.
- A **smoke test runs at build time** — a one-page `pdflatex` document must compile, or
  the build fails. A broken scheme is caught by the build, not by your first document.
- `texlive-latex-extra` depends on `python3`, so apt's `/usr/bin/python3` is installed
  alongside the uv-managed interpreter. Harmless: `/usr/local/bin` precedes `/usr/bin`
  in `PATH`, so `python3` still resolves to uv's.

---

## 3. Verification

```sh
podman run --rm --entrypoint /bin/bash coding-seal:latest -lc '
  pdflatex --version | head -1
  for b in pdflatex xelatex lualatex latexmk biber bibtex makeindex gs repstopdf pdfcrop; do
    command -v "$b" >/dev/null || echo "MISSING: $b"
  done
  kpsewhich tikz.sty biblatex.sty'
```

The image is self-contained, so this needs **no mounts and no host TeX Live**.

### What was tested

`curated` passes twelve checks with no mounts beyond the project directory: `pdflatex`,
`lualatex`, `xelatex`+`fontspec` (both a texmf font and a system font), `latexmk`,
`biber`/biblatex, `latex`→`dvips`, `ps2pdf`, `.eps` include via `repstopdf`+`gs`,
`pdfcrop`, `makeindex`, `tikz`/`booktabs`, and `kpsewhich pgfplots`. `minimal` passes the
seven that apply to it. `none` has no `pdflatex` and an otherwise intact base image. An
invalid scheme fails the build. In every scheme `claude`, `node`, `uv` and the
uv-managed `python3` still work — apt's `python3` does not shadow it.

**`full` has not been built or tested here.** It is offered as a supported option and is
the lowest-risk scheme by construction (`texlive-full` is a single Debian metapackage),
but it carries no test evidence, unlike the other three.

---

## 4. Trade-offs, and the alternative

This approach buys **independence and reproducibility** with **image size and build
time**.

| | **In-image install** (this branch) | **Host bind-mount** (`latex-host-mount` branch) |
|---|---|---|
| Works on a host without TeX Live | **Yes** | No — requires it on the host |
| Requires host/container OS versions to match | **No** | Yes (both must be Ubuntu 24.04 noble) |
| Image size (from a 1.03 GB base) | 3.81 GB `curated` | **1.35 GB** |
| Build time | ~17 min `curated` | **~45 s** for the TeX layer |
| Reproducible from the repo alone | **Yes** | No — depends on the host's TeX Live |
| Package coverage | Fixed at build time; adding one means a rebuild | The host's, instantly; `apt install` on the host is enough |
| Can modify the host TeX install | No host TeX involved | No — all mounts are `:ro` |
| Extra machinery needed | None | A generated symlink manifest + a fontconfig snippet |

The other branch installs only the engines in the image (~320 MB) and bind-mounts the
host's TeX Live data read-only, reusing the host's prebuilt `.fmt` files so `fmtutil`
never runs. See `LATEX-HOST.md` there for that analysis.

**Pick this branch** when the container must stand alone, when you can't guarantee what
is on the host, or when you want the image to be the single source of truth.
**Pick that one** when the host already has TeX Live, you want a small image and fast
builds, and you don't mind the coupling.
