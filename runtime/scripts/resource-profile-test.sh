#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ "$("$script_dir/resource-profile.sh" low-memory)" = 'royd.resource_profile=low-memory' ]
[ "$("$script_dir/resource-profile.sh" performance)" = 'royd.resource_profile=performance' ]
[ "$(ROYD_RESOURCE_PROFILE=performance "$script_dir/resource-profile.sh")" = \
  'royd.resource_profile=performance' ]

if "$script_dir/resource-profile.sh" unknown >/dev/null 2>&1; then
  printf '%s\n' 'error: resource profile resolver accepted an unknown profile' >&2
  exit 1
fi

printf '%s\n' 'Runtime resource profile contract test passed'
