#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
  echo 'NOT_RUN: P100 RTL candidate gate needs iverilog and vvp' >&2
  exit 2
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
iverilog -g2012 -s tb_a0_p100_primitive_candidates -o "$WORK/run" \
  "$ROOT/rtl/graphics/a0_p59_scissor_coverage.sv" \
  "$ROOT/rtl/graphics/a0_p68_depth_compare.sv" \
  "$ROOT/rtl/graphics/a0_p70_rgb_blend.sv" \
  "$ROOT/rtl/texture/a0_p74_nearest_texel_address.sv" \
  "$ROOT/rtl/core/a0_p83_lane_mask_filter.sv" \
  "$ROOT/tests/rtl/tb_a0_p100_primitive_candidates.sv"
vvp "$WORK/run"
