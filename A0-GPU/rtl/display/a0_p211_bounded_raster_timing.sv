`timescale 1ns/1ps
// P211: fixed raster coordinates, blanking and active-low sync on one clock.
// pixel_ce is a *clock enable*, NOT an independent pixel clock or HDMI PHY.
// A missing/misordered physical P210 EBR pixel at an active raster slot
// latches underflow, blanks all subsequent pixels until reset, and never
// advances the P210 ready/valid source on a corrupt sample.
module a0_p211_bounded_raster_timing #(
  parameter integer H_ACTIVE=32,
  parameter integer V_ACTIVE=32,
  parameter integer H_FRONT=8,
  parameter integer H_SYNC=4,
  parameter integer H_BACK=8,
  parameter integer V_FRONT=2,
  parameter integer V_SYNC=2,
  parameter integer V_BACK=2,
  parameter integer PIXEL_DIV=64,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy,underflow,
  output logic pixel_ce,video_de,video_hsync,video_vsync,
  output logic [47:0] video_pixel
);
  localparam integer WORDS=H_ACTIVE*V_ACTIVE;
  localparam integer H_TOTAL=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
  localparam integer V_TOTAL=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
  logic run_q,underflow_q;
  logic [15:0] div_q,h_q,v_q;
  logic [31:0] held_epoch_q;
  wire scan_fault,scan_busy,scan_valid,scan_start,scan_end;
  wire [47:0] scan_data;
  wire [9:0] scan_index;
  wire [31:0] scan_epoch;
  wire scan_ready;
  wire active_slot=(h_q<H_ACTIVE && v_q<V_ACTIVE);
  wire tick=run_q && div_q==16'(PIXEL_DIV-1);
  wire [9:0] word_index=10'(v_q*H_ACTIVE+h_q);
  wire index_ok=scan_index==word_index;
  wire edge_ok=(scan_start==(word_index==10'd0)) &&
      (scan_end==(word_index==10'(WORDS-1)));
  wire epoch_ok=(word_index==10'd0) ?
      (scan_epoch!=32'd0) : (scan_epoch==held_epoch_q);
  wire sample_ok=scan_valid && index_ok && edge_ok && epoch_ok;
  assign scan_ready=rst_n && tick && active_slot &&
      !underflow_q && !scan_fault && sample_ok;
  assign fault=underflow_q || scan_fault;
  assign busy=scan_busy;
  assign underflow=underflow_q;
  a0_p210_frame_boundary_stream #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) stream(
    .clk(clk),.rst_n(rst_n),.host_valid(host_valid),
    .host_write(host_write),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_ready(host_ready),
    .host_rdata(host_rdata),.fault(scan_fault),.busy(scan_busy),
    .pixel_ready(scan_ready),.pixel_valid(scan_valid),
    .pixel_data(scan_data),.pixel_index(scan_index),
    .pixel_epoch(scan_epoch),.frame_start(scan_start),
    .frame_end(scan_end)
  );
  always_ff @(posedge clk)begin
    if(!rst_n)begin
      run_q<=0;underflow_q<=0;div_q<=0;h_q<=0;v_q<=0;
      held_epoch_q<=0;pixel_ce<=0;video_de<=0;
      video_hsync<=1;video_vsync<=1;video_pixel<=0;
    end else begin
      pixel_ce<=0;
      if(!run_q && !underflow_q && !scan_fault && scan_valid)begin
        if(scan_index!=10'd0 || !scan_start || scan_epoch==0)
          underflow_q<=1;
        else run_q<=1;
      end
      if(run_q)begin
        if(tick)begin
          div_q<=0;pixel_ce<=1;
          video_hsync<=!(h_q>=H_ACTIVE+H_FRONT &&
                          h_q<H_ACTIVE+H_FRONT+H_SYNC);
          video_vsync<=!(v_q>=V_ACTIVE+V_FRONT &&
                          v_q<V_ACTIVE+V_FRONT+V_SYNC);
          video_de<=active_slot && sample_ok &&
                    !underflow_q && !scan_fault;
          video_pixel<=(active_slot && sample_ok &&
                        !underflow_q && !scan_fault) ?
                        scan_data : 48'd0;
          if(active_slot && !underflow_q && !scan_fault)begin
            if(!sample_ok)underflow_q<=1;
            else if(word_index==10'd0)held_epoch_q<=scan_epoch;
          end
          if(h_q==16'(H_TOTAL-1))begin
            h_q<=0;
            if(v_q==16'(V_TOTAL-1))v_q<=0;
            else v_q<=v_q+16'd1;
          end else h_q<=h_q+16'd1;
        end else div_q<=div_q+16'd1;
      end
      if(scan_fault)begin
        video_de<=0;video_pixel<=0;
      end
      if(underflow_q)begin
        video_de<=0;video_pixel<=0;
      end
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       H_ACTIVE<2 || V_ACTIVE<2 || H_FRONT<1 || H_SYNC<1 ||
       H_BACK<1 || V_FRONT<1 || V_SYNC<1 || V_BACK<1 ||
       H_TOTAL>65535 || V_TOTAL>65535 ||
       PIXEL_DIV<1 || PIXEL_DIV>65535 ||
       BASE_WORD_ADDR>32'hffff_ffff-2*WORDS ||
       RESPONSE_TIMEOUT<64)
      $fatal(1,"P211 unsupported raster timing geometry");
  end
endmodule
