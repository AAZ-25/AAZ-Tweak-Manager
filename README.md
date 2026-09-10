# AAZ Tweak Manager

AAZ Tweak Manager is a rootless jailbreak app for reviewing and backing up packages that the user intentionally installed through APT frontends such as Sileo and Zebra.

## Current beta scope

- Shows manually installed package candidates while excluding automatic dependencies, essential packages, and protected bootstrap components.
- Lets the user correct the inferred personal-package selection. Confirmed choices are kept in a private local ledger.
- Searches the shown package list and provides `Select All` and `Unselect All` actions scoped to the current results.
- Saves bulk selection changes in one ledger update and confirms destructive bulk deselection.
- Confirms the exact selected-package and sanitized-source counts before creating a backup.
- Shows a clear in-progress state and reports the package, source, and cached-DEB totals after creation.
- Reads installation dates from available `dpkg` logs. Missing historical data is reported as unknown rather than estimated.
- Backs up selected package metadata, sanitized APT source definitions, and exact cached `.deb` files when available.
- Produces a portable `.aaztmbackup` archive with a versioned JSON manifest and SHA-256 hashes for included package files.
- Lists backups with human-readable dates and package, source, and cached-DEB totals.
- Validates a backup and shows a count-based compatibility summary without exposing a long raw identifier list.
- Presents a local activity timeline with readable package/backup events, date sections, filters, and safe history clearing.
- Writes backups atomically through a private partial file, validates archive structure and CRC values, then exposes the final file only after success.
- Inspects backup health, verifies cached-DEB SHA-256 hashes, and reports migration readiness using counts rather than public package identities.
- Imports through a dedicated iOS Share Extension that materializes the selected Files item into a private shared container before the app performs protected staging and integrity validation. Duplicate archives are rejected.
- Compares standard backups using Added, Removed, Updated, and Unchanged counts.
- Supports reusable local selection profiles with a dedicated Load/Rename/Duplicate/Delete manager, plus backup search, size-aware sorting, and pinning.
- Shows the installed Version and Build in Settings and keeps the empty History presentation centered and easy to read.
- Optionally encrypts the complete archive with AES-256-CBC, PBKDF2-HMAC-SHA256 key derivation, and encrypt-then-MAC authentication. Passwords are never stored.

The current beta intentionally does not install, remove, or restore packages. Restore execution will be added only after archive, compatibility, dependency, and transaction behavior are verified on a real jailbroken device.

## Compatibility

- iOS 15 or later
- Rootless jailbreak with the `/var/jb` layout
- Sileo or Zebra backed by APT/dpkg
- `iphoneos-arm64`

Rootful and roothide environments are not supported by the current beta.

## Backup contents

Each backup can contain:

- Package ID, name, installed version, architecture, section, dependencies, and classification evidence
- Exact installation time when recoverable from local package logs
- Sanitized `.list` and `.sources` files, including disabled entries
- Exact cached `.deb` payloads and SHA-256 hashes when present

Repository passwords, backup passwords, tokens, `auth.conf`, device identifiers, detailed device-environment fields, account details, and personal files are not included. Credential-bearing source URLs are redacted, so paid or private repositories may require sign-in again after transfer.

## Build

The project uses Theos:

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

The permanent GitHub workflow is manual-only and builds an artifact without publishing a Release.

## Safety

AAZ Tweak Manager never treats a successful build or archive creation as proof that restoration is safe. A future restore engine must verify the jailbreak scheme, bootstrap, architecture, iOS compatibility, source availability, exact package versions, hashes, conflicts, and dependencies before showing a separately confirmed transaction.

## License

MIT. See `LICENSE` and `THIRD_PARTY.md`.

## Developer

[@_kkk2 on X](https://x.com/_kkk2)
