#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Web app icons come from the site itself: no third-party icon service learns
# which sites get installed.
installer="$ROOT/bin/omarchy-webapp-install"
if grep -E 'google\.com/s2|favicons\?|icons\.duckduckgo' "$installer" >/dev/null; then
  fail "web app icons come from the site, not an icon service"
fi
pass "web app icons come from the site, not an icon service"

eval "$(awk '/^page_icon_href\(\) \{/,/^}/' "$installer")"
declare -F page_icon_href >/dev/null || fail "the installer has its icon link lookup"

page='<link rel="icon" type="image/svg+xml" href="/icon.svg"><link rel="shortcut icon" href="static/icon.png"><link rel="apple-touch-icon" href="/touch.png">'
[[ $(page_icon_href "$page" "apple-touch-icon" "https://site.test") == "https://site.test/touch.png" ]] ||
  fail "the touch icon resolves against the site"
[[ $(page_icon_href "$page" "icon" "https://site.test") == "https://site.test/static/icon.png" ]] ||
  fail "a declared bitmap icon is used, skipping SVG"
[[ $(page_icon_href "<link rel='icon' href='//cdn.test/f.png'>" "icon" "https://site.test") == "https://cdn.test/f.png" ]] ||
  fail "a protocol-relative icon gets https"
[[ -z $(page_icon_href "<html></html>" "icon" "https://site.test") ]] || fail "a page without icons yields nothing"
pass "declared icons resolve against the site and skip SVG"
