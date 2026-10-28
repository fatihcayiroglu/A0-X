`timescale 1ns/1ps
// P212 independent-clock, power-of-two ready/valid FIFO.
// CDC: Gray-coded read/write pointers, *two clocked sync flops per direction*.
// Shared reset assertion must reach both domains; each release is held two
// local clocks. BRAM payload is never read across domains without a pointer
// handshake. A prefetched output register remains stable under backpressure.
// This is a simulation/FPGA implementation, NOT a proof of metastability MTBF.
module a0_p212_gray_async_fifo #(
  parameter integer WIDTH=92,
  parameter integer ADDR_BITS=6
)(
  input logic wr_clk,rd_clk,rst_n,
  input logic wr_valid,
  output logic wr_ready,
  input logic [WIDTH-1:0] wr_data,
  output logic rd_valid,
  input logic rd_ready,
  output logic [WIDTH-1:0] rd_data
);
  localparam integer DEPTH=(1<<ADDR_BITS);
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR_BITS:0] wbin_q=0,wgray_q=0,rbin_q=0,rgray_q=0;
  (* async_reg = "true" *) logic [ADDR_BITS:0] w_rgray_meta_q=0,w_rgray_sync_q=0;
  (* async_reg = "true" *) logic [ADDR_BITS:0] r_wgray_meta_q=0,r_wgray_sync_q=0;
  (* async_reg = "true" *) logic w_release_meta_q=0,w_release_q=0;
  (* async_reg = "true" *) logic r_release_meta_q=0,r_release_q=0;
  logic rd_valid_q;
  logic [WIDTH-1:0] rd_data_q;
  function automatic [ADDR_BITS:0] gray(input logic [ADDR_BITS:0] binary);
    gray=(binary>>1)^binary;
  endfunction
  wire [ADDR_BITS:0] wbin_next=wbin_q+1'b1;
  wire [ADDR_BITS:0] wgray_next=gray(wbin_next);
  wire full=(wgray_q==
      {~w_rgray_sync_q[ADDR_BITS:ADDR_BITS-1],
        w_rgray_sync_q[ADDR_BITS-2:0]});
  wire empty=(rgray_q==r_wgray_sync_q);
  wire write_fire=wr_valid && wr_ready;
  wire prefetch=r_release_q && !rd_valid_q && !empty;
  assign wr_ready=rst_n && w_release_q && !full;
  assign rd_valid=rst_n && r_release_q && rd_valid_q;
  assign rd_data=rd_valid ? rd_data_q : '0;
  always_ff @(posedge wr_clk or negedge rst_n)begin
    if(!rst_n)begin
      wbin_q<=0;wgray_q<=0;
      w_rgray_meta_q<=0;w_rgray_sync_q<=0;
      w_release_meta_q<=0;w_release_q<=0;
    end else begin
      w_release_meta_q<=1;
      w_release_q<=w_release_meta_q;
      w_rgray_meta_q<=rgray_q;
      w_rgray_sync_q<=w_rgray_meta_q;
      if(write_fire)begin wbin_q<=wbin_next;wgray_q<=wgray_next;end
    end
  end
  always_ff @(posedge wr_clk)if(write_fire)
    mem[wbin_q[ADDR_BITS-1:0]]<=wr_data;
  always_ff @(posedge rd_clk or negedge rst_n)begin
    if(!rst_n)begin
      rbin_q<=0;rgray_q<=0;rd_valid_q<=0;
      r_wgray_meta_q<=0;r_wgray_sync_q<=0;
      r_release_meta_q<=0;r_release_q<=0;
    end else begin
      r_release_meta_q<=1;
      r_release_q<=r_release_meta_q;
      r_wgray_meta_q<=wgray_q;
      r_wgray_sync_q<=r_wgray_meta_q;
      if(prefetch)begin
        rbin_q<=rbin_q+1'b1;
        rgray_q<=gray(rbin_q+1'b1);
        rd_valid_q<=1;
      end else if(rd_valid_q && rd_ready)rd_valid_q<=0;
    end
  end
  // Registered read enables inference of real dual-clock block RAM.
  always_ff @(posedge rd_clk)if(prefetch)
    rd_data_q<=mem[rbin_q[ADDR_BITS-1:0]];
  initial begin
    if(WIDTH<1 || ADDR_BITS<2 || ADDR_BITS>10)
      $fatal(1,"P212 unsupported asynchronous FIFO dimensions");
  end
endmodule
