#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

migration="$ROOT/migrations/1791952985.sh"
test_home="$test_tmp/home"
applications="$test_home/.local/share/applications"
mock_bin="$test_tmp/bin"
mkdir -p "$applications" "$mock_bin" "$test_home/.config/omarchy"

cat >"$mock_bin/update-desktop-database" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_DESKTOP_DB"
SH
chmod +x "$mock_bin/update-desktop-database"

# Stock launchers as fresh installs used to copy them, plus one the user
# repointed to a site of their own and an unrelated web app.
printf '[Desktop Entry]\nName=YouTube\nExec=omarchy-launch-webapp https://youtube.com/\n' >"$applications/YouTube.desktop"
printf '[Desktop Entry]\nName=Google Maps\nExec=omarchy-launch-webapp https://maps.google.com\n' >"$applications/Google Maps.desktop"
printf '[Desktop Entry]\nName=Google Photos\nExec=omarchy-launch-webapp https://photos.example.test/\n' >"$applications/Google Photos.desktop"
printf '[Desktop Entry]\nName=WhatsApp\nExec=omarchy-launch-webapp https://web.whatsapp.com/\n' >"$applications/WhatsApp.desktop"
printf '{"dock":{"pinned":["org.gnome.Nautilus","X","YouTube"]}}\n' >"$test_home/.config/omarchy/shell.json"

run_migration() {
  HOME="$test_home" OMARCHY_PATH="$ROOT" PATH="$mock_bin:$ROOT/bin:$PATH" \
    OMARCHY_TEST_DESKTOP_DB="$test_tmp/desktop-db" bash -euo pipefail "$migration" >/dev/null
}

run_migration
[[ ! -e $applications/YouTube.desktop && ! -e "$applications/Google Maps.desktop" ]] ||
  fail "the stock Google and YouTube launchers are removed"
[[ -f "$applications/Google Photos.desktop" && -f $applications/WhatsApp.desktop ]] ||
  fail "launchers the user repointed, and other web apps, stay"
grep -Fxq "$applications" "$test_tmp/desktop-db" || fail "the desktop database is refreshed after removing launchers"
jq -e '.dock.pinned == ["org.gnome.Nautilus","X"]' "$test_home/.config/omarchy/shell.json" >/dev/null ||
  fail "YouTube is unpinned from a dock with its own pins" "$(cat "$test_home/.config/omarchy/shell.json")"
pass "the migration removes only the stock Google and YouTube launchers and the YouTube pin"

: >"$test_tmp/desktop-db"
run_migration
[[ ! -s $test_tmp/desktop-db ]] || fail "a second run changes nothing"
pass "the migration is idempotent"
