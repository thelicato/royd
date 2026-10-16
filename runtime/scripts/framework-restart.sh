#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
container=${1:?usage: framework-restart.sh CONTAINER OUTPUT_DIR TIMEOUT}
output=${2:?usage: framework-restart.sh CONTAINER OUTPUT_DIR TIMEOUT}
limit=${3:-180}
assert_runner=${ROYD_RESTART_ASSERT_RUNNER:-$script_dir/assert-runtime.sh}
trace_pid=
suspend_trace_pid=
command -v strace >/dev/null 2>&1 || { printf '%s\n' 'error: strace is required for framework restart validation' >&2; exit 1; }
case "${DOCKER_HOST:-unix:///var/run/docker.sock}" in unix://*) ;; *) exit 1 ;; esac
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in unix://*) ;; *) exit 1 ;; esac

stop_trace() {
  kill -0 "$1"
  kill -INT "$1"
  trace_status=0
  wait "$1" || trace_status=$?
  case "$trace_status" in 0|130) ;; *) return 1 ;; esac
}
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$trace_pid" ]; then
    kill -INT "$trace_pid" 2>/dev/null || true
    wait "$trace_pid" || true
  fi
  if [ -n "$suspend_trace_pid" ]; then
    kill -INT "$suspend_trace_pid" 2>/dev/null || true
    wait "$suspend_trace_pid" || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

# Refuse remote-daemon PID guesses and trace only native processes in this container.
host_init=$(docker inspect --format '{{.State.Pid}}' "$container")
host_suspend=$(docker top "$container" -eo pid,args | awk '$2 == "/system/bin/hw/android.system.suspend-service" {print $1}')
case "$host_init" in ''|0|*[!0-9]*) exit 1 ;; esac
case "$host_suspend" in ''|0|*[!0-9]*) exit 1 ;; esac
namespace=$(docker exec "$container" readlink /proc/1/ns/pid)
[ "$namespace" = "$(readlink "/proc/$host_init/ns/pid")" ]
[ "$namespace" = "$(readlink "/proc/$host_suspend/ns/pid")" ]
docker exec "$container" sh -ec '
  tr "\000" "\n" < /proc/1/environ | grep -Fxq ROYD_CONTAINER=1
  # Verify ENOENT, not just an unreadable SELinux interface.
  if error=$(LC_ALL=C stat /sys/fs/selinux/enforce 2>&1); then exit 1; fi
  printf "%s\n" "$error" | grep -Fq "No such file or directory"
' >"$output/container-gate.log" 2>&1

# Trace every existing init thread without following its Java descendants.
init_threads() {
  for task in /proc/"$host_init"/task/*; do printf '%s\n' "${task##*/}"; done | sort -n
}
init_tids=$(init_threads)
printf '%s\n' "$init_tids" >"$output/init-tids.txt"
set --
for tid in $init_tids; do
  case "$tid" in ''|*[!0-9]*) exit 1 ;; esac
  set -- "$@" -p "$tid"
done
strace -qq -tt -y -s 256 -e trace=open,openat,openat2,write,writev,pwrite64 \
  -P /sys/power/state -P /sys/power/wakeup_count \
  -P /sys/power/wake_lock -P /sys/power/wake_unlock \
  "$@" -o "$output/power-init.strace" 2>"$output/strace-init.log" &
trace_pid=$!
# SystemSuspend has native Binder/autosuspend workers, not Java descendants.
# Follow its threads so newly created workers cannot escape the trace.
strace -f -qq -tt -y -s 256 -e trace=open,openat,openat2,write,writev,pwrite64 \
  -P /sys/power/state -P /sys/power/wakeup_count \
  -P /sys/power/wake_lock -P /sys/power/wake_unlock \
  -p "$host_suspend" -o "$output/power-suspend.strace" 2>"$output/strace-suspend.log" &
suspend_trace_pid=$!
verify_attachments() {
  # Reject unexpected new init workers rather than silently leaving them untraced.
  [ "$init_tids" = "$(init_threads)" ] || return 1
  for tid in $init_tids; do
    [ "$(awk '/^TracerPid:/ {print $2}' "/proc/$tid/status")" = "$trace_pid" ] || return 1
  done
  for task in /proc/"$host_suspend"/task/*; do
    [ "$(awk '/^TracerPid:/ {print $2}' "$task/status")" = "$suspend_trace_pid" ] || return 1
  done
}
attached=0
for attempt in 1 2 3 4 5; do
  kill -0 "$trace_pid"
  kill -0 "$suspend_trace_pid"
  if verify_attachments; then
    attached=1
    break
  fi
  sleep 1
done
[ "$attached" = 1 ]
printf 'HOST_INIT=%s\nHOST_SUSPEND=%s\nINIT_TRACER_PID=%s\nSUSPEND_TRACER_PID=%s\nATTACHED=1\n' \
  "$host_init" "$host_suspend" "$trace_pid" "$suspend_trace_pid" >"$output/trace-attachment.env"
"$script_dir/framework-restart-transition.sh" "$container" "$limit" >"$output/readiness.tsv" 2>"$output/transition.log"
ROYD_HAL_PROFILE=graphical "$assert_runner" "$container" >"$output/runtime.log" 2>&1
# Require the tracer to remain attached throughout recovery and the workload.
verify_attachments
printf '%s\n' ATTACHED_AFTER_WORKLOAD=1 >>"$output/trace-attachment.env"
stop_trace "$trace_pid"
trace_pid=
stop_trace "$suspend_trace_pid"
suspend_trace_pid=
cat "$output/power-init.strace" "$output/power-suspend.strace" >"$output/power.strace"
if grep -Eq '/sys/power/(state|wakeup_count|wake_lock|wake_unlock)' "$output/power.strace"; then
  printf '%s\n' 'error: native framework restart accessed host power controls' >&2
  exit 1
fi
docker logs "$container" >"$output/markers.log" 2>&1
[ "$(grep -Fc 'ROYD: skipping init writes to host power controls' "$output/markers.log")" -eq 1 ]
[ "$(grep -Fc 'ROYD: routing init diagnostics to container stderr' "$output/markers.log")" -eq 1 ]
[ "$(grep -Fc 'ROYD: starting framework service initialisation' "$output/markers.log")" -eq 2 ]
[ "$(grep -Fc 'ROYD: framework services initialised' "$output/markers.log")" -eq 2 ]
printf '%s\n' 'Framework restart recovered with native host-power isolation'
