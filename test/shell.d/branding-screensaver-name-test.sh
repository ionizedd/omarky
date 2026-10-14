#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/home/.config/omarchy/branding"
printf '#!/bin/bash\necho launched >>"$TEST_DIR/launches"\n' >"$tmpdir/bin/omarchy-launch-screensaver"
chmod +x "$tmpdir/bin/omarchy-launch-screensaver"

branding() {
  PATH="$tmpdir/bin:$ROOT/bin:$PATH" TEST_DIR="$tmpdir" HOME="$tmpdir/home" "$ROOT/bin/omarchy-branding-screensaver" "$@"
}

screensaver="$tmpdir/home/.config/omarchy/branding/screensaver.txt"
printf 'old art\n' >"$screensaver"

branding name veran
[[ $(<"$screensaver") == "$("$ROOT/bin/omarchy-ascii" veran)" ]] || fail "the screensaver shows the name in omarchy ascii"
pass "the screensaver shows the name in omarchy ascii"

[[ $(<"$tmpdir/home/.config/omarchy/branding/name") == "veran" ]] || fail "the name is kept in an editable file"
pass "the name is kept in an editable file"

[[ -f $tmpdir/launches ]] || fail "setting the name previews the screensaver"
pass "setting the name previews the screensaver"

branding name two words
[[ $(<"$tmpdir/home/.config/omarchy/branding/name") == "two words" ]] || fail "a name can be several words"
pass "a name can be several words"

# A name with nothing the font can draw must not wipe the art that is there.
cp "$screensaver" "$tmpdir/before"
branding name 123 2>/dev/null && fail "a name with no letters is refused"
cmp -s "$screensaver" "$tmpdir/before" || fail "a refused name leaves the screensaver art alone"
pass "a refused name leaves the screensaver art alone"
