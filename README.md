<div align="center">
  <img src="assets/banner.png" alt="Claude Desktop RTL for macOS" width="820">
</div>

<p align="center">
  <b>English</b> ·
  <a href="README.fa.md">فارسی</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white" alt="Platform: macOS">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-D97757" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/RTL-Persian%20%C2%B7%20Arabic%20%C2%B7%20Hebrew-D97757" alt="RTL: Persian, Arabic, Hebrew">
  <img src="https://img.shields.io/badge/built%20with-Bash%20%2B%20JS-4EAA25?logo=gnubash&logoColor=white" alt="Built with Bash and JavaScript">
  <a href="https://github.com/soheil42/claude-desktop-rtl/stargazers"><img src="https://img.shields.io/github/stars/soheil42/claude-desktop-rtl?color=D97757" alt="Stars"></a>
</p>

# Claude Desktop RTL for macOS

Adds proper **right-to-left** (Hebrew / Arabic / Persian / Urdu …) support to
[Claude Desktop](https://claude.ai/download) on macOS. RTL text is detected in
real time — in the composer as you type and in Claude's responses as they stream
— and aligned correctly, while code blocks and math stay left-to-right.

It does **not** modify your installed Claude. It builds a separate, patched copy
at `/Applications/Claude-RTL.app` and leaves the original untouched.

---

## Features

- **Live RTL detection** — composer and streamed responses, no toggle needed.
- **Persian/Arabic font built in** — bundles [Vazirmatn](https://github.com/rastikerdar/vazirmatn)
  and applies it to RTL text by default (installs it for you). Turn off with `--no-font`.
- **Code & math stay LTR** — `pre`/`code`, KaTeX, MathJax and MathML are never mirrored.
- **Permissions that stick** — the copy is signed with a stable identity, so macOS
  remembers Screen Recording and other grants instead of asking every launch.
- **Non-destructive** — your real `Claude.app` is never modified and keeps auto-updating.
- **Own icon & identity** — an "RTL"-badged icon and its own bundle id, so it lives
  happily beside the original.

---

## Requirements

- macOS (tested on macOS 15 Sequoia / macOS 26 Tahoe)
- Claude Desktop installed at `/Applications/Claude.app`
- [Node.js](https://nodejs.org/) 16+ (`npx`, for `@electron/asar` and `@electron/fuses`)
- Xcode command line tools (`codesign`) — `xcode-select --install`

---

## Quick start

```bash
git clone https://github.com/soheil42/claude-desktop-rtl.git
cd claude-desktop-rtl
./patch.sh --install
```

That builds `/Applications/Claude-RTL.app`, installs the Vazirmatn font, and
launches it. Downloaded the ZIP instead of cloning? Run `chmod +x patch.sh` first.

---

## Usage

```bash
./patch.sh --install        # build patched copy (Vazirmatn on by default) and launch
./patch.sh --install --no-font   # RTL direction only, keep Claude's font
./patch.sh --install --font "B Nazanin"   # use a different family
./patch.sh --uninstall      # remove the patched copy (original untouched)
./patch.sh --status         # show versions + fuse state
./patch.sh                  # interactive menu
```

`--install` is idempotent — re-run it any time (for example after Claude updates).

### First launch (one time)

- **Keychain prompt** — approve access to "Claude Safe Storage". The patched copy
  has a different signature than the original, so macOS asks once.
- **Screen Recording** — if you use a feature that needs it, grant it once in
  System Settings → Privacy & Security → Screen & System Audio Recording. Thanks
  to the stable signature it then persists across launches and re-installs.

---

## Fonts

By default the patch applies **Vazirmatn** to RTL text and installs it into
`~/Library/Fonts`. Installing it is necessary because the chat UI is served from
`claude.ai`, whose Content-Security-Policy blocks embedded fonts — an installed
copy, referenced via `local()`, is what actually renders in chat.

- **Use a different bundled font:** drop your `.ttf`/`.otf` files into `fonts/`
  and run `./patch.sh --install --font "<family name>"`. They'll be embedded and
  installed automatically.
- **Use a font already on your system:** `./patch.sh --install --font "B Nazanin"`.
- **No font change:** `./patch.sh --install --no-font`.

> **Hebrew:** Vazirmatn covers Persian/Arabic/Latin but **not** Hebrew — Hebrew
> falls back to the system Hebrew font. For a Hebrew-first setup, bundle a Hebrew
> font (Heebo, Rubik, Assistant …) in `fonts/` and pass its family with `--font`.

---

## After Claude updates

Claude's auto-updater only touches the original `/Applications/Claude.app`. The
patched copy is independent, so after an update just rebuild it:

```bash
./patch.sh --install
```

The signing certificate and installed font are reused, so you won't need to
re-grant permissions.

---

## How it works

1. Copies `Claude.app` → `Claude-RTL.app` (original untouched).
2. Gives the copy its own icon, display name and bundle id.
3. Extracts `app.asar`, prepends the RTL payload (and font CSS) to the renderer
   bundles, repacks.
4. Disables the Electron `EnableEmbeddedAsarIntegrityValidation` fuse (required
   after editing the archive, or Electron refuses to load it).
5. Re-signs with a stable self-signed identity created once in your login keychain.
6. Installs the bundled font into `~/Library/Fonts`.

The RTL detection uses the standard Unicode first-strong-character heuristic and
a `MutationObserver` to keep up with streamed content.

---

## Troubleshooting

- **"Claude quit unexpectedly" on launch** — re-run `./patch.sh --install`; it
  re-disables the ASAR fuse. Check `npx --yes @electron/fuses --help` works.
- **RTL text isn't aligned** — make sure you launched `Claude-RTL`, not the
  original. Type some Hebrew/Arabic/Persian to trigger detection.
- **Font isn't Vazirmatn in chat** — the family must be installed system-wide
  (the installer does this). Confirm `~/Library/Fonts/Vazirmatn-*.ttf` exist,
  then relaunch.
- **"…wants to modify applications" prompt on re-install** — expected;
  `/Applications` is protected by macOS App Management. Allow it.
- **Gatekeeper warning** — the copy is self-signed, so on first open you may need
  right-click → Open, or System Settings → Privacy & Security → Open Anyway.
- **Structure changed error** (`.vite/build/ not found`) — a Claude update
  reorganized the app; the patcher needs updating for the new layout.

---

## Uninstall

```bash
./patch.sh --uninstall
```

Removes `/Applications/Claude-RTL.app`. The original Claude is unaffected. The
`Claude RTL Local` keychain certificate and the installed font are left in place
so a future re-install keeps its permissions — remove them by hand for a clean slate.

---

## License

MIT — see [LICENSE](LICENSE). The bundled Vazirmatn font is under the SIL Open
Font License 1.1 — see [fonts/OFL.txt](fonts/OFL.txt).
