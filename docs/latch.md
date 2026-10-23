# latch

Reference for the latch deniable container that ships in Omarky. The end-user guide is [`manual/52-latch-vaults.md`](../manual/52-latch-vaults.md); this page is for people changing it.

## Layout

- `default/latch/latch.py` is the whole tool: one Python file using the stdlib plus `cryptography`, also importable. It is a data file rather than a `bin/` command so the tests and `omarchy-vault`'s container check can import it.
- `bin/omarchy-latch` is the command (`omarchy latch ...`). It checks `python-cryptography` and `words`, installs them with `omarchy-pkg-add` when a terminal is there (otherwise prints the one sentence saying what to install), then runs latch with `/usr/bin/python3 -I` so mise's Python, `PYTHON*` variables and the current directory cannot change what gets imported.
- `bin/omarchy-vault send|received` moves containers between machines; see "Sending" below.
- `test/latch/test_latch.py` is latch's own suite, about 90 seconds. It lives outside `test/shell.d/` on purpose so `./test/shell` stays fast; run it with `python3 test/latch/test_latch.py` after touching `default/latch/latch.py`. The send and received logic is covered by `test/shell.d/vault-test.sh`.

Do not weaken the laws below when editing latch.

## The laws

1. **Twin slots, shuffled.** Two frames, two independent rituals, frame order
   randomised with `secrets.SystemRandom`. `open` and `verify` never ask which
   slot; the single moment latch names the real ritual is `create`.
2. **Metadata inside the ciphertext.** Seal time, label, payload length are
   encrypted. Plaintext is limited to the container id, offsets, lengths,
   hashes and each frame's salt, nonce, codec and pad.
3. **Constant-work open.** Every slot is fully attempted before any verdict.
4. **Shared size class.** Both frames are padded to one power-of-two class at
   `create` and `seal --both`; a single-slot seal pads to the twin's exact
   length or refuses.
5. **Bound frames.** Each frame's authenticated data includes the container
   id, slot count and slot index: dropping the decoy, swapping frames or
   moving them into another container makes them fail to open. A container
   with a slot count other than 2 is rejected.
6. **Ownership.** A single-slot seal needs a secret that owns the slot;
   `--force` needs 6+ words; owning the twin slot is refused outright.
7. **Self-verify.** The frames latch built are decrypted back before commit.
8. **Atomic write.** Random-named temp file made `O_EXCL|O_NOFOLLOW` beside
   the target, fsync, rename; symlinked containers update their target;
   failure shreds the temp file. ENOSPC is a sentence.
9. **Clean failure.** Every error is one `latch: ...` sentence on stderr with
   exit status 2 (wrong secret, bad file, closed stdout, `/dev/full`, ...).

## Format v4

```
container = "latch-v4" | n_slots(1)=2 | container_id(16) | top_len(4)
            | top_body (JSON: ct_len, frame_len, frame_sha per frame)
            | frame_0 | frame_1
frame     = frame_json {"salt","nonce","codec","pad"} | ciphertext (+16 byte tag)
AAD       = frame_json | container_id | n_slots | slot_index
key       = scrypt(secret, salt, N=32768, r=8, p=1) -> AES-256-GCM
```

## Sending

`omarchy-vault send <machine> <file>` first parses the file with latch's own `_parse_container` (magic `latch-v4`, two slots, sane lengths), so only genuine containers move. It refuses names that look like ritual files and any `--rituals-to` argument, because rituals must never travel with the container. The container goes over `tailscale ssh`: the receiving side writes into a hidden temp file in `~/Downloads`, checks the magic and byte count, then `ln`s it to its final name, which fails if the name exists, so nothing is overwritten and a half-sent file never appears under the real name. `--taildrop` uses `tailscale file cp` instead (not available to or from tagged devices; the receiver renames on conflict). The command prints the name and size class only.
