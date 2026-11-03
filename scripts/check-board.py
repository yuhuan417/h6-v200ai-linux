#!/usr/bin/env python3
"""Read-only checks over USB SSH; no netlink dumps, resets or installs."""
import argparse
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', default='root@192.168.60.1')
args = parser.parse_args()
command = r'''set -eu
test "$(cat /sys/class/net/wlan0/operstate)" = up
grep -q '50000000 Hz' /sys/kernel/debug/mmc0/ios
grep -q 'sd high-speed' /sys/kernel/debug/mmc0/ios
hostapd_cli -p /run/hostapd -i wlan0 status | grep -E '^(state|channel|vht_oper_chwidth)='
hostapd_cli -p /run/hostapd -i wlan0 status | grep -q '^state=ENABLED$'
hciconfig hci0
hciconfig hci0 | grep -q 'UP RUNNING'
test "$(cat /sys/module/hci_uart/parameters/v200ai_speed)" = 1500000
test -c /dev/video0
LC_ALL=en_US.UTF-8 bash -lc 'test "$(locale charmap)" = UTF-8'
cat /sys/kernel/debug/mmc0/ios
cat /sys/kernel/debug/mmc0/err_stats
systemctl is-active v200ai-ap.service v200ai-bt-late.service usbgadget.service
systemctl --failed --no-pager
systemd-analyze
'''
subprocess.run(['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', args.host, command], check=True)
