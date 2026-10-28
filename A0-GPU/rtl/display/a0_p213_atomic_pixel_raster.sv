`timescale 1ns/1ps
// P213: pixel-clock-local 2-bank frame staging + atomic vertical-boundary
// display publication. Full frame transport comes from the P212 Gray FIFO.
// Duplicate COMPLETE source epochs are drained without being displayed
// multiple times; only a completely received new epoch can swap at VBlank.
// Still a clock-enable raster, NOT HDMI/DP or an independent pixel PLL.
module a0_p213_atomic_pixel_raster #(
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
  localparam integer WORDS=H_ACTIVE*V_ACTIVE;
  localparam integer HT=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
  localparam integer VT=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
  // These are pixel-clock-local BRAM frame images; no reset data dependency.
  logic [47:0] frame0 [0:WORDS-1],frame1 [0:WORDS-1];
  logic [47:0] front_read_q;
  logic [15:0] h_q,v_q,div_q;
  logic run_q,front_valid_q,front_bank_q,stage_valid_q,stage_bank_q;
  logic [31:0] front_epoch_q,stage_epoch_q;
  logic [9:0] ingest_index_q;
  logic [31:0] ingest_epoch_q;
  logic ingest_skip_q,ingest_bank_q,local_fault_q;
  logic [15:0] duplicate_frames_q;
  wire src_valid,src_fault,src_start,src_end;
  wire [47:0] src_data;
  wire [9:0] src_index;
  wire [31:0] src_epoch;
  wire consume=src_valid && !local_fault_q && !src_fault;
  wire first_ingest=(ingest_index_q==10'd0);
  wire last_ingest=(ingest_index_q==10'(WORDS-1));
  wire duplicate_start=
    (front_valid_q && src_epoch==front_epoch_q) ||
    (stage_valid_q && src_epoch==stage_epoch_q);
  wire skip_ingest=first_ingest ? duplicate_start : ingest_skip_q;
  wire target_bank=first_ingest ?
      (front_valid_q ? !front_bank_q : 1'b0) : ingest_bank_q;
  wire bad_index=src_index!=ingest_index_q;
  wire bad_marker=src_start!=first_ingest || src_end!=last_ingest;
  wire bad_epoch=src_epoch==32'd0 ||
      (!first_ingest && src_epoch!=ingest_epoch_q) ||
      (first_ingest && front_valid_q && src_epoch<front_epoch_q) ||
      (first_ingest && stage_valid_q && src_epoch<stage_epoch_q);
  wire bad_sample=bad_index || bad_marker || bad_epoch;
  wire discard_stage=consume && first_ingest && !bad_sample && !skip_ingest;
  wire active=(h_q<H_ACTIVE && v_q<V_ACTIVE);
  wire tick=run_q && div_q==16'(PIXEL_DIV-1);
  wire prefetch=run_q && div_q==16'(PIXEL_DIV-2) &&
       active && !pixel_fault;
  wire [9:0] display_index=10'(v_q*H_ACTIVE+h_q);
  wire frame_boundary=tick && h_q==16'(HT-1) && v_q==16'(VT-1);
  wire pixel_stream_ready=!local_fault_q && !src_fault;
  assign pixel_fault=local_fault_q || src_fault;
  a0_p212_async_frame_queue #(
    .WORDS(WORDS),.FIFO_ADDR_BITS(FIFO_ADDR_BITS),
    .BASE_WORD_ADDR(BASE_WORD_ADDR),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) source(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(host_fault),.busy(host_busy),
    .pixel_ready(pixel_stream_ready),
    .pixel_valid(src_valid),.pixel_fault(src_fault),
    .pixel_data(src_data),.pixel_index(src_index),
    .pixel_epoch(src_epoch),.frame_start(src_start),
    .frame_end(src_end)
  );
  // Explicit dual-port same-pixel-clock RAM semantics: write the staging
  // bank while displaying the immutable opposite front bank.
  always_ff @(posedge pixel_clk)begin
    if(consume && !bad_sample && !skip_ingest)begin
      if(target_bank)frame1[src_index]<=src_data;
      else frame0[src_index]<=src_data;
    end
    if(prefetch)begin
      if(front_bank_q)front_read_q<=frame1[display_index];
      else front_read_q<=frame0[display_index];
    end
  end
  always_ff @(posedge pixel_clk or negedge rst_n)begin
    if(!rst_n)begin
      h_q<=0;v_q<=0;div_q<=0;run_q<=0;
      front_valid_q<=0;front_bank_q<=0;front_epoch_q<=0;
      stage_valid_q<=0;stage_bank_q<=0;stage_epoch_q<=0;
      ingest_index_q<=0;ingest_epoch_q<=0;
      ingest_skip_q<=0;ingest_bank_q<=0;
      local_fault_q<=0;duplicate_frames_q<=0;
      pixel_ce<=0;video_de<=0;video_hsync<=1;video_vsync<=1;
      video_pixel<=0;
    end else begin
      pixel_ce<=0;
      if(src_fault)local_fault_q<=1;
      if(consume)begin
        if(bad_sample)local_fault_q<=1;
        else begin
          if(first_ingest)begin
            ingest_epoch_q<=src_epoch;
            ingest_skip_q<=skip_ingest;
            ingest_bank_q<=target_bank;
            if(!skip_ingest)stage_valid_q<=0;
          end
          if(last_ingest)begin
            ingest_index_q<=0;
            if(skip_ingest)duplicate_frames_q<=duplicate_frames_q+16'd1;
            else begin
              stage_valid_q<=1;
              stage_bank_q<=target_bank;
              stage_epoch_q<=src_epoch;
            end
          end else ingest_index_q<=ingest_index_q+10'd1;
        end
      end
      if(!run_q)begin
        if(stage_valid_q && !discard_stage && !pixel_fault)begin
          front_valid_q<=1;front_bank_q<=stage_bank_q;
          front_epoch_q<=stage_epoch_q;stage_valid_q<=0;
          h_q<=0;v_q<=0;div_q<=0;run_q<=1;
        end
      end else begin
        if(tick)begin
          div_q<=0;pixel_ce<=1;
          video_hsync<=!(h_q>=H_ACTIVE+H_FRONT &&
                          h_q<H_ACTIVE+H_FRONT+H_SYNC);
          video_vsync<=!(v_q>=V_ACTIVE+V_FRONT &&
                          v_q<V_ACTIVE+V_FRONT+V_SYNC);
          video_de<=active && front_valid_q && !pixel_fault;
          video_pixel<=(active && front_valid_q && !pixel_fault) ?
                         front_read_q : 48'd0;
          if(h_q==16'(HT-1))begin
            h_q<=0;
            if(v_q==16'(VT-1))v_q<=0;
            else v_q<=v_q+16'd1;
          end else h_q<=h_q+16'd1;
          if(frame_boundary && stage_valid_q && !discard_stage &&
             !pixel_fault)begin
            front_bank_q<=stage_bank_q;front_epoch_q<=stage_epoch_q;
            stage_valid_q<=0;
          end
        end else div_q<=div_q+16'd1;
      end
      if(local_fault_q || src_fault)begin
        video_de<=0;video_pixel<=0;
      end
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       H_ACTIVE<2 || V_ACTIVE<2 ||
       H_FRONT<1 || H_SYNC<1 || H_BACK<1 ||
       V_FRONT<1 || V_SYNC<1 || V_BACK<1 ||
       HT>65535 || VT>65535 || PIXEL_DIV<3 || PIXEL_DIV>65535 ||
       FIFO_ADDR_BITS<2 || FIFO_ADDR_BITS>10)
      $fatal(1,"P213 unsupported pixel-local raster geometry");
  end
endmodule
