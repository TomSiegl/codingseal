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
| `curated` **(default)** | **4.16 GB** | ~19 min | pdflatex, xelatex, lualatex, latex | Ordinary documents: papers, reports, theses |
| `full` | ~8.3 GB ᵉ | ~32 min ᵉ | all of the above | You want every package Debian ships and can't predict what a document needs |
| `minimal` | **1.66 GB** | ~6 min | pdflatex, lualatex, latex (**no xelatex**) | Simple documents; no tikz, no bibliography tooling |
| `none` | **1.34 GB** | ~3 min | — | You don't want LaTeX in the image |

Bold sizes are measured from built images. Every figure includes the ~300 MB of system
fonts and pandoc, which are installed in **all** schemes — ~250 MB of that is pandoc's
static Haskell binary and data, the rest the fonts; the bare base with neither LaTeX nor
fonts/pandoc is 1.03 GB. Build times are end-to-end on a warm apt cache and are dominated
by download plus format generation.

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

System fonts are **not** part of any scheme — they are installed separately for every
scheme (see [System fonts and pandoc](#system-fonts-and-pandoc) below), because the
`texlive-*` packages ship essentially none.

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

### System fonts and pandoc

Installed in **every** scheme, in a layer *after* the TeX Live layers — so editing the
font or pandoc list never triggers the slow multi-GB LaTeX rebuild.

```
fontconfig                                         fc-cache / fc-match / fc-list
fonts-liberation fonts-liberation2                 Arial / Times / Courier metric clones
fonts-crosextra-carlito fonts-crosextra-caladea    Calibri / Cambria metric clones
fonts-dejavu fonts-dejavu-extra fonts-freefont-ttf
fonts-noto-core                                    Greek, Cyrillic, Hebrew, Arabic, … (no CJK)
ttf-mscorefonts-installer                          the real Arial, Times New Roman, …
lmodern                                            pandoc's template needs it (see below)
pandoc
```

`fontconfig` is named here even though the LaTeX block's `COMMON` also installs it, and
that duplication is load-bearing rather than sloppy: with `LATEX_SCHEME=none` the LaTeX
block `exit 0`s before installing anything at all, so a layer that assumed `fc-cache`
existed would fail this one scheme and no other. (It did, once.) apt makes the duplicate a
no-op everywhere else.

**Why this is separate from `texlive-fonts-*`.** Those packages populate the texmf tree
with fonts addressed by pdflatex's NFSS names (`\usepackage{helvet}`). They install almost
nothing that **fontconfig** can see — and fontconfig is how `fontspec` resolves fonts
under xelatex/lualatex. Before this layer existed, the image had exactly one
general-purpose system font (DejaVu), so every `\setmainfont{<ordinary font name>}` failed.

**Metric clones are not substitutes, and this is the trap.** fontconfig ships
`30-metric-aliases.conf`, which makes `fc-match Arial` answer `Liberation Sans` when no
real Arial is installed. `fontspec` does **not** honour that aliasing — it matches on the
family's own name. So with only `fonts-liberation`:

```
$ fc-match Arial
LiberationSans-Regular.ttf: "Liberation Sans" "Regular"   # looks fine
$ xelatex doc.tex   # \setmainfont{Arial}
! Package fontspec Error: The font "Arial" cannot be found.
```

That is measured, not theorised: it is exactly what `\setmainfont{Calibri}` still does in
the built image, because only the `Carlito` clone is present under its own name. A family
is usable from `fontspec` only if that family's name is installed.

`ttf-mscorefonts-installer` is therefore what makes `\setmainfont{Arial}` work. It is also
the least pleasant package in the file, in three ways. It lives in `multiverse` and needs a
EULA accepted, preseeded via `debconf-set-selections`. Its postinst downloads the fonts
from **SourceForge**, one file at a time — the build's least reliable network step (the
`Containerfile` also reaches NodeSource, astral.sh and npm, but those are fast and
resilient). And it hard-`Depends:` on `update-notifier-common`, which pulls in
`python3-apt` and `ubuntu-pro-client` — ~35 MB of machinery with no purpose in a container,
which `--no-install-recommends` cannot exclude and which cannot be purged afterwards
without deleting the fonts along with them.

Opt out with:

```bash
podman build --build-arg MSCOREFONTS=false -t coding-seal:latest .
```

Measured, that image is **4.14 GB against 4.16 GB** — so this flag buys ~2 minutes of build
time and essentially no space. Choose it because you don't want the EULA or the SourceForge
round-trip, not to slim the image. The cost is that Arial then resolves only through
fontconfig substitution: fine for `fc-match` and for pdflatex, **not** for
`\setmainfont{Arial}`. The build-time smoke test adapts and tests `Liberation Sans` instead.

`pandoc` (3.1.3 from Ubuntu, ~250 MB, mostly the static Haskell binary) has no PDF
machinery of its own — it drives the LaTeX installed above. Under `curated`,
`--pdf-engine=pdflatex`, `=xelatex` and `=lualatex` all work, as does `-V mainfont=Arial`
under xelatex.

What PDF output needs per scheme is worth stating, because it is not simply "whichever
engines exist":

| Scheme | pandoc → PDF |
|---|---|
| `curated`, `full` | All three engines |
| `minimal` | **`pdflatex` only.** `lualatex` exists but pandoc's template routes it through `fontspec`, whose font resolution needs `texlive-luatex` — absent here. There is no `xelatex` at all. |
| `none` | Nothing. Every other conversion still works. |

`minimal` needed one addition to get even that far: pandoc's default template does
`\usepackage{lmodern}`, which `minimal` does not ship, so `pandoc -o x.pdf` failed with
``File `lmodern.sty' not found`` while html/docx/tex output was fine. `lmodern` is
therefore installed in the **fonts/pandoc layer**, not added to the `minimal` package
list — same reasoning as `fontconfig` above, it keeps the slow LaTeX layers untouched.
`curated` already has it, so apt no-ops there, and `none` skips it.

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
   outside the texmf tree. The broader system font set lives in a later layer — see
   [System fonts and pandoc](#system-fonts-and-pandoc).

4. **`--no-install-recommends` is load-bearing.** `texlive-latex-extra` *recommends*
   `default-jre`; without the flag every image would carry a JRE.

5. **The doc packages cannot be dropped from `full`.** They are hard `Depends:` of
   `texlive-full`, not `Recommends:`, so `--no-install-recommends` does not exclude
   them. Avoiding the 2.3 GB of manuals is precisely why `curated` names sub-packages
   instead.

### Build-time behaviour

- **This is a slow build.** `curated` takes roughly **19 minutes** end to end on a warm
  apt cache — about 1.25 GB of downloads plus format generation. `full` is worse (~3.9 GB
  of downloads). Budget for it, and expect the same again whenever you change
  `LATEX_SCHEME` or the package list, since that invalidates the layer.
- Of that, the fonts/pandoc layer is **~2 minutes**, and most of it is the
  `ttf-mscorefonts-installer` postinst pulling 12 files from SourceForge one at a time.
  `MSCOREFONTS=false` makes this layer take about 20 seconds.
- The LaTeX block sits **early** in the `Containerfile`, before the fonts/pandoc and
  Node/uv/Claude layers, so editing those does not invalidate a multi-GB layer. The reverse
  is not true: changing the scheme rebuilds everything after it (the fonts/pandoc layer
  plus a few extra minutes of npm/uv work).
- An **invalid `LATEX_SCHEME` fails the build immediately** with
  `unknown LATEX_SCHEME='…' (want: none|minimal|curated|full)`, rather than silently
  producing an image with no LaTeX.
- Installing `texlive-latex-base` runs `fmtutil-sys`, which **compiles the `.fmt`
  formats into `/var/lib/texmf` during the build**. This is a large part of that time,
  and it is what makes the image self-contained: no format generation on first compile.
- **Three smoke tests run at build time**, so a broken scheme is caught by the build and
  not by your first document: a one-page `pdflatex` document must compile; a `fontspec`
  document must compile under `xelatex` naming **Arial**, **Times New Roman** and
  **Carlito** (`Liberation Sans`/`Liberation Serif` when `MSCOREFONTS=false`); and `pandoc`
  must turn Markdown into a PDF. The middle one is a real test of font *resolution* —
  `fontspec` raises a hard error for a missing family rather than substituting.
  Each test skips only the schemes that genuinely cannot run it: the fontspec test needs
  `xelatex` so `minimal` skips it, the pandoc test needs only `pdflatex` so `minimal` runs
  it, and `none` skips both.
- `texlive-latex-extra` depends on `python3`, so apt's `/usr/bin/python3` is installed
  alongside the uv-managed interpreter. Harmless: `/usr/local/bin` precedes `/usr/bin`
  in `PATH`, so `python3` still resolves to uv's.

---

## 3. Verification

```sh
podman run --rm --entrypoint /bin/bash coding-seal:latest -lc '
  pdflatex --version | head -1
  for b in pdflatex xelatex lualatex latexmk biber bibtex makeindex gs repstopdf pdfcrop pandoc; do
    command -v "$b" >/dev/null || echo "MISSING: $b"
  done
  kpsewhich tikz.sty biblatex.sty
  for f in Arial "Times New Roman" "Courier New" Carlito Caladea "DejaVu Sans"; do
    fc-match "$f" | grep -q "\"$f\"" || echo "NOT A REAL FAMILY: $f"
  done'
```

The image is self-contained, so this needs **no mounts and no host TeX Live**.

`fc-match` is the quick check, but note it is the *misleading* one — it reports success via
fontconfig aliasing even when the family itself is absent (hence the `grep` above, which
compares the resolved family name against the one asked for). The check that actually
matters is compiling a `fontspec` document, which is what the build-time smoke test does.

### What was tested

`curated` passes twelve checks with no mounts beyond the project directory: `pdflatex`,
`lualatex`, `xelatex`+`fontspec` (both a texmf font and a system font), `latexmk`,
`biber`/biblatex, `latex`→`dvips`, `ps2pdf`, `.eps` include via `repstopdf`+`gs`,
`pdfcrop`, `makeindex`, `tikz`/`booktabs`, and `kpsewhich pgfplots`. `minimal` passes the
seven that apply to it. `none` has no `pdflatex` and an otherwise intact base image. An
invalid scheme fails the build. In every scheme `claude`, `node`, `uv` and the
uv-managed `python3` still work — apt's `python3` does not shadow it.

The fonts and pandoc were verified separately, running as `coder` (uid 1000) in the built
`curated` image — 46 checks, all passing:

- **21 font families resolve to themselves**, not to an alias: the nine MS core fonts
  (Arial, Times New Roman, Courier New, Georgia, Verdana, Trebuchet MS, Andale Mono, Comic
  Sans MS, Impact), the Liberation trio, Carlito, Caladea, DejaVu Sans/Serif, FreeSans/
  FreeSerif, Noto Sans, and the texmf-side Latin Modern Roman and TeX Gyre Pagella. 610
  fonts are visible to fontconfig in total.
- **`xelatex`+`fontspec` compiles** naming the MS fonts, and again naming only the free
  ones; **`lualatex`+`fontspec`** compiles with Arial. `pdflatex`+`amsmath`+`tikz` still
  works, i.e. no regression from the new layer.
- **Two negative controls**, without which the above would prove nothing: a nonsense family
  name is a hard `fontspec` error (so a "pass" means the font was really found), and
  `\setmainfont{Calibri}` *still fails* even though `fc-match Calibri` answers `Carlito` —
  the concrete demonstration that metric clones do not satisfy `fontspec`.
- **pandoc** converts Markdown to html, docx, tex, odt, epub, rst and json; produces PDFs
  through all three engines; honours `-V mainfont=Arial` under xelatex; and round-trips
  docx back to Markdown.
- The **system fontconfig cache is complete**: deleting `~/.cache/fontconfig` and running
  `fc-match` writes no per-user cache, so a fresh container does no font scanning.

`minimal` and `none` were then verified against the same claims, as `coder`, and both pass
in full: pandoc, `fc-match` and the real Arial/Times New Roman/Carlito families are present
in *both*; html/docx/tex/odt/epub conversion works in both; and the PDF limitations are
exactly as tabulated above — under `minimal`, `pdflatex` produces a PDF while `lualatex`
fails and `xelatex` is absent; under `none`, there is no `pdflatex` and PDF output fails
while everything else still converts. `claude`, `node`, `uv` and `python3` are unaffected in
both.

`MSCOREFONTS=false` was built and checked as well, so every conditional branch in the new
layer is exercised rather than assumed.

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
| Image size (from a 1.03 GB base) | 4.16 GB `curated` | **1.35 GB** ᵃ |
| Build time | ~19 min `curated` | **~45 s** for the TeX layer |
| Reproducible from the repo alone | **Yes** | No — depends on the host's TeX Live |
| Package coverage | Fixed at build time; adding one means a rebuild | The host's, instantly; `apt install` on the host is enough |
| Can modify the host TeX install | No host TeX involved | No — all mounts are `:ro` |
| Extra machinery needed | None | A generated symlink manifest + a fontconfig snippet |

ᵃ Not a like-for-like comparison any more: the 1.35 GB figure predates the fonts/pandoc
layer, so subtract ~300 MB from this branch's 4.16 GB before comparing the LaTeX parts.

The other branch installs only the engines in the image (~320 MB) and bind-mounts the
host's TeX Live data read-only, reusing the host's prebuilt `.fmt` files so `fmtutil`
never runs. See `LATEX-HOST.md` there for that analysis.

**Pick this branch** when the container must stand alone, when you can't guarantee what
is on the host, or when you want the image to be the single source of truth.
**Pick that one** when the host already has TeX Live, you want a small image and fast
builds, and you don't mind the coupling.
