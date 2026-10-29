`timescale 1ns/1ps
// P232: experimental display-facing RGB888 adapter for the unchanged P226
// split-domain committed framebuffer raster. Input word is PACKED
// {RGB888[23:0], Z24[23:0]}, NOT RGB16.
// Outputs are pixel-clock-domain registered signals plus a combinational
// reset/fault/blanking mask. pixel_ce is an enable, NOT a pixel clock/PHY.
module a0_p232_rgb888_output(
  input  wire        raw_rst_n,
  input  wire        pixel_fault,
  input  wire        pixel_ce_in,
  input  wire        video_de_in,
  input  wire        video_hsync_in,
  input  wire        video_vsync_in,
  input  wire [47:0] video_pixel_in,
  output wire        pixel_ce,
  output wire        video_de,
  output wire        video_hsync,
  output wire        video_vsync,
  output wire [23:0] rgb888
);
  wire visible = raw_rst_n && !pixel_fault && video_de_in;
  assign rgb888 = visible ? video_pixel_in[47:24] : 24'd0;
  assign video_de = visible;
  assign pixel_ce = raw_rst_n && !pixel_fault && pixel_ce_in;
  assign video_hsync = (raw_rst_n && !pixel_fault) ? video_hsync_in : 1'b1;
  assign video_vsync = (raw_rst_n && !pixel_fault) ? video_vsync_in : 1'b1;
endmodule

// The same host bus, reset supervisor, async FIFO, EBR source and VBlank
// publication as P226. The only interface reduction is 48-bit packed
// RGB+depth -> 24-bit RGB; depth never appears on the external pixel pins.
// No PLL, real pixel clock output, EDID, board pin map, HDMI or DP PHY.
module a0_p232_domain_local_rgb888_raster #(
  parameter integer H_ACTIVE=32,V_ACTIVE=32,
  parameter integer H_FRONT=8,H_SYNC=4,H_BACK=8,
  parameter integer V_FRONT=2,V_SYNC=2,V_BACK=2,
  parameter integer PIXEL_DIV=64,FIFO_ADDR_BITS=6,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input  wire        host_clk,pixel_clk,rst_n,
  input  wire        host_valid,host_write,
  input  wire [5:0]  host_addr,
  input  wire [7:0]  host_wdata,
  output wire        host_ready,
  output wire [7:0]  host_rdata,
  output wire        host_fault,host_busy,pixel_fault,
  output wire        pixel_ce,video_de,video_hsync,video_vsync,
  output wire [23:0] rgb888
);
  wire src_ce,src_de,src_hsync,src_vsync,src_fault;
  wire [47:0] src_pixel;
  a0_p226_domain_local_reset_raster #(
    .H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),
    .H_FRONT(H_FRONT),.H_SYNC(H_SYNC),.H_BACK(H_BACK),
    .V_FRONT(V_FRONT),.V_SYNC(V_SYNC),.V_BACK(V_BACK),
    .PIXEL_DIV(PIXEL_DIV),.FIFO_ADDR_BITS(FIFO_ADDR_BITS),
    .BASE_WORD_ADDR(BASE_WORD_ADDR),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) core (
    .host_clk(host_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .host_fault(host_fault),.host_busy(host_busy),.pixel_fault(src_fault),
    .pixel_ce(src_ce),.video_de(src_de),
    .video_hsync(src_hsync),.video_vsync(src_vsync),
    .video_pixel(src_pixel)
  );
  assign pixel_fault=src_fault;
  a0_p232_rgb888_output output_adapter (
    .raw_rst_n(rst_n),.pixel_fault(src_fault),
    .pixel_ce_in(src_ce),.video_de_in(src_de),
    .video_hsync_in(src_hsync),.video_vsync_in(src_vsync),
    .video_pixel_in(src_pixel),
    .pixel_ce(pixel_ce),.video_de(video_de),
    .video_hsync(video_hsync),.video_vsync(video_vsync),
    .rgb888(rgb888)
  );
endmodule
