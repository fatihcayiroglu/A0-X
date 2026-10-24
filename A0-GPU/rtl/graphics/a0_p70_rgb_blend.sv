// P135: exact 8-bit alpha blend, replacing /255 arithmetic with a
// bounded shift/add identity; outputs must match the original P70 RTL bitwise.
// Input channel and alpha are each 0..255. Thus the weighted accumulator
// x = src*alpha + dst*(255-alpha) + 127 satisfies 127<=x<=65152.
// Over this bound floor(x/255) == (x + 1 + (x>>8)) >> 8.
module a0_p70_rgb_blend(
  input logic [23:0] source_rgb,
  input logic [23:0] destination_rgb,
  input logic [7:0] source_alpha,
  input logic blend_enable,
  output logic [23:0] output_rgb
);
  logic [16:0] r_acc,g_acc,b_acc;

  function automatic logic [7:0] div255_exact(input logic [16:0] x);
    logic [16:0] corrected;
    begin
      corrected = x + 17'd1 + (x >> 8);
      div255_exact = corrected[15:8];
    end
  endfunction

  always_comb begin
    r_acc = (source_rgb[23:16]*source_alpha)
          + (destination_rgb[23:16]*(8'd255-source_alpha)) + 17'd127;
    g_acc = (source_rgb[15:8]*source_alpha)
          + (destination_rgb[15:8]*(8'd255-source_alpha)) + 17'd127;
    b_acc = (source_rgb[7:0]*source_alpha)
          + (destination_rgb[7:0]*(8'd255-source_alpha)) + 17'd127;
    if (blend_enable)
      output_rgb = {div255_exact(r_acc),div255_exact(g_acc),div255_exact(b_acc)};
    else
      output_rgb = source_rgb;
  end
endmodule
