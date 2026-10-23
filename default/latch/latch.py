#!/usr/bin/python3
"""latch.py — a compression vault only the holder of an external secret can open.

Rebuilt 2026-10-22 from the design notes (the original 10-05 build was lost; the
design laws survived there, so this is rebuilt to those laws, not guessed).
Format VERSION=4 — the format map is in README.md.

The laws, each one a fix for a measured attack:
  TWIN — two slots, two independent secrets ("ritual A" opens the real data,
         "ritual B" the decoy). open/verify never ask "which slot": they try
         the typed secret against every frame. The only moment the tool says
         which ritual is which is `create`, once, on a terminal or into a
         0600 file; no later command or file field says it.
  METADATA INSIDE THE CIPHERTEXT — seal time, labels and payload length live
         inside the ciphertext. The only plaintext is the container id,
         offsets/lengths/hashes and per-frame crypto bookkeeping (salt, nonce,
         codec, pad). Codec lives in the frame, not the header, so changing
         it on a re-seal cannot brick the twin.
  CONSTANT-WORK — open/verify fully attempt EVERY slot before releasing any
         verdict, so a stopwatch cannot tell which slot matched. (The original
         early-return leaked a measured 72.7 ms gap identifying the real card.)
  SHARED SIZE CLASS — both frames are padded to ONE power-of-two class at
         create (and `seal --both`); a single-slot `seal` pads to the twin's
         exact ciphertext length or refuses. Length never says which is which.
  BOUND FRAMES — each frame's AEAD associated data covers the frame header,
         the container id, the slot count and the slot index, so dropping,
         swapping or transplanting a frame fails to open. n != 2 is rejected.
  OWNERSHIP — a single-slot seal verifies the presented secret owns the slot
         it overwrites; re-keying needs --force (and a 6-word secret); a
         secret that owns the TWIN slot is refused even with --force.
  SELF-VERIFY — seal decrypts the frames it built before committing.
  ATOMIC — random-named temp file (O_EXCL|O_NOFOLLOW) in the target's own
         directory, fsync, rename; a symlinked container updates its target;
         failure shreds the temp file.

Honest limits: Python cannot zero immutable bytes, core dumps are disabled but
RAM is not scrubbed, swap is a real threat, SSD wear-levelling keeps old
blocks. Plaintext only ever exists in RAM and stdout / a child's stdin
(--exec); never a temp file.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import errno
import getpass
import hashlib
import json
import math
import os
import resource
import secrets
import sys
import time
import zlib

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # surfaced later as a sentence, not an import traceback
    AESGCM = None

VERSION = 4
MAGIC = b"latch-v4"
MAGIC_V3 = b"latch-v3"
CID_LEN = 16     # random container id, plaintext in the header
N_SLOTS = 2

SCRYPT_N = 32768
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_MAXMEM = 64 * 2 ** 20

NONCE_LEN = 12   # bytes, plaintext in each frame header
SALT_LEN = 16    # bytes, plaintext in each frame header
TAG_LEN = 16     # GCM tag, appended to ciphertext

PAD_POW2 = "pow2"   # default
PAD_NONE = "none"
CODECS = ("zlib", "raw")
DEFAULT_CODEC = "zlib"

MAX_PAYLOAD = 1 << 30        # refuse to hold more than 1 GiB payload in RAM
HEARTBEAT_DAYS = 30          # verify(): sealed older than this = stale

WORDLIST_PATHS = (
    "/usr/share/dict/american-english",
    "/usr/share/dict/british-english",
    "/usr/share/dict/words",
)
RITUAL_WORDS = 6
MIN_WORDS = 65536   # 16 bits/word floor, so the printed bits figure is honest

MSG_NO_OPEN = "no slot opened with this secret (0/2 slots matched)"
MSG_NOT_CONTAINER = "not a latch container (or unrecoverably corrupt)"
MSG_CORRUPT = "corrupt container: a frame header was damaged"


class LatchError(Exception):
    """Uniform, sentence-shaped user-facing error. Never a traceback."""


def _fail(msg: str):
    raise LatchError(msg)


def _disable_coredumps():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# wordlist / rituals
# --------------------------------------------------------------------------- #
def load_wordlist() -> list:
    for p in WORDLIST_PATHS:
        try:
            words, seen = [], set()
            with open(p, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    w = line.strip().lower()
                    if w and w.isascii() and w.isalpha() and "'" not in w:
                        if w not in seen:
                            seen.add(w)
                            words.append(w)
            if len(words) >= MIN_WORDS:
                words.sort()
                return words
        except OSError:
            continue
    _fail(f"no wordlist with at least {MIN_WORDS} unique words found under "
          f"/usr/share/dict/ (Arch: install the 'words' package)")


def generate_ritual() -> str:
    """RITUAL_WORDS independent words from the system wordlist."""
    wl = load_wordlist()
    words = [secrets.choice(wl) for _ in range(RITUAL_WORDS)]
    return " ".join(words)


def ritual_bits() -> float:
    return RITUAL_WORDS * math.log2(len(load_wordlist()))


# --------------------------------------------------------------------------- #
# crypto helpers
# --------------------------------------------------------------------------- #
def _slot_key(secret: str, salt: bytes) -> bytes:
    return hashlib.scrypt(secret.encode("utf-8"), salt=salt, n=SCRYPT_N,
                          r=SCRYPT_R, p=SCRYPT_P, dklen=32,
                          maxmem=SCRYPT_MAXMEM)


def pad_to_class(data: bytes, mode: str) -> bytes:
    """pow2: smallest power-of-two length strictly greater than len(data)."""
    if mode == PAD_NONE:
        return data
    target = 1
    while target <= len(data):
        target <<= 1
    return data + secrets.token_bytes(target - len(data))


def class_len(n: int) -> int:
    """Shared size class: smallest power of two strictly greater than n."""
    target = 1
    while target <= n:
        target <<= 1
    return target


def pad_to_len(data: bytes, length: int) -> bytes:
    if len(data) > length:
        _fail("payload does not fit this container's size class; "
              "use `latch seal --both` to re-size both slots together")
    return data + secrets.token_bytes(length - len(data))


def size_class(n: int) -> str:
    return f"2^{max(1, n).bit_length() - 1}"


def _codec_compress(data: bytes, codec: str, level: int = 9) -> bytes:
    if codec == "zlib":
        return zlib.compress(data, level)
    if codec == "raw":
        return data
    _fail("unknown codec")


MAX_INNER_META = 4096
MAX_INNER = MAX_PAYLOAD + MAX_INNER_META + 4   # payload + packed metadata


def _codec_decompress(data: bytes, codec: str, limit: int = MAX_INNER) -> bytes:
    if codec == "raw":
        return data
    if codec == "zlib":
        d = zlib.decompressobj()
        # max_length is a hard cap; flush() would drain the unread tail past
        # it, so there is deliberately no flush.
        out = d.decompress(data, limit + 1)
        if len(out) > limit or d.unconsumed_tail:
            _fail("compressed data expands past the size limit")
        return out
    _fail("unknown codec")


def _pack_inner(label: str, payload: bytes, sealed_at: float) -> bytes:
    meta = json.dumps({"label": label, "t": sealed_at, "plen": len(payload)},
                      separators=(",", ":")).encode()
    if len(meta) > MAX_INNER_META:
        _fail("label too long")
    return len(meta).to_bytes(4, "big") + meta + payload


def _unpack_inner(inner: bytes) -> tuple:
    try:
        mlen = int.from_bytes(inner[:4], "big")
        if mlen > MAX_INNER_META or 4 + mlen > len(inner):
            raise ValueError
        meta = json.loads(inner[4:4 + mlen].decode())
        payload = inner[4 + mlen:]
        if not isinstance(meta, dict) or "plen" not in meta:
            raise ValueError
        if meta["plen"] > MAX_PAYLOAD or meta["plen"] > len(payload):
            raise ValueError
        payload = payload[:meta["plen"]]
        return meta, payload
    except (ValueError, IndexError, UnicodeDecodeError, zlib.error):
        _fail(MSG_NO_OPEN)  # wrong secret also produces garbage here


# --------------------------------------------------------------------------- #
# container codec
# --------------------------------------------------------------------------- #
#
# container = MAGIC(8) | n_slots(1) | container_id(16) | top_len(4) | top_body
#             | frame_0 | frame_1
# frame_i   = frame_json(frame_len) | ciphertext(ct_len, incl. tag)
# frame_json= {"salt","nonce","codec","pad"}
# AAD       = frame_json | container_id | n_slots | slot_index — so a frame
#             cannot be dropped, duplicated, moved to another slot position or
#             transplanted into another container without failing to open.
# top_body  = JSON list of {"ct_len","frame_len","frame_sha"} — locating only;
#             NOT an AAD input (a re-seal of slot 1 never invalidates slot 0).

def _frame_json_bytes(fm: dict) -> bytes:
    keep = ("salt", "nonce", "codec", "pad")
    body = {k: fm[k] for k in keep}
    return json.dumps(body, sort_keys=True, separators=(",", ":")).encode()


def _aad(frame_bytes: bytes, cid: bytes, n: int, idx: int) -> bytes:
    return frame_bytes + cid + bytes([n, idx])


class Container:
    """A parsed container: the id plus its (frame_json_bytes, ct) frames.
    Behaves like the list of frames for indexing, len() and iteration."""

    def __init__(self, cid: bytes, frames: list):
        self.cid = cid
        self.frames = list(frames)

    def __getitem__(self, i):
        return self.frames[i]

    def __len__(self):
        return len(self.frames)

    def __iter__(self):
        return iter(self.frames)


def _parse_container(blob: bytes) -> tuple:
    """Returns (cid, slots, frames) where slots = list of dicts (top entries)
    and frames = list of (frame_json_bytes, ct_bytes)."""
    if blob[:len(MAGIC_V3)] == MAGIC_V3:
        _fail("this is a v3 container; this latch reads v4 only — "
              "re-create it with `latch create`")
    head = len(MAGIC) + 1 + CID_LEN + 4
    if len(blob) < head or blob[:len(MAGIC)] != MAGIC:
        _fail(MSG_NOT_CONTAINER)
    n = blob[len(MAGIC)]
    if n != N_SLOTS:
        _fail(MSG_NOT_CONTAINER)
    cid = blob[len(MAGIC) + 1:len(MAGIC) + 1 + CID_LEN]
    tlen = int.from_bytes(blob[head - 4:head], "big")
    off = head
    if len(blob) < off + tlen:
        _fail(MSG_NOT_CONTAINER)
    try:
        slots = json.loads(blob[off:off + tlen].decode())
    except (ValueError, UnicodeDecodeError):
        _fail(MSG_NOT_CONTAINER)
    if not isinstance(slots, list) or len(slots) != n:
        _fail(MSG_NOT_CONTAINER)
    off += tlen
    frames = []
    for s in slots:
        try:
            flen = int(s["frame_len"])
            clen = int(s["ct_len"])
        except (TypeError, ValueError, KeyError):
            _fail(MSG_NOT_CONTAINER)
        if flen < 2 or clen < 1 or off + flen + clen > len(blob):
            _fail(MSG_NOT_CONTAINER)
        fb = blob[off:off + flen]
        ct = blob[off + flen:off + flen + clen]
        frames.append((fb, ct))
        off += flen + clen
    return cid, slots, frames


def _build_container(frames: list, cid: bytes) -> bytes:
    """frames = list of (frame_json_bytes, ct)."""
    slots = []
    for fb, ct in frames:
        slots.append({"ct_len": len(ct), "frame_len": len(fb),
                      "frame_sha": hashlib.sha256(fb).hexdigest()})
    top_body = json.dumps(slots, separators=(",", ":")).encode()
    head = (MAGIC + bytes([len(frames)]) + cid
            + len(top_body).to_bytes(4, "big"))
    blob = bytearray(head + top_body)
    for fb, ct in frames:
        blob += fb + ct
    return bytes(blob)


def _encrypt_frame(secret: str, salt: bytes, nonce: bytes, codec: str,
                   pad: str, inner: bytes, cid: bytes, idx: int,
                   target: int = None) -> tuple:
    """Returns (frame_json_bytes, ct). target = exact plaintext length to pad
    to (the shared size class); None = this frame's own pow2 class."""
    fb = _frame_json_bytes({"salt": salt.hex(), "nonce": nonce.hex(),
                            "codec": codec, "pad": pad})
    body = _codec_compress(inner, codec)
    if pad == PAD_NONE:
        data = body
    elif target is not None:
        data = pad_to_len(body, target)
    else:
        data = pad_to_class(body, pad)
    ct = AESGCM(_slot_key(secret, salt)).encrypt(nonce, data,
                                                  _aad(fb, cid, N_SLOTS, idx))
    return fb, ct


def _try_secret(secret: str, cont: Container, only=None) -> list:
    """CONSTANT-WORK: fully attempt every frame, always, in fixed order —
    an early return is the measured 72.7 ms leak. Returns list of
    (index, meta, payload) for every frame that opened; callers treat
    exactly-one as success."""
    if AESGCM is None:
        _fail("the 'cryptography' package is required (python3-cryptography)")
    opened = []
    for i, (fb, ct) in enumerate(cont.frames):
        if only is not None and i not in only:   # test hook; prod = all
            continue
        salt = None
        nonce = None
        codec = None
        pad = None
        try:
            fm = json.loads(fb.decode())
            salt = bytes.fromhex(fm["salt"])
            nonce = bytes.fromhex(fm["nonce"])
            codec = fm["codec"]
            pad = fm["pad"]
            if (len(salt) != SALT_LEN or len(nonce) != NONCE_LEN
                    or codec not in CODECS or pad not in (PAD_POW2, PAD_NONE)):
                raise ValueError
        except (ValueError, KeyError, UnicodeDecodeError):
            opened.append((i, None, None))
            continue
        key = _slot_key(secret, salt)  # full scrypt cost, always
        try:
            plain = AESGCM(key).decrypt(nonce, ct,
                                       _aad(fb, cont.cid, N_SLOTS, i))
            inner = _codec_decompress(plain, codec)
            meta, payload = _unpack_inner(inner)
            opened.append((i, meta, payload))
        except LatchError:
            opened.append((i, None, None))
        except Exception:
            opened.append((i, None, None))
    return opened


def _check_unique_salt(frames: list) -> None:
    salts = set()
    for fb, _ct in frames:
        try:
            salt = bytes.fromhex(json.loads(fb.decode())["salt"])
            if len(salt) != SALT_LEN:
                raise ValueError
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            _fail(MSG_CORRUPT)      # damage, not forgery
        salts.add(salt)
    if len(salts) != len(frames):
        _fail("container has duplicate frame salts (forged)")


# --------------------------------------------------------------------------- #
# I/O
# --------------------------------------------------------------------------- #
def _read_secret(prompt: str = "latch secret: ") -> str:
    if sys.stdin.isatty():
        s = getpass.getpass(prompt)
    else:
        # piped secret: consume exactly one line from the BINARY buffer. The
        # text wrapper's readline() would read ahead and swallow a payload
        # piped behind the secret (`seal --in -`), sealing 0 bytes.
        raw = sys.stdin.buffer.readline()
        if not raw:
            _fail("no secret provided on stdin")
        try:
            s = raw.rstrip(b"\r\n").decode("utf-8")
        except UnicodeDecodeError:
            _fail("the secret is not valid UTF-8 text")
    return s


def _read_payload(spec: str) -> bytes:
    if spec == "-":
        data = sys.stdin.buffer.read()
    else:
        try:
            with open(spec, "rb") as f:
                data = f.read()
        except OSError as e:
            _fail(f"could not read {spec}: {e.strerror or e}")
    if len(data) > MAX_PAYLOAD:
        _fail("payload over the 1 GiB in-RAM limit")
    return data


def _write_all(fd: int, data: bytes) -> None:
    off = 0
    while off < len(data):
        off += os.write(fd, data[off:])


def _write_atomic(path: str, blob: bytes) -> None:
    # A symlinked container updates what it points at (the link survives).
    target = os.path.realpath(path)
    # Random-suffixed temp name made with O_EXCL|O_NOFOLLOW: a planted
    # NAME.partial symlink is never followed, and nothing guessable exists.
    partial = os.path.join(os.path.dirname(target) or ".",
                           f".{os.path.basename(target)}."
                           f"{secrets.token_hex(8)}.partial")
    fd = None
    created = False
    try:
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                     | os.O_NOFOLLOW, 0o600)
        created = True
        _write_all(fd, blob)
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.rename(partial, target)
        pfd = os.open(os.path.dirname(target) or ".", os.O_RDONLY)
        try:
            os.fsync(pfd)
        finally:
            os.close(pfd)
    except OSError as e:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if created:      # never shred a file we did not create ourselves
            _shred(partial)
        if e.errno == errno.ENOSPC:
            _fail("out of space while sealing; nothing committed")
        _fail(f"could not seal {path}: {e.strerror or e}")


def _shred(path: str) -> None:
    try:
        size = os.path.getsize(path)
        fd = os.open(path, os.O_WRONLY)
        try:
            zero = b"\x00" * (1 << 20)
            off = 0
            while off < size:
                n = min(len(zero), size - off)
                off += os.write(fd, zero[:n])
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass
    try:
        os.unlink(path)  # spy target for the fault-injection test
    except OSError:
        pass


def _read_container_file(path: str) -> bytes:
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        _fail(f"could not read {path}: {e.strerror or e}")


def _load(path: str) -> Container:
    blob = _read_container_file(path)
    cid, slots, frames = _parse_container(blob)
    for entry, (fb, _ct) in zip(slots, frames):
        if hashlib.sha256(fb).hexdigest() != entry.get("frame_sha"):
            _fail(MSG_CORRUPT)
    _check_unique_salt(frames)
    return Container(cid, frames)


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def _seal_fresh(path: str, secret0: str, label0: str, payload0: bytes,
                secret1: str, label1: str, payload1: bytes,
                codec: str, pad: str) -> bytes:
    """Builds and self-verifies a two-slot container in RAM, then commits."""
    now = time.time()
    cid = secrets.token_bytes(CID_LEN)
    frames = []
    built = []  # (secret, frame_json_bytes) for self-verify
    items = ((secret0, label0, payload0), (secret1, label1, payload1))
    inners = [_pack_inner(lb, pl, now) for _s, lb, pl in items]
    # SHARED SIZE CLASS: both frames pad to one class, so a compressible real
    # payload and an incompressible decoy cannot be told apart by length.
    target = class_len(max(len(_codec_compress(i, codec)) for i in inners))
    for (secret, _label, _payload), inner in zip(items, inners):
        idx = len(frames)
        salt = secrets.token_bytes(SALT_LEN)
        nonce = secrets.token_bytes(NONCE_LEN)
        fb, ct = _encrypt_frame(secret, salt, nonce, codec, pad, inner,
                                cid, idx, target)
        frames.append((fb, ct))
        built.append((idx, secret, fb))
    blob = _build_container(frames, cid)
    _self_verify_frames(blob, built)
    _write_atomic(path, blob)
    return blob


def _self_verify_frames(blob: bytes, checks: list) -> None:
    """Round-trip the given frames of the container we built.
    checks = list of (slot_index, secret, frame_json_bytes). Each named slot
    must still hold exactly the frame bytes we built AND decrypt with its
    secret."""
    cid, _slots, reread = _parse_container(blob)
    for idx, secret, fb0 in checks:
        fb, ct = reread[idx]
        if fb != fb0:
            _fail("self-verify: frame mismatch; nothing committed")
        try:
            fm = json.loads(fb.decode())
            plain = AESGCM(_slot_key(secret, bytes.fromhex(fm["salt"])))\
                .decrypt(bytes.fromhex(fm["nonce"]), ct,
                          _aad(fb, cid, N_SLOTS, idx))
            inner = _codec_decompress(plain, fm["codec"])
            _unpack_inner(inner)
        except Exception:
            _fail("self-verify: fresh container failed to decrypt; "
                  "nothing committed")


def cmd_create(args) -> int:
    _disable_coredumps()
    if os.path.lexists(args.cont) and not args.force:
        _fail(f"{args.cont} already exists; refusing to overwrite it "
              f"(--force replaces it and destroys what it held)")
    if args.decoy_in and args.random_decoy:
        _fail("choose --decoy-in FILE or --random-decoy, not both")
    if not args.decoy_in and not args.random_decoy:
        _fail("create needs a decoy: give --decoy-in FILE (a plausible "
              "low-value file), or --random-decoy to accept a decoy that "
              "will look fake when you are coerced to open it")
    if args.decoy_in == "-" and args.infile == "-":
        _fail("--in and --decoy-in cannot both read stdin")
    payload = _read_payload(args.infile) if args.infile else b""
    if not payload and not args.allow_empty:
        _fail("the real payload is empty; give --in FILE (or pass "
              "--allow-empty)")
    # two independent rituals, shuffled slot assignment so "real" is not
    # always slot 0 (no plaintext sidecar may ever say which is which)
    ritual_real = generate_ritual()
    ritual_decoy = generate_ritual()
    if args.decoy_in:
        decoy_payload = _read_payload(args.decoy_in)
        if not decoy_payload:
            _fail("the decoy file is empty; an empty decoy looks fake")
    else:
        print("latch: warning: --random-decoy makes the decoy random noise; "
              "when you are coerced to open it, it will look fake. Prefer "
              "--decoy-in FILE with a plausible low-value file.",
              file=sys.stderr)
        decoy_payload = secrets.token_bytes(max(16, min(len(payload) or 64,
                                                        1 << 20)))
    # The rituals must never land in a log or a pipe: print only on a TTY,
    # otherwise write them to a fresh 0600 file. Claim the file BEFORE the
    # container exists so a refusal cannot cost the owner their rituals.
    rfd = None
    if args.rituals_to:
        try:
            rfd = os.open(args.rituals_to, os.O_WRONLY | os.O_CREAT
                          | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            _fail(f"{args.rituals_to} already exists; refusing to overwrite")
    elif not (sys.stdout is not None and sys.stdout.isatty()):
        _fail("stdout is not a terminal, so the rituals will not be printed; "
              "give --rituals-to FILE (created 0600, must not exist)")
    assignment = [(ritual_real, args.label or "real", payload),
                  (ritual_decoy, "decoy", decoy_payload)]
    secrets.SystemRandom().shuffle(assignment)
    text = (f"ritual A (opens your real data): {ritual_real}\n"
            f"ritual B (opens the decoy): {ritual_decoy}\n")
    try:
        if rfd is not None:   # rituals on disk first: never a container
            _write_all(rfd, text.encode())   # whose rituals were lost
            os.fsync(rfd)
        _seal_fresh(args.cont, assignment[0][0], assignment[0][1],
                    assignment[0][2], assignment[1][0], assignment[1][1],
                    assignment[1][2], args.codec, args.pad)
        if rfd is not None:
            os.close(rfd)
            rfd = None
    except BaseException:
        if rfd is not None:
            os.close(rfd)
            try:
                os.unlink(args.rituals_to)
            except OSError:
                pass
        raise
    if args.rituals_to:
        print(f"rituals written to {args.rituals_to} (mode 0600). Move them "
              f"to a secret manager and delete the file.")
    else:
        print(text, end="")
    print(f"\n~{math.log2(len(load_wordlist())) * RITUAL_WORDS:.0f} bits per "
          f"ritual. These words are shown ONCE — store them now (a secret "
          f"manager, not the disk next to the container).")
    print(f"sealed {args.cont}")
    return 0


def _seal_both(args) -> int:
    """Re-encrypt BOTH slots together: fresh salt+nonce, one shared size
    class, fresh seal time. Only this leaves a snapshot diff in which both
    frames changed, so the diff does not say which slot is live."""
    if args.slot is not None or args.force:
        _fail("--both takes neither --slot nor --force")
    frames = _load(args.cont)
    secrets_in = [_read_secret("ritual A: "), _read_secret("ritual B: ")]
    new_payload = None
    if args.infile:
        new_payload = _read_payload(args.infile)
        if not new_payload and not args.allow_empty:
            _fail("the new payload is empty; pass --allow-empty if you "
                  "really mean to seal nothing")
    found = []   # per ritual: (slot index, meta, payload)
    for name, sec in zip("AB", secrets_in):
        hits = [h for h in _try_secret(sec, frames) if h[1] is not None]
        if len(hits) != 1:
            _fail(f"ritual {name} does not open this container")
        found.append(hits[0])
    if found[0][0] == found[1][0]:
        _fail("ritual A and ritual B open the same slot; give one ritual "
              "for each slot")
    now = time.time()
    inners = []
    for n, (_i, meta, payload) in enumerate(found):
        label = meta.get("label", "")
        if n == 0:
            if args.label is not None:
                label = args.label
            if new_payload is not None:
                payload = new_payload
        inners.append(_pack_inner(label, payload, now))
    target = None
    if args.pad != PAD_NONE:
        target = class_len(max(len(_codec_compress(i, args.codec))
                               for i in inners))
    new_frames = list(frames)
    checks = []
    for (idx, _m, _p), sec, inner in zip(found, secrets_in, inners):
        fb, ct = _encrypt_frame(sec, secrets.token_bytes(SALT_LEN),
                                secrets.token_bytes(NONCE_LEN), args.codec,
                                args.pad, inner, frames.cid, idx, target)
        new_frames[idx] = (fb, ct)
        checks.append((idx, sec, fb))
    blob = _build_container(new_frames, frames.cid)
    _self_verify_frames(blob, checks)
    _write_atomic(args.cont, blob)
    print(f"resealed both slots (class {size_class(len(new_frames[0][1]))})")
    return 0


def cmd_seal(args) -> int:
    _disable_coredumps()
    if args.both:
        return _seal_both(args)
    frames = _load(args.cont)
    if args.slot is None:
        _fail("use --slot 0 or --slot 1 to name the slot being resealed")
    if args.slot not in (0, 1) or args.slot >= len(frames):
        _fail("there are only slots 0 and 1")
    if not args.infile:
        _fail("seal needs --in FILE (or --in - for stdin) naming the new "
              "payload")
    secret = _read_secret()
    payload = _read_payload(args.infile)
    if not payload and not args.allow_empty:
        _fail("the new payload is empty; pass --allow-empty if you really "
              "mean to seal nothing")

    # OWNERSHIP: the secret must open the slot being replaced.
    opened = _try_secret(secret, frames)
    owned = any(o[0] == args.slot for o in opened if o[1] is not None)
    if any(o[0] != args.slot for o in opened if o[1] is not None):
        # keying both slots with one secret bricks the container (open then
        # sees two hits); not even --force may do it
        _fail("this secret owns the twin slot; refusing to key both slots "
              "with one secret (even with --force)")
    if not owned and not args.force:
        _fail(f"this secret does not own slot {args.slot}; re-keying "
              f"refused (--force to re-key anyway, destroying the old "
              f"payload)")
    if not owned and len(secret.split()) < RITUAL_WORDS:
        _fail(f"--force would key the slot with a weak secret; use at least "
              f"{RITUAL_WORDS} words (see `latch genword`)")
    # also refuse to touch the TWIN slot's frame bytes
    other = 1 - args.slot if len(frames) == 2 else None

    label = args.label if args.label is not None else ""
    salt = secrets.token_bytes(SALT_LEN)
    nonce = secrets.token_bytes(NONCE_LEN)
    inner = _pack_inner(label, payload, time.time())
    # pad to the twin's exact ciphertext length, or refuse (never grow one
    # slot alone: that shows which slot was touched)
    target = None
    if other is not None and args.pad != PAD_NONE:
        target = len(frames[other][1]) - TAG_LEN
    new_fb, new_ct = _encrypt_frame(secret, salt, nonce, args.codec,
                                    args.pad, inner, frames.cid, args.slot,
                                    target)
    new_frames = list(frames)
    new_frames[args.slot] = (new_fb, new_ct)
    blob = _build_container(new_frames, frames.cid)
    # SELF-VERIFY the freshly built frame; the twin is guarded separately by
    # the byte-identity check below (seal never learns the twin's secret).
    checks = [(args.slot, secret, new_fb)]
    _self_verify_frames(blob, checks)
    _cid, _slots, reread = _parse_container(blob)
    if other is not None and reread[other][0] != frames[other][0]:
        _fail("self-verify: twin frame disturbed; nothing committed")
    if other is not None and reread[other][1] != frames[other][1]:
        _fail("self-verify: twin ciphertext disturbed; nothing committed")
    _write_atomic(args.cont, blob)
    print(f"sealed slot {args.slot}: {len(payload)} bytes "
          f"(class {size_class(len(new_ct))})")
    return 0


def cmd_open(args) -> int:
    _disable_coredumps()
    frames = _load(args.cont)
    secret = _read_secret()
    opened = _try_secret(secret, frames)     # constant work, both slots
    hits = [(i, m, p) for (i, m, p) in opened if m is not None]
    if len(hits) != 1:
        if len(hits) > 1:
            _fail("two slots opened with this secret (salt collision on one "
                  "container is forbidden)")
        _fail(MSG_NO_OPEN)
    i, _meta, payload = hits[0]
    if args.exec:
        import subprocess
        proc = subprocess.run(args.exec, shell=True, input=payload)
        return proc.returncode
    (sys.stdout.buffer if sys.stdout.buffer else sys.stdout).write(payload)
    sys.stdout.buffer.flush()
    return 0


def cmd_verify(args) -> int:
    _disable_coredumps()
    frames = _load(args.cont)
    secret = _read_secret()
    opened = _try_secret(secret, frames)     # constant work, both slots
    hits = [(i, m) for (i, m, _p) in opened if m is not None]
    if len(hits) != 1:
        _fail(MSG_NO_OPEN)       # same channel and rc as `open`
    _i, meta = hits[0]
    print("this secret opens the container")
    if args.heartbeat:
        # Opt-in: an unused decoy goes stale first, so showing age by default
        # would tell a coercer (or a shoulder) which slot is the real one.
        age = max(0, (time.time() - float(meta.get("t", time.time()))) / 86400)
        print(f"sealed {age:.1f} days ago; " + (
            "heartbeat STALE (>{:.0f}d): re-seal both slots with "
            "`latch seal --both`".format(HEARTBEAT_DAYS)
            if age > HEARTBEAT_DAYS else "heartbeat fresh"))
    return 0


def cmd_info(args) -> int:
    _disable_coredumps()
    _cid, slots, frames = _parse_container(_read_container_file(args.cont))
    classes = set()
    rows = []
    for i, (s, (fb, _ct)) in enumerate(zip(slots, frames)):
        try:
            fm = json.loads(fb.decode())
            sha_ok = hashlib.sha256(fb).hexdigest() == s.get("frame_sha")
        except Exception:
            _fail(MSG_NOT_CONTAINER)
        cls = size_class(s["ct_len"])
        classes.add(cls)
        rows.append((i, s["ct_len"], cls, fm.get("codec"), fm.get("pad"),
                     sha_ok))
    for i, clen, cls, codec, pad, sha_ok in rows:
        print(f"slot {i}: ct_len={clen} class={cls} codec={codec} pad={pad} "
              f"frame_sha={'ok' if sha_ok else 'MISMATCH'}")
    if len(classes) > 1:
        print("note: twin slots sit in different size classes — this leaks "
              "which slot is which; re-seal both if that matters")
    else:
        print(f"twin slots share size class {classes.pop() if classes else '?'}")
    return 0


def cmd_genword(args) -> int:
    if args.n < 1:
        _fail("genword --n must be at least 1")
    for _ in range(args.n):
        print(generate_ritual())
    return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="latch", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("create", help="create a new two-slot container")
    p.add_argument("cont")
    p.add_argument("--in", dest="infile", help="plaintext file (real payload), or - for stdin")
    p.add_argument("--label", default="")
    p.add_argument("--decoy-in", dest="decoy_in",
                   help="plausible low-value file the decoy ritual opens")
    p.add_argument("--random-decoy", action="store_true",
                   help="decoy = random noise (looks fake when coerced)")
    p.add_argument("--force", action="store_true",
                   help="overwrite an existing file at this path")
    p.add_argument("--rituals-to", dest="rituals_to", metavar="FILE",
                   help="write the two rituals to FILE (0600, must not "
                        "exist); required unless stdout is a terminal")
    p.add_argument("--allow-empty", action="store_true",
                   help="permit a zero-length real payload")
    p.add_argument("--codec", default=DEFAULT_CODEC, choices=CODECS)
    p.add_argument("--pad", default=PAD_POW2, choices=(PAD_POW2, PAD_NONE))
    p.set_defaults(fn=cmd_create)

    p = sub.add_parser("seal", help="replace a payload; `seal --both` is "
                                    "the recommended way")
    p.add_argument("cont")
    p.add_argument("--slot", type=int, default=None, choices=(0, 1))
    p.add_argument("--in", dest="infile", help="plaintext file, or - for stdin")
    p.add_argument("--label", default=None)
    p.add_argument("--codec", default=DEFAULT_CODEC, choices=CODECS)
    p.add_argument("--pad", default=PAD_POW2, choices=(PAD_POW2, PAD_NONE))
    p.add_argument("--allow-empty", action="store_true",
                   help="permit sealing a zero-length payload")
    p.add_argument("--both", action="store_true",
                   help="re-encrypt BOTH slots together (reads ritual A then "
                        "ritual B); --in replaces ritual A's payload only")
    p.add_argument("--force", action="store_true",
                   help="re-key a slot this secret does not own (destroys it)")
    p.set_defaults(fn=cmd_seal)

    p = sub.add_parser("open", help="print payload to stdout (or --exec CMD)")
    p.add_argument("cont")
    p.add_argument("--exec", dest="exec", help="run CMD with payload on stdin")
    p.set_defaults(fn=cmd_open)

    p = sub.add_parser("verify", help="prove a secret opens the container")
    p.add_argument("cont")
    p.add_argument("--heartbeat", action="store_true",
                   help="also show how long ago this slot was sealed (an "
                        "unused decoy goes stale: it reveals which is which)")
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("info", help="what the world can see (no secrets)")
    p.add_argument("cont")
    p.set_defaults(fn=cmd_info)

    p = sub.add_parser("genword", help="generate candidate rituals")
    p.add_argument("--n", type=int, default=2)
    p.set_defaults(fn=cmd_genword)

    args = ap.parse_args(argv)
    try:
        if sys.stdout is None:
            _fail("stdout is closed; refusing to run, the output would be "
                  "lost")
        rc = args.fn(args)
        sys.stdout.flush()     # surface a deferred write error (/dev/full)
        return rc
    except LatchError as e:
        msg = str(e)
    except BrokenPipeError:
        msg = "the output pipe was closed before latch finished writing"
    except OSError as e:
        msg = (e.strerror or str(e)) + (f": {e.filename}" if e.filename
                                        else "")
    except UnicodeError:
        msg = "input is not valid UTF-8 text (secrets must be UTF-8)"
    # a failed stdout must not raise again from the interpreter's exit flush
    try:
        if sys.stdout is not None:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    except (OSError, ValueError):
        pass
    try:
        print(f"latch: {msg}", file=sys.stderr)
        sys.stderr.flush()
    except (OSError, ValueError):
        pass
    return 2


if __name__ == "__main__":
    sys.exit(main())