# ClamAV Suite — macOS MDM package

Builds one signed, notarized distribution package containing:

- **ClamAV CLI** — [Cisco-Talos/clamav](https://github.com/Cisco-Talos/clamav), installed to `/usr/local/clamav`
- **ClamAV GUI** — [ArsenTech/clamav-gui](https://github.com/ArsenTech/clamav-gui), installed to `/Applications`
- A `freshclam` LaunchDaemon that refreshes definitions weekly, Sunday at 00:00

The output is intended for **Apple Business Manager → Devices → macOS Packages**.

## Why this is more than `productbuild --package`

Three properties of the upstream artifacts drive the build, and all three are load-bearing:

1. **The GUI resolves `clamscan` from `PATH` only.** A Finder-launched app inherits launchd's
   default `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), and Cisco installs to
   `/usr/local/clamav/bin`, which is on neither that nor any GUI-visible path. Without the
   `LSEnvironment` key this build injects into `Info.plist`, **every user lands on the GUI's
   "no ClamAV" state-gate screen** and the app is unusable. There is no configurable path
   setting in the app to use instead.
2. **There is no macOS `.pkg` upstream**, only per-arch archives. This fleet is Apple Silicon
   only, so the build takes the arm64 `.app.tar.gz` as shipped and restricts the Distribution's
   `hostArchitectures` to `arm64` — without that, an Intel Mac installs the package successfully
   (Cisco's CLI is universal) and then the GUI fails to launch with no explanation. The build
   asserts the bundle holds exactly one Mach-O, because nested code must be signed
   inner-to-outer and skipping that produces a bundle that fails notarization or trips Gatekeeper
   on the device rather than here.
3. **The vendor bundle is `adhoc, linker-signed` with no entitlements**, so it cannot be
   notarized as shipped and must be re-signed. Re-signing also gives the app a stable
   designated requirement, which is what the PPPC / Full Disk Access grant is keyed to.

Cisco ships a *distribution* pkg wrapping three component pkgs, and `productbuild --package`
only accepts components. The build expands the vendor pkg and re-flattens its components rather
than collapsing everything into one, so Cisco's three receipts and version metadata survive.

## Usage

```sh
# Full signed + notarized build. Certificates are discovered from the keychain.
TEAM_ID=ABCDE12345 ./build-clamav-suite.sh

# Everything except signing and notarization. Use this to test changes.
./build-clamav-suite.sh --no-sign

# Keep the tags in versions.env, recompute only the sha256 pins.
./build-clamav-suite.sh --rehash

# Resolve the newest non-prerelease of both upstreams, then rehash.
./build-clamav-suite.sh --refresh
```

Output lands in `out/`. Downloads are cached in `.cache/` and re-verified against
`versions.env` on every run, so a rebuild does not re-pull Cisco's ~166 MB pkg.

`--rehash` and `--refresh` need only `curl` and a sha256 tool, so they also run on Linux —
that is what lets the Renovate rehash job use `ubuntu-latest`.

### Two files own versions, and they are not the same number

| File | Owns | Bumped by |
|---|---|---|
| `versions.env` | Which upstream releases are bundled, plus their sha256 pins | Renovate, then CI's `--rehash` |
| `version.txt` | The suite's own semver, used as the pkg version | release-please |

The **"Version" field in Apple Business Manager** is neither of those — it is the *app's*
`CFBundleShortVersionString`, because that is what ABM compares against to detect an existing
install. The build prints the correct value and labels it explicitly.

## Automation

**Renovate** watches both upstreams via two custom managers in `renovate.json`. The tag
prefixes (`clamav-`, `v`) sit deliberately *outside* the capture groups so Renovate writes back
a correctly formatted tag; `extractVersionTemplate` makes the upstream tags comparable to the
bare version captured. GUI prereleases such as `v1.0.7-1` parse as semver prereleases and are
skipped.

Renovate cannot compute the new sha256 pins, so `.github/workflows/pr.yml` recomputes them with
`--rehash` and pushes onto the PR branch. The `verify` job is a *dependency* of that push rather
than a re-trigger, because a push made with `GITHUB_TOKEN` does not start new workflow runs.

**release-please** owns `version.txt` and the changelog, configured in monorepo manifest mode
with the component `clamav-suite`, so tags look like `clamav-suite-v1.2.0` and a future tool
under `mdm/` gets its own release train. On merge of a release PR,
`.github/workflows/release.yml` builds, signs, notarizes, staples, and attaches the pkg to the
GitHub release, then writes the ABM field values to the job summary.

> Release PRs opened by release-please with the default `GITHUB_TOKEN` do not trigger `pr.yml`.
> If you want the unsigned verification build to run on them too, swap in a GitHub App token.

## Certificates

Needed for any signed build, local or CI. Signing needs **two** certificates plus a notarization
key. They are easy to confuse with
similarly named certs that will not work:

| Needed | Signs | Not to be confused with |
|---|---|---|
| **Developer ID Application** | the `.app` bundle | `Apple Development` — local debug builds only |
| **Developer ID Installer** | the `.pkg` | `3rd Party Mac Developer Installer` — Mac **App Store** submission |
| **App Store Connect API key** (`.p8`) | notarization (not a certificate) | — |

Requires a **paid** Apple Developer Program membership, and on an organization account only the
**Account Holder** can create Developer ID certificates. They are team-wide with a per-team cap,
so check the portal before minting new ones and avoid churning them — revoking one can invalidate
signatures other people depend on.

**Check the expiry date; do not assume five years.** Developer ID certificates are nominally
issued for five years, but validity appears to be capped by the Apple Developer Program membership
expiry — two certs created minutes apart came back with an identical `notAfter`, roughly six
months out rather than five years. Verify with:

```sh
security find-certificate -c "Developer ID Application: <Org> (<TeamID>)" -p \
  | openssl x509 -noout -enddate
```

When they do expire, only **new builds** break. Already-distributed packages keep validating,
because the build signs with `--timestamp` (and `productsign` uses a timestamp authority), so
Gatekeeper accepts software that was signed while the certificate was valid. Renewal is therefore
a build-pipeline concern, not a fleet emergency — but it does mean a lapsed membership silently
blocks releases.

Apple issues these under the **registered legal entity name**, which may not be the name you
trade under. Expect `Developer ID Application: <Legal Entity> (<TeamID>)`, and expect the
designated requirement in the PPPC profile to reference that same legal name rather than the
product or trading name. That is correct and not something you can change.

**Install the current intermediates first.** This is the step that wastes an afternoon: a
keychain carrying only the original WWDR **G1** intermediate (expired 2023-02-07) cannot validate
certs issued by **G3**, so `security find-identity -v` reports `0 valid identities` while Xcode
cheerfully lists your certs. Developer ID certs additionally chain through **Developer ID CA G2**.

```sh
cd ~/Downloads
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer    # valid to 2030-02-20
curl -O https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer  # valid to 2031-09-17
security import AppleWWDRCAG3.cer   -k ~/Library/Keychains/login.keychain-db
security import DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db

security find-identity -v    # checkpoint: existing certs should now validate
```

Fix that checkpoint *before* creating Developer ID certs, or you will be debugging a broken trust
chain and a missing certificate at the same time.

Then, for each of the two types: Keychain Access → *Certificate Assistant* → **Request a
Certificate From a Certificate Authority** → upload the CSR at developer.apple.com → download and
double-click the `.cer`. Use a **fresh CSR for each** — reusing one would put both certificates on
a single private key. Xcode's *Manage Certificates* can also do this, but has historically not
offered the *Installer* type.

CSR field values, with *Request is: Saved to disk* and *Let me specify key pair information*
(RSA, 2048):

| Field | Value |
|---|---|
| User Email Address | the Apple ID email of the Account Holder |
| Common Name | `<Org> Developer ID Application` / `<Org> Developer ID Installer` |
| CA Email Address | leave blank (only used for *Emailed to the CA*) |

None of these appear in the issued certificate — Apple replaces the whole subject, so the result
is always `Developer ID Application: <Org> (<TeamID>)`. The Common Name's only lasting effect is
labelling the **private key** in your keychain, which is why the two should differ: you will later
export each key with its matching certificate, and two identically-labelled keys make it easy to
build a `.p12` that imports fine and then cannot sign.

```sh
security find-identity -v | grep 'Developer ID'   # expect exactly 2
```

**Export a `.p12` backup of each immediately.** The private key is generated locally and never
leaves the machine — lose it and the certificate is dead, costing you a slot to replace.

For notarization, create a **Team** key (not Individual) at App Store Connect → *Users and
Access* → *Integrations* → App Store Connect API; the *Developer* role is sufficient. Note the
Issuer ID and Key ID, and save the `.p8` — **it downloads only once**.

```sh
xcrun notarytool store-credentials notary \
  --key ~/AuthKey_XXXXXXXX.p8 --key-id KEYID --issuer ISSUER-UUID
```

## Required repository secrets

One repository **variable** (Settings → Secrets and variables → Actions → *Variables*):

| Variable | Purpose |
|---|---|
| `TEAM_ID` | Apple Developer team, used to select the certificates |

`TEAM_ID` is deliberately a variable rather than a secret. It is not sensitive — it is embedded in
every signed artifact and readable with `codesign -d` on any distributed pkg — and registering it
as a secret makes GitHub redact it from logs, which corrupts the designated-requirement string in
the build summary. A variable keeps it out of the repo just as effectively.

And seven **secrets**:

| Secret | Purpose |
|---|---|
| `DEVID_APP_P12_BASE64` | Developer ID **Application** cert + key, base64 of a `.p12` |
| `DEVID_INSTALLER_P12_BASE64` | Developer ID **Installer** cert + key, base64 of a `.p12` |
| `DEVID_APP_P12_PASSWORD` | Password for the Application `.p12` |
| `DEVID_INSTALLER_P12_PASSWORD` | Password for the Installer `.p12` |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API key, base64 of the `.p8` |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER` | API key issuer UUID |

The keychain password is generated per-run rather than stored, so it is not in this list. The
keychain is created in `RUNNER_TEMP` and deleted in an `always()` step.

Each `.p12` carries its own password, held in its own secret, so they do not need to match. After
importing, the workflow asserts both Developer ID identities are present in the keychain — a wrong
password and a `.p12` exported without its private key both surface as a missing identity, and
failing there is much cheaper than failing after a notarization wait. To produce the base64 values:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy   # DEVID_APP_P12_BASE64
base64 -i DeveloperIDInstaller.p12   | pbcopy   # DEVID_INSTALLER_P12_BASE64
base64 -i AuthKey_XXXXXXXX.p8        | pbcopy   # NOTARY_KEY_P8_BASE64
```

Export each `.p12` from Keychain Access by selecting the **private key** and its certificate
together — a `.p12` containing only the certificate imports without error and then fails to sign.

## Deploying

Values for **Apple Business Manager → Devices → macOS Packages** are printed at the end of
every build (and to the CI job summary). You need:

- **URL** — the release asset URL. Must be HTTPS, unauthenticated, a direct download rather
  than a landing page, and unique per version. A new build needs a new URL and a new hash.
- **Hash** — sha256 of the pkg.
- **Bundle ID** — `com.arsentech.clamav-gui`. Required. Note this is the **vendor's** app bundle
  identifier, not our package receipt id (`com.pelotech.clamav-gui`) or distribution id
  (`com.pelotech.clamav-suite`), both of which look plausible and are wrong.
- **Version** — the app's `CFBundleShortVersionString` (`1.0.6`), *not* the suite version.
  Per Apple's docs this field is **optional and display-only** — it is what users see in the
  Apple Business app, and is **not** used to detect an existing install. Bumping it triggers
  nothing. To redeploy a rebuilt package you update its **URL and Hash** (Devices > macOS
  Packages > select package > Updates > Update Package), which is why every build needs a
  version-unique URL.
- **Add permissions** — `System Policy All Files → Allow`, keyed to the bundle ID and the
  designated requirement from the build output. The GUI needs Full Disk Access to scan.
- **Add Items** — a Service Label background item for `com.pelotech.clamav.freshclam`, which
  stops users disabling the updater.

## Definition updates

`com.pelotech.clamav.freshclam` runs `freshclam` weekly via `StartCalendarInterval`, **Sunday at
00:00** (launchd's `Weekday 0` is Sunday). `RunAtLoad` is also set, so the job runs at boot and
at install. Logs go to `/var/log/freshclam.log`; the daemon's own stderr goes to
`/var/log/freshclam.err`.

Two things to know about this cadence:

- **Midnight Sunday is when laptops are closed.** If the Mac is asleep at the window, launchd
  fires the job on wake. If it is powered off across the whole window, that is less reliable —
  which is why `RunAtLoad` stays, so a boot closes the gap rather than the machine waiting until
  the following Sunday. Remove `RunAtLoad` if you want the schedule strictly weekly; the
  postinstall does the initial pull regardless, so a fresh install is never left with no
  definitions.
- **Weekly means definitions can be up to seven days stale.** ClamAV publishes updates several
  times a day, so this is a deliberate trade of freshness for bandwidth and quiet. Worth
  confirming it matches whatever your compliance baseline actually requires.

If the fleet grows, having every machine hit ClamAV's mirrors at exactly `00:00` is the
thundering-herd pattern the project's own guidance warns against. The fix is to spread the
`Minute` value per-machine when the postinstall writes the plist.

To change the schedule, edit the `StartCalendarInterval` dict in `build-clamav-suite.sh`
(stage 5) and rebuild — the plist is generated, not checked in.

## Uninstalling

macOS flat packages have **no removal semantics** of their own. `installer` has no uninstall
verb, and `pkgutil --forget` only discards receipt data — it removes no files, and doing it first
throws away the only record of what was installed.

MDM gives you a partial removal path, but only a partial one. Apple's deployment guide states
that with declarative app management (macOS 26 or later), "any app bundle which gets stored in
/Applications can become managed and can individually be removed by the device management service
using the remove application command." So `/Applications/ClamAV GUI.app` may be removable from
MDM on new enough systems. That command removes an **app bundle** — it will not touch
`/usr/local/clamav`, the ~250 MB definition database, the LaunchDaemon, the seeded configs, the
logs, or per-user state. Older guidance for package-installed apps is blunter: they "aren't
considered managed apps," so removing them from a collection leaves them installed.

Either way, unassigning from a Blueprint is not a substitute for uninstalling, which is why the
package ships its own uninstaller.

So the package ships its own uninstaller, generated at build time and installed alongside the
licensing record:

```sh
sudo /usr/local/share/clamav-suite/uninstall.sh --dry-run   # preview, changes nothing
sudo /usr/local/share/clamav-suite/uninstall.sh             # remove
sudo /usr/local/share/clamav-suite/uninstall.sh --keep-user-data
```

It is self-contained, so it works without this repo and without MDM, and it is shaped to run
as-is from an MDM script payload. It removes the payload, the definition database, the seeded
configs and logs that **no receipt tracks**, per-user GUI state across all home directories, the
Full Disk Access grant, and all four receipts. Cisco's receipt IDs are read out of each
component's `PackageInfo` at build time rather than hardcoded, so it keeps working if Cisco
renames or re-splits its components.

Two implementation details carry more weight than they look like they do:

1. **The self-relocation runs before argument parsing.** The script lives in a directory it
   deletes, and bash reads scripts incrementally rather than all at once, so it copies itself to
   a temp file and re-execs from there. That must happen *before* the parse loop, because the
   loop consumes `$@` via `shift` — re-exec afterwards passes an empty argument list, which
   silently resets `--dry-run` and turns a preview into a real uninstall. Relocating first leaves
   no parsed state to carry across the re-exec.
2. **`remove()` refuses broad paths.** Every path is built from build-time substitutions, so a
   bad or empty placeholder would aim `rm -rf` somewhere catastrophic. `/`, `/usr/local`,
   `/Applications`, relative paths, and single-component paths are all rejected and counted as
   failures.

## Verification

```sh
sudo installer -verboseR -pkg out/clamav-suite-*.pkg -target /
/usr/local/clamav/bin/clamscan --version
sudo launchctl print system/com.pelotech.clamav.freshclam | head
pkgutil --pkgs | grep -i clamav          # 3 Cisco receipts + com.pelotech.clamav-gui
lipo -archs "/Applications/ClamAV GUI.app/Contents/MacOS/clamav-gui"   # arm64
ls -ld "/Applications/ClamAV GUI.app"    # root:wheel
ls -a "/Applications/ClamAV GUI.app/Contents" | grep '^\._' || echo "no AppleDouble litter"
```

Then **launch it from Finder** — not from a terminal, since `LSEnvironment` only applies to
LaunchServices launches — and confirm it does *not* show the "no ClamAV" page, and that a scan
runs to completion.

## Known constraints

- **`LSEnvironment` is LaunchServices-only.** Running the binary directly from a shell will
  still hit the "no ClamAV" page. Not a concern for deployed use.
- **An admin user can still self-update the GUI.** The Tauri updater is active and points at
  the vendor's releases. The payload is `root:wheel`, so a standard user cannot complete an
  update, but an admin can — which replaces the signed build with the vendor's adhoc one and
  invalidates the designated requirement, silently breaking Full Disk Access.
  Re-push from MDM if that happens. Hard-blocking the updater would mean patching its endpoint
  out of the binary, which is tampering the build deliberately avoids.
- **Full Disk Access and the spawned child.** TCC attributes a child process to the responsible
  process, so FDA on the GUI should cover the `clamscan` it spawns. Confirm on a scratch machine
  before assigning a Blueprint — a silent FDA failure looks exactly like a clean scan.
- **`._` AppleDouble entries in the payload.** macOS 14+ stamps an unremovable
  `com.apple.provenance` xattr on every file, which `pkgbuild` encodes as AppleDouble
  companions; `xattr -cr` and `ditto --noextattr` cannot strip it. The installer consumes these
  as metadata rather than writing literal files — the verification step above checks that.

## Licensing

The GUI is GPL-3.0 and this build distributes a **modified** bundle. The modifications are the
added `LSEnvironment` key and the re-signature — no executable code is altered.
`/usr/local/share/clamav-suite/README-licensing.txt` ships in the payload recording the exact
upstream tags and every modification made; `build-clamav-suite.sh` is the public record of how
they are applied.

## Apple Silicon only

The build targets `arm64` alone, which keeps it simple: one artifact to download, no architecture
reconciliation, and no disk image to attach and detach — the `.app.tar.gz` extracts directly, and
its bundle is byte-identical to the one inside the `.dmg`.

Adding Intel support would mean pinning the `x86_64` DMG as a second artifact, mounting both
bundles and asserting they differ only in their single Mach-O, merging that binary with `lipo`,
and widening `hostArchitectures` in the distribution.
