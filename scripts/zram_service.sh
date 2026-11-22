#!/system/bin/sh

MODDIR=${0%/*}
CONFIG="$MODDIR/zram_config.conf"

apply_zram() {
  alg="$1"
  size="$2"
  try=0
  while [ ! -e /dev/block/zram0 ] && [ "$try" -lt 60 ]; do
    sleep 1
    try=$((try + 1))
  done
  [ -e /dev/block/zram0 ] || return 1

  su -c 'swapoff /dev/block/zram0 2>/dev/null || true'
  su -c 'rmmod zram 2>/dev/null || true'
  su -c 'rmmod zsmalloc 2>/dev/null || true'
  sleep 2
  if [ -f "$MODDIR/zsmalloc.ko" ]; then
    su -c "insmod '$MODDIR/zsmalloc.ko'" || return 1
  fi
  su -c "insmod '$MODDIR/zram.ko'" || return 1
  sleep 2
  echo 1 > /sys/block/zram0/reset
  echo 0 > /sys/block/zram0/disksize
  echo "$alg" > /sys/block/zram0/comp_algorithm
  echo "$size" > /sys/block/zram0/disksize
  mkswap /dev/block/zram0 >/dev/null 2>&1
  swapon -p 32767 /dev/block/zram0 >/dev/null 2>&1
}

if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
  [ -n "${algorithm:-}" ] && [ -n "${size:-}" ] && apply_zram "$algorithm" "$size"
fi
