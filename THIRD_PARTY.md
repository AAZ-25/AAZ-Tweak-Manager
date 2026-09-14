# Third-Party References

AAZ Tweak Manager is implemented independently. No third-party source code is copied into the project.

## Research references

- Debian APT documentation for manual/automatic package state, sources, authenticated repositories, downloads, and simulation behavior.
- Debian `dpkg-query` and `dpkg-deb` documentation was reviewed for reproducible installed-file enumeration, diversion output, package construction, extraction, and Rootless build cautions.
- Debian `dpkg-repack` and Twackup were reviewed as architectural references for reconstructing packages from the dpkg-owned file list while preserving symlinks. Their GPL source code is not copied, linked, or bundled; the app uses an independently implemented restricted pipeline.
- Sileo public source for Rootless command/APT path conventions and the persona-99 root-spawn entitlement contract. The implementation here was independently adapted to a single internally constructed package action; no Sileo source code was copied.
- IAmLazy by Lightmann as an ISC-licensed architectural reference for jailbreak package backup and restore. Its code was not incorporated.
- RootHide's public developer documentation and TrollStore's public documentation were reviewed for the container-preserving entitlement pattern used by unsandboxed jailbreak applications.
- LiveContainer's public File Picker repair and Erosion's public picker behavior were reviewed as evidence for copy-mode document selection. The repair here was implemented independently; no third-party source code was incorporated.

Apple, Debian, Twackup, Sileo, Zebra, Chariz, IAmLazy, RootHide, TrollStore, LiveContainer, and Erosion are not affiliated with or endorsing this project.
