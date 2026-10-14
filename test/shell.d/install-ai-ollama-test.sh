#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"

# Nothing here may reach the real package manager, GPU, or system manager.
cat >"$tmp_dir/bin/omarchy-pkg-add" <<'SCRIPT'
#!/bin/bash
printf 'pkg-add:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
cat >"$tmp_dir/bin/sudo" <<'SCRIPT'
#!/bin/bash
printf 'sudo:%s\n' "$*" >>"$TEST_LOG"
SCRIPT
cat >"$tmp_dir/bin/omarchy-hw-nvidia" <<'SCRIPT'
#!/bin/bash
[[ $TEST_GPU == "nvidia" ]]
SCRIPT
cat >"$tmp_dir/bin/omarchy-cmd-present" <<'SCRIPT'
#!/bin/bash
[[ $1 == "rocminfo" && $TEST_GPU == "rocm" ]]
SCRIPT
chmod +x "$tmp_dir/bin"/*

export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir/bin:$PATH"

install_ollama() {
  : >"$TEST_LOG"
  TEST_GPU=$1 "$ROOT/bin/omarchy-install-ai-ollama" "${@:2}" >/dev/null
}

install_ollama nvidia
grep -Fxq 'pkg-add:ollama-cuda' "$TEST_LOG" || fail "an NVIDIA GPU gets the CUDA build" "$(<"$TEST_LOG")"
grep -Fxq 'sudo:systemctl enable --now ollama.service' "$TEST_LOG" || fail "the Ollama service starts now and at boot" "$(<"$TEST_LOG")"
pass "an NVIDIA GPU gets the CUDA build, with the service enabled"

install_ollama rocm
grep -Fxq 'pkg-add:ollama-rocm' "$TEST_LOG" || fail "a ROCm system gets the ROCm build" "$(<"$TEST_LOG")"
pass "a ROCm system gets the ROCm build"

install_ollama none
grep -Fxq 'pkg-add:ollama' "$TEST_LOG" || fail "a computer without a supported GPU gets the CPU build" "$(<"$TEST_LOG")"
pass "a computer without a supported GPU gets the CPU build"

install_ollama nvidia cpu
grep -Fxq 'pkg-add:ollama' "$TEST_LOG" || fail "a named variant overrides detection" "$(<"$TEST_LOG")"
pass "a named variant overrides detection"

: >"$TEST_LOG"
if TEST_GPU=none "$ROOT/bin/omarchy-install-ai-ollama" metal >/dev/null 2>&1; then
  fail "an unknown variant is refused"
fi
[[ ! -s $TEST_LOG ]] || fail "an unknown variant installs nothing" "$(<"$TEST_LOG")"
pass "an unknown variant is refused before anything is installed"

ollama_row=$(grep '^  "install.ai.ollama":' "$ROOT/default/omarchy/omarchy-menu.jsonc")
[[ $ollama_row == *'"action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-ai-ollama"'* ]] ||
  fail "the menu installs Ollama through the same command agents use" "$ollama_row"
pass "the menu installs Ollama through the same command agents use"
