// P74 development RTL candidate: nearest texel fetch address.
// Inputs u,v in unsigned Q0.16 fractional [0,1). No filtering/memory read.
// Invalid texture dimensions fail closed.
module a0_p74_nearest_texel_address (
  input logic [15:0] uv_u, uv_v,
  input logic [15:0] width, height,
  output logic valid,
  output logic [31:0] byte_offset_rgba8
);
  logic [31:0] product_x, product_y;
  logic [15:0] texel_x, texel_y;
  logic [31:0] linear_index;
  always_comb begin
    product_x = uv_u * width;
    product_y = uv_v * height;
    texel_x=product_x[31:16];
    texel_y=product_y[31:16];
    linear_index=({16'd0,texel_y}*width)+{16'd0,texel_x};
    valid = (width != 0) && (height != 0) && (linear_index <= 32'h3fff_ffff);
    byte_offset_rgba8=valid ? (linear_index << 2) : 32'd0;
  end
endmodule
