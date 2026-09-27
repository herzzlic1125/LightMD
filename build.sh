#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
install_requested=false
if (( $# > 1 )); then
  print -u2 "Usage: ./build.sh [--install]"
  exit 2
fi
case "${1:-}" in
  "") ;;
  --install) install_requested=true ;;
  --help|-h) print "Usage: ./build.sh [--install]"; exit 0 ;;
  *) print -u2 "Usage: ./build.sh [--install]"; exit 2 ;;
esac
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

mathjax_checkout="$PWD/.build/checkouts/mathjaxswift"
mathjax_expected="00e9c3df6b1c82031c7fe3785028f3d21c0d73ba"
mathjax_actual="$(git -C "$mathjax_checkout" rev-parse HEAD)"
if [[ "$mathjax_actual" != "$mathjax_expected" ]]; then
  print -u2 "MathJaxSwift revision changed: $mathjax_actual. Review the resource patch before building."
  exit 1
fi
mathjax_constants="$mathjax_checkout/Sources/MathJaxSwift/Internal/Constants.swift"
if ! grep -q 'LightMD packaged resources' "$mathjax_constants"; then
  chmod u+w "$mathjax_constants"
  git -C "$mathjax_checkout" apply --check "$PWD/mathjax-app-resources.patch"
  git -C "$mathjax_checkout" apply "$PWD/mathjax-app-resources.patch"
fi

mermaid_expected="7a644017d37f93c8359790884e6b67fb1f747c78eb20475952404bd87190a3f8"
mermaid_actual="$(shasum -a 256 Assets/Mermaid/mermaid.tiny.js | cut -d ' ' -f 1)"
if [[ "$mermaid_actual" != "$mermaid_expected" ]]; then
  print -u2 "Mermaid bundle checksum changed. Review the vendored runtime before building."
  exit 1
fi

swift run -c release CJKParserCheck
swift build -c release --product LightMD
output_bundle="$PWD/LightMD.app"
installed_bundle="/Applications/LightMD.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
for target in "$output_bundle"; do
  if [[ -e "$target" && ( ! -d "$target" || -L "$target" ) ]]; then
    print -u2 "$target is not a regular app directory."
    exit 1
  fi
  if pgrep -f "$target/Contents/MacOS/LightMD$" >/dev/null; then
    print -u2 "Quit $target before replacing it."
    exit 1
  fi
done
if $install_requested; then
  if [[ ! -w /Applications ]]; then
    print -u2 "/Applications is not writable."
    exit 1
  fi
  if [[ -e "$installed_bundle" || -L "$installed_bundle" ]]; then
    if [[ ! -d "$installed_bundle" || -L "$installed_bundle" ]]; then
      print -u2 "$installed_bundle is not a regular app directory."
      exit 1
    fi
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_bundle/Contents/Info.plist")"
    if [[ "$installed_id" != "$bundle_id" ]]; then
      print -u2 "Installed bundle identifier does not match."
      exit 1
    fi
    if pgrep -f "$installed_bundle/Contents/MacOS/LightMD$" >/dev/null; then
      print -u2 "Quit the installed LightMD before updating it."
      exit 1
    fi
  fi
fi

package_work="$(mktemp -d "$PWD/.build/LightMD-package.XXXXXX")"
bundle="$package_work/LightMD.app"
cleanup_package() {
  if [[ -d "$package_work/previous.app" ]]; then
    print -u2 "Previous build retained at $package_work/previous.app."
  else
    rm -rf "$package_work"
  fi
}
trap cleanup_package EXIT
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/zh-Hans.lproj"
cp .build/release/LightMD "$bundle/Contents/MacOS/LightMD"
cp Info.plist "$bundle/Contents/Info.plist"
cp zh-Hans.lproj/Localizable.strings "$bundle/Contents/Resources/zh-Hans.lproj/Localizable.strings"
iconset="$package_work/LightMDIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/LightMDIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$(( size * 2 ))
  sips -z "$doubled" "$doubled" Assets/LightMDIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/LightMDIcon.icns"
ditto Assets/Mermaid "$bundle/Contents/Resources/Mermaid"
ditto .build/release/MathJaxSwift_MathJaxSwift.bundle "$bundle/Contents/Resources/MathJaxSwift_MathJaxSwift.bundle"
mkdir -p "$bundle/Contents/Resources/Licenses"
for notice in docs/licenses/*; do
  install -m 644 "$notice" "$bundle/Contents/Resources/Licenses/${notice:t}"
done
install -m 644 LICENSE "$bundle/Contents/Resources/Licenses/LightMD-LICENSE.txt"
install -m 644 ThirdPartyNotices.md "$bundle/Contents/Resources/Licenses/ThirdPartyNotices.md"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
if [[ -d "$output_bundle" ]]; then
  mv "$output_bundle" "$package_work/previous.app"
fi
if ! mv "$bundle" "$output_bundle"; then
  [[ ! -d "$package_work/previous.app" ]] || mv "$package_work/previous.app" "$output_bundle"
  exit 1
fi
rm -rf "$package_work/previous.app"
cleanup_package
trap - EXIT
print "Built $output_bundle."

if $install_requested; then
  install_work="$(mktemp -d /Applications/.LightMD-install.XXXXXX)"
  cleanup_install() {
    if [[ -d "$install_work/previous.app" ]]; then
      print -u2 "Previous LightMD preserved at $install_work/previous.app."
    else
      rm -rf "$install_work"
    fi
  }
  trap cleanup_install EXIT
  ditto "$output_bundle" "$install_work/new.app"
  codesign --verify --deep --strict "$install_work/new.app"
  if pgrep -f "$installed_bundle/Contents/MacOS/LightMD$" >/dev/null; then
    print -u2 "The installed LightMD started during the build; close it before updating."
    exit 1
  fi
  if [[ -d "$installed_bundle" ]]; then
    current_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_bundle/Contents/Info.plist")"
    if [[ "$current_id" != "$bundle_id" ]]; then
      print -u2 "Installed bundle identifier changed during the build."
      exit 1
    fi
    mv "$installed_bundle" "$install_work/previous.app"
  fi
  if ! mv "$install_work/new.app" "$installed_bundle"; then
    [[ ! -d "$install_work/previous.app" ]] || mv "$install_work/previous.app" "$installed_bundle"
    exit 1
  fi
  if ! codesign --verify --deep --strict "$installed_bundle"; then
    mv "$installed_bundle" "$install_work/failed.app"
    [[ ! -d "$install_work/previous.app" ]] || mv "$install_work/previous.app" "$installed_bundle"
    exit 1
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed_bundle"
  rm -rf "$install_work/previous.app"
  print "Installed $installed_bundle."
fi
