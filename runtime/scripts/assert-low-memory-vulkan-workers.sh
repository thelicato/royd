#!/bin/sh
set -eu
container=${1:?usage: assert-low-memory-vulkan-workers.sh CONTAINER}
identity=$(docker inspect --format '{{.Id}} {{.Image}} {{.State.StartedAt}}' "$container")
receipt=$(docker exec "$container" sh -ec '
  [ "$(getprop ro.build.version.sdk)" = 35 ]
  [ "$(getprop ro.product.cpu.abi)" = x86_64 ]
  [ "$(getprop ro.hardware.vulkan)" = pastel ]
  [ "$(getprop ro.config.low_ram)" = true ]
  tr "\000" "\n" < /proc/1/environ | grep -Fxq ROYD_CONTAINER=1
  if error=$(LC_ALL=C stat /sys/fs/selinux/enforce 2>&1); then exit 1; fi
  printf "%s\n" "$error" | grep -Fq "No such file or directory"
  pid=$(pidof surfaceflinger)
  case "$pid" in ""|*[!0-9]*) exit 1 ;; esac
  [ "$(readlink /proc/$pid/cwd)" = / ]
  [ ! -e /SwiftShader.ini ]
  start=$(awk "{print \$22}" /proc/$pid/stat)
  count=0
  for task in /proc/$pid/task/*; do
    name=$(cat "$task/comm")
    case "$name" in Thread\<[0-9][0-9]\>) count=$((count + 1)) ;; esac
  done
  [ "$count" -ge 1 ] && [ "$count" -le 4 ]
  [ "$(pidof surfaceflinger)" = "$pid" ]
  [ "$(awk "{print \$22}" /proc/$pid/stat)" = "$start" ]
  printf "%s %s\n" "$pid" "$count"
')
pid=$(printf '%s\n' "$receipt" | awk '{print $1}')
workers=$(printf '%s\n' "$receipt" | awk '{print $2}')
log=$(mktemp)
trap 'rm -f "$log"' EXIT HUP INT TERM
docker logs "$container" >"$log" 2>&1
awk -v pid="$pid" -v workers="$workers" '
  $3 == pid && index($0, "ROYD: low-memory software Vulkan worker budget:") {
    count++; if ($NF != workers) wrong = 1
  }
  END { exit count == 1 && !wrong ? 0 : 1 }
' "$log"
[ "$(docker inspect --format '{{.Id}} {{.Image}} {{.State.StartedAt}}' "$container")" = "$identity" ]
printf 'Low-memory software Vulkan worker budget passed: surfaceflinger=%s workers=%s\n' "$pid" "$workers"
