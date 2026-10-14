#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command timeout
require_command sleep

status_command="$ROOT/bin/omarchy-system-status"
sleep_bin=$(command -v sleep)

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# Every scenario gets a PATH of its own holding jq, timeout, stat,
# omarchy-cmd-present and whatever stubs it adds, so no hyprctl, wpctl, nmcli, ollama or Omarchy
# helper installed on the machine running the test can answer, and a call the
# command should never make shows up in the call log.
new_scenario() {
  scenario_dir=$(mktemp -d "$tmp_dir/scenario.XXXXXX")
  bin_dir=$scenario_dir/bin
  home_dir=$scenario_dir/home
  power_dir=$scenario_dir/power
  stderr_file=$scenario_dir/stderr

  mkdir -p "$bin_dir" "$home_dir" "$power_dir"
  ln -s "$(command -v jq)" "$bin_dir/jq"
  ln -s "$(command -v timeout)" "$bin_dir/timeout"
  ln -s "$(command -v stat)" "$bin_dir/stat"
  ln -s "$ROOT/bin/omarchy-cmd-present" "$bin_dir/omarchy-cmd-present"

  STUB_LOG=$scenario_dir/calls.log
  : >"$STUB_LOG"
  export STUB_LOG
  export STUB_SLEEP=$sleep_bin
  unset STUB_WPCTL STUB_NMCLI STUB_HYPRCTL STUB_OLLAMA
}

# stub <name> <body>: an executable of that name on the scenario's PATH that
# logs how it was called, then runs the body.
stub() {
  local name=$1 body=$2

  cat >"$bin_dir/$name" <<STUB
#!/bin/bash
echo "$name\${*:+ \$*}" >>"\$STUB_LOG"
$body
STUB
  chmod +x "$bin_dir/$name"
}

stub_working_machine() {
  stub omarchy-version 'echo 3.5.0'
  stub omarchy-version-channel 'echo stable'
  stub omarchy-version-branch 'echo feature-x'
  stub omarchy-hw-platform 'echo aarch64-apple'
  stub omarchy-theme-current 'echo "Tokyo Night"'
  stub omarchy-font-current 'echo "JetBrainsMono Nerd Font"'
  stub omarchy-default-browser 'echo firefox'
  stub omarchy-default-terminal 'echo ghostty'
  stub omarchy-default-editor 'echo helix'
  stub omarchy-default-agent 'echo claude'
  stub omarchy-default-dictation 'echo voxtype'

  stub wpctl '[[ $1 == get-volume && $2 == @DEFAULT_AUDIO_SINK@ ]] || exit 1
echo "Volume: $STUB_WPCTL"'
  stub nmcli 'case " $* " in
  *" device status "*) printf "%s\n" "$STUB_NMCLI" ;;
  *) exit 1 ;;
esac'
  stub hyprctl '[[ $1 == monitors && $2 == -j ]] || exit 1
printf "%s\n" "$STUB_HYPRCTL"'
  stub ollama '[[ $1 == list ]] || exit 1
printf "%s\n" "$OLLAMA_HOST" >"$STUB_LOG.ollama-host"
case $STUB_OLLAMA in
  up) printf "NAME ID SIZE MODIFIED\nllama3.2:latest abc123 2.0 GB 2 weeks ago\nqwen3:8b def456 5.2 GB 3 days ago\n" ;;
  empty) printf "NAME ID SIZE MODIFIED\n" ;;
  down) echo "Error: could not connect to ollama app, is it running?" >&2; exit 1 ;;
  hang) exec "$STUB_SLEEP" 30 ;;
esac'

  # Commands that would leave the machine or probe the network. The command must
  # never run them, and the call log proves it did not.
  local probe
  for probe in ping curl wget nc dig host nslookup ip iw; do
    stub "$probe" 'exit 1'
  done

  export STUB_WPCTL="0.45 [MUTED]"
  export STUB_NMCLI=$'lo:loopback:connected (externally):lo\neth0:ethernet:unavailable:--\nwlan0:wifi:connected:Home Wifi\np2p-dev-wlan0:wifi-p2p:disconnected:--'
  export STUB_HYPRCTL='[
    {"id":0,"name":"eDP-1","width":2880,"height":1800,"refreshRate":120.00200,"x":0,"y":0,"scale":1.67,"focused":true,"disabled":false},
    {"id":1,"name":"DP-2","width":3840,"height":2160,"refreshRate":143.99800,"x":1724,"y":0,"scale":1.0,"focused":false,"disabled":false}
  ]'
  export STUB_OLLAMA=up
}

# A laptop battery, an AC adapter, and a wireless mouse's battery that sorts
# first and must not be mistaken for the machine's own.
stub_power_supplies() {
  mkdir -p "$power_dir"/{AC,BAT0,0mouse}
  printf 'Mains\n' >"$power_dir/AC/type"
  printf '1\n' >"$power_dir/AC/online"
  printf 'Battery\n' >"$power_dir/BAT0/type"
  printf '1\n' >"$power_dir/BAT0/present"
  printf 'System\n' >"$power_dir/BAT0/scope"
  printf '87\n' >"$power_dir/BAT0/capacity"
  printf 'Discharging\n' >"$power_dir/BAT0/status"
  printf 'Battery\n' >"$power_dir/0mouse/type"
  printf '1\n' >"$power_dir/0mouse/present"
  printf 'Device\n' >"$power_dir/0mouse/scope"
  printf '5\n' >"$power_dir/0mouse/capacity"
  printf 'Discharging\n' >"$power_dir/0mouse/status"
}

stub_pending_restarts() {
  local state_dir=$home_dir/.local/state/omarchy

  mkdir -p "$state_dir/restart-directory-required"
  touch "$state_dir/reboot-required" \
    "$state_dir/restart-tmux-required" \
    "$state_dir/restart-hyprsunset-required" \
    "$state_dir/restart-brave-origin-required" \
    "$state_dir/restart-required" \
    "$state_dir/something-else-required"
}

run_status() {
  PATH=$bin_dir HOME=$home_dir OMARCHY_PATH=$ROOT OMARCHY_POWER_SUPPLY_PATH=$power_dir LC_ALL=C "$status_command" "$@"
}

# Runs the command expecting success and clean stderr; the output lands in $output.
status_ok() {
  local description=$1
  shift

  if ! output=$(run_status "$@" 2>"$stderr_file"); then
    fail "$description: exits 0" "$(<"$stderr_file")"
  fi
  [[ ! -s $stderr_file ]] || fail "$description: stays quiet on stderr" "$(<"$stderr_file")"
}

# expect_json <description> <jq filter>: the filter must hold for $output.
expect_json() {
  jq -e "$2" <<<"$output" >/dev/null || fail "$1" "$output"
  pass "$1"
}

top_level_keys='["omarchy","platform","theme","font","defaults","audio","battery","network","displays","pending","ollama"]'

# --- everything answers ------------------------------------------------------

new_scenario
stub_working_machine
stub_power_supplies
stub_pending_restarts

state_before=$(cd "$home_dir" && find . | sort)

status_ok "--json" --json
jq -es 'length == 1' <<<"$output" >/dev/null || fail "--json prints one JSON document" "$output"
expect_json "--json is one object with every top-level key" \
  "type == \"object\" and (keys | sort) == ($top_level_keys | sort)"

expect_json "omarchy version, channel and branch come from the version helpers" \
  '.omarchy == {version: "3.5.0", channel: "stable", branch: "feature-x"}'
expect_json "platform, theme and font come from their helpers" \
  '.platform == "aarch64-apple" and .theme == "Tokyo Night" and .font == "JetBrainsMono Nerd Font"'
expect_json "defaults come from the omarchy-default-* helpers" \
  '.defaults == {browser: "firefox", terminal: "ghostty", editor: "helix", agent: "claude", dictation: "voxtype"}'
expect_json "audio reads a muted default sink" \
  '.audio == {volume: 45, muted: true}'
expect_json "battery is the machine's own, not the mouse's" \
  '.battery == {percent: 87, status: "Discharging"}'
expect_json "network reports the Wi-Fi connection" \
  '.network == {connected: true, ssid: "Home Wifi"}'
expect_json "displays list each monitor's mode, scale and focus" \
  '.displays == [
    {name: "eDP-1", width: 2880, height: 1800, refresh: 120, scale: 1.67, focused: true},
    {name: "DP-2", width: 3840, height: 2160, refresh: 144, scale: 1, focused: false}
  ]'
expect_json "a pending reboot and the components to restart show up" \
  '.pending == {reboot_required: true, restarts_required: ["brave-origin", "hyprsunset", "tmux"]}'
expect_json "ollama reports the server and its models" \
  '.ollama == {running: true, models: ["llama3.2:latest", "qwen3:8b"]}'

status_ok "text status"
expected=$(
  cat <<'TEXT'
version: 3.5.0
channel: stable
branch: feature-x
platform: aarch64-apple
theme: Tokyo Night
font: JetBrainsMono Nerd Font
browser: firefox
terminal: ghostty
editor: helix
agent: claude
dictation: voxtype
volume: 45% (muted)
battery: 87% Discharging
network: connected (Home Wifi)
display: eDP-1 2880x1800@120Hz scale 1.67 (focused)
display: DP-2 3840x2160@144Hz scale 1
reboot_required: yes
restarts_required: brave-origin, hyprsunset, tmux
ollama: running, models: llama3.2:latest, qwen3:8b
TEXT
)
[[ $output == "$expected" ]] || fail "text mode prints key: value lines" "$output"
pass "text mode prints key: value lines"

# --- read-only, local-only ---------------------------------------------------

# Every call the two runs above made, each against what a status read may do:
# the default helpers with no argument (an argument would change the setting),
# wpctl only reading the volume, ollama only listing, hyprctl only listing
# monitors, nmcli only listing devices. Nothing from the network probe list.
allowed_calls=(
  '^omarchy-version$'
  '^omarchy-version-channel$'
  '^omarchy-version-branch$'
  '^omarchy-hw-platform$'
  '^omarchy-theme-current$'
  '^omarchy-font-current$'
  '^omarchy-default-(browser|terminal|editor|agent|dictation)$'
  '^wpctl get-volume @DEFAULT_AUDIO_SINK@$'
  '^nmcli .*device status$'
  '^hyprctl monitors -j$'
  '^ollama list$'
)
while IFS= read -r call; do
  allowed=false
  for pattern in "${allowed_calls[@]}"; do
    if [[ $call =~ $pattern ]]; then
      allowed=true
      break
    fi
  done
  [[ $allowed == "true" ]] || fail "status only makes read-only local calls" "unexpected call: $call"
done <"$STUB_LOG"
for helper in browser terminal editor agent dictation; do
  grep -qx "omarchy-default-$helper" "$STUB_LOG" || fail "status reads the default $helper"
done
pass "status only makes read-only local calls, with no network probes"

state_after=$(cd "$home_dir" && find . | sort)
[[ $state_before == "$state_after" ]] || fail "status leaves the state directory as it found it" "$state_after"
pass "status changes nothing under HOME"

# --- audio -------------------------------------------------------------------

# wpctl prints hundredths, and zero-padded ones (0.07, 0.08) are not octal.
for row in "0.45 [MUTED]|45|true" "0.45|45|false" "1.00|100|false" "0.07|7|false" "0.08 [MUTED]|8|true" "0.00 [MUTED]|0|true" "0.5|50|false"; do
  IFS='|' read -r wpctl_output volume muted <<<"$row"
  STUB_WPCTL=$wpctl_output status_ok "audio $wpctl_output" --json
  expect_json "audio parses \"Volume: $wpctl_output\"" ".audio == {volume: $volume, muted: $muted}"
done

STUB_WPCTL="" status_ok "audio with nothing parseable" --json
expect_json "audio is null when wpctl prints nothing it can read" '.audio == null'

# --- battery -----------------------------------------------------------------

printf 'Charging\n' >"$power_dir/BAT0/status"
printf '100\n' >"$power_dir/BAT0/capacity"
status_ok "battery charging" --json
expect_json "battery reports the status and percent the kernel gives" \
  '.battery == {percent: 100, status: "Charging"}'
status_ok "battery text"
[[ $output == *$'\nbattery: 100% Charging\n'* ]] || fail "text mode prints the battery" "$output"
pass "text mode prints the battery"

# The kernel reports 0 to 100; a broken driver's value is no percent at all.
for capacity in 101 -5 1e400 abc; do
  printf '%s\n' "$capacity" >"$power_dir/BAT0/capacity"
  status_ok "battery capacity $capacity" --json
  expect_json "a battery capacity of $capacity is no percent" '.battery == {percent: null, status: "Charging"}'
done

printf '0\n' >"$power_dir/BAT0/present"
status_ok "battery bay empty" --json
expect_json "an empty battery bay is no battery" '.battery == null'

rm -rf "$power_dir/BAT0"
status_ok "only a mouse battery and AC" --json
expect_json "a wireless mouse's battery and an AC adapter are no battery" '.battery == null'

real_power_dir=$power_dir
power_dir=$scenario_dir/no-power-supply-directory
status_ok "no power supply directory" --json
expect_json "a machine with no power supply directory has no battery" '.battery == null'
power_dir=$real_power_dir

# --- network -----------------------------------------------------------------

check_network() {
  local description=$1 nmcli_output=$2 expected_network=$3

  STUB_NMCLI=$nmcli_output status_ok "network $description" --json
  expect_json "network: $description" ".network == $expected_network"
}

check_network "Ethernet only" \
  $'eth0:ethernet:connected:Wired connection 1\nwlan0:wifi:disconnected:--' \
  '{connected: true, ssid: null}'
check_network "Wi-Fi and Ethernet" \
  $'eth0:ethernet:connected:Wired connection 1\nwlan0:wifi:connected:Home Wifi' \
  '{connected: true, ssid: "Home Wifi"}'
check_network "nothing connected (loopback does not count)" \
  $'lo:loopback:connected (externally):lo\nwlan0:wifi:disconnected:--\neth0:ethernet:unavailable:--' \
  '{connected: false, ssid: null}'
check_network "still connecting" \
  $'wlan0:wifi:connecting (getting IP configuration):Home Wifi' \
  '{connected: false, ssid: null}'
check_network "SSID with a colon" \
  $'wlan0:wifi:connected:Cafe: Free' \
  '{connected: true, ssid: "Cafe: Free"}'

# --- ollama ------------------------------------------------------------------

STUB_OLLAMA=empty status_ok "ollama with no models" --json
expect_json "ollama running with no models" '.ollama == {running: true, models: []}'

STUB_OLLAMA=down status_ok "ollama stopped" --json
expect_json "ollama installed but not running" '.ollama == {running: false, models: []}'

STUB_OLLAMA=up status_ok "ollama text"
[[ $output == *$'\nollama: running, models: llama3.2:latest, qwen3:8b' ]] || fail "text mode prints ollama" "$output"
pass "text mode prints ollama"

# OLLAMA_HOST can point the client at another machine; status asks only this
# machine's own server, wherever on it that listens.
check_ollama_host() {
  local configured=$1 expected=$2

  OLLAMA_HOST=$configured status_ok "ollama with OLLAMA_HOST=$configured" --json
  [[ $(<"$STUB_LOG.ollama-host") == "$expected" ]] ||
    fail "OLLAMA_HOST=$configured asks $expected" "$(<"$STUB_LOG.ollama-host")"
  pass "OLLAMA_HOST=$configured asks $expected"
}

check_ollama_host "" 127.0.0.1:11434
check_ollama_host 127.0.0.1:12345 127.0.0.1:12345
check_ollama_host http://localhost:11434 http://localhost:11434
check_ollama_host 0.0.0.0 0.0.0.0
check_ollama_host http://gpu-box.lan:11434 127.0.0.1:11434
check_ollama_host 10.0.0.5:11434 127.0.0.1:11434

# --- pending -----------------------------------------------------------------

# A reboot that skipped omarchy-system (a plain systemctl reboot, a crash) left
# its markers behind; they predate this boot, so nothing is owed any more.
pending_dir=$home_dir/.local/state/omarchy
touch -d @0 "$pending_dir/reboot-required" "$pending_dir/restart-tmux-required"
status_ok "markers from before this boot" --json
expect_json "markers from before this boot are no longer pending" \
  '.pending == {reboot_required: false, restarts_required: ["brave-origin", "hyprsunset"]}'
touch "$pending_dir/reboot-required" "$pending_dir/restart-tmux-required"

# --- displays ----------------------------------------------------------------

STUB_HYPRCTL='Couldn'"'"'t connect to /run/user/1000/hypr/none/.socket.sock. (3)' status_ok "no compositor" --json
expect_json "displays are null when hyprctl has no compositor to ask" '.displays == null'

STUB_HYPRCTL='[]' status_ok "no monitors" --json
expect_json "no monitors is an empty list, not null" '.displays == []'

# --- sources missing ---------------------------------------------------------

# Nothing on the PATH but jq, timeout and omarchy-cmd-present: no helper, no
# wpctl, nmcli, hyprctl or ollama, no power supplies, and an empty HOME.
new_scenario
status_ok "nothing installed" --json
expect_json "with every source missing, --json still has every top-level key" \
  "type == \"object\" and (keys | sort) == ($top_level_keys | sort)"
expect_json "with every source missing, each section is null" '
  .omarchy == {version: null, channel: null, branch: null} and
  .platform == null and .theme == null and .font == null and
  .defaults == {browser: null, terminal: null, editor: null, agent: null, dictation: null} and
  .audio == null and .battery == null and .network == null and
  .displays == null and .ollama == null'
expect_json "with every source missing, nothing is pending" \
  '.pending == {reboot_required: false, restarts_required: []}'

status_ok "nothing installed, text"
expected=$(
  cat <<'TEXT'
version: n/a
channel: n/a
branch: n/a
platform: n/a
theme: n/a
font: n/a
browser: n/a
terminal: n/a
editor: n/a
agent: n/a
dictation: n/a
volume: n/a
battery: none
network: n/a
displays: n/a
reboot_required: no
restarts_required: none
ollama: not installed
TEXT
)
[[ $output == "$expected" ]] || fail "text mode reads n/a for every missing source" "$output"
pass "text mode reads n/a for every missing source"

# Present but failing: helpers that exit 1 with noise on stderr, a wpctl with no
# sink, an nmcli with NetworkManager stopped, a hyprctl outside Hyprland.
new_scenario
for helper in omarchy-version omarchy-version-channel omarchy-version-branch omarchy-hw-platform omarchy-theme-current \
  omarchy-font-current omarchy-default-browser omarchy-default-terminal omarchy-default-editor omarchy-default-agent \
  omarchy-default-dictation; do
  stub "$helper" 'echo "Error: not available" >&2; exit 1'
done
stub wpctl 'echo "Failed to find sink" >&2; exit 1'
stub nmcli 'echo "Error: NetworkManager is not running." >&2; exit 8'
stub hyprctl 'echo "HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)"; exit 1'

status_ok "failing sources" --json
expect_json "with every source failing, each section is null" '
  .omarchy == {version: null, channel: null, branch: null} and
  .platform == null and .theme == null and .font == null and
  .defaults == {browser: null, terminal: null, editor: null, agent: null, dictation: null} and
  .audio == null and .battery == null and .network == null and .displays == null and .ollama == null'

# A helper that succeeds with a sentinel instead of failing is no answer either.
stub omarchy-version-channel 'echo unknown'
stub omarchy-theme-current 'echo Unknown'
stub hyprctl 'echo "not a monitor list"'
status_ok "sentinel answers" --json
expect_json "the channel and theme helpers' unknown sentinels are null" \
  '.omarchy.channel == null and .theme == null'
expect_json "a hyprctl that prints no JSON leaves displays null" '.displays == null'

# --- hung sources ------------------------------------------------------------

# A theme helper and an Ollama server that never answer cost their timeouts and
# no more: the command still finishes, exits 0, and reports them as null.
new_scenario
stub_working_machine
stub omarchy-theme-current 'exec "$STUB_SLEEP" 30'
STUB_OLLAMA=hang
export STUB_OLLAMA
start=$EPOCHREALTIME
status_ok "hung sources" --json
end=$EPOCHREALTIME
elapsed=$(( ${end/[.,]/} - ${start/[.,]/} ))
(( elapsed < 8000000 )) || fail "a hung helper and a hung Ollama are cut off by their timeouts" "took $((elapsed / 1000))ms"
expect_json "a hung helper is null and a hung Ollama is not running" \
  '.theme == null and .ollama == {running: false, models: []} and .platform == "aarch64-apple"'

# --- arguments ---------------------------------------------------------------

new_scenario
stub_working_machine

bad_arguments=("--bogus" "bogus" "--json --json" "--json extra" "-j" "--JSON")
for arguments in "${bad_arguments[@]}"; do
  read -ra argument_list <<<"$arguments"
  if output=$(run_status "${argument_list[@]}" 2>"$stderr_file"); then
    code=0
  else
    code=$?
  fi
  (( code == 2 )) || fail "bad argument \"$arguments\" exits 2" "exit $code"
  [[ -z $output ]] || fail "bad argument \"$arguments\" prints nothing on stdout" "$output"
  grep -qF 'Usage: omarchy-system-status [--json]' "$stderr_file" || fail "bad argument \"$arguments\" prints usage on stderr" "$(<"$stderr_file")"
done
pass "a bad argument prints usage on stderr and exits 2"

if output=$(run_status "" 2>"$stderr_file"); then code=0; else code=$?; fi
(( code == 2 )) || fail "an empty argument exits 2" "exit $code"
pass "an empty argument exits 2"

: >"$STUB_LOG"
if output=$(run_status --help 2>"$stderr_file"); then code=0; else code=$?; fi
(( code == 0 )) || fail "--help exits 0" "exit $code"
[[ $output == "Usage: omarchy-system-status [--json]" ]] || fail "--help prints usage on stdout" "$output"
[[ ! -s $STUB_LOG ]] || fail "--help reads nothing" "$(<"$STUB_LOG")"
pass "--help prints usage and reads nothing"

# --- routing -----------------------------------------------------------------

# The router resolves the route to this command, and the command is not hidden
# from the listing of its group.
route=$("$ROOT/bin/omarchy" commands --json | jq -r '.commands[] | select(.binary == "omarchy-system-status") | .route')
[[ $route == "omarchy system status" ]] || fail "omarchy-system-status routes as omarchy system status" "$route"
pass "omarchy-system-status routes as omarchy system status"
