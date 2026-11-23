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
test -d /sys/module/sun8i_thermal
test -d /sys/module/v200ai_cpufreq
test "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver)" = v200ai-clock
grep -qw 480000 /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
grep -qw 888000 /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
test "$(cat /sys/class/thermal/thermal_zone0/trip_point_0_type)" = passive
test "$(cat /sys/class/thermal/thermal_zone0/trip_point_0_temp)" = 85000
test "$(cat /sys/class/thermal/thermal_zone0/trip_point_1_temp)" = 100000
grep -q cpufreq /sys/class/thermal/cooling_device*/type
LC_ALL=en_US.UTF-8 bash -lc 'test "$(locale charmap)" = UTF-8'
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq
cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq
cat /sys/class/thermal/thermal_zone0/temp
cat /sys/class/thermal/thermal_zone1/temp
cat /sys/class/thermal/cooling_device0/cur_state
cat /sys/kernel/debug/mmc0/ios
cat /sys/kernel/debug/mmc0/err_stats
systemctl is-active v200ai-ap.service v200ai-bt-late.service usbgadget.service
systemctl --failed --no-pager
systemd-analyze
'''
subprocess.run(['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', args.host, command], check=True)
