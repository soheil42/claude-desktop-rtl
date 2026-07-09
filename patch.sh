#!/bin/bash
# ============================================================================
#  Claude Desktop RTL for macOS
#
#  Adds right-to-left (Hebrew / Arabic / Persian) support to Claude Desktop by
#  building a patched *copy* of the app — the original /Applications/Claude.app
#  is never modified.
#
#  Pipeline (install):
#    1. Copy Claude.app -> Claude-RTL.app
#    2. Give the copy its own icon, name and bundle id
#    3. Inject the RTL payload (+ optional font CSS) into the renderer bundles
#    4. Disable the Electron ASAR-integrity fuse (required after editing the ASAR)
#    5. Re-sign with a stable self-signed identity (so macOS remembers granted
#       permissions such as Screen Recording across launches and re-installs)
#    6. Install the bundled RTL font into ~/Library/Fonts so it renders in chat
#
#  Requirements: Node.js (npx), Xcode command line tools (codesign), openssl.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD_FILE="$SCRIPT_DIR/rtl-payload.js"
ICON_FILE="$SCRIPT_DIR/icon.icns"
FONTS_DIR="$SCRIPT_DIR/fonts"

# Font applied to RTL text. On by default (Vazirmatn ships in fonts/). Override
# with --font NAME, or turn it off with --no-font (RTL direction still applies).
# The chat UI loads from claude.ai, whose CSP blocks embedded data: fonts, so the
# font is also installed into ~/Library/Fonts and referenced via local() — see
# build_font_injector and install_fonts.
RTL_FONT_FAMILY="${RTL_FONT_FAMILY-Vazirmatn}"

SOURCE_APP="/Applications/Claude.app"
# Patched copy lives beside the original in /Applications (distinct bundle id, so
# they coexist). /Applications is writable by admins without sudo; a re-install
# may show a one-time macOS "wants to modify applications" prompt — allow it.
# Prefer your home folder instead? Set this to "$HOME/Applications/Claude-RTL.app".
PATCHED_APP="/Applications/Claude-RTL.app"
PATCHED_ASAR="$PATCHED_APP/Contents/Resources/app.asar"

# Distinct bundle id for the patched copy. macOS TCC (Screen Recording, etc.)
# keys permissions to bundle id + code requirement. Reusing the original id would
# tie the copy to Anthropic's Developer-ID requirement, which it can't satisfy,
# so permissions would re-prompt forever. A separate id gives it its own identity.
# (CFBundleName is left alone — Electron's fuse lookup reads it; the identifier is
# unrelated.)
PATCHED_BUNDLE_ID="com.anthropic.claudefordesktop.rtl"

# Stable self-signed code-signing identity. Ad-hoc signatures have no stable
# identity (their cdhash changes on every re-sign) so macOS forgets TCC grants
# and re-prompts each launch. A self-signed cert yields a stable designated
# requirement that survives re-signing, so a granted permission persists (subject
# to macOS Sequoia's periodic re-auth, which no non-Developer-ID signature
# avoids). Created once in the login keychain and reused afterwards. Resolved at
# run time; falls back to "-" (ad-hoc) if it cannot be created.
SIGN_IDENTITY_NAME="Claude RTL Local"
SIGN_IDENTITY="-"

TMP_DIR=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "  ${CYAN}[*]${NC} $1"; }
success() { echo -e "  ${GREEN}[+]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $1"; }
err()     { echo -e "  ${RED}[X]${NC} $1"; }
step()    { echo -e "\n${BOLD}${CYAN}> $1${NC}"; }
die()     { err "$1"; exit 1; }

cleanup() { [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
asar_cmd() {
    if command -v asar &>/dev/null; then asar "$@"
    elif command -v npx &>/dev/null; then npx --yes @electron/asar "$@"
    else die "Bug: asar_cmd called without asar or npx."; fi
}

fuses_cmd() {
    command -v npx &>/dev/null || die "Bug: fuses_cmd called without npx."
    npx --yes @electron/fuses "$@"
}

check_dependencies() {
    local missing=()
    command -v npx &>/dev/null || command -v asar &>/dev/null || \
        missing+=("Node.js (npx) or @electron/asar")
    command -v npx &>/dev/null || missing+=("Node.js (npx, for @electron/fuses)")
    command -v codesign &>/dev/null || missing+=("Xcode command line tools (codesign)")
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required dependencies:"
        for d in "${missing[@]}"; do echo -e "    - $d"; done
        echo ""
        echo "  Node.js:   https://nodejs.org/  or  brew install node"
        echo "  Xcode CLI: xcode-select --install"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Only ever quits the patched copy — never the user's real Claude or Claude Code
# ---------------------------------------------------------------------------
quit_claude_rtl() {
    if pgrep -f "Claude-RTL.app" &>/dev/null; then
        step "Quitting Claude-RTL..."
        osascript -e 'tell application "Claude-RTL" to quit' 2>/dev/null || true
        sleep 2
        pkill -f "Claude-RTL.app/Contents/MacOS" 2>/dev/null || true
        sleep 1
        success "Claude-RTL stopped."
    fi
}

# ---------------------------------------------------------------------------
# Signing identity (stable self-signed cert for persistent TCC permissions)
# ---------------------------------------------------------------------------
ensure_signing_identity() {
    # Reuse the existing identity if present — reusing the SAME cert keeps the
    # designated requirement stable, which is what lets TCC remember the grant.
    # (No -v: the cert is self-signed/untrusted, which is fine for signing.)
    if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY_NAME\""; then
        SIGN_IDENTITY="$SIGN_IDENTITY_NAME"
        log "Reusing signing identity \"$SIGN_IDENTITY_NAME\"."
        return 0
    fi

    log "Creating a one-time self-signed certificate \"$SIGN_IDENTITY_NAME\" so"
    log "macOS keeps Screen Recording instead of asking on every launch."

    local cdir pw kc
    cdir=$(mktemp -d)
    pw="claude-rtl"   # non-empty: macOS rejects the empty-password p12 LibreSSL makes
    kc=$(security default-keychain 2>/dev/null | tr -d ' "' || true)
    [ -n "$kc" ] || kc="$HOME/Library/Keychains/login.keychain-db"

    cat > "$cdir/req.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGN_IDENTITY_NAME
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$cdir/key.pem" -out "$cdir/cert.pem" \
        -days 3650 -config "$cdir/req.cnf" >/dev/null 2>&1 \
    && openssl pkcs12 -export -out "$cdir/id.p12" \
        -inkey "$cdir/key.pem" -in "$cdir/cert.pem" \
        -passout "pass:$pw" >/dev/null 2>&1 \
    && security import "$cdir/id.p12" -k "$kc" -P "$pw" \
        -T /usr/bin/codesign >/dev/null 2>&1 \
    || true
    rm -rf "$cdir"

    if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY_NAME\""; then
        SIGN_IDENTITY="$SIGN_IDENTITY_NAME"
        success "Created signing identity \"$SIGN_IDENTITY_NAME\"."
    else
        SIGN_IDENTITY="-"
        warn "Could not create a signing identity — using ad-hoc signing."
        warn "Screen Recording may re-prompt each launch (macOS ad-hoc limitation)."
    fi
}

# ---------------------------------------------------------------------------
# Font: build the @font-face injector and install the font system-wide
# ---------------------------------------------------------------------------
# Sanitized RTL font family (empty when --no-font). Set by resolve_font_family.
FONT_FAMILY=""
resolve_font_family() {
    FONT_FAMILY="${RTL_FONT_FAMILY//\"/}"
    FONT_FAMILY="${FONT_FAMILY//\\/}"
    FONT_FAMILY="${FONT_FAMILY//\'/}"
}

# Append an @font-face + [dir='rtl'] font rule to the combined header file.
# Each src is  local('NAME'), url(data:...)  — installed font first (bypasses
# CSP), embedded data: URI as fallback for app:// contexts (e.g. the artifact
# preview). All CSS uses single quotes so it stays valid inside the JS string.
build_font_injector() {
    local header="$1"
    [ -z "$FONT_FAMILY" ] && { log "Font disabled (--no-font) — RTL direction only."; return 0; }

    local face_css="" embedded=0
    if [ -d "$FONTS_DIR" ]; then
        shopt -s nullglob nocaseglob
        local f
        for f in "$FONTS_DIR"/*.woff2 "$FONTS_DIR"/*.woff "$FONTS_DIR"/*.ttf "$FONTS_DIR"/*.otf; do
            [ -f "$f" ] || continue
            local lc weight style ext fmt mime b64
            lc=$(basename "$f" | tr '[:upper:]' '[:lower:]')
            weight=400
            case "$lc" in
                *thin*)                    weight=100 ;;
                *extralight*|*ultralight*) weight=200 ;;
                *light*)                   weight=300 ;;
                *medium*)                  weight=500 ;;
                *semibold*|*demibold*)     weight=600 ;;
                *extrabold*|*ultrabold*)   weight=800 ;;
                *black*|*heavy*)           weight=900 ;;
                *bold*)                    weight=700 ;;
            esac
            style=normal
            case "$lc" in *italic*|*oblique*) style=italic ;; esac
            ext="${lc##*.}"
            case "$ext" in
                woff2) fmt=woff2;    mime="font/woff2" ;;
                woff)  fmt=woff;     mime="font/woff" ;;
                ttf)   fmt=truetype; mime="font/ttf" ;;
                otf)   fmt=opentype; mime="font/otf" ;;
                *) continue ;;
            esac
            b64=$(base64 < "$f" | tr -d '\n')
            face_css+="@font-face{font-family:'${FONT_FAMILY}';font-style:${style};font-weight:${weight};font-display:swap;src:local('${FONT_FAMILY}'),url(data:${mime};base64,${b64}) format('${fmt}');}"
            embedded=$((embedded + 1))
        done
        shopt -u nullglob nocaseglob
    fi

    # Apply the family to RTL text (code stays monospace). Fallbacks cover glyphs
    # the chosen font may lack (e.g. Vazirmatn has no Hebrew).
    face_css+="[dir='rtl'],[dir='rtl'] *{font-family:'${FONT_FAMILY}',Tahoma,-apple-system,system-ui,sans-serif!important}"
    face_css+="[dir='rtl'] pre,[dir='rtl'] code,[dir='rtl'] pre *,[dir='rtl'] code *{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace!important}"

    {
        printf '\n// --- CLAUDE RTL FONT START ---\n'
        printf ';(function(){if(typeof document==="undefined")return;function add(){if(document.getElementById("claude-rtl-font"))return;if(!document.head&&!document.documentElement)return;var s=document.createElement("style");s.id="claude-rtl-font";s.textContent="%s";(document.head||document.documentElement).appendChild(s);}if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",add);}else{add();}})();\n' "$face_css"
        printf '// --- CLAUDE RTL FONT END ---\n'
    } >> "$header"

    if [ "$embedded" -gt 0 ]; then
        success "RTL font: \"$FONT_FAMILY\" — embedded $embedded file(s) as data: URIs."
    else
        warn "RTL font: \"$FONT_FAMILY\" — no files in fonts/, relying on an installed font."
    fi
}

# Install bundled .ttf/.otf into ~/Library/Fonts so the family renders in the
# claude.ai chat (where the embedded data: font is blocked by CSP and local()
# resolves to an installed copy). woff2 is skipped — the system can't install it.
install_fonts() {
    [ -z "$FONT_FAMILY" ] && return 0
    [ -d "$FONTS_DIR" ] || return 0
    local dest="$HOME/Library/Fonts" installed=0 f
    mkdir -p "$dest"
    shopt -s nullglob nocaseglob
    for f in "$FONTS_DIR"/*.ttf "$FONTS_DIR"/*.otf; do
        [ -f "$f" ] || continue
        cp -f "$f" "$dest/" && installed=$((installed + 1))
    done
    shopt -u nullglob nocaseglob
    if [ "$installed" -gt 0 ]; then
        success "Installed $installed font file(s) into ~/Library/Fonts."
    else
        log "No .ttf/.otf in fonts/ — chat will rely on an already-installed \"$FONT_FAMILY\"."
    fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_patch() {
    echo -e "\n${BOLD}${CYAN}=====================================================${NC}"
    echo -e "${BOLD}${CYAN}     Claude Desktop RTL — Install${NC}"
    echo -e "${BOLD}${CYAN}=====================================================${NC}"

    [ ! -d "$SOURCE_APP" ] && die "Claude.app not found at $SOURCE_APP. Is Claude Desktop installed?"
    [ ! -f "$PAYLOAD_FILE" ] && die "rtl-payload.js not found. Re-clone the repository."
    check_dependencies
    resolve_font_family
    quit_claude_rtl

    # --- Copy ---
    step "Creating patched copy..."
    mkdir -p "$(dirname "$PATCHED_APP")"
    [ -d "$PATCHED_APP" ] && { log "Removing previous patched copy..."; rm -rf "$PATCHED_APP"; }
    log "Copying Claude.app -> Claude-RTL.app (this may take a moment)..."
    cp -R "$SOURCE_APP" "$PATCHED_APP"
    success "Created $PATCHED_APP"

    # --- Icon ---
    if [ -f "$ICON_FILE" ]; then
        step "Replacing app icon..."
        cp "$ICON_FILE" "$PATCHED_APP/Contents/Resources/electron.icns"
        # macOS prefers CFBundleIconName (asset catalog) over the .icns file.
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null || true
        success "Icon replaced."
    fi

    # --- Name + bundle id ---
    step "Setting name and bundle identifier..."
    # CFBundleDisplayName is cosmetic; do NOT touch CFBundleName (Electron fuse).
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude-RTL" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Claude-RTL" "$PATCHED_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PATCHED_BUNDLE_ID" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $PATCHED_BUNDLE_ID" "$PATCHED_APP/Contents/Info.plist"
    success "Shows as \"Claude-RTL\"; bundle id $PATCHED_BUNDLE_ID."

    # --- Extract ASAR ---
    TMP_DIR=$(mktemp -d)
    step "Extracting app.asar..."
    asar_cmd extract "$PATCHED_ASAR" "$TMP_DIR/app"
    success "Extracted."

    # --- Build combined header (RTL payload + optional font CSS) ---
    HEADER_FILE="$TMP_DIR/rtl-header.js"
    cp "$PAYLOAD_FILE" "$HEADER_FILE"
    build_font_injector "$HEADER_FILE"

    # --- Inject into renderer/preload bundles ---
    step "Injecting RTL code..."
    BUILD_DIR="$TMP_DIR/app/.vite/build"
    [ -d "$BUILD_DIR" ] || die ".vite/build/ not found in ASAR. Claude Desktop's structure may have changed."

    # Skip the Electron main-process entry (package.json "main"): the payload is
    # renderer-side, and prepending it there stops any BrowserWindow from opening.
    local main_basename=""
    if [ -f "$TMP_DIR/app/package.json" ]; then
        local main_entry
        main_entry=$(node -p "require('$TMP_DIR/app/package.json').main || ''" 2>/dev/null || echo "")
        [ -z "$main_entry" ] && die "Could not read \"main\" from package.json. Claude's layout may have changed."
        main_basename=$(basename "$main_entry")
    fi

    local injected=0 skipped=0 js_file
    for js_file in "$BUILD_DIR"/*.js; do
        [ -f "$js_file" ] || continue
        if [ -n "$main_basename" ] && [ "$(basename "$js_file")" = "$main_basename" ]; then
            log "Skipping $(basename "$js_file") (Electron main process)"
            skipped=$((skipped + 1)); continue
        fi
        if grep -q "CLAUDE RTL PATCH START" "$js_file" 2>/dev/null; then
            skipped=$((skipped + 1)); continue   # idempotent
        fi
        cat "$HEADER_FILE" "$js_file" > "$TMP_DIR/merged.js"
        mv "$TMP_DIR/merged.js" "$js_file"
        injected=$((injected + 1))
        log "Injected into: $(basename "$js_file")"
    done
    [ "$injected" -eq 0 ] && [ "$skipped" -eq 0 ] && die "No .js files in .vite/build/. Claude's structure may have changed."
    [ "$injected" -gt 0 ] && success "Injected RTL JS into $injected file(s)."
    [ "$skipped" -gt 0 ] && log "Skipped $skipped file(s)."

    # --- Repack ASAR ---
    step "Repacking app.asar..."
    asar_cmd pack "$TMP_DIR/app" "$TMP_DIR/app.asar.new"
    cp "$TMP_DIR/app.asar.new" "$PATCHED_ASAR"
    success "Repacked."

    # --- Disable ASAR integrity fuse (required after editing the archive) ---
    step "Disabling ASAR integrity validation..."
    fuses_cmd write --app "$PATCHED_APP" EnableEmbeddedAsarIntegrityValidation=off 2>&1 | while IFS= read -r line; do log "$line"; done
    success "ASAR integrity fuse disabled."

    # --- Re-sign ---
    step "Re-signing..."
    ensure_signing_identity
    if [ "$SIGN_IDENTITY" = "-" ]; then
        log "Signing ad-hoc — macOS may re-prompt for permissions each launch."
    else
        log "Signing with \"$SIGN_IDENTITY\" — a stable identity, so granted"
        log "permissions (e.g. Screen Recording) persist across launches."
    fi
    # Preserve the original entitlements (Cowork needs com.apple.security.
    # virtualization). Strip the three team-id-coupled keys — they reference
    # Anthropic's team and macOS rejects them under a non-Anthropic signature.
    local ent="$TMP_DIR/entitlements.plist"
    if codesign -d --entitlements :- "$SOURCE_APP" > "$ent" 2>/dev/null && [ -s "$ent" ]; then
        /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$ent" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$ent" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ent" 2>/dev/null || true
        log "Preserving entitlements from original (incl. virtualization for Cowork)..."
        codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ent" "$PATCHED_APP" 2>&1 | while IFS= read -r line; do log "$line"; done
    else
        warn "Could not extract entitlements from original — Cowork will not work."
        codesign --force --deep --sign "$SIGN_IDENTITY" "$PATCHED_APP" 2>&1 | while IFS= read -r line; do log "$line"; done
    fi
    success "App re-signed."

    rm -rf "$TMP_DIR" 2>/dev/null || true; TMP_DIR=""

    # --- Install font system-wide (needed for the claude.ai chat) ---
    if [ -n "$FONT_FAMILY" ]; then
        step "Installing RTL font \"$FONT_FAMILY\"..."
        install_fonts
    fi

    # --- Launch ---
    step "Launching Claude-RTL..."
    open "$PATCHED_APP"

    echo -e "\n${BOLD}${GREEN}=====================================================${NC}"
    echo -e "${BOLD}${GREEN}     INSTALLED${NC}"
    echo -e "${BOLD}${GREEN}=====================================================${NC}\n"
    echo -e "  Patched app:  ${BOLD}$PATCHED_APP${NC}"
    echo -e "  Original app: ${BOLD}$SOURCE_APP${NC} (untouched)"
    [ -n "$FONT_FAMILY" ] && echo -e "  RTL font:     ${BOLD}$FONT_FAMILY${NC}"
    echo ""
    echo "  First launch only: approve the keychain prompt, and grant Screen"
    echo "  Recording once if you use it — both then persist."
    echo "  Remove with: $0 --uninstall"
    echo ""
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall_patch() {
    echo -e "\n${BOLD}${CYAN}=====================================================${NC}"
    echo -e "${BOLD}${CYAN}     Claude Desktop RTL — Uninstall${NC}"
    echo -e "${BOLD}${CYAN}=====================================================${NC}"

    [ ! -d "$PATCHED_APP" ] && { warn "No patched app at $PATCHED_APP. Nothing to remove."; exit 0; }
    quit_claude_rtl
    step "Removing patched app..."
    rm -rf "$PATCHED_APP"
    success "Removed $PATCHED_APP"
    echo ""
    echo "  The original Claude.app was never modified."
    echo "  (The \"$SIGN_IDENTITY_NAME\" keychain cert and installed fonts are left"
    echo "   in place so a future re-install keeps its permissions. Remove them"
    echo "   manually if you want a clean slate.)"
    echo ""
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    echo -e "\n${BOLD}Claude Desktop RTL — Status${NC}\n"

    if [ -d "$SOURCE_APP" ]; then
        local v; v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
        success "Original Claude.app: installed (v$v)"
    else
        warn "Original Claude.app: not found"
    fi

    if [ -d "$PATCHED_APP" ]; then
        local pv fuse
        pv=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
        fuse=$(npx --yes @electron/fuses read --app "$PATCHED_APP" 2>/dev/null | grep "EnableEmbeddedAsarIntegrityValidation" || echo "unknown")
        if echo "$fuse" | grep -q "Disabled"; then
            success "Patched Claude-RTL.app: installed (v$pv, fuse disabled)"
        else
            warn "Patched Claude-RTL.app: found (v$pv) but fuse status unclear"
        fi
    else
        log "Patched Claude-RTL.app: not installed"
    fi

    if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY_NAME\""; then
        success "Signing identity \"$SIGN_IDENTITY_NAME\": present"
    else
        log "Signing identity \"$SIGN_IDENTITY_NAME\": not created yet"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Usage / menu
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

${BOLD}Claude Desktop RTL for macOS${NC}

Usage: $0 [ACTION] [FONT OPTION]

Actions:
  --install       Build the patched copy and launch it
  --uninstall     Remove the patched copy (original untouched)
  --status        Show installed versions + fuse state
  --help          Show this help

Font options (default: Vazirmatn, bundled):
  --font NAME     Use NAME for RTL text (drop matching files in fonts/ to bundle it)
  --no-font       Do not change the font (RTL direction only)
                  Env equivalent: RTL_FONT_FAMILY=NAME  (empty disables)

With no action, an interactive menu is shown.
EOF
}

interactive_menu() {
    echo -e "${BOLD}${CYAN}Claude Desktop RTL for macOS${NC}\n"
    echo "  1. Install"
    echo "  2. Uninstall"
    echo "  3. Status"
    echo "  4. Exit"
    echo ""
    read -rp "Choice (1-4): " choice
    case "$choice" in
        1) install_patch ;;
        2) uninstall_patch ;;
        3) show_status ;;
        4) exit 0 ;;
        *) die "Invalid choice." ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install|--uninstall|--status)
            [ -n "$ACTION" ] && die "Multiple action flags: $ACTION and $1"
            ACTION="$1"; shift ;;
        --help|-h) usage; exit 0 ;;
        --font)
            [ $# -lt 2 ] && die "--font requires a family name (e.g. --font Vazirmatn)"
            RTL_FONT_FAMILY="$2"; shift 2 ;;
        --font=*) RTL_FONT_FAMILY="${1#--font=}"; shift ;;
        --no-font) RTL_FONT_FAMILY=""; shift ;;
        "") shift ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

case "$ACTION" in
    --install)   install_patch ;;
    --uninstall) uninstall_patch ;;
    --status)    show_status ;;
    "")          interactive_menu ;;
esac
