#!/usr/bin/env bash
#
# build-clamav-suite.sh
#
# Downloads Cisco's ClamAV distribution package and ArsenTech's ClamAV GUI, then
# combines them into a single signed, notarized distribution package for
# Apple Business Manager > Devices > macOS Packages.
#
# Three things about the upstream artifacts drive the shape of this script:
#
#   1. The GUI resolves `clamscan` from PATH only, and launchd hands GUI apps
#      PATH=/usr/bin:/bin:/usr/sbin:/sbin. Cisco installs to
#      /usr/local/clamav/bin, which is not on it. Stage 4 installs a compiled
#      launcher as the bundle's main executable to prepend it; without that the
#      GUI shows its "no ClamAV" state-gate screen and is unusable.
#   2. There is no macOS pkg upstream, only per-arch archives. This fleet is
#      Apple Silicon only, so stage 3 uses the arm64 bundle as shipped and the
#      Distribution restricts hostArchitectures to arm64, which makes an Intel
#      Mac refuse the package rather than install a GUI that cannot launch.
#   3. The vendor bundle is adhoc/linker-signed with no entitlements, so it
#      cannot be notarized as shipped and must be re-signed.
#
# Cisco ships a *distribution* pkg wrapping three component pkgs. productbuild
# --package only accepts components, so stage 5 expands the vendor pkg and
# re-flattens its components rather than collapsing everything into one. That
# preserves Cisco's three receipts and version metadata.
#
# Usage:
#   TEAM_ID=ABCDE12345 ./build-clamav-suite.sh     full signed + notarized build
#   ./build-clamav-suite.sh --no-sign              unsigned, for testing assembly
#   ./build-clamav-suite.sh --rehash               keep tags, recompute hashes
#   ./build-clamav-suite.sh --refresh              resolve latest, rewrite pins
#
# Requires: Xcode CLI tools, Developer ID Application + Installer certs, and
# either a notarytool keychain profile or App Store Connect API key args.
# --rehash and --refresh need only curl and a sha256 tool, so they also run on
# Linux (the Renovate rehash job uses ubuntu-latest).
#
set -euo pipefail

# ---------------------------------------------------------------- config -----

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
VERSIONS_FILE="$SCRIPT_DIR/versions.env"
VERSION_FILE="$SCRIPT_DIR/version.txt"
CACHE="$SCRIPT_DIR/.cache"
OUT_DIR="$SCRIPT_DIR/out"

SUITE_ID="com.pelotech.clamav-suite"
GUI_COMPONENT_ID="com.pelotech.clamav-gui"
DAEMON_LABEL="com.pelotech.clamav.freshclam"
CLAMAV_DIR="/usr/local/clamav"
GUI_APP_NAME="ClamAV GUI.app"

# Holds the licensing record and the uninstaller. Deliberately outside
# CLAMAV_DIR so the two are independently removable.
SUPPORT_DIR="/usr/local/share/clamav-suite"

CLAMAV_REPO="Cisco-Talos/clamav"
GUI_REPO="ArsenTech/clamav-gui"

MODE="build"
SIGN=1
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
TEAM_ID="${TEAM_ID:-}"

# ------------------------------------------------------------- utilities -----

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Prints the whole leading comment block, stopping at the first non-comment
# line. No line numbers, so editing the header cannot silently truncate --help.
usage() {
  awk 'NR > 2 { if (!/^#/) exit; sub(/^#[[:space:]]?/, ""); print }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required tool: $c"
  done
}

# Render a template from templates/ into place.
#
# Every __PLACEHOLDER__ resolves to the same-named shell variable, so adding one
# means adding a variable and nothing else. Values are substituted with `|` as
# the sed delimiter, so none of them may contain `|` or `&` -- they are paths,
# versions, repo slugs and bundle identifiers, so that holds.
#
# Only the placeholders a template actually contains are substituted, and an
# empty or unset value is fatal. Templates are rendered at different stages, so
# that check is what catches one being rendered before its values exist.
render() {
  local tpl="$TEMPLATES/$1" dest="$2" ph name val leftover
  local -a args=()
  [ -f "$tpl" ] || die "missing template: templates/$1"

  while IFS= read -r ph; do
    name="${ph//__/}"
    val="${!name-}"
    [ -n "$val" ] || die "templates/$1 uses ${ph}, but \$${name} is empty here.
Templates render in stage order; this one runs before that value is set."
    args+=(-e "s|${ph}|${val}|g")
  done < <(grep -ohE '__[A-Z_]+__' "$tpl" | sort -u)

  sed ${args[@]+"${args[@]}"} "$tpl" > "$dest"

  leftover="$(grep -o '__[A-Z_]\{3,\}__' "$dest" | sort -u || true)"
  [ -z "$leftover" ] || die "unsubstituted placeholders in $(basename "$dest"):
$(printf '%s\n' "$leftover" | sed 's/^/  /')"
}

# macOS ships shasum, most Linux images ship sha256sum. Support both so the
# fetch/rehash path works on the ubuntu runner.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Rewrite KEY=value in place without relying on sed -i, whose syntax differs
# between BSD and GNU. Writes through the existing file to keep mode and inode.
set_kv() {
  local key="$1" val="$2" file="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    BEGIN { FS = "=" }
    $1 == k { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

gh_api() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sfL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1"
  else
    curl -sfL "$1"
  fi
}

# Newest non-prerelease tag for a repo. /releases/latest already excludes
# prereleases, which is what keeps GUI builds like v1.0.7-1 out of the pins.
latest_tag() {
  gh_api "https://api.github.com/repos/$1/releases/latest" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# ------------------------------------------------------------ arg parsing -----

while [ $# -gt 0 ]; do
  case "$1" in
    --no-sign)          SIGN=0 ;;
    --rehash)           MODE="rehash" ;;
    --refresh)          MODE="refresh" ;;
    --keychain-profile) NOTARY_PROFILE="$2"; shift ;;
    --notary-key)       NOTARY_KEY="$2"; shift ;;
    --notary-key-id)    NOTARY_KEY_ID="$2"; shift ;;
    --notary-issuer)    NOTARY_ISSUER="$2"; shift ;;
    -h|--help)          usage 0 ;;
    *)                  printf 'error: unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
  shift
done

# --------------------------------------------------------- version pinning ----

[ -f "$VERSIONS_FILE" ] || die "missing $VERSIONS_FILE"
# shellcheck source=versions.env
. "$VERSIONS_FILE"

: "${CLAMAV_TAG:?not set in versions.env}"
: "${GUI_TAG:?not set in versions.env}"

derive_urls() {
  CLAMAV_VER="${CLAMAV_TAG#clamav-}"
  GUI_VER="${GUI_TAG#v}"

  CLAMAV_PKG_NAME="${CLAMAV_TAG}.macos.universal.pkg"
  CLAMAV_URL="https://github.com/${CLAMAV_REPO}/releases/download/${CLAMAV_TAG}/${CLAMAV_PKG_NAME}"
  CLAMAV_SIG_URL="${CLAMAV_URL}.sig"

  # Upstream names this asset without a version, so the cache filename gets the
  # version added -- otherwise two releases collide on one cache entry and a
  # stale bundle gets built.
  GUI_ARM64_ASSET="ClamAV.GUI_aarch64.app.tar.gz"
  GUI_ARM64_NAME="ClamAV.GUI_${GUI_VER}_aarch64.app.tar.gz"
  GUI_ARM64_URL="https://github.com/${GUI_REPO}/releases/download/${GUI_TAG}/${GUI_ARM64_ASSET}"
}
derive_urls

fetch() {
  local url="$1" dest="$2"
  info "downloading $(basename "$dest")"
  curl -fL --retry 3 --retry-delay 2 --no-progress-meter -o "${dest}.part" "$url" \
    || die "download failed: $url"
  mv "${dest}.part" "$dest"
}

fetch_verified() {
  local url="$1" dest="$2" want="$3" got
  if [ -f "$dest" ]; then
    got="$(sha256 "$dest")"
    if [ "$got" = "$want" ]; then
      info "cached   $(basename "$dest")"
      return 0
    fi
    rm -f "$dest"
  fi
  fetch "$url" "$dest"
  got="$(sha256 "$dest")"
  [ "$got" = "$want" ] || die "sha256 mismatch for $(basename "$dest")
  expected  $want
  actual    $got
If you just bumped a tag in versions.env, or upstream re-cut the asset, run:
  $0 --rehash"
}

# --rehash keeps whatever tags are in versions.env and recomputes only the
# hashes. --refresh resolves the newest release first, then rehashes. Renovate
# picks the tag, so its PRs use --rehash -- --refresh would fight that choice.
do_rehash() {
  need curl awk mktemp
  mkdir -p "$CACHE"
  derive_urls

  log "rehashing pins for ${CLAMAV_TAG} / ${GUI_TAG}"
  local pairs=(
    "CLAMAV_SHA256|$CLAMAV_URL|$CACHE/$CLAMAV_PKG_NAME"
    "GUI_ARM64_SHA256|$GUI_ARM64_URL|$CACHE/$GUI_ARM64_NAME"
  )
  local entry key url dest sum
  for entry in "${pairs[@]}"; do
    IFS='|' read -r key url dest <<<"$entry"
    [ -f "$dest" ] || fetch "$url" "$dest"
    sum="$(sha256 "$dest")"
    set_kv "$key" "$sum" "$VERSIONS_FILE"
    info "$key=$sum"
  done

  log "versions.env updated"
}

do_refresh() {
  need curl awk mktemp
  log "resolving latest releases"

  local new_clamav new_gui
  new_clamav="$(latest_tag "$CLAMAV_REPO")" || die "could not resolve $CLAMAV_REPO"
  new_gui="$(latest_tag "$GUI_REPO")"       || die "could not resolve $GUI_REPO"
  [ -n "$new_clamav" ] || die "empty tag for $CLAMAV_REPO"
  [ -n "$new_gui" ]    || die "empty tag for $GUI_REPO"

  info "clamav   ${CLAMAV_TAG} -> ${new_clamav}"
  info "clamavgui ${GUI_TAG} -> ${new_gui}"

  set_kv CLAMAV_TAG "$new_clamav" "$VERSIONS_FILE"
  set_kv GUI_TAG    "$new_gui"    "$VERSIONS_FILE"
  CLAMAV_TAG="$new_clamav"
  GUI_TAG="$new_gui"

  do_rehash
}

case "$MODE" in
  rehash)  do_rehash;  exit 0 ;;
  refresh) do_refresh; exit 0 ;;
esac

# ------------------------------------------------------------- 1. preflight ---

[ "$(uname -s)" = "Darwin" ] || die "building the package requires macOS"
need curl tar clang pkgutil pkgbuild productbuild productsign lipo codesign \
     xcrun awk mktemp xmllint
[ -x /usr/libexec/PlistBuddy ] || die "missing /usr/libexec/PlistBuddy"
for t in postinstall.in uninstall.sh.in freshclam.plist.in README-licensing.txt.in \
         launcher.c; do
  [ -f "$TEMPLATES/$t" ] || die "missing template: templates/$t"
done

[ -f "$VERSION_FILE" ] || die "missing $VERSION_FILE (owned by release-please)"
SUITE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$SUITE_VERSION" ] || die "$VERSION_FILE is empty"

: "${CLAMAV_SHA256:?not set in versions.env -- run --rehash}"
: "${GUI_ARM64_SHA256:?not set in versions.env -- run --rehash}"

SIGN_APP=""
SIGN_INSTALLER=""
if [ "$SIGN" -eq 1 ]; then
  [ -n "$TEAM_ID" ] || die "TEAM_ID is not set. Either export it, e.g.
  TEAM_ID=ABCDE12345 $0
or build without signing for testing:
  $0 --no-sign"

  # The trailing `|| true` must stay: grep exits 1 when it matches nothing,
  # pipefail propagates that, and `set -e` would then kill the script on the
  # assignment below -- silently, with exit 1 and no output, before reaching the
  # die messages that explain what is actually missing.
  find_identity() {
    security find-identity -v 2>/dev/null \
      | sed -n 's/.*"\(.*\)".*/\1/p' \
      | grep -F "$1" | grep -F "($TEAM_ID)" | head -1 || true
  }
  SIGN_APP="$(find_identity 'Developer ID Application')"
  SIGN_INSTALLER="$(find_identity 'Developer ID Installer')"

  [ -n "$SIGN_APP" ] || die "no 'Developer ID Application' identity for team ${TEAM_ID} in the keychain.
Available identities:
$(security find-identity -v 2>/dev/null | sed 's/^/  /')"
  [ -n "$SIGN_INSTALLER" ] || die "no 'Developer ID Installer' identity for team ${TEAM_ID} in the keychain.
Available identities:
$(security find-identity -v 2>/dev/null | sed 's/^/  /')"

  info "app cert       $SIGN_APP"
  info "installer cert $SIGN_INSTALLER"
else
  log "--no-sign: building an unsigned package (not deployable)"
fi

OUT="$OUT_DIR/clamav-suite-${SUITE_VERSION}.pkg"
mkdir -p "$CACHE" "$OUT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/components" \
         "$WORK/gui-root/Applications" \
         "$WORK/gui-root/Library/LaunchDaemons" \
         "$WORK/scripts"

log "suite ${SUITE_VERSION}  (clamav ${CLAMAV_VER}, gui ${GUI_VER})"
info "work dir: $WORK"

# ----------------------------------------------------- 2. fetch and verify ----

log "fetching upstream artifacts"
fetch_verified "$CLAMAV_URL"    "$CACHE/$CLAMAV_PKG_NAME" "$CLAMAV_SHA256"
fetch_verified "$GUI_ARM64_URL" "$CACHE/$GUI_ARM64_NAME"  "$GUI_ARM64_SHA256"

# Cisco's detached GPG signature is belt-and-braces on top of the pinned hash.
# Skipped rather than fatal when gpg or the Talos key is absent, since the hash
# pin is the control we actually depend on.
if command -v gpg >/dev/null 2>&1; then
  [ -f "$CACHE/${CLAMAV_PKG_NAME}.sig" ] \
    || fetch "$CLAMAV_SIG_URL" "$CACHE/${CLAMAV_PKG_NAME}.sig" || true
  if gpg --verify "$CACHE/${CLAMAV_PKG_NAME}.sig" \
                  "$CACHE/$CLAMAV_PKG_NAME" >/dev/null 2>&1; then
    info "gpg      vendor signature verified"
  else
    info "gpg      skipped (Talos signing key not in keyring)"
  fi
else
  info "gpg      skipped (gpg not installed)"
fi

# ---------------------------------------------------- 3. stage the GUI --------
# This fleet is Apple Silicon only, so the arm64 build is used exactly as
# shipped. The Distribution restricts hostArchitectures to arm64 (stage 10) so an
# Intel Mac refuses the package at install time instead of installing a GUI that
# cannot launch -- Cisco's CLI is universal, so without that restriction the
# install would succeed and only the GUI would be broken.
#
# Of the two arm64 artifacts upstream publishes, the .app.tar.gz is used in
# preference to the .dmg because it extracts directly, with no disk image to
# attach and detach and therefore no mount lifecycle to leak on a failure path.
# It is Tauri's updater artifact, and its bundle is byte-for-byte identical to
# the one inside the DMG; the pinned sha256 fails the build if that ever stops
# being true.

log "staging the GUI"
tar xzf "$CACHE/$GUI_ARM64_NAME" -C "$WORK/gui-root/Applications"
STAGED="$WORK/gui-root/Applications/$GUI_APP_NAME"
[ -d "$STAGED" ] || die "no $GUI_APP_NAME inside $GUI_ARM64_NAME"
chmod -R u+w "$STAGED"
xattr -cr "$STAGED"

list_machos() {
  find "$1" -type f -print0 \
    | while IFS= read -r -d '' f; do
        if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then printf '%s\n' "$f"; fi
      done
}

# Asserted because signing depends on it: nested code must be signed
# inner-to-outer, and silently skipping that yields a bundle which fails
# notarization or trips Gatekeeper on the device rather than here.
MACHOS="$(list_machos "$STAGED")"
MACHO_COUNT="$(printf '%s\n' "$MACHOS" | grep -c . || true)"
if [ "$MACHO_COUNT" -ne 1 ]; then
  die "expected exactly 1 Mach-O in the GUI bundle, found ${MACHO_COUNT}:
$(printf '%s\n' "$MACHOS" | sed 's/^/  /')
Nested code needs signing inner-to-outer. Rework stages 3 and 4."
fi

REL_MACHO="${MACHOS#"$STAGED"/}"
ARCHS="$(lipo -archs "$STAGED/$REL_MACHO" 2>/dev/null || echo unknown)"
case "$ARCHS" in
  *arm64*) : ;;
  *) die "the GUI binary is '$ARCHS', which contains no arm64 slice.
Wrong asset pinned in versions.env?" ;;
esac
info "staged   $REL_MACHO ($ARCHS)"

# ------------------------------------------- 4. install the launcher ----------
# The GUI shells out to bare `clamscan`, and launchd hands GUI apps
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, which does not include Cisco's
# /usr/local/clamav/bin. Without a fix the app shows its "no ClamAV" state-gate
# screen and is unusable.
#
# The fix is a compiled launcher installed as the bundle's main executable: it
# prepends the CLI directory to PATH and execs the real binary, renamed
# alongside it. Setting PATH inside the process is the only approach that cannot
# be overridden by whatever the launch supplies.
#
# Two approaches that look simpler do not work, and are worth not re-trying:
#   - LSEnvironment in Info.plist supplies only variables the launch does not
#     already provide, and launchd always provides a PATH, so it is ignored.
#   - A shell script cannot be the main executable: launchd refuses to spawn a
#     non-Mach-O one, failing with "Launchd job spawn failed".

REAL_BINARY="$(basename "$REL_MACHO")-bin"
LAUNCHER_SRC="$WORK/launcher.c"
render launcher.c "$LAUNCHER_SRC"

mv "$STAGED/$REL_MACHO" "$STAGED/$(dirname "$REL_MACHO")/$REAL_BINARY"
clang -arch arm64 -O2 -Wall -Werror \
      -mmacosx-version-min=11.0 \
      -o "$STAGED/$REL_MACHO" "$LAUNCHER_SRC" \
  || die "failed to compile the launcher"

# Checked statically rather than by running it: executing the launcher would exec
# the real binary and open the GUI in the middle of a build.
LAUNCHER_ABS="$STAGED/$REL_MACHO"
REAL_ABS="$STAGED/$(dirname "$REL_MACHO")/$REAL_BINARY"
[ -x "$REAL_ABS" ] || die "the real binary is missing at $REAL_ABS after the rename"
file -b "$LAUNCHER_ABS" | grep -q 'Mach-O' \
  || die "the compiled launcher is not Mach-O; launchd would refuse to spawn it"
strings -a "$LAUNCHER_ABS" | grep -qF "$REAL_BINARY" \
  || die "the launcher does not reference ${REAL_BINARY}; placeholder substitution failed"
strings -a "$LAUNCHER_ABS" | grep -qF "${CLAMAV_DIR}/bin" \
  || die "the launcher does not reference ${CLAMAV_DIR}/bin"
info "launcher $REL_MACHO -> $REAL_BINARY ($(lipo -archs "$LAUNCHER_ABS"))"

PLIST="$STAGED/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$PLIST" 2>/dev/null || echo "$GUI_VER")"

# The vendor bundle is adhoc/linker-signed and carries no entitlements, so the
# signature is replaced outright rather than adjusted. Signing with a Developer
# ID also gives the app a stable designated requirement, which is what the Apple
# Business PPPC entry is keyed to.
#
# Order matters: the real binary is nested code and must be signed before the
# launcher that execs it, and both before the bundle that seals them. Signing
# outside-in leaves an inner signature the outer seal does not cover, which
# fails notarization or trips Gatekeeper on the device rather than here.
log "signing the GUI"
if [ "$SIGN" -eq 1 ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$REAL_ABS"
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$LAUNCHER_ABS"
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$STAGED"
  codesign --verify --deep --strict --verbose=2 "$STAGED"
else
  # Renaming the binary and adding the launcher invalidated the vendor
  # signature; adhoc re-sign so the staged bundle is internally consistent.
  codesign --force --options runtime --sign - "$REAL_ABS" >/dev/null 2>&1
  codesign --force --options runtime --sign - "$LAUNCHER_ABS" >/dev/null 2>&1
  codesign --force --sign - "$STAGED" >/dev/null 2>&1
  info "adhoc signed (--no-sign)"
fi

# -------------------------------------------------- 5. freshclam daemon -------
# A launchd job rather than `freshclam -d`: survives crashes, no PID file to go
# stale, and launchd owns the scheduling.
#
# StartCalendarInterval fires weekly, Sunday at 00:00 (Weekday 0 is Sunday).
# RunAtLoad is kept deliberately as the catch-up: if the Mac is asleep at the
# window launchd fires the job on wake, but a machine powered off across the
# whole window can otherwise go a fortnight on stale definitions. RunAtLoad
# costs one quick check per boot and closes that gap. Drop it if you want the
# schedule to be strictly weekly -- the postinstall already does the initial
# pull, so a fresh install is not left without definitions either way.

DAEMON_PLIST="$WORK/gui-root/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
render freshclam.plist.in "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

# ------------------------------------------------------ 6. postinstall -------
# Runs as root at MDM check-in with no console user. Therefore: no osascript, no
# stdin reads, no assumptions about a logged-in session. Deliberately never
# exits non-zero on a transient network failure -- an offline device or a
# TLS-inspecting proxy must not fail the whole install.



render postinstall.in "$WORK/scripts/postinstall"
chmod 755 "$WORK/scripts/postinstall"

# The repo is public and this ships a modified GPL-3.0 bundle, so carry the
# upstream licence alongside it.
mkdir -p "$WORK/gui-root${SUPPORT_DIR}"
render README-licensing.txt.in "$WORK/gui-root${SUPPORT_DIR}/README-licensing.txt"

# ------------------------------------- 7. unwrap the vendor distribution -----
# Done before our own component is built because the uninstaller needs Cisco's
# receipt identifiers baked in, and they are only knowable from here. Reading
# them out of PackageInfo rather than hardcoding com.cisco.ClamAV.* means the
# uninstaller keeps working if Cisco ever renames or re-splits its components.

log "expanding the vendor package"
pkgutil --expand "$CACHE/$CLAMAV_PKG_NAME" "$WORK/vendor"

VENDOR_COMPONENTS=()
VENDOR_RECEIPTS=()
for c in "$WORK/vendor"/*.pkg; do
  [ -d "$c" ] || continue
  name="$(basename "$c")"
  pkgutil --flatten "$c" "$WORK/components/$name"
  VENDOR_COMPONENTS+=("$name")

  # xpath rather than a regex: PackageInfo carries several identifier=
  # attributes (the payload bundle has one too) and a greedy match grabs the
  # wrong one.
  vid="$(xmllint --xpath 'string(/pkg-info/@identifier)' "$c/PackageInfo" 2>/dev/null || true)"
  [ -n "$vid" ] || die "could not read the receipt identifier from $name"
  VENDOR_RECEIPTS+=("$vid")
  info "component $name  ($vid)"
done

[ "${#VENDOR_COMPONENTS[@]}" -gt 0 ] || \
  die "no components found -- is $CLAMAV_PKG_NAME a distribution package?"

# ------------------------------------------------- 8. the uninstaller ---------
# macOS flat packages have no removal semantics -- `installer` has no uninstall
# verb, and unassigning the package from a Blueprint leaves it installed. So the
# only way a machine can be cleaned up is a script that ships inside the payload.

RECEIPTS="${VENDOR_RECEIPTS[*]} ${GUI_COMPONENT_ID}"
render uninstall.sh.in "$WORK/gui-root${SUPPORT_DIR}/uninstall.sh"
chmod 755 "$WORK/gui-root${SUPPORT_DIR}/uninstall.sh"
bash -n "$WORK/gui-root${SUPPORT_DIR}/uninstall.sh" \
  || die "the generated uninstaller is not valid bash"
info "uninstaller ${SUPPORT_DIR}/uninstall.sh  (receipts: ${RECEIPTS})"

# ------------------------------------------- 9. build the GUI component ------
# --ownership recommended lands the payload root:wheel. That is deliberate: it
# is what stops a standard user's Tauri self-updater from replacing our signed
# universal build with the vendor's adhoc thin one.

# The component is versioned with the APP's version, not the suite's. A
# component version should describe the payload it delivers, and pkgbuild
# already records the bundle at $APP_VERSION in PackageInfo -- claiming a
# different number for the component itself makes the receipt disagree with the
# bundle it installed. It also means the receipt, the installed app, and the
# Version field in Apple Business all report one number instead of three, which
# is what any install-state check on the device will be comparing.
# The suite version stays on the distribution (stage 10).
log "building the GUI component"
pkgbuild --root "$WORK/gui-root" \
         --scripts "$WORK/scripts" \
         --identifier "$GUI_COMPONENT_ID" \
         --version "$APP_VERSION" \
         --ownership recommended \
         --install-location / \
         "$WORK/components/zz-clamav-gui.pkg" >/dev/null

# ---------------------------------------- 10. assemble the distribution ------
# Order is explicit rather than glob-dependent: the vendor components install
# first so the CLI exists on disk before our postinstall runs freshclam.

PKG_ARGS=()
for name in "${VENDOR_COMPONENTS[@]}"; do
  PKG_ARGS+=(--package "$WORK/components/$name")
done
PKG_ARGS+=(--package "$WORK/components/zz-clamav-gui.pkg")

log "synthesizing the distribution"
productbuild --synthesize \
             --identifier "$SUITE_ID" \
             "${PKG_ARGS[@]}" \
             "$WORK/Distribution" >/dev/null

# --synthesize emits a bare skeleton with hostArchitectures="x86_64,arm64". Add
# a title so the installer UI is not blank, pin the install to the system domain
# (the only domain an MDM install uses), and narrow hostArchitectures to arm64.
#
# That last one matters: Cisco's CLI is universal but the GUI is arm64-only, so
# without it an Intel Mac installs the package successfully and then the GUI
# fails to launch with no explanation. Restricting it turns that into a clean
# refusal at install time.
awk '
  /<installer-gui-script/ && !titled {
    print
    print "    <title>ClamAV Suite</title>"
    print "    <domains enable_anywhere=\"false\" enable_currentUserHome=\"false\" enable_localSystem=\"true\"/>"
    titled = 1
    next
  }
  /<options / {
    sub(/hostArchitectures="[^"]*"/, "hostArchitectures=\"arm64\"")
    if ($0 !~ /hostArchitectures=/) sub(/\/>$/, " hostArchitectures=\"arm64\"/>")
    print
    next
  }
  { print }
' "$WORK/Distribution" > "$WORK/Distribution.patched"
mv "$WORK/Distribution.patched" "$WORK/Distribution"

grep -q 'hostArchitectures="arm64"' "$WORK/Distribution" \
  || die "failed to restrict hostArchitectures to arm64 in the Distribution"

log "building the distribution package"
BUILD_ARGS=(--distribution "$WORK/Distribution"
            --package-path "$WORK/components"
            --version "$SUITE_VERSION")
[ "$SIGN" -eq 1 ] && BUILD_ARGS+=(--sign "$SIGN_INSTALLER")
productbuild "${BUILD_ARGS[@]}" "$OUT" >/dev/null

# ---------------------------------------------- 11. notarize and staple ------

if [ "$SIGN" -eq 1 ]; then
  log "notarizing (waits on Apple, can take 15+ minutes)"
  if [ -n "$NOTARY_KEY" ]; then
    xcrun notarytool submit "$OUT" \
      --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
  xcrun stapler staple "$OUT"
  pkgutil --check-signature "$OUT"
else
  log "--no-sign: skipping notarization"
fi

# ------------------------------------- 12. values for the Apple Business UI ---

HASH="$(sha256 "$OUT")"

# codesign prints the requirement as "# designated => ..." -- the leading "# "
# is easy to miss and silently yields an empty string, which would leave the
# PPPC profile with no code requirement at all. Guard rather than trust it.
REQUIREMENT="$(codesign -display -r - "$STAGED" 2>/dev/null |
    sed -n 's/^[#[:space:]]*designated => //p')"
if [ -z "$REQUIREMENT" ]; then
  if [ "$SIGN" -eq 1 ]; then
    die "could not read the designated requirement from the signed app.
The Apple Business PPPC entry cannot be built without it. Check:
  codesign -display -r - '$STAGED'"
  fi
  REQUIREMENT="(unavailable -- built with --no-sign)"
fi
ASSET_URL="https://github.com/pelotech/compliance-tools/releases/download/clamav-suite-v${SUITE_VERSION}/$(basename "$OUT")"

summary() {
cat <<SUMMARY
Built: $OUT
  suite ${SUITE_VERSION} | clamav ${CLAMAV_VER} | gui ${GUI_VER}

Apple Business > Devices > macOS Packages
----------------------------------------------------------------
Name        ClamAV Suite
URL         $ASSET_URL
Hash        $HASH
Bundle ID   $BUNDLE_ID
Version     $APP_VERSION

  NOTE: "Version" is the *app* CFBundleShortVersionString (${APP_VERSION}),
  not the suite version (${SUITE_VERSION}). Per Apple's documentation it is
  optional and display-only -- what users see in the Apple Business app. It
  is NOT used to detect an existing install, so do not expect bumping it to
  trigger anything. Redeployment is driven by changing URL + Hash above.

Add permissions
  System Policy All Files -> Allow
  Bundle ID: $BUNDLE_ID
  Code requirement:
    $REQUIREMENT

Add Items  (background item; stops users disabling the updater)
  Type:  Service Label
  Value: $DAEMON_LABEL

Hosting: HTTPS, no authentication, direct download (not a landing page), and
a URL unique to this version. A new build needs a new URL and a new hash.
----------------------------------------------------------------

Uninstalling
  sudo ${SUPPORT_DIR}/uninstall.sh --dry-run   # preview
  sudo ${SUPPORT_DIR}/uninstall.sh             # remove

macOS packages have no removal semantics of their own -- installer has no
uninstall verb. On macOS 26+ declarative app management can remove an app
bundle in /Applications, but that leaves ${CLAMAV_DIR}, the definition
database, the LaunchDaemon, the seeded configs and logs, and per-user state
behind. Unassigning from a Blueprint is not an uninstall either way.

The script above ships inside the payload so a machine can be cleaned up
without this repo and without MDM. It removes all of the above plus the Full
Disk Access grant and these receipts:
  ${RECEIPTS}

Residual risk: the GUI's Tauri self-updater is active and points at
$GUI_REPO. The payload is root:wheel, so a standard user cannot
complete an update, but an admin can -- which would replace this signed,
notarized build with the vendor's adhoc-signed one and invalidate the code
requirement above, silently breaking Full Disk Access.

Verify on a scratch machine before assigning to a Blueprint:
  sudo installer -verboseR -pkg "$OUT" -target /
  ${CLAMAV_DIR}/bin/clamscan --version
  sudo launchctl print "system/${DAEMON_LABEL}" | head
  pkgutil --pkgs | grep -i clamav
  lipo -archs "/Applications/${GUI_APP_NAME}/Contents/MacOS/clamav-gui"
  open "/Applications/${GUI_APP_NAME}"   # must NOT show the "no ClamAV" page
SUMMARY
}

printf '\n================================================================\n'
summary
printf '================================================================\n'

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '## ClamAV Suite %s\n\n```\n' "$SUITE_VERSION"
    summary
    printf '```\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
