// P59 development RTL candidate: rectangular pixel scissor gate.
// Coordinates are unsigned pixel indices. Zero-sized scissor rejects all.
// Independent RTL compilation/simulation has NOT been performed.
module a0_p59_scissor_coverage (
  input logic [15:0] pixel_x, pixel_y,
  input logic [15:0] rect_x, rect_y, rect_width, rect_height,
  input logic enable,
  output logic covered
);
  logic [16:0] x_end, y_end;
  always_comb begin
    x_end = {1'b0,rect_x} + {1'b0,rect_width};
    y_end = {1'b0,rect_y} + {1'b0,rect_height};
    covered = !enable || (
      (rect_width != 0) && (rect_height != 0) &&
      ({1'b0,pixel_x} >= {1'b0,rect_x}) && ({1'b0,pixel_x} < x_end) &&
      ({1'b0,pixel_y} >= {1'b0,rect_y}) && ({1'b0,pixel_y} < y_end));
  end
endmodule
