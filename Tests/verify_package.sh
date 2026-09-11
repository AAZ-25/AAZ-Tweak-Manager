#!/bin/bash
set -euo pipefail

phase="${1:?verification phase required}"
deb="$RUNNER_TEMP/aaz-package.deb"
package_list="$RUNNER_TEMP/aaz-package.list"
package_root="$RUNNER_TEMP/aaz-package"
app="$package_root/var/jb/Applications/AAZTweakManager.app/AAZTweakManager"
app_info="$package_root/var/jb/Applications/AAZTweakManager.app/Info.plist"
extension="$package_root/var/jb/Applications/AAZTweakManager.app/PlugIns/AAZBackupImporter.appex/AAZBackupImporter"
extension_info="$package_root/var/jb/Applications/AAZTweakManager.app/PlugIns/AAZBackupImporter.appex/Info.plist"

case "$phase" in
  locate)
    source_deb="$(find packages -name '*.deb' -type f -print -quit)"
    test -n "$source_deb"
    cp "$source_deb" "$deb"
    ;;
  metadata)
    test -f "$deb"
    test "$(dpkg-deb -f "$deb" Package)" = "com.aaz.tweakmanager"
    test "$(dpkg-deb -f "$deb" Version)" = "0.1.0~beta29"
    test "$(dpkg-deb -f "$deb" Architecture)" = "iphoneos-arm64"
    dpkg-deb -c "$deb" > "$package_list"
    ;;
  layout)
    test -f "$package_list"
    grep -Fq 'AAZTweakManager.app/AAZTweakManager' "$package_list"
    grep -Fq 'AAZTweakManager.app/AppIcon60x60@3x.png' "$package_list"
    grep -Fq 'AAZTweakManager.app/PlugIns/AAZBackupImporter.appex/AAZBackupImporter' "$package_list"
    grep -Fq 'AAZTweakManager.app/PlugIns/AAZBackupImporter.appex/Info.plist' "$package_list"
    rm -rf "$package_root"
    dpkg-deb -x "$deb" "$package_root"
    test -f "$app"
    test -f "$app_info"
    test -f "$extension"
    test -f "$extension_info"
    ;;
  identities)
    ldid -e "$app" > "$RUNNER_TEMP/aaz-app.entitlements"
    ldid -e "$extension" > "$RUNNER_TEMP/aaz-extension.entitlements"
    python3 - "$RUNNER_TEMP/aaz-app.entitlements" "$RUNNER_TEMP/aaz-extension.entitlements" "$app_info" "$extension_info" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    entitlements = plistlib.load(handle)
with open(sys.argv[2], "rb") as handle:
    extension_entitlements = plistlib.load(handle)
with open(sys.argv[3], "rb") as handle:
    app_info = plistlib.load(handle)
with open(sys.argv[4], "rb") as handle:
    extension_info = plistlib.load(handle)

assert entitlements["platform-application"] is True
assert entitlements["application-identifier"] == "com.aaz.tweakmanager"
assert entitlements["com.apple.private.security.no-sandbox"] is True
assert entitlements["com.apple.private.security.storage.AppBundles"] is True
assert entitlements["com.apple.private.security.storage.AppDataContainers"] is True
assert entitlements["com.apple.security.application-groups"] == ["group.com.aaz.tweakmanager"]
assert "com.apple.private.security.no-container" not in entitlements
assert extension_entitlements == {
    "application-identifier": "com.aaz.tweakmanager.importer",
    "com.apple.security.application-groups": ["group.com.aaz.tweakmanager"],
}
assert app_info["CFBundleVersion"] == "29"
assert "CFBundleDocumentTypes" not in app_info
assert extension_info["CFBundleIdentifier"] == "com.aaz.tweakmanager.importer"
assert extension_info["CFBundleVersion"] == "29"
definition = extension_info["NSExtension"]
assert definition["NSExtensionPointIdentifier"] == "com.apple.share-services"
assert definition["NSExtensionPrincipalClass"] == "AAZShareViewController"
assert definition["NSExtensionAttributes"]["NSExtensionActivationRule"] == {
    "NSExtensionActivationSupportsFileWithMaxCount": 1,
}
PY
    ;;
  architectures)
    file "$app" > "$RUNNER_TEMP/aaz-app.file"
    file "$extension" > "$RUNNER_TEMP/aaz-extension.file"
    grep -Fq 'arm64' "$RUNNER_TEMP/aaz-app.file"
    grep -Fq 'arm64' "$RUNNER_TEMP/aaz-extension.file"
    ;;
  markers)
    strings "$app" > "$RUNNER_TEMP/aaz-app.strings"
    strings "$extension" > "$RUNNER_TEMP/aaz-extension.strings"
    grep -Fq 'Select All' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Unselect All' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Search packages' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Create Backup?' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Selection Updated' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Encrypted Backup' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq -- '--simulate' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq -- '--no-remove' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq -- '--assume-no' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq -- '--no-install-recommends' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq -- '--yes' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Final Restore Confirmation' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'The Restore plan changed after confirmation' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Selection Profiles' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Manage Profiles' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Importing Backup' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'share-extension-received' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'group.com.aaz.tweakmanager' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Backup saved. Open AAZ Tweak Manager' "$RUNNER_TEMP/aaz-extension.strings"
    grep -Fq 'group.com.aaz.tweakmanager' "$RUNNER_TEMP/aaz-extension.strings"
    grep -Fq 'x.com/_kkk2' "$RUNNER_TEMP/aaz-app.strings"
    grep -Fq 'Only a healthy backup can be imported' "$RUNNER_TEMP/aaz-app.strings"
    ;;
  stage)
    cp "$deb" AAZ-Tweak-Manager-rootless.deb
    shasum -a 256 AAZ-Tweak-Manager-rootless.deb
    ;;
  *)
    echo "unknown verification phase: $phase" >&2
    exit 2
    ;;
esac
