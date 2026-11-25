#!/bin/bash
# Copy the kr260-prbs app to the board and install it under /lib/firmware/xilinx.
# Usage: fpga/prbs_sfp/deploy.sh [user@host]   (default ubuntu@10.42.0.79)
# Needs: SSH key login to the board ($KR260_SSH_KEY, default ~/.ssh/id_ed25519) and the
# board's sudo password in $KR260_SUDO_PW.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
target="${1:-ubuntu@10.42.0.79}"
pw="${KR260_SUDO_PW:?set KR260_SUDO_PW to the board sudo password}"
ssh_opts=(-i "${KR260_SSH_KEY:-$HOME/.ssh/id_ed25519}")

[ -f "$here/out/kr260-prbs.bit.bin" ] || { echo "build first: out/kr260-prbs.bit.bin missing"; exit 1; }

ssh "${ssh_opts[@]}" "$target" 'mkdir -p ~/kr260-prbs'
scp "${ssh_opts[@]}" -q "$here/out/kr260-prbs.bit.bin" "$here/app/kr260-prbs.dtsi" \
    "$here/app/shell.json" "$here/app/prbs.py" "$target:kr260-prbs/"
# The sudo password goes over ssh's stdin, so it never appears on a command line (ps).
ssh "${ssh_opts[@]}" "$target" "cd ~/kr260-prbs && dtc -@ -q -I dts -O dtb -o kr260-prbs.dtbo kr260-prbs.dtsi && \
  sudo -S -p '' sh -c 'mkdir -p /lib/firmware/xilinx/kr260-prbs && \
  cp kr260-prbs.bit.bin kr260-prbs.dtbo shell.json /lib/firmware/xilinx/kr260-prbs/ && \
  install -m 755 prbs.py /usr/local/bin/prbs.py && echo DEPLOYED && xmutil listapps'" <<<"$pw"
