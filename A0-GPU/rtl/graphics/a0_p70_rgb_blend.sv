// P70 development RTL candidate: 8-bit channel alpha blend.
// Each output = floor((source * alpha + destination * (255-alpha)+127)/255).
// Output is RGB888. Alpha byte is a control input, not framebuffer alpha.
module a0_p70_rgb_blend(
  input logic [23:0] source_rgb,
  input logic [23:0] destination_rgb,
  input logic [7:0] source_alpha,
  input logic blend_enable,
  output logic [23:0] output_rgb
);
  logic [16:0] r_acc,g_acc,b_acc;
  always_comb begin
    r_acc = (source_rgb[23:16]*source_alpha)
          + (destination_rgb[23:16]*(8'd255-source_alpha)) + 17'd127;
    g_acc = (source_rgb[15:8]*source_alpha)
          + (destination_rgb[15:8]*(8'd255-source_alpha)) + 17'd127;
    b_acc = (source_rgb[7:0]*source_alpha)
          + (destination_rgb[7:0]*(8'd255-source_alpha)) + 17'd127;
    if (blend_enable)
      output_rgb = {8'(r_acc/17'd255),8'(g_acc/17'd255),8'(b_acc/17'd255)};
    else output_rgb=source_rgb;
  end
endmodule
