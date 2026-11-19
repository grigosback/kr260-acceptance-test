#!/usr/bin/env python3
"""Board-side tool for the kr260-prbs app (SFP+ PRBS31 at 10.3125 Gb/s).

Run as root on the KR260 after `xmutil loadapp kr260-prbs`:
  prbs.py status              one-shot status + counters
  prbs.py inject [N]          inject N single errors and check the checker counts them
  prbs.py run [SECONDS]       clear, then soak; prints progress every 10 s (default 300)
  prbs.py reset               pulse the transceiver reset and wait for lock
  prbs.py drp ADDR [VALUE]    read (or write) a GTHE4 channel DRP register (hex)
  prbs.py eyescan OUT.csv [HSTEP] [VSTEP] [PRESCALE] [VRANGE]
                              2D statistical eye scan (defaults 2 4 5 0)

Eye scan DRP addresses/fields are from corundum include/gt/gthe4_regs.h and the
procedure follows corundum utils/xcvr_gthe4.c (gthe4_ch_eyescan_start/step).
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

R_DRP_CMD, R_DRP_WDATA, R_DRP_STATUS = 0x20, 0x24, 0x28

C_GT_RESET, C_CLEAR, C_INJECT, C_SNAP, C_ES_RESET = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4

# GTHE4 channel DRP fields: name -> (address, msb, lsb)
DRP = {
    "RX_DATA_WIDTH":         (0x003, 8, 5),
    "ES_CONTROL":            (0x03C, 15, 10),
    "ES_ERRDET_EN":          (0x03C, 9, 9),
    "ES_EYE_SCAN_EN":        (0x03C, 8, 8),
    "ES_PRESCALE":           (0x03C, 4, 0),
    "ES_HORZ_OFFSET":        (0x04F, 15, 4),
    "RXOUT_DIV":             (0x063, 2, 0),
    "RX_INT_DATAWIDTH":      (0x066, 1, 0),
    "RX_EYESCAN_VS_NEG_DIR": (0x097, 10, 10),
    "RX_EYESCAN_VS_UT_SIGN": (0x097, 9, 9),
    "RX_EYESCAN_VS_CODE":    (0x097, 8, 2),
    "RX_EYESCAN_VS_RANGE":   (0x097, 1, 0),
    "ES_ERROR_COUNT":        (0x251, 15, 0),
    "ES_SAMPLE_COUNT":       (0x252, 15, 0),
    "ES_CONTROL_STATUS":     (0x253, 3, 0),
}
ES_QUAL_MASK_ADDRS = [0x044, 0x045, 0x046, 0x047, 0x048, 0x0EC, 0x0ED, 0x0EE, 0x0EF, 0x0F0]
ES_SDATA_MASK_LO = [0x049, 0x04A, 0x04B, 0x04C, 0x04D]   # bits [79:0]
ES_SDATA_MASK_HI = [0x0F1, 0x0F2, 0x0F3, 0x0F4, 0x0F5]   # bits [159:80]
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

    # ---- DRP
    def _drp_wait(self):
        for _ in range(10000):
            st = self.rd(R_DRP_STATUS)
            if not st & 1:
                if st & 2:
                    raise RuntimeError("DRP access timed out")
                return st >> 16
        raise RuntimeError("DRP stuck busy")

    def drp_read(self, addr):
        self.wr(R_DRP_CMD, addr & 0x3FF)
        return self._drp_wait()

    def drp_write(self, addr, val):
        self.wr(R_DRP_WDATA, val & 0xFFFF)
        self.wr(R_DRP_CMD, (1 << 31) | (addr & 0x3FF))
        self._drp_wait()

    def field(self, name):
        addr, msb, lsb = DRP[name]
        return (self.drp_read(addr) >> lsb) & ((1 << (msb - lsb + 1)) - 1)

    def set_field(self, name, val):
        addr, msb, lsb = DRP[name]
        mask = ((1 << (msb - lsb + 1)) - 1) << lsb
        cur = self.drp_read(addr)
        self.drp_write(addr, (cur & ~mask) | ((val << lsb) & mask))


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


def widths(r):
    """User and internal RX data widths, decoded like corundum gthe4_ch_get_rx_*_data_width."""
    dw = r.field("RX_DATA_WIDTH")
    idw = r.field("RX_INT_DATAWIDTH")
    return (8 * (1 << (dw >> 1)) * (4 + (dw & 1))) >> 2, (16 * (1 << idw) * (4 + (dw & 1))) >> 2


def es_measure(r, int_width, prescale, timeout=5.0):
    """Run one eye-scan measurement at the current offset; return (errors, bits)."""
    r.set_field("ES_CONTROL", 0x01)
    t0 = time.monotonic()
    while not r.field("ES_CONTROL_STATUS") & 1:
        if time.monotonic() - t0 > timeout:
            r.set_field("ES_CONTROL", 0x00)
            raise RuntimeError("eye scan measurement did not finish")
    r.set_field("ES_CONTROL", 0x00)
    errs = r.field("ES_ERROR_COUNT")
    samples = r.field("ES_SAMPLE_COUNT")
    return errs, (samples * int_width) << (1 + prescale)


def set_offsets(r, h, v, ut):
    r.set_field("ES_HORZ_OFFSET", (h & 0x7FF) | (0x800 if h < 0 else 0))
    r.set_field("RX_EYESCAN_VS_NEG_DIR", 1 if v < 0 else 0)
    r.set_field("RX_EYESCAN_VS_CODE", abs(v))
    r.set_field("RX_EYESCAN_VS_UT_SIGN", ut)


def eyescan(r, out, hstep=2, vstep=4, prescale=5, vrange=0):
    data_w, int_w = widths(r)
    rxout_div = r.field("RXOUT_DIV")
    # Full rate (RXOUT_DIV = 0 -> /1): +-32 horizontal codes = +-0.5 UI
    hmax = 32 << rxout_div
    print(f"RX data width {data_w}, internal {int_w}, RXOUT_DIV code {rxout_div}, "
          f"h range +-{hmax}, prescale {prescale}, vs_range {vrange}")

    # Static setup (corundum gthe4_ch_eyescan_start)
    r.set_field("ES_CONTROL", 0x00)
    r.set_field("ES_PRESCALE", 4)
    r.set_field("ES_ERRDET_EN", 1)
    for a in ES_QUAL_MASK_ADDRS:
        r.drp_write(a, 0xFFFF)
    for k, a in enumerate(ES_SDATA_MASK_LO):
        shift = int_w - (80 - (k + 1) * 16)
        mask = 0xFFFF if shift <= 0 else (0x0000 if shift >= 16 else 0xFFFF >> shift)
        r.drp_write(a, mask)
    for a in ES_SDATA_MASK_HI:
        r.drp_write(a, 0xFFFF)
    r.set_field("RX_EYESCAN_VS_RANGE", vrange)
    set_offsets(r, 0, 0, 0)
    r.set_field("ES_EYE_SCAN_EN", 1)

    # Alignment check at the eye centre; reset the eye-scan logic if it looks wrong
    for attempt in range(10):
        errs, bits = es_measure(r, int_w, 4)
        ber = errs / bits if bits else 1.0
        if ber < 0.01:
            break
        print(f"centre BER {ber:.3f}, resetting eye-scan logic")
        r.set_field("ES_HORZ_OFFSET", 0x880)
        r.ctrl_set(C_ES_RESET, True)
        r.set_field("ES_HORZ_OFFSET", 0x800)
        r.ctrl_set(C_ES_RESET, False)
    else:
        sys.exit("eye scan alignment failed (centre BER stays high)")
    print(f"centre check: {errs} errors in {bits:.3e} bits")

    r.set_field("ES_PRESCALE", prescale)
    dfe = True   # GT Wizard ties RXLPMEN = 0 for this link, so measure both UT signs
    pts = []
    t0 = time.monotonic()
    hs = list(range(-hmax, hmax + 1, hstep))
    vs = list(range(-124, 125, vstep))
    for i, h in enumerate(hs):
        for v in vs:
            halves = []
            for ut in ((0, 1) if dfe else (0,)):
                set_offsets(r, h, v, ut)
                halves.append(es_measure(r, int_w, prescale))
            # Each UT_SIGN half only samples its own data condition, so average the two
            # BERs (summing counts would hide a closed half behind an open one).
            ber = sum(e / b if b else 1.0 for e, b in halves) / len(halves)
            pts.append((h, v, sum(e for e, _ in halves), min(b for _, b in halves), ber, halves))
        print(f"  column {i + 1}/{len(hs)} (h={h:+d}) done, {time.monotonic() - t0:.0f}s", flush=True)
    set_offsets(r, 0, 0, 0)
    r.set_field("ES_EYE_SCAN_EN", 0)

    with open(out, "w") as f:
        f.write(f"# KR260 SFP+ GTHE4_CHANNEL_X0Y6 eye scan, PRBS31 10.3125G, prescale={prescale}, "
                f"vs_range={vrange}, int_width={int_w}, h_units=1/64 UI, dfe={int(dfe)}\n")
        f.write("h,v,errors,bits,ber,err_ut0,bits_ut0,err_ut1,bits_ut1\n")
        for h, v, e, b, ber, halves in pts:
            per = ",".join(f"{he},{hb}" for he, hb in halves)
            if len(halves) == 1:
                per += ",0,0"
            f.write(f"{h},{v},{e},{b},{ber:.6e},{per}\n")
    # Open area summary at the BER floor
    clean = [b for _, _, e, b, *_ in pts if e == 0]
    floor = min(clean) if clean else min(p[3] for p in pts)
    centre_row = [p for p in pts if p[1] == min(vs, key=abs)]
    open_h = [p[0] for p in centre_row if p[2] == 0]
    centre_col = [p for p in pts if p[0] == 0]
    open_v = [p[1] for p in centre_col if p[2] == 0]
    print(f"wrote {len(pts)} points to {out} in {time.monotonic() - t0:.0f}s, BER floor ~{1 / floor:.1e}")
    if open_h:
        print(f"horizontal opening at v~0: {min(open_h)}..{max(open_h)} "
              f"({(max(open_h) - min(open_h)) / 64:.2f} UI, error-free at the floor)")
    if open_v:
        print(f"vertical opening at h=0: codes {min(open_v)}..{max(open_v)}")


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

    elif cmd == "drp":
        addr = int(sys.argv[2], 16)
        if len(sys.argv) > 3:
            r.drp_write(addr, int(sys.argv[3], 16))
        print(f"DRP[0x{addr:03x}] = 0x{r.drp_read(addr):04x}")

    elif cmd == "eyescan":
        out = sys.argv[2] if len(sys.argv) > 2 else "eyescan.csv"
        args = [int(a) for a in sys.argv[3:7]]
        eyescan(r, out, *args)

    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
