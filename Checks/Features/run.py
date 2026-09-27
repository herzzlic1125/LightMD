#!/usr/bin/env python3
"""Release/offscreen regression checks; no user session, window activation or browser."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
work = root / '.build/lightmd-feature-check'
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
(work / 'LightMD-test.swift').write_text(source.replace('@main\nstruct LightMDApp: App {', 'struct LightMDApp: App {'))
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
                               'MathMarkup.swift', 'MathRenderer.swift', 'MediaSupport.swift',
                               'WebRenderSupport.swift', 'MermaidSupport.swift', 'PDFExport.swift']],
    root / 'Checks/Features/FeatureChecks.swift', root / 'Checks/Features/ExportChecks.swift', *objects, '-o', macos / 'FeatureCheck')
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
    run(macos / 'FeatureCheck', work)
finally:
    hidden.rename(resource)
print('signed_bundle_without_build_resource_fallback=passed')
