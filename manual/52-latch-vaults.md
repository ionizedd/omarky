# Latch vaults

A one-file encrypted container with two doors. Type one six-word phrase and it
opens your real data. Type the other and it opens a believable decoy. Nothing
in the file says which door is which.

latch ships with Omarky as `omarchy latch`. The first time you run it, it installs the two packages it needs, `python-cryptography` and `words` (the wordlist the phrases are made from), if you don't have them.

## Quickstart

**1. Create the container.** Pick a file to protect and a boring, believable
file for the decoy (a grocery list, an old notes file, anything low-value that
you would be willing to hand over):

```sh
omarchy latch create x.latch --in ledger.txt --decoy-in grocery-list.txt
```

On a terminal this prints two phrases, once:

```
ritual A (opens your real data): word word word word word word
ritual B (opens the decoy):      word word word word word word
```

If you are not on a terminal (a script, a pipe) latch refuses to print them and
asks for `--rituals-to FILE` instead; the file is created with mode 0600 and
must not already exist.

**2. Store both rituals** in a password manager, not next to `x.latch`. They
are shown once and cannot be recovered. Lose ritual A and the real data is gone
for good. Then delete the rituals file if you made one.

**3. Open it.**

```sh
omarchy latch open x.latch > out.txt        # type ritual A at the hidden prompt
echo "$R" | omarchy latch open x.latch > out.txt   # or pipe it in
```

Typing ritual B instead gives you the decoy file. Piping a ritual through
`echo` leaves it in your shell's environment and maybe its history; prefer the
prompt for anything that matters.

## What A and B mean

Both are equal to latch. A is simply the one *you* decided to protect real data
with; B opens whatever you gave `--decoy-in`. Under pressure you can give up B
and the file you hand over looks like an ordinary container with ordinary
content. `--random-decoy` exists (the decoy is random noise) but it prints a
warning for a reason: noise looks fake when you are made to open it.

`create` is the only moment latch says which ritual is which. After that, no
command asks "which slot" and no field in the file records it.

## Changing what is inside: use `seal --both`

```sh
omarchy latch seal x.latch --both --in new-ledger.txt
```

It asks for ritual A, then ritual B (two prompts, or two lines on stdin, A
first, then the payload if you use `--in -`). `--in` replaces what ritual A
opens; B's content stays. Both slots are re-encrypted with fresh randomness,
padded to one shared size, and stamped with a fresh time.

Use this every time you change the file, and now and then even if you have
nothing to change. The reason: a plain `seal --slot N` re-encrypts only one
slot, so anyone comparing two copies of the file (backups, a synced folder,
disk snapshots) sees exactly one half change, and that half is the one you
use. `seal --both` changes both halves, so the comparison tells them nothing.

Other `seal` rules: it needs `--in`; an empty payload needs `--allow-empty`; a
single-slot seal that would not fit the container's size is refused with a
pointer back to `--both`; `--force` re-keys a slot your secret does not own
(destroying it) and needs a secret of at least 6 words; a secret that opens
the *other* slot is always refused, because keying both slots with one secret
would make the container unopenable.

## Other commands

```sh
omarchy latch verify x.latch               # prove a ritual opens it (stays quiet about age)
omarchy latch verify x.latch --heartbeat   # also show how old this slot is
omarchy latch info x.latch                 # what an outsider can see
omarchy latch genword --n 5                # generate candidate rituals
omarchy latch open x.latch --exec CMD      # run CMD with the payload on stdin
omarchy latch create x.latch ... --force   # replace an existing file at that path
```

`verify --heartbeat` tells you a slot is STALE after 30 days. That is useful
for a smoke alarm, but an unused decoy goes stale first, so only ask for it
when nobody is watching, and fix it with `seal --both`.

## Reading `info`

```
slot 0: ct_len=2064 class=2^11 codec=zlib pad=pow2 frame_sha=ok
slot 1: ct_len=2064 class=2^11 codec=zlib pad=pow2 frame_sha=ok
twin slots share size class 2^11
```

- `slot 0 / slot 1`: file positions only. Which ritual opens which is random
  and is not recorded.
- `ct_len` and `class`: how big each encrypted half is. They should match.
  A line starting `note: twin slots sit in different size classes` means
  the halves differ in size, which shows which is which; run `seal --both`.
- `codec` and `pad`: how the data inside was compressed and padded. The
  defaults are `zlib` and `pow2`.
- `frame_sha=ok`: the header of that half is intact. `MISMATCH` means
  the file is damaged.

`info` needs no secret and shows nothing about the contents.

## Honest limits

- This hides *which* ritual is real. It does not hide that a latch container
  exists, or its size, or when the file was last modified.
- A decoy only helps if it is plausible. latch cannot make a grocery list
  look like your life; that part is on you.
- Copies matter. An old backup next to a new one can show what changed.
  Run `seal --both` before backing up, and remember that old backups of the
  container still open with the old rituals.
- Anyone who gets *both* rituals gets both contents. latch cannot tell a
  coerced open from a normal one.
- Plaintext lives in RAM and goes to stdout (or `--exec`'s stdin); it is
  never written to a temp file by latch. But RAM is not scrubbed, swap can
  keep it, and SSD wear-levelling can keep old copies of the container.
  Python cannot zero its strings.
- Six random words from a 73 000-word list are about 97 bits. That is strong,
  but only if you let latch pick them (`genword`/`create`) and do not
  substitute your own.
- `--pad none` turns off size padding and exposes exact length. Do not.
- There is no FIDO2 / hardware-key slot in this build.
- Only the v4 format is read. A v3 file gets a "re-create it" message.

## Sending a latch container to someone

A container is already encrypted, so the road it travels on does not have to be trusted: `omarchy vault send <machine> x.latch` copies it to another machine on your tailnet, and the other machine finds it in `~/Downloads`.

```sh
omarchy vault send fleagle-pc x.latch
omarchy vault received            # on the receiving PC: list what arrived
```

The same is in the Omarchy menu as _Trigger > Send Vault_ and _Trigger > Received Vaults_. Things to know:

- It goes over Tailscale SSH, because the Omarky tailnet policy tags both PCs and Taildrop does not work to or from tagged devices. It needs `omarchy setup security tailscale-ssh` on the receiving PC. On an untagged tailnet, `--taildrop` sends it with Taildrop instead.
- Only real latch containers go. Anything else, and anything named like a rituals file, is refused. The receiving side refuses to overwrite a file of the same name.
- **Never send the rituals with it.** Tell them in person, or any way that is not the same road as the file. The command reminds you every time. Anyone who gets the container and both rituals gets everything.
- Sending prints the file name and its size class, never its contents and never which door is which.

