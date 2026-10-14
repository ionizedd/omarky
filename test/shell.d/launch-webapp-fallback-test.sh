#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
mkdir -p "$mock_bin" "$test_home/.local/share/applications"
export XDG_CONFIG_HOME="$test_home/.config" XDG_DATA_HOME="$test_home/.local/share"

cat >"$test_home/.local/share/applications/chromium.desktop" <<'EOF'
[Desktop Entry]
Exec=chromium %U
EOF
cat >"$test_home/.local/share/applications/brave-browser.desktop" <<'EOF'
[Desktop Entry]
Exec=brave %U
EOF

cat >"$mock_bin/omarchy-cmd-default-browser" <<'SH'
#!/bin/bash
echo "$OMARCHY_TEST_DEFAULT_BROWSER"
SH
cat >"$mock_bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
[[ $1 == "chromium" && $OMARCHY_TEST_CHROMIUM == "missing" ]]
SH
cat >"$mock_bin/omarchy-cmd-browser-handoff" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$mock_bin/omarchy-launch-browser" <<'SH'
#!/bin/bash
printf 'launch-browser %s\n' "$*" >"$OMARCHY_TEST_LAUNCH_LOG"
SH
cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
printf 'setsid %s\n' "$*" >"$OMARCHY_TEST_LAUNCH_LOG"
SH
chmod +x "$mock_bin"/*

launch_log="$test_tmp/launch"

launch_webapp() {
  rm -f "$launch_log"
  HOME="$test_home" PATH="$mock_bin:$PATH" OMARCHY_TEST_LAUNCH_LOG="$launch_log" \
    OMARCHY_TEST_DEFAULT_BROWSER="$1" OMARCHY_TEST_CHROMIUM="$2" \
    bash "$ROOT/bin/omarchy-launch-webapp" "https://example.test/app"
}

launch_webapp firefox.desktop missing
[[ $(<"$launch_log") == "launch-browser --new-window https://example.test/app" ]] ||
  fail "a web app opens in a new default-browser window without Chromium" "$(<"$launch_log")"
pass "a web app opens in a new default-browser window without Chromium"

launch_webapp firefox.desktop present
[[ $(<"$launch_log") == "setsid uwsm-app -- chromium --app=https://example.test/app" ]] ||
  fail "a web app still uses Chromium's app window when Chromium is installed" "$(<"$launch_log")"
pass "a web app still uses Chromium's app window when Chromium is installed"

launch_webapp brave-browser.desktop missing
[[ $(<"$launch_log") == "setsid uwsm-app -- brave --app=https://example.test/app" ]] ||
  fail "a Chromium-family default browser keeps opening web apps as app windows" "$(<"$launch_log")"
pass "a Chromium-family default browser keeps opening web apps as app windows"
