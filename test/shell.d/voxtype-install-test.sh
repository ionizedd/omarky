#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
lib_path="$test_tmp/lib/voxtype"
calls="$test_tmp/calls.log"
mkdir -p "$stub_bin" "$lib_path"

for command in gum omarchy-pkg-drop omarchy-pkg-add hyprctl omarchy-restart-shell omarchy-notification-send systemctl; do
  printf '#!/bin/bash\nexit 0\n' >"$stub_bin/$command"
done
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/omarchy-pkg-present"
# Voxtype is already installed, so the install asks nothing and only sets it up.
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/omarchy-cmd-missing"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/omarchy-dictation-use"
cat >"$stub_bin/omarchy-hw-vulkan" <<'SH'
#!/bin/bash
(( ${VULKAN:-1} == 1 ))
SH
cat >"$stub_bin/voxtype" <<'SH'
#!/bin/bash
printf 'voxtype %s\n' "$*" >>"$TEST_LOG"
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
exec "$@"
SH
chmod +x "$stub_bin"/*

# Runs the install in a terminal (tty) or detached from one, the way first login
# runs it (no-tty).
run_install() {
  local vulkan=$1 backend=$2 terminal=${3:-tty}

  : >"$calls"
  rm -rf "$test_tmp/home" "$lib_path/voxtype-vulkan"
  mkdir -p "$test_tmp/home"
  case $backend in
  executable)
    printf '#!/bin/bash\n' >"$lib_path/voxtype-vulkan"
    chmod +x "$lib_path/voxtype-vulkan"
    ;;
  unusable)
    : >"$lib_path/voxtype-vulkan"
    ;;
  esac

  export HOME="$test_tmp/home" OMARCHY_PATH="$ROOT" OMARCHY_VOXTYPE_LIB_PATH="$lib_path" \
    VULKAN="$vulkan" TEST_LOG="$calls" PATH="$stub_bin:$PATH" XDG_CONFIG_HOME="$test_tmp/home/.config"
  if [[ $terminal == "tty" ]]; then
    script -qec "bash '$ROOT/bin/omarchy-install-dictation-voxtype'" /dev/null >/dev/null ||
      fail "Voxtype install completes (vulkan=$vulkan backend=$backend)"
  else
    bash "$ROOT/bin/omarchy-install-dictation-voxtype" </dev/null >/dev/null 2>"$test_tmp/stderr" ||
      fail "Voxtype install completes without a terminal (vulkan=$vulkan backend=$backend)"
  fi
  export HOME="$real_home" PATH="$real_path"

  grep -Fx 'voxtype setup systemd' "$calls" >/dev/null ||
    fail "Voxtype install sets up the user service (vulkan=$vulkan backend=$backend)"
}

real_home=$HOME
real_path=$PATH

run_install 1 executable
grep -Fx 'sudo voxtype setup gpu --enable' "$calls" >/dev/null ||
  fail "Voxtype enables the GPU backend with sudo when Vulkan and the backend binary are present"
pass "Voxtype enables the GPU backend with sudo when Vulkan and the backend binary are present"

# First login has no terminal for a sudo password: the GPU switch is left for
# later, and the install says how instead of failing quietly.
run_install 1 executable no-tty
! grep -q 'setup gpu' "$calls" ||
  fail "Voxtype leaves the GPU switch alone without a terminal" "$(<"$calls")"
grep -Fq 'sudo voxtype setup gpu --enable' "$test_tmp/stderr" ||
  fail "Voxtype says how to switch to the GPU later" "$(<"$test_tmp/stderr")"
pass "Voxtype stays on the CPU without a terminal and says how to switch"

run_install 1 missing
! grep -q 'setup gpu' "$calls" ||
  fail "Voxtype does not enable a Vulkan backend the package did not ship"
pass "Voxtype does not enable a Vulkan backend the package did not ship"

run_install 1 unusable
! grep -q 'setup gpu' "$calls" ||
  fail "Voxtype does not enable a Vulkan backend that is not executable"
pass "Voxtype does not enable a Vulkan backend that is not executable"

run_install 0 executable
! grep -q 'setup gpu' "$calls" ||
  fail "Voxtype does not enable the GPU backend without a Vulkan runtime"
pass "Voxtype does not enable the GPU backend without a Vulkan runtime"
