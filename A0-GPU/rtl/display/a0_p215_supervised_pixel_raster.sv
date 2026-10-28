`timescale 1ns/1ps
// P215: external reset can pulse between host and pixel clock edges.
// Its asynchronous assertion immediately clears two local release pipelines.
// The shared fabric reset stays asserted until BOTH independent domains have
// observed at least two rising clock edges after external reset releases.
// This is a reset-assertion/release contract, not a CDC MTBF signoff or PLL.
module a0_p215_dual_clock_reset_supervisor(
  input logic host_clk,pixel_clk,raw_rst_n,
  output logic fabric_rst_n
);
  (* async_reg = "true" *) logic [1:0] host_release_q;
  (* async_reg = "true" *) logic [1:0] pixel_release_q;
  always_ff @(posedge host_clk or negedge raw_rst_n)begin
    if(!raw_rst_n)host_release_q<=2'b00;
    else host_release_q<={host_release_q[0],1'b1};
  end
  always_ff @(posedge pixel_clk or negedge raw_rst_n)begin
    if(!raw_rst_n)pixel_release_q<=2'b00;
    else pixel_release_q<={pixel_release_q[0],1'b1};
  end
  assign fabric_rst_n=raw_rst_n && host_release_q[1] &&
      pixel_release_q[1];
endmodule

// Retain all P214 physical EBR/Gray FIFO logic unchanged. The stretched,
// dual-clock-qualified fabric reset is shared by the existing source and
// sink, including the asynchronous FIFO and the two full EBR scrub walks.
module a0_p215_supervised_pixel_raster #(
  parameter integer H_ACTIVE=32,V_ACTIVE=32,
  parameter integer H_FRONT=8,H_SYNC=4,H_BACK=8,
  parameter integer V_FRONT=2,V_SYNC=2,V_BACK=2,
  parameter integer PIXEL_DIV=64,FIFO_ADDR_BITS=6,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic host_clk,pixel_clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic host_fault,host_busy,pixel_fault,
  output logic pixel_ce,video_de,video_hsync,video_vsync,
  output logic [47:0] video_pixel
);
  wire fabric_rst_n;
  a0_p215_dual_clock_reset_supervisor reset_guard(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .raw_rst_n(rst_n),.fabric_rst_n(fabric_rst_n)
  );
  a0_p213_atomic_pixel_raster #(
    .H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),
    .H_FRONT(H_FRONT),.H_SYNC(H_SYNC),.H_BACK(H_BACK),
    .V_FRONT(V_FRONT),.V_SYNC(V_SYNC),.V_BACK(V_BACK),
    .PIXEL_DIV(PIXEL_DIV),.FIFO_ADDR_BITS(FIFO_ADDR_BITS),
    .BASE_WORD_ADDR(BASE_WORD_ADDR),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) raster(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.rst_n(fabric_rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .host_fault(host_fault),.host_busy(host_busy),
    .pixel_fault(pixel_fault),.pixel_ce(pixel_ce),
    .video_de(video_de),.video_hsync(video_hsync),
    .video_vsync(video_vsync),.video_pixel(video_pixel)
  );
endmodule
