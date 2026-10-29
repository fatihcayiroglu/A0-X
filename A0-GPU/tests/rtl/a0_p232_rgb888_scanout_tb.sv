`timescale 1ns/1ps
// P232 unit test: complete 48-bit words distinguish RGB24 from hidden Z24.
// No pixel clock/PLL or HDMI/DP encoding is implied.
module a0_p232_rgb888_output_unit_tb;
  logic rst=0, fault=0, ce_in=0, de_in=0,hs_in=1,vs_in=1;
  logic [47:0] word_in=0;
  wire ce,de,hs,vs; wire [23:0] rgb;
  a0_p232_rgb888_output dut(
    .raw_rst_n(rst),.pixel_fault(fault),.pixel_ce_in(ce_in),
    .video_de_in(de_in),.video_hsync_in(hs_in),
    .video_vsync_in(vs_in),.video_pixel_in(word_in),
    .pixel_ce(ce),.video_de(de),.video_hsync(hs),
    .video_vsync(vs),.rgb888(rgb)
  );
  task automatic require(input logic [23:0] exp_rgb,
    input logic exp_ce,exp_de,exp_hs,exp_vs);
    #1;
    if(rgb!==exp_rgb || ce!==exp_ce || de!==exp_de ||
       hs!==exp_hs || vs!==exp_vs)
      $fatal(1,"P232 bad color/sync rgb=%h ce=%b de=%b hs=%b vs=%b expected=%h/%b/%b/%b/%b",
        rgb,ce,de,hs,vs,exp_rgb,exp_ce,exp_de,exp_hs,exp_vs);
  endtask
  initial begin
    word_in=48'hA1B2C3FEDCBA;ce_in=1;de_in=1;hs_in=0;vs_in=0;
    require(24'd0,0,0,1,1);              // raw asynchronous reset
    rst=1;require(24'hA1B2C3,1,1,0,0); // RGB, no depth bits
    word_in=48'hA1B2C3000000;require(24'hA1B2C3,1,1,0,0);
    word_in=48'hA1B2C3FFFFFF;require(24'hA1B2C3,1,1,0,0);
    de_in=0;require(24'd0,1,0,0,0);   // blanking must be black
    de_in=1;ce_in=0;require(24'hA1B2C3,0,1,0,0); // CE is a strobe
    ce_in=1;fault=1;require(24'd0,0,0,1,1);
    fault=0;require(24'hA1B2C3,1,1,0,0);
    rst=0;require(24'd0,0,0,1,1);
    $display("P232_RGB888_UNIT_PASS depth_discard=1 reset_blank=1 fault_blank=1 de_blank=1 ce_strobe=1 sync_idle_high=1");
    $finish;
  end
endmodule

// Reuse P231's strict full-frame real committed EBR/CDC/VBlank stimulus.
// A second, independent P232 full hardware wrapper receives the *same*
// host and clock transactions, and is compared at every observed pixel
// clock edge against the P226 source that P231 checks pixel-by-pixel.
// CI requires BOTH the P231 and P232 full-frame PASS messages.
module a0_p232_full_rgb888_raster_tb #(
  parameter integer DIV=3,MODE=0
);
  a0_p231_divider_boundary_raster_tb #(
    .WORDS(8),.MODE(MODE),.DIV(DIV)
  ) source_tb();
  wire host_ready,host_fault,host_busy,pixel_fault;
  wire [7:0] host_rdata;
  wire ce,de,hs,vs;wire [23:0] rgb;
  a0_p232_domain_local_rgb888_raster #(
    .H_ACTIVE(4),.V_ACTIVE(2),
    .H_FRONT(8),.H_SYNC(4),.H_BACK(8),
    .V_FRONT(2),.V_SYNC(2),.V_BACK(2),
    .PIXEL_DIV(DIV),.FIFO_ADDR_BITS(6),.RESPONSE_TIMEOUT(256)
  ) dut (
    .host_clk(source_tb.host_clk),.pixel_clk(source_tb.pixel_clk),
    .rst_n(source_tb.rst_n),
    .host_valid(source_tb.host_valid),.host_write(source_tb.host_write),
    .host_addr(source_tb.host_addr),.host_wdata(source_tb.host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .host_fault(host_fault),.host_busy(host_busy),
    .pixel_fault(pixel_fault),
    .pixel_ce(ce),.video_de(de),.video_hsync(hs),
    .video_vsync(vs),.rgb888(rgb)
  );
  integer epoch1_active=0,epoch2_active=0,blank_pixels=0;
  integer depth_only_changes=0;
  logic [23:0] prev_color=0,prev_depth=0;
  logic checked_once=0;
  // The P231 source_tb itself checks every 48-bit pixel and both full
  // rasters; compare the color-only *actual full wrapper* on every edge.
  always @(negedge source_tb.pixel_clk) begin
    #1;
    if(host_ready!==source_tb.host_ready ||
       host_rdata!==source_tb.host_rdata ||
       host_fault!==source_tb.host_fault ||
       host_busy!==source_tb.host_busy ||
       pixel_fault!==source_tb.pixel_fault)
      $fatal(1,"P232 host/CDC/fault wrapper diverged from unchanged P226");
    if(ce!==(source_tb.rst_n && !source_tb.pixel_fault && source_tb.pixel_ce) ||
       de!==(source_tb.rst_n && !source_tb.pixel_fault && source_tb.video_de) ||
       hs!==((source_tb.rst_n && !source_tb.pixel_fault) ? source_tb.video_hsync : 1'b1) ||
       vs!==((source_tb.rst_n && !source_tb.pixel_fault) ? source_tb.video_vsync : 1'b1))
      $fatal(1,"P232 sync/CE/DE wrapper contract mismatch div=%0d mode=%0d",DIV,MODE);
    if(rgb!==((source_tb.rst_n && !source_tb.pixel_fault && source_tb.video_de)
            ? source_tb.video_pixel[47:24] : 24'd0))
      $fatal(1,"P232 RGB888/depth isolation mismatch div=%0d mode=%0d got=%h expected=%h",
        DIV,MODE,rgb,source_tb.video_pixel[47:24]);
    if(de) begin
      if(source_tb.dut.raster.front_epoch_q==32'd1)
        epoch1_active=epoch1_active+1;
      if(source_tb.dut.raster.front_epoch_q==32'd2)
        epoch2_active=epoch2_active+1;
      if(rgb==prev_color && source_tb.video_pixel[23:0]!=prev_depth)
        depth_only_changes=depth_only_changes+1;
      prev_color=rgb;
      prev_depth=source_tb.video_pixel[23:0];
    end else if(rgb===24'd0) blank_pixels=blank_pixels+1;
    if(!checked_once && epoch1_active>=8 && epoch2_active>=8 &&
       blank_pixels>=24) begin
      checked_once=1;
      $display("P232_RGB888_FULL_RASTER_PASS div=%0d mode=%0d epoch1_active=%0d epoch2_active=%0d blank=%0d depth_exposed=0 reset_mask=1 sync_equal=1",
        DIV,MODE,epoch1_active,epoch2_active,blank_pixels);
    end
  end
  // Check the short reset pulse while clocks may be stopped. P231 performs
  // the same 2 ns reset and asserts that stale P226 pixels are erased.
  integer asynchronous_clears=0;
  always @(negedge source_tb.rst_n) begin
    #1;
    if(rgb!==24'd0 || de!==1'b0 || ce!==1'b0 ||
       hs!==1'b1 || vs!==1'b1)
      $fatal(1,"P232 asynchronous reset leaked RGB or sync during stopped clocks");
    asynchronous_clears=asynchronous_clears+1;
  end
endmodule
