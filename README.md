# compliance-tools

Deployable open-source tooling for compliance-heavy environments — the kind of place where a
control says "endpoints run anti-malware software" and the honest answer has to be evidence, not
intent.

The goal is to make the *free* option genuinely deployable. Plenty of good open-source security
software exists; what usually blocks it in a regulated environment isn't the software, it's the
packaging: an installer that isn't signed, an app that can't find its own CLI, a daemon nobody
configured, no way to remove it, and nothing an auditor can point at. Each tool here is packaged to
the same standard a commercial agent would be — signed, notarized, deployable by MDM, and
uninstallable — so that choosing the open-source option doesn't mean accepting a worse operational
story.

> **These are tools, not compliance.** Installing anti-malware does not satisfy a control on its
> own; you still need the policy that requires it, the enforcement that proves it is running, and
> the evidence trail. This repo is the deployment half of that work.

## Layout

```
mdm/
  clamav/                    ClamAV CLI + GUI as one signed macOS package for Apple Business
.github/workflows/
  pr.yml                     unsigned verification build; refreshes Renovate's checksum pins
  release.yml                release-please, then sign, notarize, staple, attach to the release
release-please-config.json   monorepo release config, one component per tool
.release-please-manifest.json  current version of each component
renovate.json                watches the upstream projects each tool bundles
```

`mdm/` holds things deployed to managed endpoints. The layout is a monorepo on purpose: each tool
gets its own version, changelog and release train, so adding a second one doesn't renumber the
first. Tags are namespaced by component, e.g. `clamav-suite-v1.0.2`.

## What's here

| Tool | Platform | What it packages |
|---|---|---|
| [`mdm/clamav`](mdm/clamav/) | macOS (Apple Silicon) | [ClamAV](https://github.com/Cisco-Talos/clamav) CLI and [ClamAV GUI](https://github.com/ArsenTech/clamav-gui) as one signed, notarized package, with a scheduled definition updater and an uninstaller |

Commonly mapped to anti-malware controls such as CIS macOS Benchmark §Antivirus, SOC 2 CC6.8,
PCI DSS Requirement 5, and HIPAA §164.308(a)(5)(ii)(B). Which controls a deployment actually
satisfies depends on your policy and evidence, not on this repo.

## Two ways to use this

**Use the published packages.** Every release attaches a signed, notarized package to its GitHub
release, ready to point an MDM at:

```
https://github.com/pelotech/compliance-tools/releases
```

The asset URL is direct-download, unauthenticated and unique per version, which is what Apple
Business Manager requires. Each build prints the exact values to enter — URL, sha256, bundle ID,
version, and the code requirement for the privacy-permissions entry.

**Or fork and build your own.** The build scripts are self-contained and take nothing on faith:
upstream artifacts are pinned by tag *and* sha256, and every build verifies them. Fork it, point
`versions.env` at the versions you want, and run the build. You get the same package, signed by
you.

Building your own is the better choice if you need to review what you deploy, pin different
upstream versions, change defaults such as the update schedule, or sign under your own identity so
the trust chain terminates at your organization rather than someone else's. Each tool's README
documents the credentials its build needs — for the macOS package that means an Apple Developer ID
and a notarization key, since a package that isn't signed by *someone* cannot be deployed by MDM at
all.

## Contributing

Conventional Commits, scoped to the tool: `fix(clamav): ...`. PRs touching a tool run its build
unsigned, which exercises everything except signing and notarization.

New tools go under the directory matching how they're deployed (`mdm/` for managed endpoints), with
their own `README.md`, and an entry added to `release-please-config.json` so they get an independent
version and changelog.

## Licensing

This repository's build tooling is separate from the licences of the software it packages, which
are unmodified upstream projects with their own terms — ClamAV is GPL-2.0 and ClamAV GUI is
GPL-3.0. Where a build modifies a bundled artifact, the package records exactly what changed and
which upstream release it came from; see the tool's README.
