#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]

required = [
    "Makefile", "control", "Resources/Info.plist",
    "Resources/AAZTweakManager.entitlements", "main.m",
    "App/ATMAppDelegate.m", "App/ATMViewControllers.m",
    "Core/ATMCore.m", "Core/ATMBackupManager.m", "Core/ATMZipWriter.m",
]
for relative in required:
    assert (ROOT / relative).is_file(), f"missing {relative}"

with (ROOT / "Resources/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.aaz.tweakmanager"
assert info["MinimumOSVersion"] == "15.0"

control = (ROOT / "control").read_text()
assert "Package: com.aaz.tweakmanager" in control
assert "Architecture: iphoneos-arm64" in control
assert "Version: 0.1.0~beta1" in control

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
