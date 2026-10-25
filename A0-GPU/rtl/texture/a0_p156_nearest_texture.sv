`timescale 1ns/1ps
// P156 research single-port synchronous RGBA8 texture sampler.
// 16x16 full texel array, signed integer texel XY, clamp/repeat,
// read-after-write ordering, valid-texel mask and exact response tags.
// This is NOT bilinear filtering, mipmaps, normalized UV coordinates,
// a shader texturing ISA, external VRAM or a physical GPU.
module a0_p156_nearest_texture #(
  parameter integer TEX_WIDTH=16,
  parameter integer TEX_HEIGHT=16,
  parameter integer TEXELS=TEX_WIDTH*TEX_HEIGHT,
  parameter integer X_BITS=$clog2(TEX_WIDTH),
  parameter integer Y_BITS=$clog2(TEX_HEIGHT),
  parameter integer ADDR_BITS=$clog2(TEXELS)
)(
  input logic clk,rst_n,
  input logic write_valid,
  output logic write_ready,
  input logic [X_BITS-1:0] write_x,
  input logic [Y_BITS-1:0] write_y,
  input logic [31:0] write_rgba,
  input logic sample_valid,
  output logic sample_ready,
  input logic signed [15:0] sample_x,sample_y,
  input logic sample_repeat,
  input logic [7:0] sample_id,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic [31:0] rsp_rgba,
  output logic rsp_present
);
  // One physical single-port RAM: simultaneous write and sample cannot
  // be accepted. Samples have priority if both requesters assert valid.
  assign sample_ready=rst_n && (!rsp_valid || rsp_ready);
  assign write_ready=rst_n && !sample_valid && (!rsp_valid || rsp_ready);
  wire sample_fire=sample_valid && sample_ready;
  wire write_fire=write_valid && write_ready;

  wire [X_BITS-1:0] tex_x=sample_repeat ?
        sample_x[X_BITS-1:0] :
        (sample_x<0 ? X_BITS'(0) :
         (sample_x>=16'(TEX_WIDTH) ? X_BITS'(TEX_WIDTH-1) :
          sample_x[X_BITS-1:0]));
  wire [Y_BITS-1:0] tex_y=sample_repeat ?
        sample_y[Y_BITS-1:0] :
        (sample_y<0 ? Y_BITS'(0) :
         (sample_y>=16'(TEX_HEIGHT) ? Y_BITS'(TEX_HEIGHT-1) :
          sample_y[Y_BITS-1:0]));
  wire [ADDR_BITS-1:0] read_addr=ADDR_BITS'(tex_y)*ADDR_BITS'(TEX_WIDTH)+
                                  ADDR_BITS'(tex_x);
  wire [ADDR_BITS-1:0] write_addr=ADDR_BITS'(write_y)*ADDR_BITS'(TEX_WIDTH)+
                                   ADDR_BITS'(write_x);
  logic [31:0] tex_ram[0:TEXELS-1];
  logic [TEXELS-1:0] written_q;

  // RAM data is intentionally not reset so synthesis can map DP16KD.
  // The validity bitmap IS reset: stale/uninitialized texels read as
  // zero without leaking undefined BRAM contents after reset.
  always_ff @(posedge clk) begin
    if(write_fire)tex_ram[write_addr]<=write_rgba;
  end
  always_ff @(posedge clk) begin
    if(!rst_n)written_q<='0;
    else if(write_fire)written_q[write_addr]<=1'b1;
  end
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      rsp_valid<=0;rsp_id<=0;rsp_rgba<=0;rsp_present<=0;
    end else if(sample_ready)begin
      rsp_valid<=sample_valid;
      if(sample_fire)begin
        rsp_id<=sample_id;
        rsp_present<=written_q[read_addr];
        rsp_rgba<=written_q[read_addr]?tex_ram[read_addr]:32'd0;
      end
    end
  end
  initial begin
    if(TEX_WIDTH<2 || TEX_HEIGHT<2 || TEXELS!=TEX_WIDTH*TEX_HEIGHT ||
       (TEX_WIDTH & (TEX_WIDTH-1))!=0 ||
       (TEX_HEIGHT & (TEX_HEIGHT-1))!=0 ||
       TEX_WIDTH>256 || TEX_HEIGHT>256)
      $fatal(1,"P156 supported texture dimensions must be powers of two [2..256]");
  end
endmodule
