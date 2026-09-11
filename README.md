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

Restore first checks package compatibility, protected and held packages, requested versions, repository availability, and a removal-free APT simulation. Execution is never automatic: it requires a second explicit confirmation, repeats the full scan and simulation, and stops if the approved plan changed.

The executor can install missing packages and required upgrades only. It keeps newer installed versions and refuses removals, downgrades, protected or held packages, unavailable metadata, insecure or unauthenticated repositories, and source changes. A count-only completion record is retained locally for recovery evidence without exposing package identities.

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
