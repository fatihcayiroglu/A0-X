`timescale 1ns/1ps
// P202: bounded bank-port guard in front of an external memory controller.
// It has no RAM/PHY and cannot prove physical DDR timing. Exactly one
// read may be outstanding; accepted writes have no response in this protocol.
// Backend responses are untagged and must arrive no earlier than the cycle
// following read acceptance. A fault quarantines the bank until reset.
module a0_p202_bounded_bank_port_guard #(
  parameter integer FRAME_WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer BANK_INDEX=0,
  parameter integer CMD_STALL_LIMIT=1024,
  parameter integer READ_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic cmd_valid,cmd_write,
  input logic [31:0] cmd_word_addr,
  input logic [47:0] cmd_pixel,
  output logic cmd_ready,
  output logic rsp_valid,rsp_error,
  output logic [47:0] rsp_pixel,
  output logic fault,read_pending,
  output logic backend_cmd_valid,backend_cmd_write,
  output logic [31:0] backend_cmd_word_addr,
  output logic [47:0] backend_cmd_pixel,
  input logic backend_cmd_ready,
  input logic backend_rsp_valid,backend_rsp_error,
  input logic [47:0] backend_rsp_pixel
);
  localparam logic [31:0] BANK_BASE =
    BASE_WORD_ADDR + 32'(FRAME_WORDS*BANK_INDEX);
  wire in_bank=cmd_word_addr>=BANK_BASE &&
    (cmd_word_addr-BANK_BASE)<FRAME_WORDS;
  logic fault_q,pending_q,timeout_rsp_q;
  logic [31:0] stall_age_q,read_age_q;
  wire can_issue=rst_n && !fault_q && !pending_q &&
    !backend_rsp_valid && in_bank;
  assign backend_cmd_valid=cmd_valid && can_issue;
  assign backend_cmd_write=cmd_write;
  assign backend_cmd_word_addr=cmd_word_addr;
  assign backend_cmd_pixel=cmd_pixel;
  assign cmd_ready=can_issue && backend_cmd_ready;
  assign read_pending=pending_q;
  assign fault=fault_q;
  // Timeout response releases upstream P200/P199 leases, but carries
  // ERROR and makes this bank unusable until reset.
  assign rsp_valid=timeout_rsp_q ||
    (rst_n && !fault_q && pending_q && backend_rsp_valid);
  assign rsp_error=timeout_rsp_q ||
    (rst_n && !fault_q && pending_q &&
     backend_rsp_valid && backend_rsp_error);
  assign rsp_pixel=timeout_rsp_q ? 48'd0 :
    (rsp_valid ? backend_rsp_pixel : 48'd0);

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      fault_q<=0;pending_q<=0;timeout_rsp_q<=0;
      stall_age_q<=0;read_age_q<=0;
    end else begin
      timeout_rsp_q<=0;
      if(fault_q)begin
        stall_age_q<=0;
      end else if((cmd_valid && !in_bank) ||
                  (cmd_valid && pending_q) ||
                  (backend_rsp_valid && !pending_q))begin
        // Wrong physical bank, overlapping read, or unsolicited reply.
        fault_q<=1;
      end else begin
        if(cmd_valid && cmd_ready)begin
          stall_age_q<=0;
          if(!cmd_write)begin
            pending_q<=1;read_age_q<=0;
          end
        end else if(cmd_valid && !pending_q)begin
          if(stall_age_q>=CMD_STALL_LIMIT-1)fault_q<=1;
          else stall_age_q<=stall_age_q+32'd1;
        end else stall_age_q<=0;
        if(pending_q)begin
          if(backend_rsp_valid)begin
            pending_q<=0;read_age_q<=0;
            if(backend_rsp_error)fault_q<=1;
          end else if(read_age_q>=READ_TIMEOUT-1)begin
            pending_q<=0;read_age_q<=0;
            timeout_rsp_q<=1;fault_q<=1;
          end else read_age_q<=read_age_q+32'd1;
        end
      end
    end
  end
  initial begin
    if(FRAME_WORDS<2 || FRAME_WORDS>65536 ||
       (BANK_INDEX!=0 && BANK_INDEX!=1) ||
       CMD_STALL_LIMIT<2 || READ_TIMEOUT<2 ||
       BASE_WORD_ADDR>(32'hffff_ffff-(2*FRAME_WORDS-1)))
      $fatal(1,"P202 invalid bank/timeout geometry");
  end
endmodule
