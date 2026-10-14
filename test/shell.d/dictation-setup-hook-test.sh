#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_home=$(mktemp -d)
test_bin=$(mktemp -d)
log_file=$(mktemp)

cleanup() {
  rm -rf "$test_home" "$test_bin"
  rm -f "$log_file"
}
trap cleanup EXIT

cat >"$test_bin/omarchy-install-dictation-voxtype" <<'EOF'
#!/bin/bash
echo install >>"$TEST_LOG"
exit "${SETUP_EXIT:-0}"
EOF
cat >"$test_bin/omarchy-cmd-present" <<'EOF'
#!/bin/bash
[[ $1 == "voxtype" ]]
EOF
chmod +x "$test_bin"/*

run_hook() {
  HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" PATH="$test_bin:$ROOT/bin:$PATH" TEST_LOG="$log_file" \
    bash "$ROOT/install/user/first-run/setup-dictation.hook"
}

mkdir -p "$test_home/.config/omarchy/defaults"
cp "$ROOT/config/omarchy/defaults/dictation" "$test_home/.config/omarchy/defaults/dictation"
[[ $(<"$test_home/.config/omarchy/defaults/dictation") == "voxtype" ]] || fail "fresh installs select Voxtype"
pass "fresh installs select Voxtype"

# Offline at first login: the model download fails, and the next update tries again.
if SETUP_EXIT=1 run_hook; then
  fail "a failed Voxtype setup fails the hook"
fi
[[ ! -f $test_home/.local/state/omarchy/done/voxtype-setup ]] || fail "a failed Voxtype setup is retried later"
run_hook
[[ -f $test_home/.local/state/omarchy/done/voxtype-setup ]] || fail "a finished Voxtype setup is recorded"
run_hook
[[ $(grep -c '^install$' "$log_file") -eq 2 ]] || fail "Voxtype setup runs until it succeeds, then stops"
pass "Voxtype setup is retried until it succeeds, then never again"

rm -rf "$test_home/.local"
: >"$log_file"
printf 'superwhisper\n' >"$test_home/.config/omarchy/defaults/dictation"
run_hook
[[ ! -s $log_file ]] || fail "another selected backend is left alone"
pass "the hook leaves another selected dictation backend alone"
