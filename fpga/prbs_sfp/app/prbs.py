#!/usr/bin/env python3
"""Board-side tool for the kr260-prbs app (SFP+ PRBS31 at 10.3125 Gb/s).

Run as root on the KR260 after `xmutil loadapp kr260-prbs`:
  prbs.py status              one-shot status + counters
  prbs.py inject [N]          inject N single errors and check the checker counts them
  prbs.py run [SECONDS]       clear, then soak; prints progress every 10 s (default 300)
  prbs.py reset               pulse the transceiver reset and wait for lock
"""
import mmap
import os
import struct
import sys
import time

BASE = 0xA0000000
LINE_RATE = 10.3125e9
BITS_PER_CYCLE = 64

R_ID, R_VER, R_CTRL, R_STATUS = 0x00, 0x04, 0x08, 0x0C
R_LOCK_LO, R_LOCK_HI, R_ERRS, R_INJ = 0x10, 0x14, 0x18, 0x1C

C_GT_RESET, C_CLEAR, C_INJECT, C_SNAP = 1 << 0, 1 << 1, 1 << 2, 1 << 3
STATUS_BITS = ["gtpowergood", "tx_done", "rx_done", "prbs_locked", "error_seen",
               "snap_ack", "rx_cdr_stable", "userclk_tx", "userclk_rx"]


class Regs:
    def __init__(self):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
        os.close(fd)

    def rd(self, off):
        return struct.unpack_from("<I", self.m, off)[0]

    def wr(self, off, val):
        struct.pack_into("<I", self.m, off, val & 0xFFFFFFFF)

    def ctrl_set(self, mask, on):
        v = self.rd(R_CTRL)
        self.wr(R_CTRL, (v | mask) if on else (v & ~mask))

    def ctrl_flip(self, mask):
        self.wr(R_CTRL, self.rd(R_CTRL) ^ mask)

    def status(self):
        s = self.rd(R_STATUS)
        return {name: bool(s >> i & 1) for i, name in enumerate(STATUS_BITS)}

    def snapshot(self):
        want = not self.status()["snap_ack"]
        self.ctrl_flip(C_SNAP)
        t0 = time.monotonic()
        while self.status()["snap_ack"] != want:
            if time.monotonic() - t0 > 0.5:
                raise RuntimeError("snapshot not acknowledged: RX user clock not running?")
        cycles = self.rd(R_LOCK_HI) << 32 | self.rd(R_LOCK_LO)
        return cycles, self.rd(R_ERRS), self.rd(R_INJ)

    def clear(self):
        self.ctrl_set(C_CLEAR, True)
        time.sleep(0.01)
        self.ctrl_set(C_CLEAR, False)


def ber_text(bits, errs):
    if bits == 0:
        return "no bits checked"
    if errs == 0:
        return f"BER < {3.0 / bits:.2e} (95% confidence, 0 errors)"
    return f"BER ~ {errs / bits:.2e} (error cycles / bits, lower bound)"


def show(r, label=""):
    st = r.status()
    cycles, errs, inj = r.snapshot()
    bits = cycles * BITS_PER_CYCLE
    flags = " ".join(f"{k}={'1' if v else '0'}" for k, v in st.items() if k != "snap_ack")
    print(f"{label}{flags}")
    print(f"{label}bits checked={bits:.4e}  error cycles={errs}  injected={inj}  {ber_text(bits, errs)}")
    return st, cycles, errs, inj


def wait_lock(r, timeout=5.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        st = r.status()
        if st["rx_done"] and st["prbs_locked"]:
            return True
        time.sleep(0.05)
    return False


def main():
    r = Regs()
    ident = r.rd(R_ID)
    if ident != 0x50524253:
        sys.exit(f"Unexpected ID 0x{ident:08x} at 0x{BASE:08x}: is kr260-prbs loaded?")
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"

    if cmd == "status":
        show(r)

    elif cmd == "reset":
        r.ctrl_set(C_GT_RESET, True)
        time.sleep(0.01)
        r.ctrl_set(C_GT_RESET, False)
        ok = wait_lock(r)
        r.clear()
        print("locked" if ok else "NOT locked after 5 s")
        show(r)

    elif cmd == "inject":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        r.clear()
        if not wait_lock(r):
            sys.exit("checker not locked; cannot test injection")
        for _ in range(n):
            r.ctrl_flip(C_INJECT)
            time.sleep(0.002)
        time.sleep(0.05)
        _, _, errs, inj = show(r)
        verdict = "PASS" if inj == n and errs >= n else "FAIL"
        print(f"injection test: requested={n} injected={inj} detected error cycles={errs} -> {verdict}")
        r.clear()

    elif cmd == "run":
        secs = int(sys.argv[2]) if len(sys.argv) > 2 else 300
        r.clear()
        if not wait_lock(r):
            show(r)
            sys.exit("checker not locked after clear")
        t0 = time.monotonic()
        c0 = 0
        while True:
            time.sleep(min(10, max(0.0, secs - (time.monotonic() - t0))))
            el = time.monotonic() - t0
            st, cycles, errs, _ = show(r, f"[{el:6.1f}s] ")
            if el >= secs:
                break
        rate = cycles * BITS_PER_CYCLE / el
        print(f"measured line rate ~ {rate / 1e9:.4f} Gb/s (expected {LINE_RATE / 1e9:.4f})")
        verdict = "PASS" if errs == 0 and st["prbs_locked"] else "FAIL"
        print(f"RESULT: {verdict}  {ber_text(cycles * BITS_PER_CYCLE, errs)}")

    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
