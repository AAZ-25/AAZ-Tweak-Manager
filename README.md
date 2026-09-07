# AAZ Tweak Manager

AAZ Tweak Manager is a rootless jailbreak app for reviewing and backing up packages that the user intentionally installed through APT frontends such as Sileo and Zebra.

## Current beta scope

- Shows manually installed package candidates while excluding automatic dependencies, essential packages, and protected bootstrap components.
- Lets the user correct the inferred personal-package selection. Confirmed choices are kept in a private local ledger.
- Reads installation dates from available `dpkg` logs. Missing historical data is reported as unknown rather than estimated.
- Backs up selected package metadata, sanitized APT source definitions, and exact cached `.deb` files when available.
- Produces a portable `.aaztmbackup` archive with a versioned JSON manifest and SHA-256 hashes for included package files.
- Lists and shares backups and requires confirmation before deleting one.
- Validates a backup and shows a restore preview.

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

Repository passwords, tokens, `auth.conf`, device identifiers, account details, and personal files are not included. Credential-bearing source URLs are redacted, so paid or private repositories may require sign-in again after transfer.

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
