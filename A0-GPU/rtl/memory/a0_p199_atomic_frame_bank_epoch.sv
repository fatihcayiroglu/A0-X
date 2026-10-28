`timescale 1ns/1ps
// P199: synthesizeable double-bank framebuffer publication/EPOCH contract.
// Maps an existing *logical* P195/P197 word stream to a staging bank; only
// publishes that bank after FRAME_WORDS sequential committed writes and
// after any old-bank reader has completed. Does NOT implement DRAM, a memory
// array, a physical mux, or render-time RMW integration.
module a0_p199_atomic_frame_bank_epoch #(
  parameter integer FRAME_WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000
)(
  input logic clk,rst_n,
  input logic stage_begin,stage_seal,
  input logic write_commit,
  input logic [31:0] write_word_addr,
  input logic read_accept,read_complete,
  output logic stage_bank,active_bank,
  output logic active_valid,stage_active,
  output logic write_permitted,read_permitted,
  output logic read_leased,seal_pending,
  output logic publish_pulse,fault,
  output logic [31:0] committed_words,published_epochs
);
  logic active_bank_q,active_valid_q,stage_q,seal_q,lease_q;
  logic [31:0] count_q,epoch_q;
  logic fault_q;
  assign active_bank=active_bank_q;
  assign stage_bank=~active_bank_q;
  assign active_valid=active_valid_q;
  assign stage_active=stage_q;
  assign read_leased=lease_q;
  assign seal_pending=seal_q;
  assign committed_words=count_q;
  assign published_epochs=epoch_q;
  assign fault=fault_q;
  assign write_permitted=rst_n && !fault_q && stage_q && !seal_q;
  assign read_permitted=rst_n && !fault_q && active_valid_q &&
     !seal_q && !lease_q;
  wire good_write_addr=write_word_addr>=BASE_WORD_ADDR &&
    (write_word_addr-BASE_WORD_ADDR)==count_q;

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      active_bank_q<=0;active_valid_q<=0;stage_q<=0;
      seal_q<=0;lease_q<=0;count_q<=0;epoch_q<=0;
      fault_q<=0;publish_pulse<=0;
    end else begin
      publish_pulse<=0;
      if(stage_begin)begin
        if(stage_q || seal_q || fault_q || write_commit)
          fault_q<=1;
        else begin stage_q<=1;count_q<=0;end
      end
      if(write_commit)begin
        if(!write_permitted || count_q>=FRAME_WORDS || !good_write_addr)
          fault_q<=1;
        else count_q<=count_q+32'd1;
      end
      if(read_accept)begin
        if(!read_permitted)fault_q<=1;
        else lease_q<=1;
      end
      if(read_complete)begin
        if(!lease_q)fault_q<=1;
        else lease_q<=0;
      end
      if(stage_seal)begin
        if(!stage_q || seal_q || fault_q ||
           count_q!=FRAME_WORDS || write_commit)
          fault_q<=1;
        else seal_q<=1;
      end
      // No reader can cross a bank flip. A read that accepted before the
      // seal remains assigned to the old active bank until its response.
      if(seal_q && !lease_q && !read_accept && !fault_q &&
         !stage_begin && !stage_seal && !write_commit && !read_complete)begin
        active_bank_q<=~active_bank_q;
        active_valid_q<=1;stage_q<=0;seal_q<=0;
        epoch_q<=epoch_q+32'd1;publish_pulse<=1;
      end
    end
  end
  initial begin
    if(FRAME_WORDS<2 || FRAME_WORDS>65536 ||
       BASE_WORD_ADDR>(32'hffff_ffff-(FRAME_WORDS-1)))
      $fatal(1,"P199 unsupported double-bank word geometry");
  end
endmodule
