#!/usr/bin/env python3
"""Validate standalone preview structure and pure rendering functions; no browser."""
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import base64

root = Path(__file__).resolve().parents[2]
work = root / '.build/preview-check'
work.mkdir(parents=True, exist_ok=True)
class Check(HTMLParser):
    void = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
    def __init__(self):
        super().__init__(); self.stack = []; self.ids = set(); self.script = False; self.current = ''; self.scripts = []
    def handle_starttag(self, tag, attrs):
        if tag not in self.void: self.stack.append(tag)
        for key, value in attrs:
            if key == 'id':
                assert value not in self.ids, value
                self.ids.add(value)
        if tag == 'script':
            self.script = True
            source = dict(attrs).get('src', '')
            if source.startswith('data:application/javascript;base64,'):
                self.current = base64.b64decode(source.split(',', 1)[1]).decode()
    def handle_startendtag(self, tag, attrs): pass
    def handle_data(self, data):
        if self.script: self.current += data
    def handle_endtag(self, tag):
        assert self.stack and self.stack[-1] == tag, (tag, self.stack)
        self.stack.pop()
        if tag == 'script':
            self.scripts.append(self.current); self.current = ''; self.script = False

check = Check()
check.feed((root / 'LightMD-preview.html').read_text())
assert '.page p { orphans: 3; widows: 3; break-inside: avoid; page-break-inside: avoid; }' in (root / 'LightMD-preview.html').read_text()
assert not check.stack and len(check.scripts) == 2
for index, script in enumerate(check.scripts):
    path = work / f'inline-{index}.js'; path.write_text(script)
    subprocess.run(['node', '--check', str(path)], check=True)
js = check.scripts[-1]
a = js.index('    const formulaExamples'); b = js.index('    let tabs =', a)
c = js.index('    function escapeHTML'); d = js.index('    async function decodeFile', c)
assertions = r'''
const assert = require('node:assert/strict');
const html = render(featureSource.replaceAll('\\`','`'));
assert.equal((html.match(/class="formula /g)||[]).length,10);
assert.equal((html.match(/class="mermaid-block"/g)||[]).length,1);
assert.equal((html.match(/class="local-image"/g)||[]).length,1);
assert.equal((html.match(/<h3 /g)||[]).length,12);
assert(html.includes('∯') && html.includes('<menclose notation="box">'));
assert.equal((render(longDocumentSource).match(/class="formula /g)||[]).length,550);
const cachedCount = formulaHTMLCache.size;
render(longDocumentSource);
assert.equal(formulaHTMLCache.size, cachedCount);
assert(html.includes('A[开始]') && html.includes('data-source-end='));
assert(inline('`$x_i^2$`').includes('<code>$x_i^2$</code>'));
assert(!render('```js\n$x_i^2$\n```').includes('class="formula'));
assert(!inline('价格 $5 和 $10').includes('<math'));
console.log('Preview pure rendering: formulas, Mermaid fences, images, source spans, code and prices passed');
'''
path = work / 'render-check.js'; path.write_text(js[a:b] + js[c:d] + assertions)
subprocess.run(['node', str(path)], check=True)
layout_start = js.index('    function textWidth(')
layout_end = js.index('    function setOutlineWidth(', layout_start)
layout_assertions = r'''
const assert = require('node:assert/strict');
const properties = new Map();
const readingArea = {clientWidth: 1000, style: {setProperty: (key, value) => properties.set(key, value)}};
const documentScroll = {get clientWidth() {return parseFloat(properties.get('--preview-width')) - 15;}};
const page = {style: {}}, outline = {style: {}};
const attributes = new Map(), outlineResize = {setAttribute: (key, value) => attributes.set(key, value)};
let outlineWidth = 221, visualInset = 0, targetInset = 0, visualModeProgress = 0, splitRatio = .4, modeTransitioning = false;
function close(a, b) {assert(Math.abs(a-b) < .001, `${a} != ${b}`);}
positionReadingArea();
close(parseFloat(properties.get('--preview-width')), 1000);
targetInset = visualInset = 221;
positionReadingArea();
close(parseFloat(properties.get('--preview-width')), 779);
close(parseFloat(properties.get('--outline-width')), 221);
assert.equal(outlineResize.tabIndex, 0);
visualModeProgress = 1;
positionReadingArea();
close(parseFloat(properties.get('--preview-left')), 408.4);
close(parseFloat(properties.get('--preview-width')), 370.6);
visualModeProgress = 0; readingArea.clientWidth = 680;
outlineWidth = visualInset = targetInset = 420;
positionReadingArea();
close(parseFloat(properties.get('--preview-width')), 306);
close(parseFloat(properties.get('--outline-width')), 374);
close(clampOutline(10, 680), 160);
visualInset = targetInset = 0;
positionReadingArea();
assert.equal(outlineResize.tabIndex, -1);
console.log('Preview outline limits and separate reading viewport geometry: passed');
'''
layout_path = work / 'layout-check.js'
layout_path.write_text(js[layout_start:layout_end] + layout_assertions)
subprocess.run(['node', str(layout_path)], check=True)
composition_start = js.index('    let sourceComposing = false;')
composition_end = js.index('    function setMode(next)', composition_start)
composition_assertions = r'''
const assert = require('node:assert/strict');
const callbacks = new Map(), pending = new Map();
let sequence = 0, renderTimer, active = 0, renders = 0, redraws = 0;
const sourceEditor = {value:'before', addEventListener:(name, fn) => callbacks.set(name,fn)};
const tabs = [{source:'before',savedSource:'before',path:'/example.md'}];
const autoSaveTimers = new WeakMap();
const documentHistory = new WeakMap();
function setTimeout(fn) {const id=++sequence; pending.set(id,fn); return id;}
function clearTimeout(id) {pending.delete(id);}
function scheduleSession() {}
function rebuildSourceMirror() {}
function drawTabs() {redraws++;}
function redrawEditedPreview() {renders++;}
renderTimer = setTimeout(() => {throw Error('obsolete preview');});
autoSaveTimers.set(tabs[0],setTimeout(() => {throw Error('obsolete autosave');}));
callbacks.get('compositionstart')();
sourceEditor.value='before nihao';
callbacks.get('input')({isComposing:true});
assert.equal(tabs[0].source,'before');
assert.equal(pending.size,0);
sourceEditor.value='before 你好';
callbacks.get('compositionend')();
callbacks.get('input')({isComposing:false});
assert.equal(tabs[0].source,'before 你好');
assert.equal(redraws,1);
assert.equal(pending.size,2);
for (const fn of pending.values()) fn();
assert.equal(renders,1);
assert.equal(tabs[0].savedSource,'before 你好');
console.log('Preview composition deferral, timer cancellation and one committed update: passed');
'''
composition_path = work / 'composition-check.js'
composition_split = composition_assertions.index('\nrenderTimer = setTimeout')
history_start = js.index('    function sourceLineRanges(')
history_end = js.index('    function installLiveEditing(', history_start)
composition_path.write_text(composition_assertions[:composition_split] + js[history_start:history_end]
                            + js[composition_start:composition_end]
                            + composition_assertions[composition_split:])
subprocess.run(['node', str(composition_path)], check=True)
live_source_assertions = r'''
const assert = require('node:assert/strict');
const documentHistory = new WeakMap();
const raw = '# 标题😀\r\n\r\nA **bold** $x^2$\r\n\r\nTail';
const rows = sourceLineRanges(raw);
assert.equal(raw.slice(rows[2].start, rows[2].end), 'A **bold** $x^2$');
const next = spliceSource(raw, rows[2].start, rows[2].end, 'Changed\n\n## New');
assert(next.startsWith('# 标题😀\r\n\r\n') && next.endsWith('\r\n\r\nTail'));
const tab = {source:raw};
rememberDocumentEdit(tab,raw,next);
assert.deepEqual(documentHistory.get(tab).undo[0],{before:raw,after:next});
const node={matches:()=>true,dataset:{sourceLine:'2',sourceEnd:'3'},querySelectorAll:()=>[]};
assert.deepEqual(liveNodeRange(node,raw),{start:rows[2].start,end:rows[2].end});
console.log('Preview live UTF-16 source patches, CRLF and document history: passed');
'''
node_range_start = js.index('    function liveNodeRange(')
node_range_end = js.index('    function updateLiveText(', node_range_start)
live_path = work / 'live-source-check.js'
live_path.write_text(js[history_start:history_end] + js[node_range_start:node_range_end] + live_source_assertions)
subprocess.run(['node', str(live_path)], check=True)
print(f'HTML structure, {len(check.ids)} unique IDs and both inline JavaScript scripts: passed')
