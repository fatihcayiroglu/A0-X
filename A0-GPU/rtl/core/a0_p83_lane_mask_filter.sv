// P83 development RTL candidate. Inactive/disabled SIMD lanes never commit.
module a0_p83_lane_mask_filter #(
  parameter integer LANES = 32
) (
  input logic [LANES-1:0] execution_mask,
  input logic [LANES-1:0] predicate_mask,
  input logic write_enable,
  output logic [LANES-1:0] write_mask
);
  always_comb write_mask = write_enable ? (execution_mask & predicate_mask) : '0;
endmodule
