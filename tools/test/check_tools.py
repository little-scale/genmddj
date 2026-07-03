#!/usr/bin/env python3
"""Cross-check the constants duplicated across the user-tools HTML files.

The browser tools are deliberately single-file (each works offline with no imports),
so the save-format geometry, type lists and rates are duplicated by design. This
script keeps the duplication honest: canonical values come from src/main.asm and
tools/makesamples.py; every HTML copy must agree. Run by `make test`.
"""
import os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
UT   = os.path.join(ROOT, 'user-tools')

fails = []

def check(cond, msg):
    if not cond:
        fails.append(msg)

def read(p):
    return open(os.path.join(ROOT, p), encoding='utf-8').read()

asm  = read('src/main.asm')
mks  = read('tools/makesamples.py')

def asm_equ(name):
    m = re.search(r'^%s\s+equ\s+(\$?[0-9A-Fa-f]+)' % re.escape(name), asm, re.M)
    assert m, 'equate %s not found in main.asm' % name
    v = m.group(1)
    return int(v[1:], 16) if v.startswith('$') else int(v)

# ---- canonical values -------------------------------------------------------------
DATA_SIZE  = asm_equ('SAVE_DATA')          # $5D60 = 23904: the de-interleaved data block
NCH        = asm_equ('NCH')
NCHAINS    = asm_equ('NCHAINS')
INSTR_SIZE = asm_equ('INSTR_SIZE')
CONFIG_OFS = asm_equ('CONFIG_OFS')
DAC_RATE   = int(re.search(r'^DAC_RATE = (\d+)', mks, re.M).group(1))
NITYPE     = asm_equ('NITYPE')             # 6 instrument types incl PERC

# ---- per-file expectations ----------------------------------------------------------
html = {f: read('user-tools/' + f) for f in os.listdir(UT) if f.endswith('.html')}

# DATA_SIZE copies
for f in ('als2genmddj.html', 'genmddj-savetool.html', 'genmddj-wave-editor.html'):
    m = re.search(r'DATA_SIZE\s*=\s*(\d+)', html[f])
    check(m and int(m.group(1)) == DATA_SIZE,
          '%s: DATA_SIZE %s != canonical %d (SAVE_DATA in main.asm)' % (f, m and m.group(1), DATA_SIZE))

# instrument-type lists must carry all NITYPE entries (the PERC-drift bug class)
for f, var in (('genmddj-instrument-patcher.html', 'TYPES'),
               ('genmddj-savetool.html', 'ITYPE')):
    m = re.search(r'const %s\s*=\s*\[([^\]]*)\]' % var, html[f])
    n = len(re.findall(r'"[^"]+"', m.group(1))) if m else 0
    check(n == NITYPE, '%s: %s has %d entries != NITYPE %d' % (f, var, n, NITYPE))

# DAC_RATE fallback in the kit patcher tracks the shipped bake rate
m = re.search(r'DAC_RATE\s*=\s*(\d+)', html['genmddj-kit-patcher.html'])
check(m and int(m.group(1)) == DAC_RATE,
      'genmddj-kit-patcher.html: DAC_RATE fallback %s != makesamples %d' % (m and m.group(1), DAC_RATE))

# CONFIG_OFS in the savetool + bank editor
for f in ('genmddj-savetool.html', 'genmddj-bank-editor.html'):
    m = re.search(r'CONFIG_OFS\s*=\s*(\d+)', html[f])
    check(m and int(m.group(1)) == CONFIG_OFS,
          '%s: CONFIG_OFS %s != canonical %d' % (f, m and m.group(1), CONFIG_OFS))

# channel-name lists: PSG squares are T1-T3 everywhere (S1-S3 retired 2026-07-02);
# allow the two known-intentional S-mentions (YM operator-slot comment, legacy-MML parser)
for f, t in html.items():
    hits = [x for x in re.findall(r'"S[123]"', t)]
    check(not hits, '%s: stray PSG channel names %s (should be T1-T3)' % (f, hits))

# MD checksum loop present in every ROM-patching tool
for f in ('genmddj-font-patcher.html', 'genmddj-palette-patcher.html',
          'genmddj-kit-patcher.html', 'genmddj-instrument-patcher.html'):
    check('0x200' in html[f] or '512' in html[f],
          '%s: MD checksum loop not found (ROM patcher must re-checksum)' % f)

# ---- report ------------------------------------------------------------------------
if fails:
    for m in fails:
        print('DRIFT', m)
    sys.exit(1)
print('PASS tool-consistency: %d HTML tools agree with main.asm/makesamples (DATA_SIZE=%d, '
      'NITYPE=%d, DAC_RATE=%d, CONFIG_OFS=%d)' % (len(html), DATA_SIZE, NITYPE, DAC_RATE, CONFIG_OFS))
