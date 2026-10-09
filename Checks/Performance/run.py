#!/usr/bin/env python3
"""Instrumented native long-document checks; no visible window or browser."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
    raise SystemExit('Usage: python3 Checks/Performance/run.py /path/to/document.md')

root = Path(__file__).resolve().parents[2]
work = root / '.build/lightmd-scroll-check'
work.mkdir(parents=True, exist_ok=True)

def run(*args):
    result = subprocess.run([str(x) for x in args], cwd=root)
    if result.returncode:
        raise SystemExit(f"{args[0]} failed with exit code {result.returncode}")

# build.sh applies dependency patches. Use it before this check on a fresh checkout.
run('swift', 'build', '-c', 'release', '--product', 'LightMD')
release = (root / '.build/release').resolve()
source = (root / 'LightMD.swift').read_text()
assert source.count('@main\nstruct LightMDApp: App {') == 1
source = source.replace('@main\nstruct LightMDApp: App {', 'struct LightMDApp: App {')
start = source.index('struct MarkdownBlockView: View {')
source = source[:start] + source[start:].replace('    var body: some View {', '    var body: some View {\n        let _ = (ScrollMetrics.bodies += 1)', 1)
# Exercise the divider's state and scroll coordination in the offscreen view.
# This hook exists only in the compiled check, never in the shipped app.
start = source.index('struct ReaderView: View {')
source = source[:start] + source[start:].replace('        .onAppear {', '''        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("scroll-check-divider"))) { event in
            if let ratio = event.userInfo?["ratio"] as? CGFloat { editSplitRatio = ratio }
            else if event.userInfo?["start"] as? Bool == true { scrollSync.beginDividerResize() }
            else { scrollSync.endDividerResize(); scrollSync.alignSourceToPreview() }
        }
        .onAppear {''', 1)
(work / 'LightMD-test.swift').write_text(source)
math = (root / 'MathRenderer.swift').read_text().replace('        queue.async {\n            do {\n                let markup', '        Task { @MainActor in ScrollMetrics.renders += 1 }\n        queue.async {\n            do {\n                let markup')
(work / 'MathRenderer-test.swift').write_text(math)
flags = ['-O', '-parse-as-library', '-target', f'{platform.machine()}-apple-macosx13.0', '-I', str(release / 'Modules')]
for checkout, subdir in [('swift-cmark', 'extensions/include'), ('swift-cmark', 'src/include'), ('swift-markdown', 'Sources/CAtomic/include')]:
    include = root / '.build/checkouts' / checkout / subdir
    flags += ['-Xcc', f'-fmodule-map-file={include}/module.modulemap', '-Xcc', '-I', '-Xcc', str(include)]
objects = (release / 'LightMD.product/Objects.LinkFileList').read_text().splitlines()
objects = [obj for obj in objects if '/LightMD.build/' not in obj]
bundle = work / 'FeatureCheck.app'
macos = bundle / 'Contents/MacOS'
resources = bundle / 'Contents/Resources'
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
plist = {'CFBundleIdentifier': 'local.lightmd.offscreen-check', 'CFBundleName': 'FeatureCheck',
         'CFBundleExecutable': 'FeatureCheck', 'CFBundlePackageType': 'APPL', 'LSBackgroundOnly': True}
with (bundle / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump(plist, file)
run('swiftc', *flags, work / 'LightMD-test.swift',
    *[root / name for name in ['EditorSupport.swift', 'WindowChrome.swift', 'SessionStore.swift',
                               'MathMarkup.swift', 'MediaSupport.swift',
                               'WebRenderSupport.swift', 'MermaidSupport.swift', 'PDFExport.swift']],
    work / 'MathRenderer-test.swift', root / 'Checks/Performance/ScrollChecks.swift', *objects, '-o', macos / 'FeatureCheck')
resource_name = 'MathJaxSwift_MathJaxSwift.bundle'
resource = release / resource_name
run('ditto', resource, resources / resource_name)
run('ditto', root / 'Assets/Mermaid', resources / 'Mermaid')
run('codesign', '--force', '--deep', '--sign', '-', bundle)
run('codesign', '--verify', '--deep', '--strict', bundle)
# Prove bundled math works without the absolute build-directory fallback.
hidden = release / (resource_name + '.feature-check-hidden')
if hidden.exists():
    raise RuntimeError(f'Previous resource check needs recovery: {hidden}')
resource.rename(hidden)
try:
    run(macos / 'FeatureCheck', work, sys.argv[1])
finally:
    hidden.rename(resource)
print('signed_bundle_without_build_resource_fallback=passed')
