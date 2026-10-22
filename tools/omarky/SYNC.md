# Syncing Omarky with upstream Omarchy

Upstream (omacom/omarchy, omarchy-iso, omarchy-pkgs) moves ~30 commits a day and sometimes rewrites history.
A one-off hand rename drifts and conflicts constantly, so Omarky's rebrand is **scripts that re-run**:

| Repo | Repeatable rebrand | Hand-kept commits (small, rarely conflict) |
|---|---|---|
| `omarchy` (runtime) | `tools/omarky/rebrand-strings.py` (display strings), `tools/omarky/gen-branding.py` (images + font glyph) | Firefox default, IgnorePkg pin, privacy defaults, screensaver-name, README |
| `omarchy-iso` | none yet (few strings; fix conflicts by hand) | rebrand of installer/boot-menu strings, installer modes (replace-one-partition), dashboard ring |
| `omarchy-pkgs` | `omarky/apply-branding.py` (os-release) | — |

## Procedure (per repo)
1. `git fetch upstream`
2. `git checkout -b omarky-sync upstream/<quattro|master>` — start from upstream, not from our branch.
3. Cherry-pick **only our substantive commits**, in order, skipping the generated rename commit. Use `git log omarky --author=ionizedd --reverse`.
   Resolve conflicts by keeping upstream's new code and re-applying our intent (e.g. keep their `OMARCHY_FORM_TIMEZONE_DEFAULT`, drop the geo-IP fallback).
4. Re-run the rebrand scripts, commit the generated result as its own commit.
5. Test with a baseline: run the suite on a pristine `upstream/<branch>` worktree AND on ours; only failures unique to ours matter
   (this Ubuntu host fails ~58 tests by environment: missing lua/pacman-conf/Hyprland). Some tests are flaky under load: rerun a single failure ONCE alone.
6. Build the ISO from the synced trees (`iso/bin/omarchy-iso-make --local-source ../omarchy ../omarchy-pkgs`), install in a VM, check.
7. Only then move `omarky` to the synced branch (`git branch -f omarky omarky-sync`) and push.

## Pitfalls we hit
- `pgrep -f` / `pkill -f` patterns match your own shell command line; use `docker ps` or a log mtime instead.
- Strings code matches on (Limine "Omarchy" entry check, window titles, firmware boot label, update-inhibitor `--why`) must NOT be renamed; the audit is `logs/strings-audit.md`.
- Local/edge builds install the `omarchy-settings-dev` / `omarchy-dev` recipes, not the stable ones — patch both.
- After `Update System` risk: our packages are pinned with IgnorePkg until we host our own repo.
