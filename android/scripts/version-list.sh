#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
for file in "$android_dir"/versions/*.env; do
  basename "$file" .env
done | sort -V
