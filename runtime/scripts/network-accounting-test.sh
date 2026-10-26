#!/bin/bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image=${1:-${ROYD_IMAGE:-$($script_dir/default-image.sh standard x86_64)}}
output=${ROYD_ACCOUNTING_OUTPUT_DIR:-$root/.work/network-accounting-$(date -u +%Y%m%dT%H%M%SZ)-$$}
container=royd-accounting-$$
volume=$container-data
owned=0 volume_owned=0 pre=0 observer_pid= fixture_pid= host_pid= ns= bpf_root=
workload=not-tested runtime=not-tested detached=not-tested image_id=unknown system_before=
children=() inputs=()
case "${DOCKER_HOST:-unix:///var/run/docker.sock}" in unix://*) ;; *) exit 2 ;; esac
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in unix://*) ;; *) exit 2 ;; esac
case "$output" in ''|/|.|..) exit 2 ;; esac
for command in docker nsenter python3 cc go timeout; do command -v "$command" >/dev/null; done
if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then exit 1; fi
mkdir -p "$(dirname -- "$output")"
mkdir "$output"
output=$(CDPATH= cd -- "$output" && pwd)
snapshot_identity() { docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$container"; }
runtime_check() { ROYD_HAL_PROFILE=graphical ROYD_GRAPHICS_BACKEND=software ROYD_RESOURCE_PROFILE=low-memory "$script_dir/assert-runtime.sh" "$container"; }
inspect_accounting() { nsenter --net="/proc/$host_pid/ns/net" "$output/build/observe" inspect "$bpf_root" "$ns"; }
oci() { docker exec "$container" sh -c 'ip -o -4 addr show dev eth0; ip -4 route show table main; ip link show dev eth0; cat /etc/resolv.conf'; }
finish() {
 status=$?
 trap - EXIT HUP INT TERM
 for fd in "${inputs[@]}"; do exec {fd}>&-; done
 for child in "${children[@]}"; do wait "$child" || status=1; done
 if [ -n "$observer_pid" ]; then
  touch "$output/observer/stop"
  wait "$observer_pid" || status=1
  observer_pid=
  detached=fail
  if inspect_accounting >"$output/detached.json" 2>"$output/detach.log"; then
   if python3 - "$output/initial.json" "$output/detached.json" <<'PY'
import json,sys
before,after=[json.load(open(p)) for p in sys.argv[1:]]
for key in ('ifindex','map_id','production_links','query'): assert before[key]==after[key],key
PY
   then detached=pass; else status=1; fi
  else status=1; fi
 fi
 if [ -n "$fixture_pid" ]; then
  kill "$fixture_pid" 2>/dev/null || status=1
  fixture_status=0
  wait "$fixture_pid" 2>"$output/fixture-stop.log" || fixture_status=$?
  printf 'EXIT_STATUS=%s\n' "$fixture_status" >"$output/fixture-stop.env"
  [ "$fixture_status" = 143 ] || status=1
 fi
 if [ "$pre" = 1 ]; then
  runtime=fail
  if runtime_check >"$output/after-runtime.log" 2>&1; then runtime=pass; else status=1; fi
  snapshot_identity >"$output/identity-after.txt" || status=1
  cmp "$output/identity-before.txt" "$output/identity-after.txt" || status=1
  [ "$system_before" = "$(docker exec "$container" pidof system_server)" ] || status=1
  oci >"$output/oci-after.log" || status=1
  cmp "$output/oci-before.log" "$output/oci-after.log" || status=1
  docker exec "$container" timeout 10 tc qdisc show dev eth0 >"$output/qdisc-after.log" || status=1
  cmp "$output/qdisc-before.log" "$output/qdisc-after.log" || status=1
 fi
 if [ "$owned" = 1 ]; then "$script_dir/container-evidence.sh" "$container" "$output/container" >"$output/capture.log" 2>&1 || status=1; fi
 result=fail
 [ "$status" != 0 ] || result=pass
 printf 'ROYD_ACCOUNTING_EVIDENCE_FORMAT=1\nRESULT_STATUS=%s\nWORKLOAD_STATUS=%s\nRUNTIME_STATUS=%s\nDETACH_STATUS=%s\nIMAGE_ID=%s\nCOMMAND_EXIT_STATUS=%s\n' "$result" "$workload" "$runtime" "$detached" "$image_id" "$status" >"$output/manifest.env"
 if [ "$owned" = 1 ]; then docker rm -f "$container" >"$output/cleanup.log"; fi
 if [ "$volume_owned" = 1 ]; then docker volume rm "$volume" >>"$output/cleanup.log"; fi
 exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
image_id=$(docker image inspect --format '{{.Id}}' "$image")
[ "$(docker image inspect --format '{{index .Config.Labels "org.royd.android-version"}} {{index .Config.Labels "org.royd.arch"}} {{index .Config.Labels "org.royd.image-profile"}} {{index .Config.Labels "org.royd.hal-profile"}} {{index .Config.Labels "org.royd.graphics-backend"}}' "$image_id")" = '15 x86_64 standard graphical software' ]
"$script_dir/network-accounting-build.sh" "$output/build" >"$output/build.log" 2>&1
docker volume create "$volume" >"$output/volume.log"
volume_owned=1
security_args=$("$script_dir/security-args.sh" privileged)
container_args=$("$script_dir/container-args.sh")
profile_args=$(ROYD_RESOURCE_PROFILE=low-memory "$script_dir/profile.sh" default)
# Splitting is limited to trusted repository-generated arguments.
# shellcheck disable=SC2086
docker create $security_args $container_args --name "$container" --network bridge \
 --label org.royd.test=network-accounting --label "org.royd.test.owner=$container" -v "$volume:/data" "$image_id" $profile_args >"$output/create.log"
owned=1
docker start "$container" >>"$output/create.log"
ROYD_BOOT_WAIT_MARKER='ROYD: using delegated cgroup v2 subtree' "$script_dir/wait-for-boot.sh" "$container" 180 >"$output/boot.log" 2>&1
"$script_dir/wait-for-health.sh" "$container" 240 >"$output/health.log" 2>&1
"$script_dir/assert-security.sh" "$container" privileged >"$output/security.log" 2>&1
runtime_check >"$output/before-runtime.log" 2>&1
pre=1
system_before=$(docker exec "$container" pidof system_server)
snapshot_identity >"$output/identity-before.txt"
oci >"$output/oci-before.log"
docker exec "$container" timeout 10 tc qdisc show dev eth0 >"$output/qdisc-before.log"
host_pid=$(docker inspect --format '{{.State.Pid}}' "$container")
case "$host_pid" in ''|0|*[!0-9]*) exit 1 ;; esac
[ "$(docker inspect --format '{{index .Config.Labels "org.royd.test"}} {{index .Config.Labels "org.royd.test.owner"}} {{.HostConfig.NetworkMode}}' "$container")" = "network-accounting $container bridge" ]
ns=$(readlink "/proc/$host_pid/ns/net")
[ "$ns" != "$(readlink /proc/self/ns/net)" ]
[ "$ns" = "$(docker exec "$container" readlink /proc/self/ns/net)" ]
printf 'HOST_PID=%s\nNETNS=%s\n' "$host_pid" "$ns" >"$output/namespace.env"
bpf_root=/proc/$host_pid/root/sys/fs/bpf/netd_shared
inspect_accounting >"$output/initial.json"
docker exec "$container" test ! -e /data/local/tmp/royd-accounting-probe
docker cp "$output/build/traffic" "$container:/data/local/tmp/royd-accounting-probe"
gateway=$(docker inspect --format '{{(index .NetworkSettings.Networks "bridge").Gateway}}' "$container")
"$output/build/traffic" -mode server -listen "$gateway:0" >"$output/fixture.log" 2>&1 &
fixture_pid=$!
for attempt in $(seq 1 100); do grep -q '"event":"ready"' "$output/fixture.log" && break; kill -0 "$fixture_pid"; sleep 0.05; done
readarray -t fixture < <(python3 - "$output/fixture.log" <<'PY'
import json,sys
r=json.loads(open(sys.argv[1]).readline());assert r['event']=='ready'
print(r['address']);print(r['nonce']);print(r['address'].rsplit(':',1)[1])
PY
)
[ "${#fixture[@]}" = 3 ]
mkdir "$output/observer"
nsenter --net="/proc/$host_pid/ns/net" "$output/build/observe" observe "$bpf_root" "$ns" "$output/build/observe.bpf.o" "$output/observer" "${fixture[2]}" >"$output/observer.log" 2>&1 &
observer_pid=$!
wait_file() {
 for attempt in $(seq 1 100); do [ -f "$1" ] && return 0; kill -0 "$observer_pid"; sleep 0.05; done
 printf 'error: observer did not publish %s\n' "$1" >&2
 return 1
}
wait_file "$output/observer/ready.json"
observe_snapshot() {
 (set -C; printf '%s\n' "$1" >"$output/observer/request.tmp")
 ln "$output/observer/request.tmp" "$output/observer/request"
 rm "$output/observer/request.tmp"
 wait_file "$output/observer/$1.json"
}
workload=fail
for phase in 1 2 3 4 5; do
 mkdir "$output/phase-$phase"
 children=() inputs=()
 uids=(1000); options=(); count=64
 case "$phase" in
  1) uids=(0); options=(-raw) ;;
  3) options=(-segmented); count=256 ;;
  4) uids=(0 1000); options=(-segmented); count=256 ;;
  5) options=(-loopback) ;;
 esac
 for uid in "${uids[@]}"; do
  pipe=$output/phase-$phase/input-$uid
  mkfifo "$pipe"
  timeout 25 docker exec -i --user "$uid:$uid" "$container" /data/local/tmp/royd-accounting-probe \
   -address "${fixture[0]}" -nonce "${fixture[1]}" -phase "$phase" -uid "$uid" -count "$count" "${options[@]}" <"$pipe" >"$output/phase-$phase/worker-$uid.log" 2>&1 &
  children+=("$!")
  exec {input_fd}>"$pipe"
  inputs+=("$input_fd")
 done
 for uid in "${uids[@]}"; do
  for attempt in $(seq 1 100); do grep -q '"event":"ready"' "$output/phase-$phase/worker-$uid.log" && break; sleep 0.05; done
  grep -q '"event":"ready"' "$output/phase-$phase/worker-$uid.log"
 done
 observe_snapshot "p$phase-before"
 for fd in "${inputs[@]}"; do printf 'start\n' >&"$fd"; exec {fd}>&-; done
 inputs=()
 for child in "${children[@]}"; do wait "$child"; done
 children=()
 observe_snapshot "p$phase-after"
done
PYTHONDONTWRITEBYTECODE=1 python3 "$root/runtime/tests/network-accounting/assess.py" "$output" >"$output/assessment.jsonl" 2>"$output/assessment.log"
workload=pass
