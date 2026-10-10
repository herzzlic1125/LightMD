#!/usr/bin/env python3
"""Capture the native reader for documentation without showing a window."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
work = root / '.build/readme-capture'
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
chrome = (root / 'WindowChrome.swift').read_text().replace('private struct ChromeCapsuleControls: View', 'struct ChromeCapsuleControls: View')
(work / 'WindowChrome-test.swift').write_text(chrome)
flags = ['-O', '-parse-as-library', '-target', f'{platform.machine()}-apple-macosx13.0', '-I', str(release / 'Modules')]
for checkout, subdir in [('swift-cmark', 'extensions/include'), ('swift-cmark', 'src/include'), ('swift-markdown', 'Sources/CAtomic/include')]:
    include = root / '.build/checkouts' / checkout / subdir
    flags += ['-Xcc', f'-fmodule-map-file={include}/module.modulemap', '-Xcc', '-I', '-Xcc', str(include)]
objects = (release / 'LightMD.product/Objects.LinkFileList').read_text().splitlines()
objects = [obj for obj in objects if '/LightMD.build/' not in obj]
run('swiftc', *flags, work / 'LightMD-test.swift',
    *[root / name for name in ['EditorSupport.swift', 'DocumentEditing.swift', 'LiveEditing.swift', 'SessionStore.swift',
                               'MathMarkup.swift', 'MathRenderer.swift', 'MediaSupport.swift',
                               'WebRenderSupport.swift', 'MermaidSupport.swift', 'PDFExport.swift']],
    work / 'WindowChrome-test.swift', root / 'Checks/Documentation/CaptureReading.swift', *objects, '-o', work / 'capture-reading')
for language, kind, formulas, height in [
    ('en', 'type', 0, 730), ('en', 'math', 3, 800),
    ('zh', 'type', 0, 730), ('zh', 'math', 3, 800),
]:
    run(work / 'capture-reading',
        root / f'docs/examples/reading-{language}-{kind}.md',
        root / f'docs/images/reading-{language}-{kind}.png', formulas, height)
