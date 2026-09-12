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
    "Core/ATMCore.m", "Core/ATMBackupManager.m", "Core/ATMRestorePlanner.h",
    "Core/ATMRestorePlanner.m", "Core/ATMZipWriter.m",
    "Extension/ShareViewController.m", "Extension/Resources/Info.plist",
    "Extension/AAZBackupImporter.entitlements",
]
for relative in required:
    assert (ROOT / relative).is_file(), f"missing {relative}"

with (ROOT / "Resources/Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.aaz.tweakmanager"
assert info["MinimumOSVersion"] == "15.0"
assert info["CFBundleVersion"] == "33"
assert info["LSSupportsOpeningDocumentsInPlace"] is False
assert "CFBundleDocumentTypes" not in info

with (ROOT / "Resources/AAZTweakManager.entitlements").open("rb") as handle:
    entitlements = plistlib.load(handle)
assert entitlements["platform-application"] is True
assert entitlements["com.apple.private.persona-mgmt"] is True
assert entitlements["com.apple.private.spawn-subsystem-root"] is True
assert entitlements["application-identifier"] == info["CFBundleIdentifier"]
assert entitlements["com.apple.private.security.no-sandbox"] is True
assert entitlements["com.apple.private.security.storage.AppBundles"] is True
assert entitlements["com.apple.private.security.storage.AppDataContainers"] is True
assert entitlements["com.apple.security.application-groups"] == ["group.com.aaz.tweakmanager"]
assert "com.apple.private.security.no-container" not in entitlements
assert info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"] == ["AppIcon60x60"]

with (ROOT / "Extension/Resources/Info.plist").open("rb") as handle:
    extension_info = plistlib.load(handle)
assert extension_info["CFBundleIdentifier"] == "com.aaz.tweakmanager.importer"
assert extension_info["CFBundleVersion"] == "33"
assert extension_info["CFBundlePackageType"] == "XPC!"
extension_definition = extension_info["NSExtension"]
assert extension_definition["NSExtensionPointIdentifier"] == "com.apple.share-services"
assert extension_definition["NSExtensionPrincipalClass"] == "AAZShareViewController"
activation = extension_definition["NSExtensionAttributes"]["NSExtensionActivationRule"]
assert activation == {"NSExtensionActivationSupportsFileWithMaxCount": 1}

with (ROOT / "Extension/AAZBackupImporter.entitlements").open("rb") as handle:
    extension_entitlements = plistlib.load(handle)
assert extension_entitlements == {
    "application-identifier": "com.aaz.tweakmanager.importer",
    "com.apple.security.application-groups": ["group.com.aaz.tweakmanager"],
}

control = (ROOT / "control").read_text()
assert "Package: com.aaz.tweakmanager" in control
assert "Architecture: iphoneos-arm64" in control
assert "Version: 0.1.0~beta33" in control
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
    r"--allow-remove-essential", r"--force-yes",
    r"auth\.conf.*(?:copy|archive|backup)",
]:
    assert not re.search(forbidden, all_text, re.I), f"unsafe restore behavior: {forbidden}"

assert '@"restoreExecutionIncluded": @NO' in all_text
assert "credentials-redacted" in all_text
assert 'record.essential = essentialValue.length > 0 &&' in all_text
assert 'record.essential = [fields[@"Essential"]' not in all_text
assert "privacy=counts-and-stage-flags-only" in all_text
assert "AAZ-Tweak-Manager-Diagnostic.txt" in all_text
assert "fixed-stage-labels-only" in all_text
assert "Select All" in all_text
assert "Unselect All" in all_text
assert "Search packages" in all_text
assert "No matching packages" in all_text
assert "forPackageIDs" in all_text
assert "Create Backup?" in all_text
assert "Creating…" in all_text
assert "Selection Updated" in all_text
assert "No Activity Yet" in all_text
assert "Clear History?" in all_text
assert "clearHistory" in all_text
assert "No packages or sources are changed" in all_text
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
assert "Backup Details" in all_text
assert "Backup Verified" in all_text
assert "ATMBackupDetailsController" in all_text
assert "Backup Health & Readiness" not in all_text
assert "Check Restore Plan" in all_text
assert "Restore Readiness" in all_text
assert "Readiness Check Passed" in all_text
assert "Restore Needs Attention" in all_text
assert "Preview only. No packages or sources were changed." in all_text
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
assert "Import Backup" in all_text
assert "numberOfSectionsInTableView" in all_text
assert "if (indexPath.section == 0) { [self importBackup]; return; }" in all_text
assert "tableHeaderView = importHeader" not in all_text
assert "Import Troubleshooting" in all_text
assert "ATMImportDiagnosticsEnabled" in all_text
assert "ATMImportDiagnosticStageAllowed" in all_text
assert "importDebugEnabled=%@" in all_text
assert "importTraceFormat=1" in all_text
assert "importDebugPrivacy=fixed-stage-labels-only" in all_text
view_controller_text = (ROOT / "App/ATMViewControllers.m").read_text()
extension_text = (ROOT / "Extension/ShareViewController.m").read_text()
makefile_text = (ROOT / "Makefile").read_text()
restore_planner_text = (ROOT / "Core/ATMRestorePlanner.m").read_text()
assert "ATMBackupFinderController" not in view_controller_text
assert "Find local backups without opening Files" not in view_controller_text
assert "UIDocumentPickerViewController" not in view_controller_text
assert "DOCConfiguration" not in view_controller_text
assert "UniformTypeIdentifiers" not in view_controller_text
assert "loadFileRepresentationForTypeIdentifier" in extension_text
assert "ATMMaterializeBackup(url)" in extension_text
assert "containerURLForSecurityApplicationGroupIdentifier:ATMImportGroup" in extension_text
assert "group.com.aaz.tweakmanager" in extension_text
assert "O_RDONLY | O_CLOEXEC" in extension_text
assert "O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC" in extension_text
assert "fsync(destination)" in extension_text
assert "rename(partialURL.fileSystemRepresentation, finalURL.fileSystemRepresentation)" in extension_text
assert "ATMHasBackupHeader" in extension_text
assert "NSFileCoordinator" not in extension_text
assert "startAccessingSecurityScopedResource" not in extension_text
assert "APPEX_NAME = AAZBackupImporter" in makefile_text
assert "AAZBackupImporter_INSTALL_PATH = /Applications/AAZTweakManager.app/PlugIns" in makefile_text
assert "include $(THEOS_MAKE_PATH)/appex.mk" in makefile_text
assert "AAZBackupImporter_RESOURCE_DIRS = Extension/Resources" in makefile_text
assert "AAZBackupImporter_RESOURCE_FILES" not in makefile_text
assert "Core/ATMRestorePlanner.m" in makefile_text
for required_restore_guard in (
    '@"--simulate"', '@"--no-remove"', '@"--assume-no"', '@"--no-install-recommends"',
    '@"APT::Get::AllowUnauthenticated=false"', '@"APT::Get::AllowUnauthenticated=true"',
    '@"Acquire::AllowInsecureRepositories=false"',
    '@"Debug::NoLocking=true"', '@"showhold"', '@"--compare-versions"', '@"/usr/bin/apt-cache"', '@"check"',
    "ATMProtectedPackageIDs", '@"safeToExecute": @(simulationPassed && blockedCount == 0 && requests.count > 0)',
):
    assert required_restore_guard in restore_planner_text, f"missing restore guard: {required_restore_guard}"
for forbidden_restore_behavior in (
    '@"-y"', '@"--allow-downgrades"',
    '@"--allow-remove-essential"', '@"--allow-change-held-packages"',
    '@"--force-yes"',
):
    assert forbidden_restore_behavior not in restore_planner_text, f"unsafe restore option: {forbidden_restore_behavior}"
for required_restore_policy in (
    "newerVersionsKept++", '@"newerVersionsKept": @(newerVersionsKept)',
    '@"protectedOrInvalid": @(protectedOrInvalid)', '@"prerequisiteFailures": @(prerequisiteFailures)',
    'if (comparisonCode == 0) { newerVersionsKept++; continue; }',
):
    assert required_restore_policy in restore_planner_text, f"missing restore policy: {required_restore_policy}"
for required_executor_guard in (
    "posix_spawnattr_set_persona_np(&attributes, 99",
    '@"--no-remove", @"--yes", @"--no-install-recommends"',
    '@"Acquire::AllowDowngradeToInsecureRepositories=false"',
    '@"APT::Get::Allow-Downgrades=false"',
    '@"DPkg::Lock::Timeout=30"',
    '"R33-PERSONA"', '"R33-SPAWN"', '"R33-LOCK"', '"R33-PRIVILEGE"',
    '"R33-AUTH"', '"R33-SOURCE-AUTH"', '"R33-NETWORK"', '"R33-DPKG"', '"R33-APT"',
    '@"The Restore plan changed after confirmation.',
    '@"sourcesChanged": @NO', '@"removalsAllowed": @NO', '@"downgradesAllowed": @NO',
    '@"identitiesIncluded": @NO',
    '@"unexpectedActions": @(unexpectedActions)',
    'if (![requestedVersions[packageID] isEqualToString:version]) unexpectedActions++',
):
    assert required_executor_guard in restore_planner_text, f"missing executor guard: {required_executor_guard}"
for required_embedded_guard in (
    'ATMRestoreVerifiedPayload', '@"--field"', 'ATMSHA256ForFile',
    '256ULL * 1024ULL * 1024ULL', '@"source": @"embedded"',
    '@"items": [requestedItems copy]', 'restoreSessionID',
    '@"R33-READINESS"', '@"R33-READY"', '@"R33-BLOCKED"',
    'prepareRestoreSessionForBackupURL', 'AAZTweakManagerRestore',
    '1024ULL * 1024ULL * 1024ULL', 'restoreReadinessForBackupURL',
):
    assert required_embedded_guard in all_text, f"missing embedded restore guard: {required_embedded_guard}"
assert 'executionSnapshot = @{ @"requests"' not in restore_planner_text
assert restore_planner_text.count('@"--yes"') == 1
assert restore_planner_text.count('@"--allow-unauthenticated"') == 1
assert restore_planner_text.count('@"--no-download"') == 1
for required_local_auth_guard in (
    'BOOL mixedRequestSources = embeddedRequestCount > 0 && repositoryRequestCount > 0',
    'if (mixedRequestSources) { prerequisiteFailures++; blockedCount++; }',
    'BOOL embeddedOnly = requests.count > 0 && embeddedRequestCount == requests.count',
    'embeddedOnly ? @"APT::Get::AllowUnauthenticated=true" : @"APT::Get::AllowUnauthenticated=false"',
    '@"embeddedOnly": @(embeddedOnly)', '@"mixedRequestSources": @(mixedRequestSources)',
):
    assert required_local_auth_guard in restore_planner_text, f"missing local authentication guard: {required_local_auth_guard}"
for required_privileged_preflight in (
    'if (embeddedOnly) {', '@[@"--allow-unauthenticated", @"--no-download"',
    'ATMRestoreRunWithPrivilege(aptGet, preflightArguments, YES)',
    'preflightInstallActions == requests.count', 'preflightRemovalActions == 0',
    'preflightUnexpectedActions == 0', '@"R33-PREFLIGHT"',
):
    assert required_privileged_preflight in restore_planner_text, f"missing privileged preflight guard: {required_privileged_preflight}"
assert "NSXPCConnection" not in all_text
assert "setuid(" not in all_text
assert "Final Restore Confirmation" in view_controller_text
assert "Restore Now" in view_controller_text
assert "Restore Completed" in view_controller_text
assert "Unexpected Actions" in view_controller_text
assert 'regularExpressionWithPattern:@"^[0-9A-Za-z.+:~_-]+$"' in restore_planner_text
assert 'value:self.plan[@"protectedOrInvalid"]' in view_controller_text
assert 'value:self.plan[@"newerVersionsKept"]' in view_controller_text
assert "Newer Versions Kept" in view_controller_text
assert "Blocked Downgrades" not in view_controller_text
assert 'result[@"output"]' not in view_controller_text
assert "Restore code:" in view_controller_text
assert "APT exit:" in view_controller_text
assert "ATMSetRestoreDiagnosticState" in all_text
assert "restoreDiagnosticPrivacy=fixed-code-and-exit-only" in (ROOT / "Core/ATMCore.m").read_text()
assert "No packages or sources were changed." in view_controller_text
assert "ATMRestoreReadinessController" in view_controller_text
assert "restorePreviewForBackup" not in all_text
assert "share-extension-received" in all_text
assert "pendingImportURLs" in all_text
assert "In Files, Share → Save to AAZ Tweak Manager" in all_text
assert '@"Preparing backup…"' in extension_text
assert '@"Backup saved. Open AAZ Tweak Manager to verify and import it."' in extension_text
assert "filenames, paths, providers, passwords, or archive contents" in all_text
assert "Already Imported" in all_text
assert "NSFileCoordinator" in all_text
assert "copy-direct-started" in all_text
assert "copy-direct-failed" in all_text
assert "coordination-fallback-started" in all_text
assert "coordination-accessor-called" in all_text
assert "coordinateReadingItemAtURL:sourceURL options:0" in all_text
assert "NSFileCoordinatorReadingForUploading" not in (ROOT / "Core/ATMBackupManager.m").read_text()
assert "NSFileCoordinatorReadingWithoutChanges" not in all_text
assert "isReadableFileAtPath:sourceURL.path" not in all_text
assert "ATMCopyFileContents" in all_text
assert "copyItemAtURL:sourceURL toURL:destinationURL" in all_text
assert "NSInputStream" not in (ROOT / "Core/ATMBackupManager.m").read_text()
assert "security-scope-granted" in all_text
assert "security-scope-not-required" in all_text
assert "BOOL accessStarted = [url startAccessingSecurityScopedResource]" in all_text
assert "if (accessStarted) [url stopAccessingSecurityScopedResource]" in all_text
assert "@interface ATMImportDocument : UIDocument" not in all_text
assert "loadFromContents:(id)contents ofType:" not in all_text
assert "stageImportDocumentAtURL" not in all_text
assert "[document openWithCompletionHandler:" not in all_text
assert "[self beginPickerImportFromURL:url]" not in all_text
assert "ATMHandlePendingImport" in all_text
assert "for (NSUInteger index = 0; index < titles.count; index++)" in all_text
assert "AAZTweakManager_FRAMEWORKS = UIKit Foundation Security" in (ROOT / "Makefile").read_text()
assert "Restore Readiness" in all_text
assert "The developer link opens externally" not in all_text
assert '@"architecture": @"iphoneos-arm64"' in all_text
assert '@"jailbreakPrefix"' not in (ROOT / "Core/ATMBackupManager.m").read_text()
assert '@"iOSVersion"' not in (ROOT / "Core/ATMBackupManager.m").read_text()
core_text = (ROOT / "Core/ATMCore.m").read_text()
diagnostic_body = core_text.split("NSURL *ATMWriteDiagnosticReport", 1)[1].split("@implementation ATMPersonalLedger", 1)[0]
for private_field in ("record.packageID", "record.name", "record.version", "sourceOrigin", "depends", 'run[@"output"]'):
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
