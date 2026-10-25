`timescale 1ns/1ps
// P170: one-cycle look-ahead instruction fetch and decoded operand snapshot.
// P162: real P150 arithmetic and P159/P158/P156 BRAM bilinear TEX in one
// sequential, interlocked 8-register / 16-instruction research shader.
// TEX is a 25th instruction class bit; the previous 24-bit ALU ISA is intact.
// Coordinates are signed Q8.8 texels, packed {V[15:0],U[15:0]} in srcA.
// No vertex interpolation, fragment dispatch, mipmaps or external DRAM.
module a0_p162_textured_microprogram(
  input logic clk,rst_n,
  input logic reg_write_valid,
  input logic [2:0] reg_write_index,
  input logic [31:0] reg_write_data,
  input logic [2:0] reg_read_index,
  output logic [31:0] reg_read_data,
  input logic insn_write_valid,
  input logic [3:0] insn_write_index,
  input logic [24:0] insn_write_data,
  input logic texture_write_valid,
  output logic texture_write_ready,
  input logic [3:0] texture_write_x,texture_write_y,
  input logic [31:0] texture_write_rgba,
  input logic start,
  input logic [4:0] start_length,
  output logic ready,busy,done,fault,
  output logic [4:0] retired_count,
  output logic [4:0] texture_retired_count
);
  localparam logic [2:0] IDLE=0,DECODE=1,ALU_ISSUE=2,
                         ALU_WAIT=3,TEX_ISSUE=4,TEX_WAIT=5,FAILED=6;
  logic [2:0] state_q;
  logic [31:0] regs[0:7];
  logic [24:0] insn_ram[0:15];
  logic [3:0] pc_q;
  logic [4:0] run_len_q;
  // Instructions are prefetched on launch / prior retirement; the ALU
  // therefore never sees the 16-entry instruction RAM mux on its data path.
  logic [24:0] instruction_q;
  wire [24:0] instruction=instruction_q;
  // Both source registers are snapshotted during the existing DECODE cycle.
  // No extra instruction clocks or live-indexed input to P150/P158.
  logic [31:0] operand_a_q,operand_b_q;
  wire is_tex=instruction[24];
  wire [7:0] alpha=instruction[23:16];
  wire [3:0] mask=instruction[15:12];
  wire [2:0] op=instruction[11:9];
  wire [2:0] dst=instruction[8:6];
  wire [2:0] src_a=instruction[5:3];
  wire [2:0] src_b=instruction[2:0];

  wire alu_ready,alu_valid;
  wire [7:0] alu_id;
  wire [31:0] alu_result;
  a0_p150_unorm_simd4_alu alu(
    .clk(clk),.rst_n(rst_n),
    .req_valid(state_q==ALU_ISSUE),.req_ready(alu_ready),
    .req_id({4'd0,pc_q}),.opcode(op),
    .operand_a(operand_a_q),.operand_b(operand_b_q),
    .uniform_alpha(alpha),.lane_mask(mask),
    .rsp_valid(alu_valid),.rsp_ready(state_q==ALU_WAIT),
    .rsp_id(alu_id),.rsp_data(alu_result)
  );

  wire tex_ready,tex_valid,tex_present;
  wire [7:0] tex_id;
  wire [31:0] tex_rgba;
  wire internal_write_ready;
  // A texture update is legal only as a stand-alone idle configuration
  // transaction. Busy/start requests cannot alter an in-flight sample.
  assign texture_write_ready=rst_n && state_q==IDLE && !start &&
    !reg_write_valid && !insn_write_valid && internal_write_ready;
  a0_p158_bilinear_texture tex(
    .clk(clk),.rst_n(rst_n),
    .write_valid(texture_write_valid && texture_write_ready),
    .write_ready(internal_write_ready),
    .write_x(texture_write_x),.write_y(texture_write_y),
    .write_rgba(texture_write_rgba),
    .sample_valid(state_q==TEX_ISSUE),.sample_ready(tex_ready),
    .sample_u($signed(operand_a_q[15:0])),
    .sample_v($signed(operand_a_q[31:16])),
    .sample_repeat(alpha[0]),.sample_id({4'd0,pc_q}),
    .rsp_valid(tex_valid),.rsp_ready(state_q==TEX_WAIT),
    .rsp_id(tex_id),.rsp_rgba(tex_rgba),.rsp_present(tex_present)
  );

  logic [31:0] masked_tex;
  always_comb begin
    masked_tex=regs[dst];
    for(integer lane=0;lane<4;lane=lane+1)
      if(mask[lane])masked_tex[8*lane+:8]=tex_rgba[8*lane+:8];
  end
  assign ready=rst_n && state_q==IDLE && !fault;
  assign busy=rst_n && (state_q!=IDLE) && (state_q!=FAILED);
  assign reg_read_data=regs[reg_read_index];

  integer i;
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;pc_q<=0;run_len_q<=0;
      instruction_q<=0;operand_a_q<=0;operand_b_q<=0;
      retired_count<=0;texture_retired_count<=0;
      done<=0;fault<=0;
      for(i=0;i<8;i=i+1)regs[i]<=0;
      for(i=0;i<16;i=i+1)insn_ram[i]<=0;
    end else begin
      done<=0;
      case(state_q)
        IDLE:begin
          // Fail closed for mixed configuration requests and launch races.
          if((start && (reg_write_valid || insn_write_valid || texture_write_valid)) ||
             (reg_write_valid && (insn_write_valid || texture_write_valid)) ||
             (insn_write_valid && texture_write_valid))begin
            fault<=1;state_q<=FAILED;
          end else if(start)begin
            if(start_length==0 || start_length>16)begin
              fault<=1;state_q<=FAILED;
            end else begin
              pc_q<=0;run_len_q<=start_length;
              instruction_q<=insn_ram[0];
              retired_count<=0;texture_retired_count<=0;
              state_q<=DECODE;
            end
          end else begin
            if(reg_write_valid)regs[reg_write_index]<=reg_write_data;
            if(insn_write_valid)insn_ram[insn_write_index]<=insn_write_data;
          end
        end
        DECODE:begin
          operand_a_q<=regs[src_a];operand_b_q<=regs[src_b];
          // TEX reserves the legacy ALU opcode/srcB fields and alpha[7:1].
          // Malformed encodings never sample or write any destination.
          if(is_tex)begin
            if(op!=0 || src_b!=0 || alpha[7:1]!=0)begin
              fault<=1;state_q<=FAILED;
            end else state_q<=TEX_ISSUE;
          end else state_q<=ALU_ISSUE;
        end
        ALU_ISSUE:if(alu_ready)state_q<=ALU_WAIT;
        ALU_WAIT:if(alu_valid)begin
          if(alu_id!={4'd0,pc_q})begin
            fault<=1;state_q<=FAILED;
          end else begin
            regs[dst]<=alu_result;
            retired_count<=retired_count+5'd1;
            if(retired_count+5'd1==run_len_q)begin
              done<=1;state_q<=IDLE;
            end else begin
              instruction_q<=insn_ram[pc_q+4'd1];
              pc_q<=pc_q+4'd1;state_q<=DECODE;
            end
          end
        end
        TEX_ISSUE:if(tex_ready)state_q<=TEX_WAIT;
        TEX_WAIT:if(tex_valid)begin
          // A missing weighted tap or bad response tag is a sticky fault.
          // Never consume zeros as valid data, retire or write dst on miss.
          if(tex_id!={4'd0,pc_q} || !tex_present)begin
            fault<=1;state_q<=FAILED;
          end else begin
            regs[dst]<=masked_tex;
            retired_count<=retired_count+5'd1;
            texture_retired_count<=texture_retired_count+5'd1;
            if(retired_count+5'd1==run_len_q)begin
              done<=1;state_q<=IDLE;
            end else begin
              instruction_q<=insn_ram[pc_q+4'd1];
              pc_q<=pc_q+4'd1;state_q<=DECODE;
            end
          end
        end
        FAILED:begin end
        default:begin fault<=1;state_q<=FAILED;end
      endcase
    end
  end
endmodule
