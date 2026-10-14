#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

export PATH="$ROOT/bin:$PATH"

TMPDIR=""

cleanup() {
  if [[ -n $TMPDIR && -d $TMPDIR ]]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

require_command jq
require_command node

copy_url_id=$(node - <<'JS' "$ROOT/default/chromium/extensions/copy-url/manifest.json"
const crypto = require('crypto')
const fs = require('fs')

const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const hash = crypto.createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest()
const alphabet = 'abcdefghijklmnop'
let id = ''

for (const byte of hash.subarray(0, 16)) {
  id += alphabet[byte >> 4]
  id += alphabet[byte & 0x0f]
}

process.stdout.write(id)
JS
)

[[ $copy_url_id == "bgpiichlckmfanooecilcjemknkcpngb" ]] ||
  fail "copy-url extension manifest has the stable id" "$copy_url_id"
pass "copy-url extension manifest has the stable id"

jq -e '
  .manifest_version == 3 and
  (.permissions | index("nativeMessaging")) and
  (.permissions | index("notifications") | not) and
  (.permissions | index("clipboardWrite") | not) and
  (.permissions | index("offscreen") | not) and
  .background.service_worker == "background-4.js"
' "$ROOT/default/chromium/extensions/copy-url/manifest.json" >/dev/null ||
  fail "copy-url extension uses its native messaging host"
grep -q "sendNativeMessage('com.omarchy.copy_url'" \
  "$ROOT/default/chromium/extensions/copy-url/background-4.js" ||
  fail "copy-url extension sends URLs to its native messaging host"
pass "copy-url extension uses its native messaging host"

jq -e '.action != null' "$ROOT/default/chromium/extensions/copy-url/manifest.json" >/dev/null &&
  grep -q 'action.onClicked' "$ROOT/default/chromium/extensions/copy-url/"background-*.js ||
  fail "copy-url extension is clickable from the toolbar"
pass "copy-url extension is clickable from the toolbar"

TMPDIR=$(mktemp -d)
test_home="$TMPDIR/home"
native_manifest="$test_home/.config/chromium/NativeMessagingHosts/com.omarchy.copy_url.json"

HOME="$test_home" OMARCHY_PATH="$ROOT" omarchy-install-chromium-copy-url

[[ -f $native_manifest ]] || fail "copy-url native host installer creates fresh Chromium profile root"
jq -e --arg path "$ROOT/bin/omarchy-chromium-copy-url-host" '
  .name == "com.omarchy.copy_url" and
  .path == $path and
  (.allowed_origins | index("chrome-extension://bgpiichlckmfanooecilcjemknkcpngb/"))
' "$native_manifest" >/dev/null || fail "copy-url native host manifest uses Omarchy host path and extension id"
pass "copy-url native host installer registers the stable extension id"

[[ -f $test_home/.config/BraveSoftware/Brave-Origin/NativeMessagingHosts/com.omarchy.copy_url.json ]] ||
  fail "copy-url native host installer covers Brave Origin"
pass "copy-url native host installer covers Brave Origin"

# An image that ships Chromium does not go through omarchy-install-browser, and
# fresh installs mark every migration as already applied. The user install
# still has to register the host itself.
grep -q 'user/chromium.sh' "$ROOT/install/user/all.sh" ||
  fail "user install runs the Chromium native messaging host setup"

# Pin omarchy-cmd-present's answer for chromium so the host's own packages
# don't decide which branch runs.
chromium_present_bin="$TMPDIR/chromium-present-bin"
chromium_missing_bin="$TMPDIR/chromium-missing-bin"
mkdir -p "$chromium_present_bin" "$chromium_missing_bin"
printf '#!/bin/bash\n[[ $1 == "chromium" ]] && exit 0\nexec "%s/bin/omarchy-cmd-present" "$@"\n' "$ROOT" >"$chromium_present_bin/omarchy-cmd-present"
printf '#!/bin/bash\n[[ $1 == "chromium" ]] && exit 1\nexec "%s/bin/omarchy-cmd-present" "$@"\n' "$ROOT" >"$chromium_missing_bin/omarchy-cmd-present"
chmod +x "$chromium_present_bin/omarchy-cmd-present" "$chromium_missing_bin/omarchy-cmd-present"

fresh_home="$TMPDIR/fresh-install"
HOME="$fresh_home" OMARCHY_PATH="$ROOT" PATH="$chromium_present_bin:$ROOT/bin:$PATH" \
  bash -euo pipefail -c 'source "$ROOT/install/user/chromium.sh"'

[[ -f $fresh_home/.config/chromium/NativeMessagingHosts/com.omarchy.copy_url.json ]] ||
  fail "fresh install registers the copy-url native messaging host"
pass "fresh install registers the copy-url native messaging host"

# Firefox is the default browser, so an install without Chromium leaves the
# Chromium profile alone.
no_chromium_home="$TMPDIR/fresh-install-no-chromium"
HOME="$no_chromium_home" OMARCHY_PATH="$ROOT" PATH="$chromium_missing_bin:$ROOT/bin:$PATH" \
  bash -euo pipefail -c 'source "$ROOT/install/user/chromium.sh"'

[[ ! -e $no_chromium_home/.config/chromium ]] ||
  fail "fresh install without Chromium does not create a Chromium profile"
pass "fresh install without Chromium skips the Chromium native messaging hosts"

copied_url=$(bash -c '
  source "$1"
  wl-copy() { cat; }
  omarchy-notification-send() { :; }
  copy_url "$2"
' bash "$ROOT/bin/omarchy-chromium-copy-url-host" 'https://example.test/path?q=one&name=two')

[[ $copied_url == "https://example.test/path?q=one&name=two" ]] ||
  fail "copy-url native host writes the complete URL" "$copied_url"
pass "copy-url native host writes the complete URL"

native_reply=$(bash -c '
  source "$1"
  reply_copied true
' bash "$ROOT/bin/omarchy-chromium-copy-url-host" | od -An -v -tx1 | tr -d ' \n')

[[ $native_reply == "0f0000007b22636f70696564223a747275657d" ]] ||
  fail "copy-url native host returns a framed success response" "$native_reply"
pass "copy-url native host returns a framed success response"
