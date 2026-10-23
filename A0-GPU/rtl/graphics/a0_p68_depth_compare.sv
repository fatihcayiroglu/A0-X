// P68 development RTL candidate. Unsigned normalized 24-bit depth.
// 0: ALWAYS, 1: LESS, 2: LESS_EQUAL. Other modes fail closed.
module a0_p68_depth_compare (
  input logic [23:0] incoming_depth, stored_depth,
  input logic [1:0] compare_op,
  input logic candidate_valid,
  output logic accept
);
  always_comb begin
    accept = 1'b0;
    if (candidate_valid) begin
      case(compare_op)
        2'd0: accept = 1'b1;
        2'd1: accept = (incoming_depth < stored_depth);
        2'd2: accept = (incoming_depth <= stored_depth);
        default: accept = 1'b0;
      endcase
    end
  end
endmodule
