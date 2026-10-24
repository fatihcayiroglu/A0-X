`timescale 1ns/1ps
// P151: bounded first SIMD UNORM shader *microprogram* sequencer.
// 8 x RGBA8888 vector registers and 16 x 24-bit instructions.
// Sequential dependencies obey committed register values; 1 ALU
// instruction in flight, no out-of-order hazards or speculative writes.
// Single clock, research only: NOT a GPU shader ISA, register scoreboard,
// raster integrated programmable fragment insn_ram, FP32 or PCIe card.
module a0_p151_unorm_microprogram #(
  parameter integer REG_COUNT=8,
  parameter integer INSN_COUNT=16
)(
  input logic clk,rst_n,
  input logic reg_write_valid,
  input logic [2:0] reg_write_index,
  input logic [31:0] reg_write_data,
  input logic [2:0] reg_read_index,
  output logic [31:0] reg_read_data,
  input logic insn_write_valid,
  input logic [3:0] insn_write_index,
  input logic [23:0] insn_write_data,
  input logic start,
  input logic [4:0] start_length,
  output logic ready,busy,done,fault,
  output logic [4:0] retired_count
);
  // Packed little-field instruction:
  // [2:0] srcB, [5:3] srcA, [8:6] dst, [11:9] opcode,
  // [15:12] mask, [23:16] alpha.
  logic [31:0] regs[0:REG_COUNT-1];
  logic [23:0] insn_ram[0:INSN_COUNT-1];
  logic [1:0] state_q;
  localparam logic [1:0] IDLE=2'd0,ISSUE=2'd1,WAIT=2'd2,FAILED=2'd3;
  logic [3:0] pc_q;
  logic [4:0] run_len_q;
  wire [23:0] instruction=insn_ram[pc_q];
  wire [2:0] src_b=instruction[2:0];
  wire [2:0] src_a=instruction[5:3];
  wire [2:0] dst=instruction[8:6];
  wire [2:0] op=instruction[11:9];
  wire [3:0] mask=instruction[15:12];
  wire [7:0] alpha=instruction[23:16];
  wire alu_ready,alu_valid;
  wire [7:0] alu_id;
  wire [31:0] alu_data;
  assign ready=rst_n && state_q==IDLE && !fault;
  assign busy=state_q==ISSUE || state_q==WAIT;
  assign reg_read_data=regs[reg_read_index];
  a0_p150_unorm_simd4_alu vector_unit(
    .clk(clk),.rst_n(rst_n),
    .req_valid(state_q==ISSUE),.req_ready(alu_ready),
    .req_id({4'd0,pc_q}),.opcode(op),
    .operand_a(regs[src_a]),.operand_b(regs[src_b]),
    .uniform_alpha(alpha),.lane_mask(mask),
    .rsp_valid(alu_valid),.rsp_ready(state_q==WAIT),
    .rsp_id(alu_id),.rsp_data(alu_data)
  );
  integer i;
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      state_q<=IDLE;pc_q<=0;run_len_q<=0;
      retired_count<=0;done<=0;fault<=0;
      for(i=0;i<REG_COUNT;i=i+1)regs[i]<=0;
      for(i=0;i<INSN_COUNT;i=i+1)insn_ram[i]<=0;
    end else begin
      done<=0;
      if(state_q==IDLE)begin
        // Configuration ports are accepted only while quiescent. A
        // simultaneous start and write is an explicit protocol fault.
        if(start && (insn_write_valid || reg_write_valid))begin
          state_q<=FAILED;fault<=1;
        end else if(start)begin
          if(start_length==0 || start_length>INSN_COUNT)begin
            state_q<=FAILED;fault<=1;
          end else begin
            run_len_q<=start_length;
            retired_count<=0;
            pc_q<=0;
            state_q<=ISSUE;
          end
        end else begin
          if(reg_write_valid)regs[reg_write_index]<=reg_write_data;
          if(insn_write_valid)insn_ram[insn_write_index]<=insn_write_data;
        end
      end else if(state_q==ISSUE)begin
        if(alu_ready)state_q<=WAIT;
      end else if(state_q==WAIT)begin
        if(alu_valid)begin
          if(alu_id!={4'd0,pc_q})begin
            state_q<=FAILED;fault<=1;
          end else begin
            // One instruction retires here: all dependent following
            // instructions observe this committed register result.
            regs[dst]<=alu_data;
            retired_count<=retired_count+5'd1;
            if(retired_count+5'd1==run_len_q)begin
              done<=1;
              state_q<=IDLE;
            end else begin
              pc_q<=pc_q+4'd1;
              state_q<=ISSUE;
            end
          end
        end
      end
    end
  end
  initial begin
    if(REG_COUNT!=8 || INSN_COUNT!=16)
      $fatal(1,"P151 microprogram research profile fixed to 8 regs/16 slots");
  end
endmodule
