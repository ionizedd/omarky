#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

# Nothing the system ships may reach a Google host unless the user picks a
# Google product. Each allowed file is one of those choices: Google DNS, Google
# sign-in for Chromium, and Chrome Web Store extensions for Chromium browsers.
google_hosts='(google\.com|googleapis\.com|gstatic\.com|googleusercontent\.com|gvt[12]\.com|youtube\.com|ytimg\.com|ggpht\.com|doubleclick\.net|firebaseio\.com|recaptcha\.net|dns\.google|8\.8\.[48]\.[48]|2001:4860)'
allowed=(
  bin/omarchy-dns
  bin/omarchy-install-chromium-claude
  bin/omarchy-install-chromium-google-account
  bin/omarchy-install-service-1password
  default/omarchy/omarchy-menu.jsonc
)

cd "$ROOT"
mapfile -t found < <(grep -rIlE "$google_hosts" bin default config etc install shell applications themes | sort)
unexpected=()
for file in "${found[@]}"; do
  if [[ " ${allowed[*]} " != *" $file "* ]]; then
    unexpected+=("$file")
  fi
done
(( ${#unexpected[@]} == 0 )) || fail "only opt-in Google features name Google hosts" "${unexpected[*]}"
pass "only opt-in Google features name Google hosts"

# The menu's only Google entry is the DNS choice.
[[ $(grep -cE "$google_hosts" default/omarchy/omarchy-menu.jsonc) == 1 ]] &&
  grep -E "$google_hosts" default/omarchy/omarchy-menu.jsonc | grep -q '"setup.network.dns.google"' ||
  fail "the menu's only Google entry is the opt-in DNS choice"
pass "the menu's only Google entry is the opt-in DNS choice"

if grep -hE '^(google-|chromium$)' install/*.packages; then
  fail "no Google browser is a default package"
fi
pass "no Google browser is a default package"

# Firefox, the default browser, keeps its Google-free defaults.
policies=default/firefox/policies.json
jq -e '
  .policies as $p
  | ($p.SearchEngines.Remove | index("Google")) != null
  and $p.SearchEngines.Default != "Google"
  and $p.DisableTelemetry == true
  and $p.EncryptedMediaExtensions.Enabled == false
  and ([$p.Preferences | to_entries[] | select(.key | startswith("browser.safebrowsing.")) | .value.Value] | length == 5 and all(. == false))
  and ($p.Preferences["geo.provider.network.url"].Value | test("google") | not)
  and $p.Preferences["geo.provider.use_geoclue"].Value == false
' "$policies" >/dev/null || fail "Firefox keeps its Google-free defaults"
pass "Firefox keeps its Google-free defaults"

grep -q '^FallbackDNS=' etc/systemd/resolved.conf.d/30-fallback-dns.conf &&
  ! grep -E '^FallbackDNS=.*(8\.8\.|dns\.google|2001:4860)' etc/systemd/resolved.conf.d/30-fallback-dns.conf ||
  fail "the fallback DNS servers leave Google out"
pass "the fallback DNS servers leave Google out"
