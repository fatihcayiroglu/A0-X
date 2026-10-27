// P190 research-only coordinate bridge: 128x128 Q8.8 shader window.
// Physical framebuffer XY stays global; only legacy screen-offset UV is local.
// The host must opt in to tiling explicitly once integrated in the core.
module a0_p190_tiled_screen_uv(
  input  logic [15:0] pixel_x,pixel_y,
  input  logic signed [15:0] offset_u,offset_v,
  input  logic tile_enable,
  output logic signed [15:0] tex_u,tex_v,
  output logic invalid
);
  wire outside_legacy_window= !tile_enable &&
    ((|pixel_x[15:7]) || (|pixel_y[15:7]));
  // Q8.8 fractions are preserved; only the signed integer byte is added.
  // The ninth bit detects signed-range overflow *before* narrowing.
  wire signed [8:0] u_integer=
    $signed({2'b00,pixel_x[6:0]})+
    $signed({offset_u[15],offset_u[15:8]});
  wire signed [8:0] v_integer=
    $signed({2'b00,pixel_y[6:0]})+
    $signed({offset_v[15],offset_v[15:8]});
  assign invalid=outside_legacy_window ||
    (u_integer[8]!=u_integer[7]) ||
    (v_integer[8]!=v_integer[7]);
  // Zero outputs on fault, so a caller that accidentally captures them
  // cannot observe wrapped coordinates. The caller still MUST fault closed.
  assign tex_u=invalid ? 16'sd0 : {u_integer[7:0],offset_u[7:0]};
  assign tex_v=invalid ? 16'sd0 : {v_integer[7:0],offset_v[7:0]};
endmodule
