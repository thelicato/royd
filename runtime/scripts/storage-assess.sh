#!/bin/sh
set -eu
file=${1:?usage: storage-assess.sh RESULT UID PID CAPACITY ROUND}
uid=${2:?}; pid=${3:?}; bytes=${4:?}; round=${5:?}
for value in "$uid" "$pid" "$bytes" "$round"; do
  case "$value" in ''|*[!0-9]*) exit 2 ;; esac
done
[ "$uid" -ge 10000 ] && [ "$pid" -gt 0 ] && [ "$bytes" -gt 0 ]
case "$round" in 1|2) ;; *) exit 2 ;; esac
jq -e --argjson uid "$uid" --argjson pid "$pid" --argjson bytes "$bytes" --argjson round "$round" '
  .status == "pass" and .done == true and .uid == $uid and .pid == $pid and .round == $round
  and .error == null and (.readings | type) == "array" and (.readings | length) == 3
  and all(.readings[]; .filesystem_total == $bytes and .stats_total == $bytes
    and (.filesystem_available|type)=="number" and .filesystem_available>=0 and .filesystem_available<=$bytes
    and (.stats_free|type)=="number" and .stats_free>=0 and .stats_free<=$bytes)
' "$file" >/dev/null
printf '%s\n' 'Ordinary-UID storage capacity observation passed'
