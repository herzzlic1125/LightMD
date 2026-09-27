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
assert.equal((html.match(/class="formula /g)||[]).length,5);
assert.equal((html.match(/class="mermaid-block"/g)||[]).length,1);
assert.equal((html.match(/class="local-image"/g)||[]).length,1);
assert.equal((html.match(/<h3 /g)||[]).length,12);
assert(html.includes('A[开始]') && html.includes('data-source-end='));
assert(inline('`$x_i^2$`').includes('<code>$x_i^2$</code>'));
assert(!render('```js\n$x_i^2$\n```').includes('class="formula'));
assert(!inline('价格 $5 和 $10').includes('<math'));
console.log('Preview pure rendering: formulas, Mermaid fences, images, source spans, code and prices passed');
'''
path = work / 'render-check.js'; path.write_text(js[a:b] + js[c:d] + assertions)
subprocess.run(['node', str(path)], check=True)
print(f'HTML structure, {len(check.ids)} unique IDs and both inline JavaScript scripts: passed')
