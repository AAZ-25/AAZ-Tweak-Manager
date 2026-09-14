#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re
import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
import json
import hashlib
import struct
import warnings

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
assert info["CFBundleVersion"] == "51"
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
assert extension_info["CFBundleVersion"] == "51"
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
assert "Version: 0.1.0~beta51" in control
assert "Priority: optional" in control
assert "Depends: firmware (>= 15.0), coreutils, diffutils, dpkg, tar" in control

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
assert "No manual DEB sharing is required." in all_text
assert "inventory backup is still created" in all_text
assert "Package Vault" in all_text
assert "Full offline Restore is available." in all_text
assert "Backup Created: Limited Restore" in all_text
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
assert "The backup failed payload integrity validation and was not imported." in all_text
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
assert (ROOT / "App/ATMViewControllers.h").is_file()
extension_text = (ROOT / "Extension/ShareViewController.m").read_text()
makefile_text = (ROOT / "Makefile").read_text()
restore_planner_text = (ROOT / "Core/ATMRestorePlanner.m").read_text()
assert "ATMBackupFinderController" not in view_controller_text
assert "Find local backups without opening Files" not in view_controller_text
assert "UIDocumentPickerViewController" not in view_controller_text
assert "DOCConfiguration" not in view_controller_text
assert "UniformTypeIdentifiers" not in view_controller_text
assert "loadFileRepresentationForTypeIdentifier" in extension_text
assert "ATMMaterializeSharedFile(url)" in extension_text
assert "ATMHasDebianArchiveHeader" in extension_text
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
    '"R40-PERSONA"', '"R40-SPAWN"', '"R40-LOCK"', '"R40-PRIVILEGE"',
    '"R40-STORAGE"', '"R40-DPKG"', '"R40-DPKG-PREFLIGHT"', '"R40-PARTIAL"', '"R40-DEPENDENCY"', '"R40-ARCHIVE"', '"R40-APT-PREFLIGHT"',
    '"R40-AUTH"', '"R40-SOURCE-AUTH"', '"R40-NETWORK"', '"R40-APT"',
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
    '@"R40-READINESS"', '@"R40-READY"', '@"R40-BLOCKED"',
    'prepareRestoreSessionForBackupURL', 'AAZTweakManagerRestore',
    '1024ULL * 1024ULL * 1024ULL', 'restoreReadinessForBackupURL',
):
    assert required_embedded_guard in all_text, f"missing embedded restore guard: {required_embedded_guard}"
assert 'executionSnapshot = @{ @"requests"' not in restore_planner_text
assert restore_planner_text.count('@"--yes"') == 1
assert restore_planner_text.count('@"--allow-unauthenticated"') == 0
assert '@"--no-download"' not in restore_planner_text
assert '@"APT::Get::Download=true"' not in restore_planner_text
assert '@"Acquire::Retries=0"' not in restore_planner_text
assert '@[@"--no-act", @"--refuse-downgrade", @"--install"]' in restore_planner_text
assert '@[@"--refuse-downgrade", @"--install"]' in restore_planner_text
assert 'ATMRestoreRunWithPrivilege(dpkg, dpkgPreflightArguments, YES)' in restore_planner_text
assert 'run = ATMRestoreRunWithPrivilege(dpkg, dpkgArguments, YES)' in restore_planner_text
verified_payload_lookup = 'NSDictionary *verifiedPayload = ATMRestoreVerifiedPayload(self.environment, exactPayloads[identity], packageID, version);'
repository_metadata_lookup = 'NSDictionary *metadataResult = aptCache.length ? ATMRestoreRun(aptCache, @[@"show", request]) : @{};'
assert restore_planner_text.count(verified_payload_lookup) == 1
assert restore_planner_text.index(verified_payload_lookup) < restore_planner_text.index(repository_metadata_lookup)
assert 'if (verifiedPayload) {' in restore_planner_text
assert restore_planner_text.index('if (verifiedPayload) {') < restore_planner_text.index(repository_metadata_lookup)
assert restore_planner_text.index('return @"R40-DPKG"') < restore_planner_text.index('return @"R40-AUTH"')
assert restore_planner_text.index('return @"R40-ARCHIVE"') < restore_planner_text.index('return @"R40-AUTH"')
for required_local_auth_guard in (
    'BOOL mixedRequestSources = embeddedRequestCount > 0 && repositoryRequestCount > 0',
    'if (mixedRequestSources) { prerequisiteFailures++; blockedCount++; }',
    'BOOL embeddedOnly = requests.count > 0 && embeddedRequestCount == requests.count',
    'embeddedOnly ? @"APT::Get::AllowUnauthenticated=true" : @"APT::Get::AllowUnauthenticated=false"',
    '@"embeddedOnly": @(embeddedOnly)', '@"mixedRequestSources": @(mixedRequestSources)',
):
    assert required_local_auth_guard in restore_planner_text, f"missing local authentication guard: {required_local_auth_guard}"
for required_privileged_preflight in (
    'embeddedOnly ? @"APT::Get::AllowUnauthenticated=true" : @"APT::Get::AllowUnauthenticated=false"',
    'ATMRestoreRunWithPrivilege(aptGet, preflightArguments, YES)',
    'preflightInstallActions == requests.count', 'preflightRemovalActions == 0',
    'preflightUnexpectedActions == 0', '@"R40-APT-PREFLIGHT"',
    'if (!embeddedOnly) {', '@"R40-DPKG-PREFLIGHT"', '@"R40-PARTIAL"',
):
    assert required_privileged_preflight in restore_planner_text, f"missing privileged preflight guard: {required_privileged_preflight}"
assert "NSXPCConnection" not in all_text
assert "setuid(" not in all_text
assert "Final Restore Confirmation" in view_controller_text
assert "Restore Now" in view_controller_text
assert "Restore Completed" in view_controller_text
assert "Unexpected Actions" in view_controller_text
assert "Embedded DEBs" in view_controller_text
assert "Repository Packages" in view_controller_text
assert "verified DEBs embedded in this backup" in view_controller_text
assert 'regularExpressionWithPattern:@"^[0-9A-Za-z.+:~_-]+$"' in restore_planner_text
assert 'value:self.plan[@"protectedOrInvalid"]' in view_controller_text
assert 'value:self.plan[@"newerVersionsKept"]' in view_controller_text
assert "Newer Versions Kept" in view_controller_text
assert "Blocked Downgrades" not in view_controller_text
assert 'result[@"output"]' not in view_controller_text
assert "Restore code:" in view_controller_text
assert "Package-manager exit:" in view_controller_text
assert "ATMSetRestoreDiagnosticState" in all_text
assert "restoreDiagnosticPrivacy=fixed-code-and-exit-only" in (ROOT / "Core/ATMCore.m").read_text()
assert "No packages or sources were changed." in view_controller_text
assert "ATMRestoreReadinessController" in view_controller_text
assert "restorePreviewForBackup" not in all_text
assert "share-extension-received" in all_text
assert "pendingImportURLs" in all_text
assert "In Files, Share → Save to AAZ Tweak Manager" in all_text
assert '@"Preparing file…"' in extension_text
assert '@"Backup saved. Open AAZ Tweak Manager to verify and import it."' in extension_text
assert '@"Package saved. Open AAZ Tweak Manager to verify it for Portable Backup."' in extension_text
backup_manager_text = (ROOT / "Core/ATMBackupManager.m").read_text()
assert "ATMRunDPKGDebField" not in backup_manager_text
assert "ATMReadDPKGDebField" in backup_manager_text
assert 'ATMRunBackupTool(tool, @[@"--field", debURL.path, field])' in backup_manager_text
assert 'ATMValidatedBackupPayloadWithFailure' in backup_manager_text
for identity_stage in (
    "identity-file", "identity-tool", "identity-package", "identity-version",
    "identity-architecture", "identity-policy", "identity-hash", "identity-unknown",
):
    assert identity_stage in all_text, f"missing detailed identity stage: {identity_stage}"
assert "ATMRestoreDPKGDebField" in restore_planner_text
assert 'ATMRestoreRun(dpkgDeb, @[@"--field", filePath, field])' in restore_planner_text
assert 'ATMParseDebianParagraph(run[@"output"]' not in restore_planner_text
for required_portable_guard in (
    'packageVaultDirectory', 'importPackagePayloadFromURL', 'ATMValidatedBackupPayload',
    '@"--download-only"', '@"--reinstall"', '@"APT::Get::AllowUnauthenticated=false"',
    '@"Acquire::AllowInsecureRepositories=false"', '@"Acquire::AllowDowngradeToInsecureRepositories=false"',
    '@"Debug::NoLocking=true"', 'Dir::Cache::archives=',
    '@"portable": @(portable)', '@"payloadCoverage": @(payloadCoverage)',
    '@"missingPayloadCount"', '@"captureFailureCounts"',
    '[manifest[@"portable"] boolValue]', '[manifest[@"payloadCoverage"] integerValue] == 100',
    'cached == manifestPackages.count', '@"APT::Get::Allow-Downgrades=false"',
    '@"APT::Get::Allow-Change-Held-Packages=false"', '@"Acquire::Retries=0"',
    'BOOL portable = embeddedCount == chosen.count', 'chosen.count - embeddedCount',
):
    assert required_portable_guard in backup_manager_text, f"missing portable-backup guard: {required_portable_guard}"
assert backup_manager_text.index('authenticatedRepositoryMetadataForRecord') < backup_manager_text.index('acquireAuthenticatedRepositoryPackageForRecord')
assert 'if (unresolved)' not in backup_manager_text
assert 'embeddedCount != chosen.count' not in backup_manager_text
assert '@"-C", payloadRoot' in backup_manager_text
assert 'ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--listfiles", record.packageID], NO, nil)' in backup_manager_text
for required_automatic_capture_guard in (
    'packagesIncludingDependenciesForSelected', 'installedPackageCanBeRepackedWithoutPrivateData',
    'record.provides = fields[@"Provides"]', '[record.provides componentsSeparatedByString:@","]',
    '@"--listfiles"', '@"--control-list"', '@"--control-show"', '@"md5sums"', '@"--verify"', '@"-x"', '@"--build"', '@"verified-repack"',
    'repackInventoryForRecord', 'rootedMatches == listedPaths.count', 'S_ISDIR(info.st_mode)',
    '@"supportingDependency"', '@"/var/mobile"', '@"/Library/Preferences"',
    'restoreSanitizedSources', '@"R40-SOURCE-RESTORE"', '@"sourcesToRestore"',
    '@"privateSourcesSkipped"', '@"aaztm-%@.%@"', 'entry[@"restorable"] = @(!source.credentialsRedacted)',
):
    assert required_automatic_capture_guard in all_text, f"missing automatic capture guard: {required_automatic_capture_guard}"
assert "dpkg-repack" not in control
assert 'currentRestoreCode = [storedRestoreCode hasPrefix:@"R40-"]' in (ROOT / "Core/ATMCore.m").read_text()
assert 'ATMProtectedPackageIDs() containsObject:packageID.lowercaseString' in backup_manager_text
assert 'isPendingPackagePayloadURL' in all_text
assert "filenames, paths, providers, passwords, or archive contents" in all_text
assert 'Portable Backup Verified' in all_text
assert 'Backup Not Portable' in all_text
assert '@"directories": directoryPaths.array' in all_text
assert '@"archive-fallback-create"' in all_text
assert '@"archive-fallback-extract"' in all_text
assert 'stagePayloadDirectlyFromRoot' in backup_manager_text
assert '@"direct-copy-verify"' in all_text
assert 'ATMStagedPayloadVerificationFailure' in backup_manager_text
assert '@"package-reopen"' in all_text
assert '@"package-payload-verify"' in all_text
assert 'runBackupPreflight' in all_text
assert 'newBackupWorkingRootNamed' in backup_manager_text
assert '@"preflight-workspace"' in all_text
assert '@"preflight-reopen-directory"' in all_text
assert 'preflightFailureCounts[preflightStage] = @1' in backup_manager_text
assert 'Safe check warning; continuing backup' in backup_manager_text
assert 'combinedFailureCounts = [preflightFailureCounts mutableCopy]' in backup_manager_text
assert '[packageCaptureFailureCounts enumerateKeysAndObjectsUsingBlock:' in backup_manager_text
assert 'ATMStagedPayloadVerificationFailure' in backup_manager_text
assert 'ATMVerificationStage' in backup_manager_text
assert 'ATMRequiredDirectoryPaths' in backup_manager_text
assert 'ATMNormalizeStagedPayloadModes' in backup_manager_text
assert 'ATMPruneUnexpectedStagedEntries' in backup_manager_text
assert 'enumeratorAtPath:stage.path' in backup_manager_text
assert 'substringFromIndex:stage.path.length + 1' not in backup_manager_text
assert 'unlink(fullPath.fileSystemRepresentation)' in backup_manager_text
assert 'rmdir(fullPath.fileSystemRepresentation)' in backup_manager_text
assert 'if (![expectedDirectories containsObject:relativePath]) return @"unexpected-directory";' in backup_manager_text
assert 'pathsWithListedDescendants' in backup_manager_text
assert 'rootedMatches == listedPaths.count' in backup_manager_text
assert 'directMatches != listedPaths.count' in backup_manager_text
assert '[pathsWithListedDescendants containsObject:path]' in backup_manager_text
assert 'stat(physicalPath.fileSystemRepresentation, &resolvedInfo)' in backup_manager_text
assert 'for (NSString *relativePath in directoryPaths ?: @[])' in backup_manager_text
assert 'stat(sourcePath.fileSystemRepresentation, &sourceInfo)' in backup_manager_text
assert 'NSString *pruneFailure = ATMPruneUnexpectedStagedEntries(stage, safePaths, directoryPaths);' in backup_manager_text
assert 'NSString *pruneFailure = ATMPruneUnexpectedStagedEntries(fallbackStage, paths, directories);' in backup_manager_text
assert '@"-P", sourcePath, destinationPath' in backup_manager_text
assert '@"-pP", sourcePath, destinationPath' not in backup_manager_text
assert '@[@"-x", @"-m", @"-f", tarURL.path' in backup_manager_text
assert 'preflightFailureCounts[@"preflight-warning"] = @1' in backup_manager_text
assert 'preflightFailureCounts[@"preflight"] = @1' not in backup_manager_text
assert '[@"preflight-" stringByAppendingString:directFailure]' in backup_manager_text
assert 'if (S_ISREG(sourceInfo.st_mode)) {' in backup_manager_text
assert 'if ((sourceInfo.st_mode & 07777) != (stagedInfo.st_mode & 07777)) return @"mode";' in backup_manager_text
assert 'return @"symlink";' in backup_manager_text
assert '@[@"enumeration", @"unexpected-directory", @"unexpected-entry", @"missing-entry", @"source", @"type", @"mode", @"size", @"content", @"symlink"]' in backup_manager_text
assert 'verificationPrefixes = @[@"preflight-direct-copy-verify", @"preflight-fallback-verify", @"preflight-payload-verify", @"direct-copy-verify", @"archive-fallback-verify", @"package-payload-verify"]' in all_text
assert '@"preflight-warning"' in all_text
assert '@"stages": observedStages' in backup_manager_text
assert 'preflight-direct-' in backup_manager_text
assert 'observedFailureStages:(NSArray<NSString *> **)observedFailureStages' in backup_manager_text
assert 'for (NSString *observedStage in observedFailureStages)' in backup_manager_text
assert 'ATMFilesEqualWithOptionalPrivilegedTool' in backup_manager_text
assert 'ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--version"], YES, nil)' in backup_manager_text
assert 'ATMRunBackupToolWithPrivilege(dpkg, @[@"--no-act", @"--refuse-downgrade", @"--install", debURL.path], YES, nil)' in backup_manager_text
assert '@"preflight-restore-dry-run"' in all_text
assert 'if (embeddedOnly ? !dpkg.length : !aptGet.length)' in restore_planner_text
assert '@"/usr/bin/true"' not in backup_manager_text
assert 'cancelCurrentBackup' in all_text
assert 'Share Privacy-Safe Report' in all_text
assert 'hasAttemptWarnings' in all_text
assert '(!portable || hasAttemptWarnings)' in all_text
assert 'hasCaptureWarnings' in all_text
assert 'ATMFailureCountForPrefixes' in all_text
assert 'Tool or Archive Failure Events' in all_text
assert 'ATMCreateDirectoryTreeBelowRoot' in backup_manager_text
assert 'mkdirat(directoryFD, name, 0755)' in backup_manager_text
assert 'openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)' in backup_manager_text
assert '@"directory-containment"' in all_text
assert '@"directory-create"' in all_text
assert 'stage.URLByStandardizingPath.path' not in backup_manager_text
assert '@"--no-recursion"' not in backup_manager_text
assert 'packageHashFailureCount' in all_text
assert 'sourceHashFailureCount' in all_text
assert 'archive-validation-failed' not in all_text
assert 'package-hash-failed' in all_text
assert 'source-hash-failed' in all_text
assert 'Privacy-Safe Report' in all_text
assert 'privacy=counts-and-fixed-stage-labels-only' in all_text

# Beta 51 is one complete workflow correction, not a diagnostic-only release.
for required_import_freshness in (
    "ATMBeginImportDiagnosticAttempt", "ATMLastImportBuildV2", "ATMLastImportAttemptV2",
    "ATMLastImportAttemptStateV2", "currentImportAttempt", 'importAttemptBuild=%@',
    'importAttemptID=%@', 'importAttemptState=%@',
):
    assert required_import_freshness in all_text, f"missing current-attempt import diagnostic: {required_import_freshness}"
assert 'ATMSetImportDiagnosticState(@"validation-failed"' not in all_text
for detailed_import_stage in (
    "archive-decryption-failed", "archive-layout-failed", "archive-crc-failed",
    "archive-footer-failed", "archive-index-failed", "manifest-schema-failed",
    "package-hash-failed", "source-hash-failed", "entry-integrity-failed",
    "duplicate", "finalize-failed", "cancelled", "completed",
):
    assert detailed_import_stage in all_text, f"missing detailed import stage: {detailed_import_stage}"
assert "ATMImportDiagnosticSuppressionDepth" in all_text
assert "ATMPushImportDiagnosticSuppression" in backup_manager_text
assert "ATMPopImportDiagnosticSuppression" in backup_manager_text
assert "selfTestNonce" in backup_manager_text
assert "selftest-encrypted.aaztmbackup" in backup_manager_text
assert "incorrect-self-test-password" in backup_manager_text
assert "wrongPasswordError.code != ATMBackupErrorWrongPassword" in backup_manager_text
assert "[self stageImportFromURL:inboxProbe" in backup_manager_text
assert "[self importBackupFromURL:stagedImport password:nil" in backup_manager_text
assert "[self importBackupFromURL:encryptedStaged password:selfTestPassword" in backup_manager_text
assert "if (!self.importSelfTestActive) [self.ledger recordEvent" in backup_manager_text
assert "cleanupStaleImportArtifacts" in backup_manager_text
assert 'hasSuffix:@".import.staged"' in backup_manager_text
assert 'hasSuffix:@".partial"' in backup_manager_text

for required_source_only_guard in (
    "sourceRestoreReadiness", 'sourcePlan[@"pending"]', 'sourcePlan[@"snapshot"]',
    'sessionPlan[@"packageExecutionSnapshot"]', '@"packages": plan[@"executionSnapshot"]',
    '@"sources": sourcePlan[@"snapshot"]', 'sourcesPending > 0',
    "currentPackageSafetyPassed", "approvedSourceActions", "if (!requests.count)",
    '@"requested": @0', '@"remaining": @0', '@"R40-SOURCE-PREFLIGHT"',
):
    assert required_source_only_guard in all_text, f"missing source-only Restore guard: {required_source_only_guard}"
source_preflight = backup_manager_text.index("NSDictionary *sourcePlan = [self sourceRestoreReadiness];", backup_manager_text.index("executeRestoreForManifest"))
package_execution = backup_manager_text.index("[self.restorePlanner executeManifest", backup_manager_text.index("executeRestoreForManifest"))
assert source_preflight < package_execution, "source destinations must be checked before package mutation"
assert "sourcesStable" in backup_manager_text
assert 'S_ISREG(status.st_mode)' in backup_manager_text
assert '@[@"-d", destinationRoot]' in backup_manager_text
assert '@[@"-w", destinationRoot]' in backup_manager_text
assert 'packageActions == 0 ? @"no package changes"' in all_text
assert "ATMWriteRestoreSummaryReport" in all_text
assert all_text.count("Share Privacy-Safe Report") >= 4

# The source-only gate must distinguish actual pending sources from a true no-op.
def source_only_safe(simulation_passed, blocked, package_actions, source_states):
    pending = sum(state == "pending" for state in source_states)
    return simulation_passed and blocked == 0 and (package_actions > 0 or pending > 0)

assert source_only_safe(True, 0, 0, ["pending", "present"])
assert not source_only_safe(True, 0, 0, ["present", "present"])
assert not source_only_safe(True, 1, 0, ["pending"])
assert source_only_safe(True, 0, 1, [])

with tempfile.TemporaryDirectory() as temporary:
    temporary_root = Path(temporary)
    payload_root = temporary_root / "payload"
    shared = payload_root / "shared"
    shared.mkdir(parents=True)
    (shared / "wanted").write_text("wanted")
    (shared / "not-listed").write_text("private")
    file_list = temporary_root / "payload-files"
    file_list.write_text("shared/wanted\n")
    archive = temporary_root / "payload.tar"
    subprocess.run(["tar", "-cpf", str(archive), "-C", str(payload_root), "-T", str(file_list)], check=True, capture_output=True)
    with tarfile.open(archive) as handle:
        assert handle.getnames() == ["shared/wanted"], "archive capture recursed beyond the verified file list"

    synthetic = payload_root / "usr" / "lib" / "aaz-preflight"
    synthetic.mkdir(parents=True)
    executable = synthetic / "probe"
    executable.write_text("safe synthetic payload\n")
    executable.chmod(0o755)
    (synthetic / "probe-link").symlink_to("probe")
    direct_stage = temporary_root / "direct-stage"
    direct_stage.mkdir()
    for directory in ("usr", "usr/lib", "usr/lib/aaz-preflight"):
        (direct_stage / directory).mkdir(exist_ok=True)
    shutil.copy2(executable, direct_stage / "usr/lib/aaz-preflight/probe", follow_symlinks=False)
    os.symlink(os.readlink(synthetic / "probe-link"), direct_stage / "usr/lib/aaz-preflight/probe-link")
    assert (direct_stage / "usr/lib/aaz-preflight/probe").read_bytes() == executable.read_bytes()
    assert (direct_stage / "usr/lib/aaz-preflight/probe").stat().st_mode & 0o777 == 0o755
    assert (direct_stage / "usr/lib/aaz-preflight/probe-link").is_symlink()
    assert os.readlink(direct_stage / "usr/lib/aaz-preflight/probe-link") == "probe"

    fallback_list = temporary_root / "fallback-files"
    fallback_list.write_text("usr/lib/aaz-preflight/probe\nusr/lib/aaz-preflight/probe-link\n")
    fallback_archive = temporary_root / "fallback.tar"
    subprocess.run(["tar", "-cpf", str(fallback_archive), "-C", str(payload_root), "-T", str(fallback_list)], check=True, capture_output=True)
    fallback_stage = temporary_root / "fallback-stage"
    fallback_stage.mkdir()
    subprocess.run(["tar", "-xmf", str(fallback_archive), "-C", str(fallback_stage)], check=True, capture_output=True)
    (fallback_stage / "usr").chmod((payload_root / "usr").stat().st_mode & 0o7777)
    (fallback_stage / "usr/lib").chmod((payload_root / "usr/lib").stat().st_mode & 0o7777)
    (fallback_stage / "usr/lib/aaz-preflight").chmod(synthetic.stat().st_mode & 0o7777)
    (fallback_stage / "usr/lib/aaz-preflight/probe").chmod(executable.stat().st_mode & 0o7777)
    assert (fallback_stage / "usr/lib/aaz-preflight/probe").read_bytes() == executable.read_bytes()
    assert (fallback_stage / "usr/lib/aaz-preflight/probe").stat().st_mode & 0o777 == 0o755
    assert (fallback_stage / "usr/lib/aaz-preflight/probe-link").is_symlink()
    assert os.readlink(fallback_stage / "usr/lib/aaz-preflight/probe-link") == "probe"
    assert not (fallback_stage / "shared/not-listed").exists()

    implicit_root = temporary_root / "implicit"
    implicit_file = implicit_root / "one" / "two" / "payload"
    implicit_file.parent.mkdir(parents=True)
    implicit_file.write_text("implicit parents")
    implicit_stage = temporary_root / "implicit-stage"
    implicit_stage.mkdir()
    subprocess.run(["cp", "-P", str(implicit_file), str(implicit_stage / "payload")], check=True, capture_output=True)
    (implicit_stage / "payload").chmod(implicit_file.stat().st_mode & 0o7777)
    assert (implicit_stage / "payload").read_bytes() == implicit_file.read_bytes()

    expected_parents = set()
    for relative in ("one/two/payload", "one/three/link"):
        parts = Path(relative).parts
        expected_parents.update(str(Path(*parts[:index])) for index in range(1, len(parts)))
    assert expected_parents == {"one", "one/two", "one/three"}

    # A Rootless redirection symlink may be a listed ancestor of package files.
    # It must become a contained logical directory, never a symlink escape and
    # never both a staged symlink and a directory.
    physical_root = temporary_root / "physical-root"
    redirected_directory = physical_root / "real-usr" / "lib" / "aaz-package"
    redirected_directory.mkdir(parents=True)
    redirected_payload = redirected_directory / "payload"
    redirected_payload.write_text("rootless payload")
    logical_root = temporary_root / "logical-root"
    logical_root.mkdir()
    (logical_root / "usr").symlink_to(physical_root / "real-usr", target_is_directory=True)
    listed_paths = ["/usr", "/usr/lib/aaz-package", "/usr/lib/aaz-package/payload"]
    listed_descendant_parents = set()
    for listed_path in listed_paths:
        parent = Path(listed_path).parent
        while str(parent) != "/":
            listed_descendant_parents.add(str(parent))
            parent = parent.parent
    assert "/usr" in listed_descendant_parents
    assert (logical_root / "usr").is_symlink()
    assert (logical_root / "usr").resolve().is_dir()
    direct_visible_root = temporary_root / "direct-visible-root"
    direct_visible_root.mkdir()
    (direct_visible_root / "usr").symlink_to(logical_root / "usr", target_is_directory=True)
    direct_matches = sum((direct_visible_root / path.lstrip("/")).exists() or (direct_visible_root / path.lstrip("/")).is_symlink() for path in listed_paths)
    rooted_matches = sum((logical_root / path.lstrip("/")).exists() or (logical_root / path.lstrip("/")).is_symlink() for path in listed_paths)
    assert rooted_matches == len(listed_paths)
    assert direct_matches == len(listed_paths), "fixture must reproduce the Rootless visibility tie"
    selected_payload_root = logical_root if rooted_matches == len(listed_paths) else direct_visible_root
    assert selected_payload_root == logical_root

    structural_stage = temporary_root / "structural-stage"
    (structural_stage / "usr/lib/aaz-package").mkdir(parents=True)
    subprocess.run(
        ["cp", "-P", str(logical_root / "usr/lib/aaz-package/payload"), str(structural_stage / "usr/lib/aaz-package/payload")],
        check=True,
        capture_output=True,
    )
    assert not (structural_stage / "usr").is_symlink()
    assert (structural_stage / "usr/lib/aaz-package/payload").read_bytes() == redirected_payload.read_bytes()
    # Transfer-created entries outside the exact dpkg inventory are removed,
    # including nested structural directories once their contents are gone.
    (structural_stage / "transfer-structure").mkdir()
    (structural_stage / "transfer-structure/metadata").write_text("not package payload")
    (structural_stage / "usr/lib/aaz-package/._payload").write_text("transfer metadata")
    expected_files = {"usr/lib/aaz-package/payload"}
    expected_directories = {"usr", "usr/lib", "usr/lib/aaz-package"}
    for candidate in sorted(structural_stage.rglob("*"), key=lambda item: len(item.relative_to(structural_stage).parts), reverse=True):
        relative = str(candidate.relative_to(structural_stage))
        if candidate.is_dir() and not candidate.is_symlink():
            if relative not in expected_directories:
                candidate.rmdir()
        elif relative not in expected_files:
            candidate.unlink()
    assert {str(item.relative_to(structural_stage)) for item in structural_stage.rglob("*")} == expected_files | expected_directories

    # iOS can expose an app-owned /var path through its /private/var physical
    # alias. Absolute URL-prefix slicing then corrupts every relative name.
    # Root-relative enumeration must keep the inventory names unchanged.
    physical_container = temporary_root / "private-var-container"
    aliased_container = temporary_root / "var-container"
    physical_stage = physical_container / "stage"
    (physical_stage / "usr/lib/aaz-package").mkdir(parents=True)
    (physical_stage / "usr/lib/aaz-package/payload").write_text("alias-safe payload")
    aliased_container.symlink_to(physical_container, target_is_directory=True)
    aliased_stage = aliased_container / "stage"
    relative_entries = {
        str(item.relative_to(aliased_stage))
        for item in aliased_stage.rglob("*")
    }
    assert relative_entries == {
        "usr",
        "usr/lib",
        "usr/lib/aaz-package",
        "usr/lib/aaz-package/payload",
    }
    physical_child = physical_stage / "usr/lib/aaz-package/payload"
    assert str(physical_child)[len(str(aliased_stage)) + 1:] != "usr/lib/aaz-package/payload"

    structural_tar_list = temporary_root / "structural-files"
    structural_tar_list.write_text("usr/lib/aaz-package/payload\n")
    structural_tar = temporary_root / "structural.tar"
    subprocess.run(["tar", "-cpf", str(structural_tar), "-C", str(logical_root), "-T", str(structural_tar_list)], check=True, capture_output=True)
    structural_fallback = temporary_root / "structural-fallback"
    (structural_fallback / "usr/lib/aaz-package").mkdir(parents=True)
    subprocess.run(["tar", "-xmf", str(structural_tar), "-C", str(structural_fallback)], check=True, capture_output=True)
    assert (structural_fallback / "usr/lib/aaz-package/payload").read_bytes() == redirected_payload.read_bytes()

    package_stage = temporary_root / "package-stage"
    shutil.copytree(direct_stage, package_stage, symlinks=True)
    (package_stage / "DEBIAN").mkdir()
    (package_stage / "DEBIAN/control").write_text(
        "Package: com.aaz.preflight\nVersion: 1\nArchitecture: all\n"
        "Maintainer: AAZ\nDescription: safe synthetic preflight\n"
    )
    synthetic_deb = temporary_root / "preflight.deb"
    subprocess.run(["dpkg-deb", "--build", str(package_stage), str(synthetic_deb)], check=True, capture_output=True)
    expected_identity = {
        "Package": "com.aaz.preflight",
        "Version": "1",
        "Architecture": "all",
        "Priority": "",
        "Essential": "no",
    }
    for field, expected in expected_identity.items():
        value = subprocess.run(
            ["dpkg-deb", "--field", str(synthetic_deb), field],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert value == expected
    subprocess.run(
        ["dpkg", "--no-act", "--refuse-downgrade", "--install", str(synthetic_deb)],
        check=True,
        capture_output=True,
    )
    reopened = temporary_root / "reopened"
    subprocess.run(["dpkg-deb", "--extract", str(synthetic_deb), str(reopened)], check=True, capture_output=True)
    assert (reopened / "usr/lib/aaz-preflight/probe").read_bytes() == executable.read_bytes()
    assert (reopened / "usr/lib/aaz-preflight/probe").stat().st_mode & 0o777 == 0o755
    assert os.readlink(reopened / "usr/lib/aaz-preflight/probe-link") == "probe"

    # Stored-ZIP import regression matrix: success, truncation, CRC/content
    # damage, malformed manifest, hash mismatch, and duplicate path.
    import_zip = temporary_root / "import.aaztmbackup"
    package_bytes = synthetic_deb.read_bytes()
    package_hash = hashlib.sha256(package_bytes).hexdigest()
    import_manifest = {
        "format": "com.aaz.tweakmanager.backup", "formatVersion": 1,
        "rootless": True, "architecture": "iphoneos-arm64",
        "packages": [{"packageID": "com.aaz.preflight", "version": "1", "architecture": "all", "debStatus": "exact-cache", "debPath": "packages/preflight.deb", "sha256": package_hash}],
        "sources": [], "portable": True, "payloadCoverage": 100,
    }
    with zipfile.ZipFile(import_zip, "w", compression=zipfile.ZIP_STORED) as archive_handle:
        archive_handle.writestr("packages/preflight.deb", package_bytes)
        archive_handle.writestr("manifest.json", json.dumps(import_manifest, sort_keys=True).encode())
    with zipfile.ZipFile(import_zip) as archive_handle:
        assert archive_handle.testzip() is None
        assert json.loads(archive_handle.read("manifest.json"))["formatVersion"] == 1
        assert hashlib.sha256(archive_handle.read("packages/preflight.deb")).hexdigest() == package_hash

    truncated_zip = temporary_root / "truncated.aaztmbackup"
    truncated_zip.write_bytes(import_zip.read_bytes()[:-11])
    try:
        zipfile.ZipFile(truncated_zip).testzip()
        raise AssertionError("truncated archive unexpectedly validated")
    except zipfile.BadZipFile:
        pass

    corrupted_zip = temporary_root / "crc.aaztmbackup"
    corrupted = bytearray(import_zip.read_bytes())
    name_length, extra_length = struct.unpack_from("<HH", corrupted, 26)
    payload_offset = 30 + name_length + extra_length
    corrupted[payload_offset] ^= 0x01
    corrupted_zip.write_bytes(corrupted)
    with zipfile.ZipFile(corrupted_zip) as archive_handle:
        assert archive_handle.testzip() == "packages/preflight.deb"

    malformed_zip = temporary_root / "malformed.aaztmbackup"
    with zipfile.ZipFile(malformed_zip, "w", compression=zipfile.ZIP_STORED) as archive_handle:
        archive_handle.writestr("manifest.json", b"not-json")
    with zipfile.ZipFile(malformed_zip) as archive_handle:
        try:
            json.loads(archive_handle.read("manifest.json"))
            raise AssertionError("malformed manifest unexpectedly parsed")
        except json.JSONDecodeError:
            pass

    wrong_hash_manifest = dict(import_manifest)
    wrong_hash_manifest["packages"] = [dict(import_manifest["packages"][0], sha256="0" * 64)]
    assert wrong_hash_manifest["packages"][0]["sha256"] != hashlib.sha256(package_bytes).hexdigest()

    duplicate_zip = temporary_root / "duplicate.aaztmbackup"
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(duplicate_zip, "w", compression=zipfile.ZIP_STORED) as archive_handle:
            archive_handle.writestr("manifest.json", b"{}")
            archive_handle.writestr("manifest.json", b"{}")
    with zipfile.ZipFile(duplicate_zip) as archive_handle:
        names = archive_handle.namelist()
        assert len(names) != len(set(names))
assert 'Only a healthy backup can be imported' not in all_text
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
for private_field in ("record.packageID", "record.name", "record.version", "sourceOrigin", "depends", "provides", 'run[@"output"]'):
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
