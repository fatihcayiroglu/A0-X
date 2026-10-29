\`timescale 1ns/1ps
// P236: independent host-clock *tile upload* to the P235 pixel-clock-local
// dual-bank EBR renderer. Reuses the P226 Gray-pointer, double-synchronized
// asynchronous FIFO (no combinational cross-domain data/control).
// 768 ordered RGB888 words plus a COMMIT marker comprise one host frame.
// The old front bank is never written. FIFO backpressure is lossless.
// Clock-lock loss and raw reset assert an asynchronous *shared* reset;
// deassertion is locally qualified by the P226 per-domain supervisor.
// This is not PCIe, full-resolution VRAM, DMA, EDID or a display PHY.
module a0_p236_async_host_tile_top #(
  parameter integer MODE=0,
  parameter integer FIFO_ADDR_BITS=4
)(
  input wire host_clk,pixel_clk,raw_rst_n,clock_locked,
  input wire src_valid,src_commit,
  input wire [9:0] src_index,
  input wire [23:0] src_rgb,
  output wire src_ready,
  output wire host_protocol_fault,
  output wire pixel_load_fault,
  output wire [23:0] rgb888,
  output wire video_de,video_hsync,video_vsync
);
  wire reset_all_n=raw_rst_n && clock_locked;
  wire host_rst_n,pixel_rst_n,unused_both_released;
  a0_p226_split_reset_supervisor reset_guard(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .raw_rst_n(reset_all_n),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .both_released(unused_both_released)
  );
  // Commit MUST follow exactly 768 accepted host-indexed words. The FIFO
  // carries that marker in-order *after* all 768 words, never bypassing
  // the last physical EBR write. A host error latches until full reset.
  logic [9:0] host_count_q=0;
  logic host_fault_q=0;
  wire fifo_wr_ready,fifo_rd_valid,fifo_rd_ready;
  wire [34:0] fifo_rd_data;
  wire invalid_packet=src_commit ? (host_count_q!=10'd768) :
                       (host_count_q==10'd768 || src_index!=host_count_q);
  assign host_protocol_fault=host_fault_q;
  assign src_ready=host_rst_n && !host_fault_q && fifo_wr_ready;
  wire src_fire=src_valid && src_ready;
  // Invalid host packet is *accepted as an error* but never enters FIFO.
  wire fifo_wr_valid=src_fire && !invalid_packet;
  a0_p226_split_reset_fifo #(.WIDTH(35),.ADDR_BITS(FIFO_ADDR_BITS))
  queue(
    .wr_clk(host_clk),.rd_clk(pixel_clk),
    .wr_rst_n(host_rst_n),.rd_rst_n(pixel_rst_n),
    .wr_valid(fifo_wr_valid),.wr_ready(fifo_wr_ready),
    .wr_data({src_commit,src_index,src_rgb}),
    .rd_valid(fifo_rd_valid),.rd_ready(fifo_rd_ready),
    .rd_data(fifo_rd_data)
  );
  always_ff @(posedge host_clk or negedge reset_all_n) begin
    if(!reset_all_n)begin host_count_q<=0;host_fault_q<=0;end
    else if(!host_rst_n)begin host_count_q<=0;host_fault_q<=0;end
    else if(src_fire)begin
      if(invalid_packet)host_fault_q<=1;
      else if(src_commit)host_count_q<=0;
      else host_count_q<=host_count_q+10'd1;
    end
  end

  wire core_load_ready,core_commit_ready;
  wire fifo_commit=fifo_rd_data[34];
  wire bridge_live=pixel_rst_n && !host_fault_q && !pixel_load_fault;
  // The pixel-domain P235 sink accepts an indexed word only at ready.
  // Its stage_valid backpressures the FIFO until the next frame boundary.
  // This prevents overwriting a full pending bank while scanout continues.
  wire load_valid=fifo_rd_valid && bridge_live && !fifo_commit;
  wire commit_valid=fifo_rd_valid && bridge_live && fifo_commit;
  assign fifo_rd_ready=bridge_live &&
                      (fifo_commit ? core_commit_ready : core_load_ready);
  a0_p235_scaled_bram_rgb #(.MODE(MODE)) scanout(
    .pixel_clk(pixel_clk),.raw_rst_n(raw_rst_n),
    .clock_locked(clock_locked),
    .load_valid(load_valid),
    .load_index(fifo_rd_data[33:24]),
    .load_rgb(fifo_rd_data[23:0]),
    .load_ready(core_load_ready),
    .commit_valid(commit_valid),.commit_ready(core_commit_ready),
    .load_fault(pixel_load_fault),
    .rgb888(rgb888),.video_de(video_de),
    .video_hsync(video_hsync),.video_vsync(video_vsync)
  );
  initial begin
    if(MODE!=0 && MODE!=1 || FIFO_ADDR_BITS<2 || FIFO_ADDR_BITS>10)
      $fatal(1,"P236 unsupported mode or CDC FIFO depth");
  end
endmodule
