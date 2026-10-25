#!/bin/sh
set -eu
file=${1:?observation required}
uid=${2:?ordinary UID required}
pid=${3:?PID required}
jq -e --argjson uid "$uid" --argjson pid "$pid" '
  .uid == $uid and $uid >= 10000 and .pid == $pid and $pid > 0
  and .done == true and .status == "pass" and (has("error") | not)
  and (.rounds | length) == 5
' "$file" >/dev/null
jq -e '
  [.rounds[].round] == [1,2,3,4,5]
  and all(.rounds[]; .duration_ms == 250 and (.tracks | length) == 1
    and .tracks[0].type == 2)
' "$file" >/dev/null
printf '%s\n' 'Ordinary-UID media preparation passed (five 250 ms audio observations)'
