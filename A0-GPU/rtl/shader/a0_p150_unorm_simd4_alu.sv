`timescale 1ns/1ps
// P150: first bounded user-programmable shader *arithmetic primitive*.
// Four independent 8-bit UNORM lanes (RGBA); one operation per cycle
// when output is accepted. Exact independent rounding and saturation.
// NOT an ISA, shader program engine, floating-point GPU, texture unit,
// raster attachment, PCIe board, or proof of game performance.
module a0_p150_unorm_simd4_alu(
  input logic clk,rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic [7:0] req_id,
  input logic [2:0] opcode,
  input logic [31:0] operand_a,operand_b,
  input logic [7:0] uniform_alpha,
  input logic [3:0] lane_mask,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic [31:0] rsp_data
);
  // 0 MOV_A, 1 MOV_B, 2 ADD_SAT, 3 SUB_SAT,
  // 4 MUL_UNORM8, 5 MIN, 6 MAX, 7 LERP_UNORM8.
  function automatic [7:0] div255_exact(input logic [16:0] x);
    logic [16:0] v;
    begin
      // All P150 numerators are <= 65,152. Exact integer division
      // by 255 after nearest rounding, not truncated shift/approx.
      v=x+17'd1+(x>>8);
      div255_exact=v[15:8];
    end
  endfunction
  function automatic [7:0] eval_lane(
    input logic [2:0] op,
    input logic [7:0] a,b,alpha
  );
    logic [8:0] sum;
    logic [16:0] numerator;
    begin
      sum={1'b0,a}+{1'b0,b};
      numerator=0;
      case(op)
        3'd0:eval_lane=a;
        3'd1:eval_lane=b;
        3'd2:eval_lane=sum[8] ? 8'hff : sum[7:0];
        3'd3:eval_lane=(a>=b)?a-b:8'd0;
        3'd4:begin
          numerator=(17'(a)*17'(b))+17'd127;
          eval_lane=div255_exact(numerator);
        end
        3'd5:eval_lane=(a<b)?a:b;
        3'd6:eval_lane=(a>b)?a:b;
        default:begin
          numerator=17'(a)*17'(255-alpha)+17'(b)*17'(alpha)+17'd127;
          eval_lane=div255_exact(numerator);
        end
      endcase
    end
  endfunction
  logic [31:0] computed;
  always_comb begin
    computed='0;
    for(integer lane=0;lane<4;lane=lane+1)
      computed[8*lane+:8]=lane_mask[lane] ?
        eval_lane(opcode,operand_a[8*lane+:8],operand_b[8*lane+:8],
                  uniform_alpha) :
        operand_a[8*lane+:8];
  end

  // One registered output slot. With output ready asserted, it can
  // accept a fresh packet every cycle. Under backpressure hold its
  // entire payload/ID/valid stable, including simultaneous input valid.
  assign req_ready=rst_n && (!rsp_valid || rsp_ready);
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      rsp_valid<=0;
      rsp_id<=0;
      rsp_data<=0;
    end else if(req_ready)begin
      rsp_valid<=req_valid;
      if(req_valid)begin
        rsp_id<=req_id;
        rsp_data<=computed;
      end
    end
  end
endmodule
