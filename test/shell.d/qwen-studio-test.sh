#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pkgbuild_dir="$ROOT/default/pkgbuilds/qwen-studio"

# The local sources makepkg checks must match their recorded sums, or a fixed
# patch ships with stale ones and every build fails.
mapfile -t sums < <(sed -n "/^sha256sums=(/,/)/p" "$pkgbuild_dir/PKGBUILD" | grep -oE "'[^']*'" | tr -d "'")
mapfile -t sources < <(sed -n "/^source=(/,/)/p" "$pkgbuild_dir/PKGBUILD" | grep -oE "[\"'][^\"']*[\"']" | tr -d "\"'")
(( ${#sums[@]} == ${#sources[@]} )) || fail "the PKGBUILD has a checksum for every source"
for i in "${!sources[@]}"; do
  [[ ${sources[i]} == *::git+* ]] && continue
  actual=$(sha256sum "$pkgbuild_dir/${sources[i]}" | cut -d' ' -f1)
  [[ $actual == "${sums[i]}" ]] || fail "the checksum for ${sources[i]} matches the file" "expected ${sums[i]}, got $actual"
done
pass "the Qwen Studio PKGBUILD's checksums match its local sources"

grep -q '^_commit=[0-9a-f]\{40\}$' "$pkgbuild_dir/PKGBUILD" || fail "the upstream source is pinned to a full commit"
pass "the upstream source is pinned to a full commit"

# The fix is the point of building from source: the binary must not look for
# the MCP bridge under the build machine's crate directory, and release builds
# must not open the MCP bridge plugin's network socket.
patch_file="$pkgbuild_dir/qwen-studio-fixes.patch"
grep -q '^-        let bridge_path = concat!(env!("CARGO_MANIFEST_DIR"), "/mcp-bridge.mjs");' "$patch_file" ||
  fail "the patch replaces the build-time MCP bridge path"
grep -q '^+    #\[cfg(debug_assertions)\]' "$patch_file" && grep -q 'tauri_plugin_mcp_bridge::init()' "$patch_file" ||
  fail "the patch keeps the MCP bridge plugin out of release builds"
pass "the patch carries the MCP path and network socket fixes"

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/makepkg" <<'SCRIPT'
#!/bin/bash
printf 'makepkg:%s\n' "$*" >>"$TEST_LOG"
for file in PKGBUILD qwen-studio-fixes.patch qwen-studio.desktop; do
  [[ -f $file ]] && printf 'has:%s\n' "$file" >>"$TEST_LOG"
done
SCRIPT
cat >"$tmp_dir/bin/setsid" <<'SCRIPT'
#!/bin/bash
printf 'setsid:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
cat >"$tmp_dir/bin/omarchy-pkg-drop" <<'SCRIPT'
#!/bin/bash
printf 'drop:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
cat >"$tmp_dir/bin/pkill" <<'SCRIPT'
#!/bin/bash
printf 'pkill:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
chmod +x "$tmp_dir/bin"/*

export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir/bin:$PATH"
export OMARCHY_PATH="$ROOT"

if (( EUID == 0 )); then
  skip "Qwen Studio install builds as the desktop user (running as root)"
else
  : >"$TEST_LOG"
  "$ROOT/bin/omarchy-install-ai-qwen" >/dev/null
  grep -Fxq 'makepkg:-sri --noconfirm' "$TEST_LOG" || fail "the installer builds and installs with makepkg" "$(<"$TEST_LOG")"
  for file in PKGBUILD qwen-studio-fixes.patch qwen-studio.desktop; do
    grep -Fxq "has:$file" "$TEST_LOG" || fail "the build directory has $file" "$(<"$TEST_LOG")"
  done
  grep -Fxq 'setsid:uwsm-app -- qwen-studio.desktop' "$TEST_LOG" || fail "the installer opens the app" "$(<"$TEST_LOG")"
  pass "the Qwen Studio installer builds the packaged PKGBUILD and opens the app"
fi

rm -rf "$tmp_dir/home"
mkdir -p "$tmp_dir/home/.config/qwen-studio" "$tmp_dir/home/.local/share/com.qwen.studio" "$tmp_dir/home/.cache/com.qwen.studio" "$tmp_dir/home/.config/Claude"
: >"$TEST_LOG"
HOME="$tmp_dir/home" "$ROOT/bin/omarchy-remove-ai-qwen" >/dev/null
grep -Fxq 'pkill:-x qwen-studio' "$TEST_LOG" || fail "Qwen Studio removal quits the running app first"
grep -Fxq 'drop:qwen-studio' "$TEST_LOG" || fail "Qwen Studio removal drops the package"
[[ ! -e $tmp_dir/home/.config/qwen-studio && ! -e $tmp_dir/home/.local/share/com.qwen.studio && ! -e $tmp_dir/home/.cache/com.qwen.studio ]] ||
  fail "Qwen Studio removal deletes its settings, sign-in and cache"
[[ -d $tmp_dir/home/.config/Claude ]] || fail "Qwen Studio removal leaves other apps alone"
pass "Qwen Studio removal deletes only its own settings, sign-in and cache"

for row in install.ai.qwen remove.ai.qwen; do
  grep -q "^  \"$row\":" "$ROOT/default/omarchy/omarchy-menu.jsonc" || fail "the menu has $row"
done
pass "the menu offers installing and removing Qwen Studio"
