#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]

required = [
    "Makefile", "control", "Resources/Info.plist",
    "Resources/AAZTweakManager.entitlements", "Resources/AppIcon60x60.png",
    "Resources/AppIcon60x60@2x.png", "Resources/AppIcon60x60@3x.png", "main.m",
    "App/ATMAppDelegate.m", "App/ATMViewControllers.m",
    "Core/ATMCore.m", "Core/ATMBackupManager.m", "Core/ATMZipWriter.m",
]
for relative in required:
    assert (ROOT / relative).is_file(), f"missing {relative}"

with (ROOT / "Resources/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.aaz.tweakmanager"
assert info["MinimumOSVersion"] == "15.0"
assert info["CFBundleVersion"] == "9"
assert info["LSSupportsOpeningDocumentsInPlace"] is True
assert info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"] == ["AppIcon60x60"]

control = (ROOT / "control").read_text()
assert "Package: com.aaz.tweakmanager" in control
assert "Architecture: iphoneos-arm64" in control
assert "Version: 0.1.0~beta9" in control
assert "Priority: optional" in control

excluded_directories = {".git", ".theos-build", "packages"}
public_files = [
    path for path in ROOT.rglob("*")
    if path.is_file()
    and not any(part in excluded_directories for part in path.relative_to(ROOT).parts)
]

all_text = "\n".join(
    path.read_text(errors="replace")
    for path in public_files
    if path != Path(__file__).resolve()
    and path.suffix.lower() not in {".png", ".jpg", ".jpeg"}
)

for forbidden in [
    r"apt(?:-get)?\s+.*\b(?:install|remove|purge|autoremove)\b",
    r"dpkg\s+(?:-i|--install|--remove|--purge)",
    r"--allow-remove-essential", r"--force-yes", r"--allow-unauthenticated",
    r"auth\.conf.*(?:copy|archive|backup)",
]:
    assert not re.search(forbidden, all_text, re.I), f"unsafe restore behavior: {forbidden}"

assert '@"restoreExecutionIncluded": @NO' in all_text
assert "credentials-redacted" in all_text
assert 'record.essential = essentialValue.length > 0 &&' in all_text
assert 'record.essential = [fields[@"Essential"]' not in all_text
assert "privacy=counts-and-stage-flags-only" in all_text
assert "AAZ-Tweak-Manager-Diagnostic.txt" in all_text
assert "Counts and stage flags only" in all_text
assert "Select All" in all_text
assert "Unselect All" in all_text
assert "Search packages" in all_text
assert "No matching packages" in all_text
assert "forPackageIDs" in all_text
assert "Create Backup?" in all_text
assert "Creating…" in all_text
assert "Backup Summary" in all_text
assert "Selection Updated" in all_text
assert "No Activity Yet" in all_text
assert "Clear History?" in all_text
assert "clearHistory" in all_text
assert "No changes are made" in all_text
assert 'cell.textLabel.text = item[@"event"]' not in all_text
assert '@"cachedDEBCount"' in all_text
assert "ATMValidateStoredZipArchive" in all_text
assert '@"atomicWrite": @YES' in all_text
assert "AAZTME01" in all_text
assert "kCCPBKDF2" in all_text
assert "kCCHmacAlgSHA256" in all_text
assert "SecRandomCopyBytes" in all_text
assert "passwords are never stored" in all_text.lower()
assert "Import" in all_text
assert "Only a healthy backup can be imported" in all_text
assert "Backup Health & Readiness" in all_text
assert "Backup Changes" in all_text
assert "Selection Profiles" in all_text
assert "Manage Profiles" in all_text
assert "Version %@ — Build %@" in all_text
assert "https://x.com/_kkk2" in all_text
assert "Importing Backup" in all_text
assert "import.staged" in all_text
assert "importStage=%@" in all_text
assert "importErrorCode=%ld" in all_text
assert "Search backups" in all_text
assert "Pin" in all_text and "Unpin" in all_text
assert "UIDocumentPickerModeImport" in all_text
assert '@"public.archive"' in all_text
assert "ATMHandleBackupURL" in all_text
assert "open-in-received" in all_text
assert '"picker-opened"' in all_text
assert '"file-selected"' in all_text
assert '"picker-cancelled"' in all_text
assert "UTType.data" not in all_text
assert "for (NSUInteger index = 0; index < titles.count; index++)" in all_text
assert "AAZTweakManager_FRAMEWORKS = UIKit Foundation Security" in (ROOT / "Makefile").read_text()
assert "Restore preview" in all_text or "Restore Preview" in all_text
assert "The developer link opens externally" not in all_text
assert '@"architecture": @"iphoneos-arm64"' in all_text
assert '@"jailbreakPrefix"' not in (ROOT / "Core/ATMBackupManager.m").read_text()
assert '@"iOSVersion"' not in (ROOT / "Core/ATMBackupManager.m").read_text()
core_text = (ROOT / "Core/ATMCore.m").read_text()
diagnostic_body = core_text.split("NSURL *ATMWriteDiagnosticReport", 1)[1].split("@implementation ATMPersonalLedger", 1)[0]
for private_field in ("record.packageID", "record.name", "record.version", "sourceOrigin", "depends"):
    assert private_field not in diagnostic_body, f"diagnostic exposes {private_field}"
assert "performsFirstActionWithFullSwipe = NO" in all_text
assert "workflow_dispatch:" in (ROOT / ".github/workflows/build.yml").read_text()
assert not re.search(r"^\s*(push|pull_request|schedule):", (ROOT / ".github/workflows/build.yml").read_text(), re.M)

private_markers = [
    "workspace/" + "scratch",
    "PROJECT_" + "MASTER_" + "CONTEXT",
    "BEGIN ADDITIONAL" + " MESSAGE",
    "Chat" + "GPT",
]
for path in public_files:
    if path == Path(__file__).resolve():
        continue
    text = path.read_text(errors="ignore")
    for marker in private_markers:
        assert marker not in text, f"private marker {marker!r} in {path.relative_to(ROOT)}"

print("Static source, metadata, workflow, and safety checks passed.")
