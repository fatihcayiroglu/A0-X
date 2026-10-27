`timescale 1ns/1ps
// P197: synthesizable single-port word-command arbiter for the P195 FIFO.
// This is a protocol adapter, NOT a DRAM/PCIe controller or a VRAM PHY.
// Contract: a write completes at mem_cmd_valid && mem_cmd_ready. A read
// returns EXACTLY one mem_rsp_valid after its accepted command, with no
// unsolicited/stale responses. Reset must flush the external responder too.
// The adapter has one outstanding read, no response-ready/backpressure.
module a0_p197_external_word_port_arbiter #(
  parameter integer FRAME_WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000
)(
  input logic clk,rst_n,
  input logic write_valid,
  output logic write_ready,
  input logic [31:0] write_word_addr,
  input logic [47:0] write_pixel,
  output logic write_fault,
  input logic read_valid,
  output logic read_ready,
  input logic [31:0] read_word_addr,
  output logic read_rsp_valid,read_rsp_error,
  output logic [47:0] read_rsp_pixel,
  output logic mem_cmd_valid,
  input logic mem_cmd_ready,
  output logic mem_cmd_write,
  output logic [31:0] mem_cmd_word_addr,
  output logic [47:0] mem_cmd_pixel,
  input logic mem_rsp_valid,mem_rsp_error,
  input logic [47:0] mem_rsp_pixel,
  output logic read_pending,protocol_fault
);
  logic pending_q,failed_q,prefer_read_q;
  logic held_grant_q,held_write_q;
  wire write_in_range=(write_word_addr>=BASE_WORD_ADDR) &&
    ((write_word_addr-BASE_WORD_ADDR)<FRAME_WORDS);
  wire read_in_range=(read_word_addr>=BASE_WORD_ADDR) &&
    ((read_word_addr-BASE_WORD_ADDR)<FRAME_WORDS);
  // The chosen request remains selected through port stalls. Preference
  // changes only on acceptance; both contenders eventually make progress.
  wire choose_write=held_grant_q ? held_write_q :
    (write_valid && (!read_valid || !prefer_read_q));
  wire choose_read=held_grant_q ? !held_write_q :
    (read_valid && (!write_valid || prefer_read_q));
  wire can_issue=rst_n && !pending_q && !failed_q && !mem_rsp_valid;
  assign mem_cmd_valid=can_issue &&
    ((choose_write && write_in_range) || (choose_read && read_in_range));
  assign mem_cmd_write=can_issue && choose_write;
  assign mem_cmd_word_addr=mem_cmd_valid ?
    (choose_write ? write_word_addr : read_word_addr) : 32'd0;
  assign mem_cmd_pixel=(mem_cmd_valid && choose_write) ? write_pixel : 48'd0;
  assign write_ready=can_issue && choose_write &&
    (!write_in_range || mem_cmd_ready);
  assign read_ready=can_issue && choose_read &&
    (!read_in_range || mem_cmd_ready);
  wire accept_write=write_valid && write_ready;
  wire accept_read=read_valid && read_ready;
  assign read_pending=pending_q;
  assign protocol_fault=failed_q;

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      pending_q<=0;failed_q<=0;prefer_read_q<=0;
      held_grant_q<=0;held_write_q<=0;
      write_fault<=0;
      read_rsp_valid<=0;read_rsp_error<=0;read_rsp_pixel<=0;
    end else begin
      write_fault<=accept_write && !write_in_range;
      read_rsp_valid<=0;read_rsp_error<=0;read_rsp_pixel<=0;
      // Lock the arbitration winner throughout external backpressure.
      // Upstream request payload/valid must remain stable until ready.
      if(mem_cmd_valid && !mem_cmd_ready)begin
        held_grant_q<=1;
        held_write_q<=choose_write;
      end else if(mem_cmd_valid && mem_cmd_ready)begin
        held_grant_q<=0;
      end
      if(mem_rsp_valid && !pending_q)
        failed_q<=1;  // fail closed on unsolicited/late response
      if(pending_q && mem_rsp_valid)begin
        pending_q<=0;
        read_rsp_valid<=1;
        read_rsp_error<=mem_rsp_error;
        if(!mem_rsp_error) read_rsp_pixel<=mem_rsp_pixel;
      end
      if(accept_write)prefer_read_q<=1;
      if(accept_read)begin
        prefer_read_q<=0;
        if(!read_in_range)begin
          // Invalid host address is a registered error, never a bus command.
          read_rsp_valid<=1;read_rsp_error<=1;
        end else begin
          pending_q<=1;
        end
      end
    end
  end
  initial begin
    if(FRAME_WORDS<1 || FRAME_WORDS>65536 ||
       BASE_WORD_ADDR>(32'hffff_ffff-(FRAME_WORDS-1)))
      $fatal(1,"P197 unsupported memory address window");
  end
endmodule
