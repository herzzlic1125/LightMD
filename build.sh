#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
swift package resolve

checkout="$PWD/.build/checkouts/swift-cmark"
expected_revision="0c8947bbd58c491c54aae114aca40621cddc8357"
actual_revision="$(git -C "$checkout" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
  print -u2 "swift-cmark revision changed: $actual_revision. Review the CJK patch before building."
  exit 1
fi

parser="$checkout/src/inlines.c"
if ! grep -q 'is_cjk_emphasis_punctuation' "$parser"; then
  chmod u+w "$parser"
  git -C "$checkout" apply --check "$PWD/cmark-cjk-emphasis.patch"
  git -C "$checkout" apply "$PWD/cmark-cjk-emphasis.patch"
fi

swift run -c release CJKParserCheck
swift build -c release --product LightMD
bundle="$PWD/LightMD.app"
installed_bundle="/Applications/LightMD.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
if pgrep -f "$bundle/Contents/MacOS/LightMD$" >/dev/null; then
  print -u2 "Quit this LightMD.app before replacing its executable."
  exit 1
fi
if [[ -e "$installed_bundle" || -L "$installed_bundle" ]]; then
  if [[ ! -d "$installed_bundle" || -L "$installed_bundle" ]]; then
    print -u2 "$installed_bundle is not an app directory; refusing to replace it."
    exit 1
  fi
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_bundle/Contents/Info.plist")"
  if [[ "$installed_id" != "$bundle_id" ]]; then
    print -u2 "$installed_bundle has bundle ID $installed_id; expected $bundle_id."
    exit 1
  fi
  if pgrep -f "$installed_bundle/Contents/MacOS/LightMD$" >/dev/null; then
    print -u2 "Quit the LightMD installed in /Applications before updating it."
    exit 1
  fi
  if [[ ! -w /Applications ]]; then
    print -u2 "/Applications is not writable; cannot update the installed LightMD."
    exit 1
  fi
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/zh-Hans.lproj"
cp .build/release/LightMD "$bundle/Contents/MacOS/LightMD"
cp Info.plist "$bundle/Contents/Info.plist"
cp zh-Hans.lproj/Localizable.strings "$bundle/Contents/Resources/zh-Hans.lproj/Localizable.strings"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
print "Built $bundle with CJK Markdown emphasis support."

if [[ -d "$installed_bundle" ]]; then
  install_work="$(mktemp -d /Applications/.LightMD-install.XXXXXX)"
  cleanup_install() {
    if [[ -d "$install_work/previous.app" ]]; then
      print -u2 "Previous LightMD preserved at $install_work/previous.app."
    else
      rm -rf "$install_work"
    fi
  }
  trap cleanup_install EXIT
  ditto "$bundle" "$install_work/new.app"
  codesign --verify --deep --strict "$install_work/new.app"
  staged_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_work/new.app/Contents/Info.plist")"
  if [[ "$staged_id" != "$bundle_id" ]]; then
    print -u2 "Staged app bundle ID changed; refusing to install it."
    exit 1
  fi
  if pgrep -f "$installed_bundle/Contents/MacOS/LightMD$" >/dev/null; then
    print -u2 "The installed LightMD started during the build; close it before updating."
    exit 1
  fi
  mv "$installed_bundle" "$install_work/previous.app"
  if ! mv "$install_work/new.app" "$installed_bundle"; then
    mv "$install_work/previous.app" "$installed_bundle"
    print -u2 "Install failed; restored the previous LightMD.app."
    exit 1
  fi
  if ! codesign --verify --deep --strict "$installed_bundle"; then
    mv "$installed_bundle" "$install_work/failed.app"
    mv "$install_work/previous.app" "$installed_bundle"
    print -u2 "Installed app failed signature verification; restored the previous LightMD.app."
    exit 1
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed_bundle"
  rm -rf "$install_work/previous.app"
  print "Updated $installed_bundle."
fi
