#!/bin/bash
#
# The Vault commands decide state from the cipher dir and the mount table, must
# never force an unmount, and must never delete the encrypted files. External
# programs are stubbed only to observe which of them the commands call and with
# what; the decisions under test are the commands' own.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
stub_bin="$test_dir/bin"
calls="$test_dir/calls"
mkdir -p "$stub_bin"

cat >"$stub_bin/findmnt" <<'STUB'
#!/bin/bash
printf '%s\n' "${FAKE_FSTYPE:-}"
STUB
cat >"$stub_bin/fusermount3" <<'STUB'
#!/bin/bash
echo "fusermount3 $*" >>"$CALLS"
exit "${FAKE_UNMOUNT_STATUS:-0}"
STUB
cat >"$stub_bin/gocryptfs" <<'STUB'
#!/bin/bash
echo "gocryptfs $*" >>"$CALLS"
STUB
cat >"$stub_bin/omarchy-notification-send" <<'STUB'
#!/bin/bash
echo "notify $*" >>"$CALLS"
STUB
cat >"$stub_bin/omarchy-launch-floating-terminal-with-presentation" <<'STUB'
#!/bin/bash
echo "terminal $*" >>"$CALLS"
STUB
cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
echo "pkg-add $*" >>"$CALLS"
STUB
cat >"$stub_bin/omarchy-pkg-drop" <<'STUB'
#!/bin/bash
echo "pkg-drop $*" >>"$CALLS"
STUB
cat >"$stub_bin/omarchy-pkg-present" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$stub_bin/gum" <<'STUB'
#!/bin/bash
echo "gum $*" >>"$CALLS"
exit "${GUM_ANSWER:-0}"
STUB
chmod +x "$stub_bin"/*

export OMARKY_VAULT_CIPHER="$test_dir/cipher"
export OMARKY_VAULT_MOUNT="$test_dir/mount"
export CALLS="$calls"

# run <command> [args...]: stdin is not a terminal, as when started from a keybind.
run() {
  : >"$calls"
  local status=0
  OMARCHY_PATH="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" bash "$ROOT/bin/$1" "${@:2}" >"$test_dir/out" 2>"$test_dir/err" </dev/null || status=$?
  return "$status"
}
status_of() { local s=0; run "$@" || s=$?; echo "$s"; }
called() { grep -q -- "$1" "$calls"; }

# --- status and guard answers ---------------------------------------------

[[ $(status_of omarchy-vault status) == 2 ]] || fail "status exits 2 when not set up"
[[ $(<"$test_dir/out") == "unset" ]] || fail "status prints unset when not set up"

mkdir -p "$OMARKY_VAULT_CIPHER" "$OMARKY_VAULT_MOUNT"
touch "$OMARKY_VAULT_CIPHER/gocryptfs.conf"

[[ $(status_of omarchy-vault status) == 1 ]] || fail "status exits 1 when set up but not mounted"
[[ $(status_of omarchy-vault status closed) == 0 ]] || fail "'status closed' succeeds when closed"
[[ $(status_of omarchy-vault status open) == 1 ]] || fail "'status open' fails when closed"

# A mount of some other filesystem on the mountpoint is not the Vault.
FAKE_FSTYPE=ext4 run omarchy-vault status || true
[[ $(<"$test_dir/out") == "closed" ]] || fail "a foreign mount at the mountpoint does not count as open"

export FAKE_FSTYPE=fuse.gocryptfs
[[ $(status_of omarchy-vault status) == 0 ]] || fail "status exits 0 when mounted"
[[ $(status_of omarchy-vault status open) == 0 ]] || fail "'status open' succeeds when mounted"
[[ $(status_of omarchy-vault status unset) == 1 ]] || fail "'status unset' fails when set up"
pass "status reports unset, closed and open through output and exit codes"

# --- close never forces ------------------------------------------------------

[[ $(status_of omarchy-vault close) == 0 ]] || fail "close succeeds on an idle Vault"
called "^fusermount3 -u $OMARKY_VAULT_MOUNT\$" || fail "close unmounts with plain fusermount3 -u" "$(<"$calls")"

[[ $(FAKE_UNMOUNT_STATUS=1 status_of omarchy-vault close --quiet) != 0 ]] || fail "close fails when the Vault is busy"
FAKE_UNMOUNT_STATUS=1 run omarchy-vault close --quiet || true
called "^fusermount3 " || fail "a busy close still tries the unmount"
if grep "^fusermount3 " "$calls" | grep -qv "^fusermount3 -u $OMARKY_VAULT_MOUNT\$"; then
  fail "a busy Vault is never force- or lazy-unmounted" "$(<"$calls")"
fi
called "^notify .*Vault is still open" || fail "a busy close notifies even with --quiet" "$(<"$calls")"
[[ ! -s $test_dir/out ]] || fail "--quiet keeps stdout empty on a busy close"

FAKE_FSTYPE= run omarchy-vault close
called "fusermount3" && fail "closing an already closed Vault does not unmount"
pass "close unmounts plainly, refuses to force a busy Vault, and notifies"

# --- open --------------------------------------------------------------------

export FAKE_FSTYPE=
run omarchy-vault open
called "^terminal omarchy-vault open\$" || fail "open without a terminal relaunches itself in a floating terminal" "$(<"$calls")"
called "^gocryptfs " && fail "open does not prompt for a password without a terminal"

export FAKE_FSTYPE=fuse.gocryptfs
run omarchy-vault open
called "terminal\|gocryptfs" && fail "opening an open Vault does nothing"

rm "$OMARKY_VAULT_CIPHER/gocryptfs.conf"
[[ $(status_of omarchy-vault open) == 2 ]] || fail "open exits 2 when the Vault is not set up"
touch "$OMARKY_VAULT_CIPHER/gocryptfs.conf"
pass "open hands over to a terminal, and is a no-op when open or not set up"

# --- setup is idempotent -------------------------------------------------------

export FAKE_FSTYPE=
run omarchy-setup-security-vault
called "^gocryptfs \|^gum " && fail "setup on an existing Vault neither re-inits nor prompts" "$(<"$calls")"
grep -q "already set up" "$test_dir/out" || fail "setup says the Vault is already set up"
pass "setup on an existing Vault exits cleanly and changes nothing"

# --- remove keeps the data -----------------------------------------------------

export FAKE_FSTYPE=fuse.gocryptfs
[[ $(FAKE_UNMOUNT_STATUS=1 status_of omarchy-remove-security-vault) != 0 ]] || fail "remove fails while the Vault is busy"
called "pkg-drop" && fail "remove keeps the package while the Vault cannot be closed"

export FAKE_FSTYPE=
GUM_ANSWER=1 run omarchy-remove-security-vault
called "pkg-drop" && fail "remove keeps the package unless confirmed"
GUM_ANSWER=0 run omarchy-remove-security-vault
called "pkg-drop gocryptfs" || fail "remove drops gocryptfs once confirmed"
[[ -f $OMARKY_VAULT_CIPHER/gocryptfs.conf ]] || fail "remove never deletes the encrypted files"
grep -q "$OMARKY_VAULT_CIPHER" "$test_dir/out" || fail "remove prints where the encrypted files are"
pass "remove closes the Vault, asks before dropping the package, and keeps the cipher dir"

# --- sending latch containers --------------------------------------------------
#
# `tailscale` is faked only to see which transport is chosen: `tailscale ssh`
# runs the remote command here with $HOME pointed at a fake receiver, so the
# receiving script (the real logic under test) runs for real.

cat >"$stub_bin/tailscale" <<'STUB'
#!/bin/bash
echo "tailscale $*" >>"$CALLS"
if [[ $1 == ssh ]]; then
  shift 2
  HOME="$RECEIVER_HOME" sh -c "$*"
fi
STUB
chmod +x "$stub_bin/tailscale"

export RECEIVER_HOME="$test_dir/receiver"
mkdir -p "$RECEIVER_HOME"

# A structurally valid container (header and frame hashes) needs no cipher.
make_container() {
  python3 -I - "$ROOT/default/latch" "$1" "$2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import latch
frames = []
for i in range(2):
    fb = latch.json.dumps({"salt": (bytes([i]) * 16).hex(), "nonce": "00" * 12, "codec": "zlib", "pad": "pow2"}).encode()
    frames.append((fb, bytes([int(sys.argv[3])]) * 64))
open(sys.argv[2], "wb").write(latch._build_container(frames, b"c" * 16))
PY
}

vault_a="$test_dir/a.latch"
make_container "$vault_a" 1
echo "just some notes" >"$test_dir/notes.txt"
cp "$vault_a" "$test_dir/my-rituals.latch"

[[ $(status_of omarchy-vault send fleagle-pc "$test_dir/notes.txt") != 0 ]] || fail "send refuses a file that is not a latch container"
grep -q "not a latch container" "$test_dir/err" || fail "refusing a non-container says why" "$(<"$test_dir/err")"
called "^tailscale" && fail "a refused file never reaches tailscale"

[[ $(status_of omarchy-vault send fleagle-pc "$test_dir/my-rituals.latch") != 0 ]] || fail "send refuses a file named like a rituals file"
[[ $(status_of omarchy-vault send fleagle-pc "$vault_a" --rituals-to "$test_dir/r.txt") != 0 ]] || fail "send refuses --rituals-to"
called "^tailscale" && fail "ritual refusals never reach tailscale"
pass "send refuses non-containers and ritual files before touching the network"

run omarchy-vault send fleagle-pc "$vault_a"
called "^tailscale ssh fleagle-pc " || fail "send uses Tailscale SSH by default" "$(<"$calls")"
called "^tailscale file" && fail "the default transport is not Taildrop"
cmp -s "$vault_a" "$RECEIVER_HOME/Downloads/a.latch" || fail "the container arrives byte for byte in the receiver's Downloads"
[[ -z $(ls -A "$RECEIVER_HOME/Downloads" | grep -v '^a.latch$') ]] || fail "no temp file is left behind on the receiver" "$(ls -A "$RECEIVER_HOME/Downloads")"
grep -q "size class" "$test_dir/out" || fail "send prints the size class"
grep -qi "in person" "$test_dir/out" || fail "send reminds to share rituals in person" "$(<"$test_dir/out")"
pass "send goes over Tailscale SSH, lands whole in Downloads and reminds about rituals"

make_container "$vault_a.2" 2
mkdir -p "$test_dir/second"
cp "$vault_a.2" "$test_dir/second/a.latch"
[[ $(status_of omarchy-vault send fleagle-pc "$test_dir/second/a.latch") != 0 ]] || fail "send fails when the receiver already has that name"
grep -q "already has" "$test_dir/err" || fail "an existing name is explained" "$(<"$test_dir/err")"
cmp -s "$vault_a" "$RECEIVER_HOME/Downloads/a.latch" || fail "the receiver's existing file is never overwritten"
[[ -z $(ls -A "$RECEIVER_HOME/Downloads" | grep -v '^a.latch$') ]] || fail "a refused delivery leaves no temp file"
pass "the receiver refuses to overwrite and leaves nothing behind"

run omarchy-vault send --taildrop fleagle-pc "$vault_a"
called "^tailscale file cp .*a.latch fleagle-pc:\$" || fail "--taildrop uses tailscale file cp" "$(<"$calls")"
called "^tailscale ssh" && fail "--taildrop does not also use SSH"
pass "Taildrop is used only when asked for"

export XDG_DOWNLOAD_DIR="$RECEIVER_HOME/Downloads"
cp "$test_dir/notes.txt" "$XDG_DOWNLOAD_DIR/notes.txt"
run omarchy-vault received
grep -q "^a.latch " "$test_dir/out" || fail "received lists the container" "$(<"$test_dir/out")"
grep -q "notes.txt" "$test_dir/out" && fail "received lists only latch containers"
unset XDG_DOWNLOAD_DIR
pass "received lists only genuine latch containers"
