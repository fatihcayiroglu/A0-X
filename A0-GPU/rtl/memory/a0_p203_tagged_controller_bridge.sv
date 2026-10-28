`timescale 1ns/1ps
// P203: synthesizable tagged, acknowledgement-precise controller boundary.
// A WRITE becomes upstream-ready only after the controller's matching
// COMMITTED write response. Read requests are accepted on req handshake,
// then returned separately. This is NOT a DDR/PCIe PHY or RAM.
module a0_p203_tagged_controller_bridge #(
  parameter integer FRAME_WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer BANK_INDEX=0,
  parameter integer TAG_BITS=32,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic bank_cmd_valid,bank_cmd_write,
  input logic [31:0] bank_cmd_word_addr,
  input logic [47:0] bank_cmd_pixel,
  output logic bank_cmd_ready,
  output logic bank_rsp_valid,bank_rsp_error,
  output logic [47:0] bank_rsp_pixel,
  output logic fault,busy,
  output logic ctrl_flush_req,
  input logic ctrl_flush_ack,
  output logic ctrl_req_valid,ctrl_req_write,
  output logic [31:0] ctrl_req_word_addr,
  output logic [47:0] ctrl_req_pixel,
  output logic [TAG_BITS-1:0] ctrl_req_id,
  input logic ctrl_req_ready,
  input logic ctrl_rsp_valid,ctrl_rsp_error,
  input logic [47:0] ctrl_rsp_pixel,
  input logic [TAG_BITS-1:0] ctrl_rsp_id,
  output logic ctrl_rsp_ready
);
  localparam logic [2:0] FLUSH=3'd0,IDLE=3'd1,
    WAIT_WRITE=3'd2,WAIT_READ=3'd3,FAILED=3'd4;
  localparam logic [31:0] BANK_BASE=
    BASE_WORD_ADDR+32'(FRAME_WORDS*BANK_INDEX);
  logic [2:0] state_q;
  logic fault_q,timeout_read_pulse_q;
  logic [TAG_BITS-1:0] next_tag_q,pending_tag_q;
  logic [31:0] age_q,write_addr_q;
  logic [47:0] write_pixel_q;
  wire in_bank=bank_cmd_word_addr>=BANK_BASE &&
    (bank_cmd_word_addr-BANK_BASE)<FRAME_WORDS;
  wire matching_rsp=ctrl_rsp_valid && ctrl_rsp_id==pending_tag_q;
  wire write_held=bank_cmd_valid && bank_cmd_write &&
    bank_cmd_word_addr==write_addr_q &&
    bank_cmd_pixel==write_pixel_q;
  wire request_fire=ctrl_req_valid && ctrl_req_ready;
  assign fault=fault_q;
  assign busy=state_q!=IDLE;
  assign ctrl_flush_req=rst_n && state_q==FLUSH && !fault_q;
  assign ctrl_req_valid=rst_n && state_q==IDLE && !fault_q &&
    bank_cmd_valid && in_bank && !ctrl_rsp_valid &&
    next_tag_q!={TAG_BITS{1'b1}};
  assign ctrl_req_write=bank_cmd_write;
  assign ctrl_req_word_addr=bank_cmd_word_addr;
  assign ctrl_req_pixel=bank_cmd_pixel;
  assign ctrl_req_id=next_tag_q;
  // Consume an unexpected or mismatched reply and latch a fault. Never
  // return it upstream under a different transaction or bank.
  assign ctrl_rsp_ready=rst_n && !fault_q && state_q!=FLUSH &&
    state_q!=FAILED;
  assign bank_cmd_ready=rst_n && !fault_q &&
    ((state_q==IDLE && request_fire && !bank_cmd_write) ||
     (state_q==WAIT_WRITE && matching_rsp && !ctrl_rsp_error &&
      write_held));
  assign bank_rsp_valid=timeout_read_pulse_q ||
    (rst_n && !fault_q && state_q==WAIT_READ && matching_rsp);
  assign bank_rsp_error=timeout_read_pulse_q ||
    (rst_n && !fault_q && state_q==WAIT_READ &&
      matching_rsp && ctrl_rsp_error);
  assign bank_rsp_pixel=timeout_read_pulse_q ? 48'd0 :
    (bank_rsp_valid ? ctrl_rsp_pixel : 48'd0);

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=FLUSH;fault_q<=0;timeout_read_pulse_q<=0;
      next_tag_q<=0;pending_tag_q<=0;age_q<=0;
      write_addr_q<=0;write_pixel_q<=0;
    end else begin
      timeout_read_pulse_q<=0;
      case(state_q)
        FLUSH:begin
          if(ctrl_flush_ack && !ctrl_rsp_valid)state_q<=IDLE;
        end
        IDLE:begin
          if(ctrl_rsp_valid || (bank_cmd_valid && !in_bank) ||
             (bank_cmd_valid && next_tag_q=={TAG_BITS{1'b1}}))begin
            fault_q<=1;state_q<=FAILED;
          end else if(request_fire)begin
            pending_tag_q<=next_tag_q;
            next_tag_q<=next_tag_q+{{(TAG_BITS-1){1'b0}},1'b1};
            age_q<=0;
            if(bank_cmd_write)begin
              write_addr_q<=bank_cmd_word_addr;
              write_pixel_q<=bank_cmd_pixel;
              state_q<=WAIT_WRITE;
            end else state_q<=WAIT_READ;
          end
        end
        WAIT_WRITE:begin
          if(!write_held || (ctrl_rsp_valid && !matching_rsp))begin
            fault_q<=1;state_q<=FAILED;
          end else if(matching_rsp)begin
            if(ctrl_rsp_error)begin fault_q<=1;state_q<=FAILED;end
            else state_q<=IDLE;
          end else if(age_q>=RESPONSE_TIMEOUT-1)begin
            fault_q<=1;state_q<=FAILED;
          end else age_q<=age_q+32'd1;
        end
        WAIT_READ:begin
          if(bank_cmd_valid || (ctrl_rsp_valid && !matching_rsp))begin
            fault_q<=1;state_q<=FAILED;
          end else if(matching_rsp)begin
            if(ctrl_rsp_error)begin fault_q<=1;state_q<=FAILED;end
            else state_q<=IDLE;
          end else if(age_q>=RESPONSE_TIMEOUT-1)begin
            timeout_read_pulse_q<=1;fault_q<=1;state_q<=FAILED;
          end else age_q<=age_q+32'd1;
        end
        FAILED:begin end
        default:begin fault_q<=1;state_q<=FAILED;end
      endcase
    end
  end
  initial begin
    if(FRAME_WORDS<2 || FRAME_WORDS>65536 ||
       (BANK_INDEX!=0 && BANK_INDEX!=1) ||
       BASE_WORD_ADDR>(32'hffff_ffff-(2*FRAME_WORDS-1)) ||
       TAG_BITS<2 || TAG_BITS>32 || RESPONSE_TIMEOUT<2)
      $fatal(1,"P203 unsupported tagged memory geometry");
  end
endmodule
