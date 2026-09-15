# AAZ Tweak Manager

AAZ Tweak Manager is a Rootless jailbreak app for keeping a clean, portable record of the tweaks you chose to install through Sileo or Zebra.

## What it does

- Finds likely user-installed packages while keeping essential bootstrap and dependency packages out of the default selection.
- Lets you review the selection, search packages, and save reusable selection profiles.
- Always creates a useful `.aaztmbackup` inventory containing selected packages, required non-system dependencies, and sanitized sources. It becomes fully portable when a verified DEB is captured for every included package.
- Prefers the original exact DEB from the local cache or an authenticated repository, then safely repacks unchanged installed package files when the original is unavailable. No package-by-package sharing is required.
- Runs a privacy-safe synthetic system check before touching selected package data, including both independent staging paths, DEB build/reopen, an embedded-package Restore dry-run, archive integrity, and the shared import inbox. Staging uses root-relative enumeration that is unaffected by the iOS `/var` to `/private/var` alias, safely flattens Rootless directory redirections that contain listed package children, removes every transfer-created file or directory outside the exact dpkg inventory, then strictly verifies package-owned type, mode, size, content, and symlink targets before and after DEB creation. A failed self-check is reported at a fixed sub-stage but does not discard the safe inventory/source backup; independent package verification still decides whether each DEB can be embedded.
- Shows count-only backup progress with safe cancellation; cancellation removes temporary data and does not leave a partial backup.
- Keeps one privacy-safe current-build report for Backup, Import, Restore, and Environment in the Reports tab, with Share, Copy, and report-state clearing in one place. Activity history remains below it.
- Supports standard or password-encrypted backups. Passwords are never stored.
- Verifies the complete import path before an import is accepted: shared-inbox handoff, local staging, ZIP layout/CRC/footer/index, manifest schema, package/source hashes, duplicate detection, and atomic finalization. The synthetic preflight runs the same import/finalization path and removes its app-owned test data afterward. Limited backups remain usable as inventory and source records, while full offline Restore stays blocked until payload coverage reaches 100%.
- Binds Backup, Import, and Restore results independently to the current app build, so stored results from an older build are shown as not run. Failures open the same count-only report center without filenames, package identities, paths, repository URLs, passwords, or raw tool output.
- Imports from Files through **Share → Save to AAZ Tweak Manager**.
- Shows backup health, compares backups, and runs a guarded Restore Readiness check.
- Restores only missing packages and required upgrades, then merges missing sanitized public Source entries into their validated original source-list files after a separate final confirmation and immediate plan recheck. This keeps Sileo-managed entries inside `sileo.sources`, so normal add/remove behavior remains under Sileo's control. A source-only Restore is allowed when verified entries are genuinely pending; a true package-and-source no-op remains disabled.
- Keeps a private on-device activity history below the unified report without mixing it into report state.

## Compatibility

- iOS 15 or later
- Rootless jailbreak using `/var/jb`
- Sileo or Zebra with APT/dpkg
- `iphoneos-arm64`

Rootful and roothide environments are not supported by the current beta.

## Restore safety

Restore first checks package compatibility, protected and held packages, requested versions, exact package availability, and a removal-free APT simulation. If an exact repository version is unavailable, it may use only the matching DEB embedded in the inspected backup after verifying its archive entry, SHA-256, package ID, version, architecture, priority, and Essential status. DEB identity fields are queried individually through the same fixed, non-interactive execution environment used by Backup validation, so Backup and Restore enforce the same metadata boundary without parsing diagnostic output. Execution is never automatic: it requires a second explicit confirmation, repeats the full scan, payload verification, and simulation, and stops if the approved plan changed.

The executor can install missing packages and required upgrades only. It keeps newer installed versions and refuses removals, downgrades, protected or held packages, packages without a verified embedded DEB, additional unlisted dependency actions, and mixed repository/embedded plans. Original package archives are preferred. Automatic repacking is permitted only when the package owns no user-data file and `dpkg --verify` reports no modified packaged file. A package that fails those checks is omitted from the payload without discarding the inventory backup, and the backup is clearly marked as limited. Embedded-only execution requires only the verified `dpkg` tool, not repository access or `apt-get`. It performs a privileged dpkg no-action check before installing only the same verified DEB paths directly.

Before any package mutation, Restore validates each original APT destination against a strict path allowlist, verifies the sanitized payload hash, requires a regular existing file and writable parent, computes an additive merge that never removes newer entries, and binds the existing and merged hashes into the approved plan snapshot. It repeats that exact check immediately before execution and stops on drift. Writes use a verified atomic replacement of the package manager's own file, and every changed file has an app-owned rollback copy until the group succeeds. Sources containing private credentials remain skipped. Legacy `aaztm-<hash>` files from earlier betas are detected and can be moved—only after explicit confirmation—to a disabled recovery folder so they no longer override Sileo deletions. No Source content, path, or repository identity enters diagnostics.

The Rootless app uses a fixed persona-based package-manager launch boundary with the required persona/root-spawn entitlements. It never accepts a caller-supplied command. Restore failures are reduced to fixed privacy-safe codes and a numeric exit status; raw package-manager output, package identities, versions, and paths are not stored or shared.

## Privacy

Backups and diagnostics stay focused on the information needed by the tool. Repository credentials, passwords, tokens, account details, device identifiers, personal files, modified package files, user-data paths, and raw diagnostic paths are not included. Paid or private repositories require sign-in again after transfer.

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
