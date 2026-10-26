#!/bin/bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$root/runtime/scripts/network-accounting-policy.sh"
policy_tmp=$(mktemp -d)
trap 'rm -rf "$policy_tmp"' EXIT
output=$policy_tmp
container=owned
mock_mode=healthy mock_chain=enabled mock_rule=deny
mock_execs=0
# No Docker engine is used. Execute only the actual owned-file publication script.
docker() {
 if [ "$1" = inspect ]; then
  if [ "$mock_mode" = unowned ]; then printf 'other other\n'; else printf 'network-accounting owned\n'; fi
  return
 fi
 [ "$1" = exec ] || return 2
 shift
 if [ "$1" = --user ]; then
  [ "$2" = "$(id -u):$(id -u)" ] || return 2
  shift 2
 fi
 [ "$1" = owned ] || return 2
 shift
 mock_execs=$((mock_execs+1))
 if [ "$1" = timeout ]; then shift 2; fi
 if [ "$1" = sh ] || [ "$1" = cat ]; then "$@"; return; fi
 [ "$1 $2" = 'cmd connectivity' ] || return 2
 shift 2
 case "$1" in
  set-package-networking-enabled)
   [ "$mock_mode" != rule_failure ] || return 17
   mock_rule=allow ;;
  set-chain3-enabled)
   [ "$mock_mode" != chain_failure ] || return 18
   mock_chain=disabled ;;
  get-chain3-enabled)
   if [ "$mock_mode" = getter_failure ]; then printf 'chain:unreadable\n'; else printf 'chain:%s\n' "$mock_chain"; fi ;;
  get-package-networking-enabled)
   if [ "$2" = org.royd.networkcontrol ]; then printf '%s:allow\n' "$2"; else printf '%s:%s\n' "$2" "$mock_rule"; fi ;;
  *) return 2 ;;
 esac
}
for mock_mode in healthy rule_failure chain_failure getter_failure unowned; do
 mock_chain=enabled mock_rule=deny mock_execs=0
 if policy_restore >"$policy_tmp/restore-$mock_mode.log" 2>&1; then
  [ "$mock_mode" = healthy ]
  [ "$mock_chain:$mock_rule" = disabled:allow ]
 else
  [ "$mock_mode" != healthy ]
 fi
 [ "$mock_mode" != unowned ] || [ "$mock_execs" = 0 ]
done
mock_mode=healthy
fixture=(unused 00000000000000000000000000000000)
policy_uids=("$(id -u)")
mkdir "$policy_tmp/app"
policy_directories=("$policy_tmp/app")
policy_command 0 8
[ "$(cat "$policy_tmp/app/command-8")" = "${fixture[1]}" ]
[ ! -e "$policy_tmp/app/command-8.tmp" ]
cmp "$policy_tmp/app/command-8" "$output/policy-command-0-8.txt"
fixture[1]=11111111111111111111111111111111
if policy_command 0 8 >"$policy_tmp/duplicate.log" 2>&1; then
 printf '%s\n' 'error: an existing command was adopted or overwritten' >&2
 exit 1
fi
[ "$(cat "$policy_tmp/app/command-8")" = 00000000000000000000000000000000 ]
printf '%s\n' 'Owned policy restoration failures and non-overwriting atomic commands passed'
