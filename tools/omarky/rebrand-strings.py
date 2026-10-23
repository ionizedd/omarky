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
 ('install/user/theme.sh', 'omarchy-theme-set "Tokyo Night"', 'omarchy-theme-set "Morganite"'),   # our own default theme
 ('etc/fastfetch/config.jsonc', 'echo \\"Omarchy $version\\"', 'echo \\"Omarky $version\\"'),   # About / fastfetch OS line
 ('etc/fastfetch/config.jsonc', '"color": { "1": "green" }', '"color": { "1": "blue" }'),   # logo in the theme accent (blue slot)
 ('bin/omarchy-agent-crash', 'reporting upstream to Omarky', 'reporting upstream to Omarchy'),   # upstream IS Omarchy
]
WORD = re.compile(r'(?<![A-Za-z0-9_])Omarchy(?![A-Za-z0-9_])')
# lines that match, parse or compare text (efibootmgr labels, grep/sed/awk patterns, [[ == ]]) are logic, not display
LOGIC = re.compile(r'\b(grep|egrep|sed|awk|efibootmgr|rg|cut)\b|\[\[:|=~|\[\[ .* == |^\s*case\b.*\bin\s*$')
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
                    if new != l:   # only real renames feed the i18n catalogs, not the "Omarchy manual" relabel
                        for lit in LITERAL.findall(l): renamed_literals[lit] = WORD.sub('Omarky', lit)
                if new != l:
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
# strings upstream allowlisted as 'no translation needed' follow the rename too
ap = 'default/i18n/extract-allowlist.json'
if os.path.exists(ap):
    raw = open(ap, encoding='utf-8').read(); d = json.loads(raw)
    new_list = [renamed_literals.get(x, x) for x in d.get('strings', [])]
    if new_list != d.get('strings'):
        d['strings'] = new_list
        open(ap, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=False) + ('\n' if raw.endswith('\n') else '')); changed += 1
# Keybinding descriptions are i18n keys (default/i18n/*/keybindings.json, keyed by the English text, hashed in
# translation-manifest.json as sha256[:12]), so a renamed description must move its key, translations and hash too.
import hashlib
KEYBIND_RENAMES = {'Omarchy menu': 'Omarky menu'}
for old, new in KEYBIND_RENAMES.items():
    for cp in glob.glob('default/i18n/*/keybindings.json'):
        raw = open(cp, encoding='utf-8').read(); d = json.loads(raw)
        if old not in d: continue
        d = {(new if k == old else k): (WORD.sub('Omarky', v) if k == old else v) for k, v in d.items()}
        open(cp, 'w', encoding='utf-8').write(json.dumps(d, indent=2, ensure_ascii=False) + ('\n' if raw.endswith('\n') else '')); changed += 1
    mp = 'default/i18n/translation-manifest.json'
    if os.path.exists(mp):
        m = open(mp, encoding='utf-8').read()
        oh, nh = hashlib.sha256(old.encode()).hexdigest()[:12], hashlib.sha256(new.encode()).hexdigest()[:12]
        m2 = m.replace(f'"keybindings:{old}": "{oh}"', f'"keybindings:{new}": "{nh}"')
        if m2 != m: open(mp, 'w', encoding='utf-8').write(m2); changed += 1
REPLACE += [
 ('default/hypr/bindings/utilities.lua', '"Omarchy menu"', '"Omarky menu"'),
 ('bin/omarchy-menu-keybindings', 'match(line, /Omarchy menu/)', 'match(line, /Om(archy|arky) menu/)'),   # user bindings may keep the old text
 ('test/shell.d/shell-shortcuts-test.sh', "omarchy:menu.root\\tOmarchy menu'", "omarchy:menu.root\\tOmarky menu'"),
]
for p, old, new in REPLACE:
    if os.path.exists(p):
        s = open(p, encoding='utf-8').read()
        if old in s: open(p, 'w', encoding='utf-8').write(s.replace(old, new)); changed += 1
print(f'rebrand-strings: {changed} line(s) changed')
