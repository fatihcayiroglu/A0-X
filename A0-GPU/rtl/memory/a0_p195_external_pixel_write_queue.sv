`timescale 1ns/1ps
// P195: small single-clock ordered pixel write queue for a FUTURE external
// memory controller. out_ready means the downstream port ACCEPTED the word,
// not that nonvolatile storage, DRAM, or a PCIe transaction completed.
// Word-addressed 48-bit {RGB888,depth24}; no DDR/PCIe pins or PHY here.
module a0_p195_external_pixel_write_queue #(
  parameter integer FRAME_WIDTH=256,
  parameter integer FRAME_HEIGHT=256,
  parameter logic [31:0] BASE_WORD_ADDR=32'd0
)(
  input logic clk,rst_n,
  input logic in_valid,
  output logic in_ready,
  input logic [15:0] in_x,in_y,
  input logic [47:0] in_pixel,
  output logic reject_valid,
  output logic out_valid,
  input logic out_ready,
  output logic [31:0] out_word_addr,
  output logic [47:0] out_pixel,
  output logic [1:0] queued_words
);
  localparam integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT;
  logic [31:0] word_addr0_q,word_addr1_q;
  logic [47:0] pixel0_q,pixel1_q;
  logic head_q,tail_q;
  logic [1:0] used_q;

  wire in_bounds=(in_x<FRAME_WIDTH && in_y<FRAME_HEIGHT);
  wire [31:0] linear_addr=32'(in_y)*32'(FRAME_WIDTH)+32'(in_x);
  wire [31:0] new_addr=BASE_WORD_ADDR+linear_addr;
  assign out_valid=rst_n && (used_q!=2'd0);
  assign out_word_addr=out_valid ? (head_q ? word_addr1_q : word_addr0_q) : 32'd0;
  assign out_pixel=out_valid ? (head_q ? pixel1_q : pixel0_q) : 48'd0;
  assign queued_words=used_q;
  wire pop=out_valid && out_ready;

  // Bad coordinates are consumed and explicitly rejected, even at full
  // occupancy. A simultaneous downstream pop permits a full-queue push.
  assign in_ready=rst_n && (!in_bounds || used_q<2 || pop);
  wire push=in_valid && in_ready && in_bounds;

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      head_q<=0;tail_q<=0;used_q<=0;
      reject_valid<=0;
      word_addr0_q<=0;word_addr1_q<=0;
      pixel0_q<=0;pixel1_q<=0;
    end else begin
      reject_valid<=in_valid && in_ready && !in_bounds;
      if(push) begin
        if(tail_q) begin
          word_addr1_q<=new_addr;pixel1_q<=in_pixel;
        end else begin
          word_addr0_q<=new_addr;pixel0_q<=in_pixel;
        end
        tail_q<=~tail_q;
      end
      if(pop) head_q<=~head_q;
      case({push,pop})
        2'b10: used_q<=used_q+2'd1;
        2'b01: used_q<=used_q-2'd1;
        default: used_q<=used_q;
      endcase
    end
  end

  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || PIXELS<2 ||
       PIXELS>65536 || FRAME_WIDTH>65536 || FRAME_HEIGHT>65536 ||
       BASE_WORD_ADDR > (32'hffff_ffff - (PIXELS-1)))
      $fatal(1,"P195 unsupported external write geometry or address overflow");
  end
endmodule
