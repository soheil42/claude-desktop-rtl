# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A macOS patcher that adds RTL (Hebrew/Arabic/Persian) support to Claude Desktop. It does **not** modify the installed `/Applications/Claude.app`; it builds a separate patched copy at `/Applications/Claude-RTL.app`. The value of this repo is the macOS pipeline in `patch.sh` plus the renderer payload in `rtl-payload.js` (an original implementation of the standard Unicode first-strong RTL heuristic).

There is no build system, test suite, or linter — the only artifact is the patched `.app` bundle. `patch.sh` is a single `set -euo pipefail` bash script; `rtl-payload.js` is a self-contained IIFE prepended into the app's bundles.

## Commands

```bash
./patch.sh --install            # build patched copy (Vazirmatn font on by default) + launch
./patch.sh --install --no-font  # RTL direction only, keep Claude's font
./patch.sh --install --font "B Nazanin"   # different family (env: RTL_FONT_FAMILY=NAME)
./patch.sh --uninstall          # delete the patched copy (original untouched)
./patch.sh --status             # versions, ASAR fuse state, signing-identity presence
./patch.sh                      # interactive menu
```

Runtime deps (`check_dependencies`): `npx` (Node ≥16, fetches `@electron/asar` + `@electron/fuses` on demand), `codesign` (Xcode CLI), and `openssl` (for the signing cert; falls back to ad-hoc if absent). `--install` is idempotent — it removes the prior copy and rebuilds; per-file injection is guarded by the `CLAUDE RTL PATCH START` marker.

## Patching pipeline (`install_patch`)

1. `cp -R` `$SOURCE_APP` → `$PATCHED_APP` (`/Applications/Claude-RTL.app`).
2. Replace `electron.icns` with `icon.icns` and delete `CFBundleIconName` (macOS prefers the asset-catalog icon otherwise).
3. Set `CFBundleDisplayName=Claude-RTL` and `CFBundleIdentifier=com.anthropic.claudefordesktop.rtl`. **Never touch `CFBundleName`** — Electron's fuse lookup reads it. The distinct **bundle id** is deliberate: TCC keys permissions to bundle id + code requirement, so reusing the original id ties the copy to Anthropic's Developer-ID requirement (which it can't satisfy) and permissions re-prompt forever.
4. `asar extract` → prepend the combined header (`rtl-payload.js` + optional font CSS from `build_font_injector`) to every `.js` under `.vite/build/` **except the Electron main-process entry** (read from `package.json`'s `"main"`, currently `index.pre.js`) → `asar pack`. Injecting the payload into the main process stops any `BrowserWindow` from opening.
5. `@electron/fuses write … EnableEmbeddedAsarIntegrityValidation=off` — **required**; Electron validates the ASAR hash at startup and the modified archive crashes without this.
6. Re-sign (`ensure_signing_identity` → `codesign --force --deep --sign "$SIGN_IDENTITY"`). Entitlements are extracted from `$SOURCE_APP` and re-applied (Cowork needs `com.apple.security.virtualization`), with three team-id-coupled keys stripped (`com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups`) — they reference Anthropic's team and macOS rejects them under a non-Anthropic signature.
7. `install_fonts` copies bundled `.ttf`/`.otf` into `~/Library/Fonts` (see the font note below).

`quit_claude_rtl` is scoped to the `Claude-RTL.app` bundle path so it never touches the user's running original Claude or the Claude Code CLI.

## Where the chat actually runs (important)

The chat UI is **not local**. `.vite/renderer/main_window/index.html` is only the title-bar/error shell — its own comment says *"everything else gets loaded from claude.ai"*. The chat renders in a `claude.ai` view whose **preload is `.vite/build/mainView.js`**. That is why injection targets `.vite/build/*.js` (preloads run in the renderer with DOM access) — `mainView.js` is the file that reaches the chat. Its CSP is claude.ai's server CSP, which matters for fonts (below).

## Signing identity (`ensure_signing_identity`)

Ad-hoc signing (`codesign --sign -`) has no stable identity — its cdhash changes on every re-sign — so macOS forgets TCC grants (notably **Screen Recording**) and re-prompts each launch. Instead the script creates a **stable self-signed certificate** `Claude RTL Local` once in the login keychain (openssl → PKCS#12 → `security import -T /usr/bin/codesign`) and reuses it. This yields a stable designated requirement (`identifier … and certificate leaf = H"…"`) so grants persist across launches and re-installs. Caveats: the p12 must use a **non-empty** password (macOS rejects LibreSSL's empty-password p12); the cert is untrusted (`CSSMERR_TP_NOT_TRUSTED`) which is fine for signing and for TCC. macOS Sequoia/Tahoe still re-prompts periodically by OS design — only Developer ID + notarization avoids that entirely.

## RTL payload (`rtl-payload.js`)

Self-contained IIFE wrapped in `// --- CLAUDE RTL PATCH START/END ---` (the start marker is what `patch.sh` greps to skip already-patched files — **keep it**). Bails out when `document` is undefined so it's safe to prepend anywhere. Decides direction by the first strong-directional character (skipping neutrals; stripping URLs/paths/inline-code that would falsely read LTR), marks block elements and the composer with the `dir` **attribute**, force-keeps `pre`/`code` and math (KaTeX/MathJax/MathML) LTR, and uses a debounced `MutationObserver` for streamed responses plus an `input` listener for the composer. The composer is set via the `dir` **attribute** (not just `style.direction`) so the `[dir='rtl']` font rule reaches it. The RTL **font is not set here** — `build_font_injector` owns it so the family name has one source of truth.

## RTL font (`fonts/` + `build_font_injector` + `install_fonts`)

Vazirmatn (Persian/Arabic, OFL — `fonts/OFL.txt`) is bundled as `.ttf` and applied **by default**; `--no-font` (or `RTL_FONT_FAMILY=`) disables it, `--font NAME` overrides. Two things happen because the chat is claude.ai:

- Each `@font-face` `src` is `local('NAME'), url(data:…)`. claude.ai's server CSP passes through with a `font-src` that **blocks `data:`**, so the embedded font fails in chat and RTL text would fall back to Tahoma. `local()` resolves from installed system fonts and is **not** subject to `font-src`, so an installed copy renders in chat — which is why `install_fonts` copies the bundled `.ttf` into `~/Library/Fonts`. The `data:` URL still covers `app://` contexts (e.g. the artifact preview) where `font-src data:` is allowed and the font may not be installed.
- Ship **`.ttf`/`.otf`**, not `.woff2` — the system can't install woff2, and `build_font_injector` embeds whatever formats are in `fonts/` (avoid shipping duplicate formats of the same family or you get duplicate `@font-face` blocks).

The family name is sanitized (quotes/backslashes stripped) and all generated CSS uses single quotes so it stays valid inside the double-quoted JS string literal. Vazirmatn has **no Hebrew glyphs** — Hebrew falls back to the system Hebrew font; bundle a Hebrew font in `fonts/` for Hebrew-first use.

## Things that will trip you up

- **Don't patch `/Applications/Claude.app`.** Root-owned and protected by App Management; the "patched copy" design is the whole point, and it keeps Anthropic's auto-updates working.
- **Claude updates ≠ patched copy updates.** After Claude auto-updates the original, re-run `./patch.sh --install` to rebuild from the new version. The signing cert and installed font are reused, so permissions don't need re-granting.
- **`.vite/build/` is the injection target** — if a Claude update restructures the ASAR, `install_patch` dies with a clear error (`.vite/build/ not found`). First place to look when a new version breaks the patch.
- **`/Applications` is writable by admins without sudo**, but a re-install may trigger a one-time macOS App Management prompt ("… wants to modify applications"). Set `PATCHED_APP` back to `$HOME/Applications/...` to avoid that.
- **First-launch keychain re-auth and Screen Recording grant are expected** (new signature/bundle id). Both persist afterwards thanks to the stable identity.
