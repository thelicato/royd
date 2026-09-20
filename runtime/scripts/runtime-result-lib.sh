#!/bin/sh
set -eu

runtime_result_key() {
  _royd_rr_version=$1
  _royd_rr_arch=$2
  _royd_rr_image_profile=$3
  _royd_rr_hal_profile=$4
  _royd_rr_security_mode=$5
  _royd_rr_graphics_backend=${6:-software}
  _royd_rr_graphics_suffix=
  [ "$_royd_rr_graphics_backend" = software ] || _royd_rr_graphics_suffix="-$_royd_rr_graphics_backend"
  printf '%s/%s-%s-%s-%s%s.env\n' "$_royd_rr_version" "$_royd_rr_arch" "$_royd_rr_image_profile" "$_royd_rr_hal_profile" "$_royd_rr_security_mode" "$_royd_rr_graphics_suffix"
}

runtime_result_get() {
  _royd_rr_file=$1
  _royd_rr_key=$2
  [ -f "$_royd_rr_file" ] || return 1
  sed -n "s/^$_royd_rr_key=//p" "$_royd_rr_file" | tail -n 1
}

runtime_result_write() {
  _royd_rr_file=$1
  shift
  mkdir -p "$(dirname -- "$_royd_rr_file")"
  _royd_rr_tmp="$_royd_rr_file.tmp.$$"
  : > "$_royd_rr_tmp"
  for _royd_rr_item in "$@"; do printf '%s\n' "$_royd_rr_item" >> "$_royd_rr_tmp"; done
  mv "$_royd_rr_tmp" "$_royd_rr_file"
}
