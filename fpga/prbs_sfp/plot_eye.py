#!/usr/bin/env python3
"""Plot a prbs.py eye-scan CSV as a log10(BER) heatmap.

Usage: plot_eye.py eyescan.csv [out.png]
Points with zero errors are drawn at the scan's BER floor (1 / bits measured).
"""
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".png"
    header = open(src).readline().lstrip("# ").strip()
    d = np.genfromtxt(src, delimiter=",", names=True, skip_header=1)
    hs = np.unique(d["h"])
    vs = np.unique(d["v"])
    grid = np.full((len(vs), len(hs)), np.nan)
    clean = d["bits"][d["errors"] == 0]
    floor = 1.0 / (clean.min() if len(clean) else d["bits"].min())
    for h, v, e, b, ber in zip(d["h"], d["v"], d["errors"], d["bits"], d["ber"]):
        ber = ber if e > 0 else floor
        grid[np.searchsorted(vs, v), np.searchsorted(hs, h)] = np.log10(ber)

    fig, ax = plt.subplots(figsize=(8, 6), dpi=120)
    extent = [hs[0] / 64, hs[-1] / 64, vs[0], vs[-1]]
    im = ax.imshow(grid, origin="lower", aspect="auto", extent=extent, cmap="turbo",
                   vmin=np.floor(np.log10(floor)), vmax=0)
    ax.contour(np.linspace(extent[0], extent[1], len(hs)), vs, grid,
               levels=[np.log10(floor) + 0.5, -6, -3], colors="white", linewidths=0.8)
    ax.set_xlabel("horizontal offset (UI)")
    ax.set_ylabel("vertical offset (code)")
    ax.set_title("KR260 SFP+ 10.3125 Gb/s PRBS31 loopback, statistical eye", fontsize=10)
    fig.colorbar(im, ax=ax, label="log10(BER)")
    fig.text(0.01, 0.01, header, fontsize=6)
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(out)

    zero = d["errors"] == 0
    print(f"{out}: {len(d)} points, {zero.sum()} error-free, BER floor {floor:.1e}")
    row = d[(d["v"] == vs[np.argmin(np.abs(vs))]) & zero]
    col = d[(d["h"] == 0) & zero]
    if len(row):
        print(f"open at v~0: h {row['h'].min():+.0f}..{row['h'].max():+.0f} "
              f"= {(row['h'].max() - row['h'].min()) / 64:.2f} UI")
    if len(col):
        print(f"open at h=0: v {col['v'].min():+.0f}..{col['v'].max():+.0f} codes")


if __name__ == "__main__":
    main()
