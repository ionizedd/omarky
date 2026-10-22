#!/usr/bin/env python3
"""Rename user-visible "Omarchy" to "Omarky" in the runtime repo -- repeatably.

Why a script and not a one-off edit: upstream moves ~30 commits a day and edits the same lines.
After `git merge upstream/quattro`, take upstream's side of any conflict that is only a rename,
then run this, then run the test suite. It is idempotent.

What it will NOT touch (each of these is matched by other code or a test, or is attribution):
  comments, identifiers (whole-word match only), URLs, plugin "author" fields, window titles and
  hyprland rules (default/hypr/), the firmware boot label, VS Code / Obsidian theme ids, the
  update-inhibitor identity strings, and the exact messages tests assert (PINNED below).
Rationale per skipped item: logs/strings-audit.md in the fork workspace (Haiku audit, spot-checked).
"""
import os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
os.chdir(ROOT)

SKIP_FILES = {
 'bin/omarchy-theme-set-vscode', 'bin/omarchy-theme-set-obsidian', 'bin/omarchy-setup-direct-boot',
 'bin/omarchy-windows-vm', 'bin/omarchy-update-stay-awake', 'bin/omarchy-migrate',
 'bin/omarchy-migrate-notify', 'bin/omarchy-update-available', 'bin/omarchy-menu-keybindings',
 'bin/omarchy-launch-floating-terminal-with-presentation', 'bin/omarchy-theme-set-hermes',
 'shell/plugins/dev-gallery/GalleryPanel.qml', 'bin/omarchy-upgrade-to-quattro',
}
SKIP_PREFIX = ('default/hypr/', 'tools/')
SKIP_LINES = {('bin/omarchy-restart-shell', 'Refusing to restart Omarchy shell while the session is locked.')}
# verbatim messages that tests assert
PINNED = ('has no $channel channel for', 'has no $pacman_channel channel for', 'has no edge channel for',
          'has no stable channel for', 'Install the matching Omarchy package', 'which Omarchy does not clone from',
          'to safely update Omarchy.', 'which Omarchy could run instead of')
# exact text swaps that are not plain renames
REPLACE = [
 ('install/provisioning/setup-form.sh', '(like dhh)', '(like fleagle)'),
 ('bin/omarchy-provision-owner', 'Beautiful, Fun & Agentic Linux by DHH', 'A private, personal Linux — yours.'),
]
WORD = re.compile(r'(?<![A-Za-z0-9_])Omarchy(?![A-Za-z0-9_])')
# lines that match, parse or compare text (efibootmgr labels, grep/sed/awk patterns, [[ == ]]) are logic, not display
LOGIC = re.compile(r'\b(grep|egrep|sed|awk|efibootmgr|rg|cut)\b|\[\[:|=~|\[\[ .* == |\bcase\b')
URLISH = re.compile(r'https?://\S*Omarchy|github\.com/\S*Omarchy|\.Omarchy|Omarchy\.\w')

changed = 0
renamed_literals = {}   # old UI literal -> new, so the i18n catalogs (keyed by English text) follow
LITERAL = re.compile(r'"([^"\\]*Omarchy[^"\\]*)"')
for root in ['shell', 'default/omarchy', 'config', 'bin', 'install']:
    for dp, _, fns in os.walk(root):
        for f in fns:
            p = os.path.join(dp, f).replace(os.sep, '/')
            if p in SKIP_FILES or p.startswith(SKIP_PREFIX) or p.endswith(('.md', '.png', '.ttf', '.svg', '.webp')):
                continue
            try: lines = open(p, encoding='utf-8').read().split('\n')
            except Exception: continue
            n = 0
            for i, l in enumerate(lines):
                if 'Omarchy' not in l or any(k[0] == p and k[1] in l for k in SKIP_LINES): continue
                if l.lstrip().startswith(('#', '//', '--', ';')) and 'omarchy:summary=' not in l: continue
                if '"author"' in l or any(s in l for s in PINNED) or URLISH.search(l) or LOGIC.search(l): continue
                if 'learn.omarchy' in l:   # opens upstream's manual, so say so
                    new = l.replace('"label":"Omarchy"', '"label":"Omarchy manual"')
                else:
                    new = WORD.sub('Omarky', l)
                if new != l:
                    for lit in LITERAL.findall(l): renamed_literals[lit] = WORD.sub('Omarky', lit)
                    lines[i] = new; n += 1
            if n:
                open(p, 'w', encoding='utf-8').write('\n'.join(lines)); changed += n
# default/i18n/en/menu.json must mirror the menu definition's labels (i18n-test): same two relabels
p = 'default/i18n/en/menu.json'
if os.path.exists(p):
    j = open(p, encoding='utf-8').read(); out = []; key = None
    for line in j.split('\n'):
        m = re.match(r'\s*"((?:learn|update)\.omarchy)": \{', line)
        if m: key = m.group(1)
        if key and line.strip() == '"label": "Omarchy"':
            line = line.replace('"Omarchy"', '"Omarchy manual"' if key.startswith('learn') else '"Omarky"'); changed += 1; key = None
        out.append(line)
    open(p, 'w', encoding='utf-8').write('\n'.join(out))
# flat catalogs (English text -> translation): rename the key (and English value) of every literal we renamed
import json, glob
for cp in glob.glob('default/i18n/*/*.json'):
    if os.path.basename(cp) == 'keybindings.json': continue   # keyed by the Hyprland binding text, which we leave alone
    raw = open(cp, encoding='utf-8').read()
    try: d = json.loads(raw)
    except Exception: continue
    if not isinstance(d, dict) or any(isinstance(v, dict) for v in d.values()): continue
    if not any(k in renamed_literals for k in d): continue
    d2 = {renamed_literals.get(k, k): (renamed_literals.get(v, v) if v == k else v) for k, v in d.items()}
    open(cp, 'w', encoding='utf-8').write(json.dumps(d2, indent=2, ensure_ascii=False) + ('\n' if raw.endswith('\n') else '')); changed += 1
for p, old, new in REPLACE:
    if os.path.exists(p):
        s = open(p, encoding='utf-8').read()
        if old in s: open(p, 'w', encoding='utf-8').write(s.replace(old, new)); changed += 1
print(f'rebrand-strings: {changed} line(s) changed')
