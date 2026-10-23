#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
    echo 'NOT_RUN: P102 behavioral RTL needs iverilog/vvp' >&2
    exit 2
fi
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
iverilog -g2012 -Wall -s a0_triangle_scissor_depth_blend_p102_tb -o "$D/p102" \
    "$ROOT/rtl/graphics/a0_triangle_coverage_p38.sv" \
    "$ROOT/rtl/graphics/a0_p59_scissor_coverage.sv" \
    "$ROOT/rtl/graphics/a0_p68_depth_compare.sv" \
    "$ROOT/rtl/graphics/a0_p70_rgb_blend.sv" \
    "$ROOT/rtl/graphics/a0_triangle_scissor_depth_blend_p102.sv" \
    "$ROOT/tests/rtl/a0_triangle_scissor_depth_blend_p102_tb.sv"
vvp "$D/p102"
