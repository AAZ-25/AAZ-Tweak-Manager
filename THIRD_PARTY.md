# Third-Party References

AAZ Tweak Manager is implemented independently. No third-party implementation source or executable binary is copied or bundled in the project.

## Research references

- Debian APT documentation for manual/automatic package state, sources, authenticated repositories, downloads, and simulation behavior.
- Debian `dpkg-query` and `dpkg-deb` documentation was reviewed for reproducible installed-file enumeration, diversion output, package construction, extraction, and Rootless build cautions.
- Debian `dpkg-repack` and Twackup were reviewed as architectural references for reconstructing packages from the dpkg-owned file list while preserving symlinks. Their GPL source code is not copied, linked, or bundled; the app uses an independently implemented restricted pipeline.
- Sileo public source for Rootless command/APT path conventions and the persona-99 root-spawn entitlement contract. The implementation here was independently adapted to a single internally constructed package action; no Sileo source code was copied.
- IAmLazy by Lightmann as an ISC-licensed architectural reference for jailbreak package backup and restore. Its code was not incorporated.
- RootHide's public developer documentation and TrollStore's public documentation were reviewed for the container-preserving entitlement pattern used by unsandboxed jailbreak applications.
- Apple's `NSItemProvider`, `NSFileCoordinator`, and App Groups documentation was reviewed for the Share Extension handoff, temporary provider-file copy, coordinated fallback read, and shared-container boundary. The implementation is independent and uses only public platform APIs for this handoff.

## Tools and system libraries

- Theos is used as the build system and is fetched only in the build environment. It is not included in the source tree or application package.
- APT/dpkg, GNU coreutils/diffutils, and `tar` are separately installed Rootless runtime tools declared by the package. Their source or binaries are not redistributed by this project.
- UIKit, Foundation, Security/CommonCrypto, and the platform-provided zlib are system SDK libraries. They are linked or called through their public platform interfaces and are not redistributed by this project.

Apple, Debian, Twackup, Sileo, IAmLazy, RootHide, TrollStore, and Theos are not affiliated with or endorsing this project.
