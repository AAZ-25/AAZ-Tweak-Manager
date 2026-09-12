# AAZ Tweak Manager

AAZ Tweak Manager is a Rootless jailbreak app for keeping a clean, portable record of the tweaks you chose to install through Sileo or Zebra.

## What it does

- Finds likely user-installed packages while keeping essential bootstrap and dependency packages out of the default selection.
- Lets you review the selection, search packages, and save reusable selection profiles.
- Creates one portable `.aaztmbackup` file containing package metadata, sanitized sources, and exact cached DEBs when available.
- Supports standard or password-encrypted backups. Passwords are never stored.
- Verifies archive integrity before an import is accepted.
- Imports from Files through **Share → Save to AAZ Tweak Manager**.
- Shows backup health, compares backups, and runs a guarded Restore Readiness check.
- Restores only missing packages and required upgrades after a separate final confirmation and an immediate plan recheck.
- Keeps a private on-device history of useful package and backup events.

## Compatibility

- iOS 15 or later
- Rootless jailbreak using `/var/jb`
- Sileo or Zebra with APT/dpkg
- `iphoneos-arm64`

Rootful and roothide environments are not supported by the current beta.

## Restore safety

Restore first checks package compatibility, protected and held packages, requested versions, exact package availability, and a removal-free APT simulation. If an exact repository version is unavailable, it may use only the matching DEB embedded in the inspected backup after verifying its archive entry, SHA-256, package ID, version, architecture, priority, and Essential status. Execution is never automatic: it requires a second explicit confirmation, repeats the full scan, payload verification, and simulation, and stops if the approved plan changed.

The executor can install missing packages and required upgrades only. It keeps newer installed versions and refuses removals, downgrades, protected or held packages, packages without exact repository metadata or a verified embedded DEB, insecure or unauthenticated repositories, additional dependency actions, mixed repository/embedded plans, and source changes. Repository authentication remains mandatory. An embedded-only plan may pass APT's local-package authentication gate only after every requested DEB has passed the app's exact cryptographic and package-identity checks. It uses APT only to simulate and verify the exact dependency/removal-free plan for those verified local archives, then requires a privileged dpkg no-action check before installing only the same verified DEB paths directly. Repository packages continue to use authenticated APT. Temporary embedded payloads are app-owned, size-limited, never shown in diagnostics, and removed after execution. A count-only completion record is retained locally for recovery evidence without exposing package identities.

The Rootless app uses a fixed persona-based package-manager launch boundary with the required persona/root-spawn entitlements. It never accepts a caller-supplied command. Restore failures are reduced to fixed privacy-safe codes and a numeric exit status; raw package-manager output, package identities, versions, and paths are not stored or shared.

## Privacy

Backups and diagnostics stay focused on the information needed by the tool. Repository credentials, passwords, tokens, account details, device identifiers, personal files, and raw diagnostic paths are not included. Paid or private repositories may require sign-in again after transfer.

## Build

The project uses Theos:

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

The permanent GitHub workflow is manual-only and builds an artifact without publishing a Release.

## License

MIT. See `LICENSE` and `THIRD_PARTY.md`.

## Developer

[@_kkk2 on X](https://x.com/_kkk2)
