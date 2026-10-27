`timescale 1ns/1ps
// P196 SIMULATION-ONLY single-port external *word* memory model.
// No PHY, timing-calibrated DDR, PCIe, cache coherence, or AXI interface.
// Registered read responses are one-cycle pulses without backpressure.
// A reset cancels protocol responses but preserves previously written data.
module a0_p196_external_word_memory_model #(
  parameter integer WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000
)(
  input logic clk,rst_n,
  input logic allow_write,allow_read,
  input logic write_valid,
  output logic write_ready,
  input logic [31:0] write_word_addr,
  input logic [47:0] write_pixel,
  output logic write_fault,
  input logic read_valid,
  output logic read_ready,
  input logic [31:0] read_word_addr,
  output logic read_rsp_valid,read_rsp_error,
  output logic [47:0] read_rsp_pixel
);
  logic [47:0] words [0:WORDS-1];
  logic word_valid [0:WORDS-1];
  logic prefer_write_q;
  wire write_candidate=write_valid && allow_write;
  wire read_candidate=read_valid && allow_read;
  // Mutual exclusion plus alternating priority under contention.
  assign write_ready=rst_n && allow_write &&
    (!read_candidate || prefer_write_q);
  assign read_ready=rst_n && allow_read &&
    (!write_candidate || !prefer_write_q);
  wire do_write=write_valid && write_ready;
  wire do_read=read_valid && read_ready;

  wire write_in_range=write_word_addr>=BASE_WORD_ADDR &&
    (write_word_addr-BASE_WORD_ADDR)<WORDS;
  wire read_in_range=read_word_addr>=BASE_WORD_ADDR &&
    (read_word_addr-BASE_WORD_ADDR)<WORDS;
  wire [31:0] w_idx=write_word_addr-BASE_WORD_ADDR;
  wire [31:0] r_idx=read_word_addr-BASE_WORD_ADDR;

  integer i;
  initial begin
    if(WORDS<2 || WORDS>65536 ||
       BASE_WORD_ADDR > (32'hffff_ffff-(WORDS-1)))
      $fatal(1,"P196 model memory address overflow or bad geometry");
    for(i=0;i<WORDS;i=i+1)word_valid[i]=1'b0;
  end

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      prefer_write_q<=1;
      write_fault<=0;
      read_rsp_valid<=0;read_rsp_error<=0;read_rsp_pixel<=0;
    end else begin
      write_fault<=do_write && !write_in_range;
      read_rsp_valid<=do_read;
      read_rsp_error<=0;read_rsp_pixel<=0;
      if(do_write)begin
        prefer_write_q<=0;
        if(write_in_range)begin
          words[w_idx]<=write_pixel;
          word_valid[w_idx]<=1;
        end
      end else if(do_read)begin
        prefer_write_q<=1;
        read_rsp_error<=!read_in_range ||
          (read_in_range && !word_valid[r_idx]);
        if(read_in_range && word_valid[r_idx])
          read_rsp_pixel<=words[r_idx];
      end
    end
  end
endmodule
