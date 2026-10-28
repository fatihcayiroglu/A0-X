`timescale 1ns/1ps
// P206: hardware-inferred single-port FPGA block RAM behind the complete
// P205 byte mailbox and the P203 tagged commit-ack bridge.
// No simulation-only RAM, external memory PHY, board pins or other clock domain.
module a0_p206_committed_bram_top #(
  parameter integer WORDS=1024,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy
);
  localparam integer AW=$clog2(WORDS);
  localparam [3:0] SCRUB=0,FLUSH_POLL=1,FLUSH_ACK=2,
    WAIT_REQ=3,GET_OP=4,GET_ADDR=5,GET_PIXEL=6,GET_TAG=7,
    MEM_EXEC=8,SET_ERROR=9,SET_TAG=10,SET_PIXEL=11,
    SEND_ACK=12,DRAIN=13,FAILED=14;
  logic [3:0] state_q;
  logic [AW-1:0] scrub_index_q;
  logic [2:0] byte_index_q;
  logic req_write_q,rsp_error_q;
  logic [31:0] req_addr_q,req_id_q;
  logic [47:0] req_pixel_q,rsp_pixel_q;
  logic ctrl_valid,ctrl_write,ctrl_ready;
  logic [5:0] ctrl_addr;
  logic [7:0] ctrl_wdata;
  wire [7:0] ctrl_rdata;
  wire bridge_fault,bridge_busy;
  wire [31:0] offset=req_addr_q-BASE_WORD_ADDR;
  wire address_ok=req_addr_q>=BASE_WORD_ADDR && offset<WORDS;
  wire [AW-1:0] ram_index=offset[AW-1:0];

  // A synchronous read and single write port permit real ECP5 EBR inference.
  // Reset *scrubs* every word before acknowledging the P203 flush barrier.
  (* ram_style="block" *) logic [47:0] ram [0:WORDS-1];
  // Exactly one synchronous write port: reset scrub and committed writes
  // share the same EBR address/data/enable signals.
  wire ram_we=rst_n && (state_q==SCRUB ||
      (state_q==MEM_EXEC && address_ok && req_write_q));
  wire [AW-1:0] ram_waddr=state_q==SCRUB ? scrub_index_q : ram_index;
  wire [47:0] ram_wdata=state_q==SCRUB ? 48'd0 : req_pixel_q;
  always_ff @(posedge clk)
    if(ram_we)ram[ram_waddr]<=ram_wdata;

  a0_p205_narrow_p203_mailbox #(
    .FRAME_WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .BANK_INDEX(0),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) mailbox(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .ctrl_valid(ctrl_valid),.ctrl_write(ctrl_write),
    .ctrl_addr(ctrl_addr),.ctrl_wdata(ctrl_wdata),
    .ctrl_ready(ctrl_ready),.ctrl_rdata(ctrl_rdata),
    .fault(bridge_fault),.busy(bridge_busy)
  );
  assign fault=bridge_fault || state_q==FAILED;
  assign busy=bridge_busy || state_q==SCRUB || state_q==FLUSH_POLL ||
    state_q==FLUSH_ACK;

  always_comb begin
    ctrl_valid=0;ctrl_write=0;ctrl_addr=6'h01;ctrl_wdata=0;
    case(state_q)
      FLUSH_ACK:begin ctrl_valid=1;ctrl_write=1;
        ctrl_addr=6'h00;ctrl_wdata=8'h01;end
      GET_OP:ctrl_addr=6'h02;
      GET_ADDR:ctrl_addr=6'h04+{3'd0,byte_index_q};
      GET_PIXEL:ctrl_addr=6'h08+{3'd0,byte_index_q};
      GET_TAG:ctrl_addr=6'h10+{3'd0,byte_index_q};
      SET_ERROR:begin ctrl_valid=1;ctrl_write=1;
        ctrl_addr=6'h14;ctrl_wdata={7'd0,rsp_error_q};end
      SET_TAG:begin ctrl_valid=1;ctrl_write=1;
        ctrl_addr=6'h18+{3'd0,byte_index_q};
        ctrl_wdata=req_id_q[byte_index_q*8+:8];end
      SET_PIXEL:begin ctrl_valid=1;ctrl_write=1;
        ctrl_addr=6'h20+{3'd0,byte_index_q};
        ctrl_wdata=rsp_pixel_q[byte_index_q*8+:8];end
      SEND_ACK:begin ctrl_valid=1;ctrl_write=1;
        ctrl_addr=6'h00;ctrl_wdata=8'h02;end
      default:begin end
    endcase
  end

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=SCRUB;byte_index_q<=0;
      scrub_index_q<=0;req_write_q<=0;rsp_error_q<=0;
      req_addr_q<=0;req_id_q<=0;req_pixel_q<=0;rsp_pixel_q<=0;
    end else begin
      case(state_q)
        SCRUB:begin
          if(scrub_index_q==WORDS-1)state_q<=FLUSH_POLL;
          else scrub_index_q<=scrub_index_q+1'b1;
        end
        FLUSH_POLL:if(ctrl_rdata[0])state_q<=FLUSH_ACK;
        FLUSH_ACK:if(ctrl_ready)state_q<=WAIT_REQ;
        WAIT_REQ:begin
          if(bridge_fault)state_q<=FAILED;
          else if(ctrl_rdata[1])state_q<=GET_OP;
        end
        GET_OP:begin req_write_q<=ctrl_rdata[0];
          byte_index_q<=0;req_addr_q<=0;req_pixel_q<=0;
          req_id_q<=0;state_q<=GET_ADDR;end
        GET_ADDR:begin
          req_addr_q[byte_index_q*8+:8]<=ctrl_rdata;
          if(byte_index_q==3)begin byte_index_q<=0;state_q<=GET_PIXEL;end
          else byte_index_q<=byte_index_q+1'b1;
        end
        GET_PIXEL:begin
          req_pixel_q[byte_index_q*8+:8]<=ctrl_rdata;
          if(byte_index_q==5)begin byte_index_q<=0;state_q<=GET_TAG;end
          else byte_index_q<=byte_index_q+1'b1;
        end
        GET_TAG:begin
          req_id_q[byte_index_q*8+:8]<=ctrl_rdata;
          if(byte_index_q==3)begin byte_index_q<=0;state_q<=MEM_EXEC;end
          else byte_index_q<=byte_index_q+1'b1;
        end
        MEM_EXEC:begin
          rsp_error_q<=!address_ok;
          rsp_pixel_q<=0;
          if(address_ok)begin
            if(!req_write_q)rsp_pixel_q<=ram[ram_index];
          end
          state_q<=SET_ERROR;
        end
        SET_ERROR:if(ctrl_ready)begin byte_index_q<=0;state_q<=SET_TAG;end
        SET_TAG:if(ctrl_ready)begin
          if(byte_index_q==3)begin
            byte_index_q<=0;
            if(req_write_q)state_q<=SEND_ACK;
            else state_q<=SET_PIXEL;
          end else byte_index_q<=byte_index_q+1'b1;
        end
        SET_PIXEL:if(ctrl_ready)begin
          if(byte_index_q==5)begin byte_index_q<=0;state_q<=SEND_ACK;end
          else byte_index_q<=byte_index_q+1'b1;
        end
        SEND_ACK:if(ctrl_ready)state_q<=DRAIN;
        DRAIN:begin
          if(bridge_fault)state_q<=FAILED;
          else if(!ctrl_rdata[1] && !ctrl_rdata[2])state_q<=WAIT_REQ;
        end
        FAILED:begin end
        default:state_q<=FAILED;
      endcase
    end
  end

  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       BASE_WORD_ADDR>32'hffff_ffff-WORDS ||
       RESPONSE_TIMEOUT<64)
      $fatal(1,"P206 unsupported onchip BRAM geometry");
  end
endmodule
