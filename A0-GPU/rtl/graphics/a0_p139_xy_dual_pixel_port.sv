`timescale 1ns/1ps
// P139: two independent XY pixel requests routed to P138 FPGA BRAM banks.
// Packed pixel word = {RGB888,depth24}. Supports one accepted request per
// *bank* per cycle; same-bank contention stalls lane 1 (lane 0 priority).
// Out-of-bounds X/Y are acknowledged as registered errors without touching
// storage or suppressing the other lane. Accepted responses are 1-cycle
// pulses; consumers must sample them (NO rsp_ready/backpressure).
// This is a STANDALONE coordinate front-end, not connected to P102.
module a0_p139_xy_dual_pixel_port #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
  parameter integer ADDR_BITS=PIXELS<=1 ? 1 : $clog2(PIXELS)
)(
  input  logic clk,rst_n,
  input  logic req0_valid,
  output logic req0_ready,
  input  logic req0_write,
  input  logic [15:0] req0_x,req0_y,
  input  logic [47:0] req0_wdata,
  output logic rsp0_valid,rsp0_error,
  output logic [47:0] rsp0_rdata,

  input  logic req1_valid,
  output logic req1_ready,
  input  logic req1_write,
  input  logic [15:0] req1_x,req1_y,
  input  logic [47:0] req1_wdata,
  output logic rsp1_valid,rsp1_error,
  output logic [47:0] rsp1_rdata
);
  logic in0,in1;
  logic [31:0] linear0,linear1;
  logic [ADDR_BITS-1:0] index0,index1;
  logic mem_ready0,mem_ready1;
  logic mem_rsp0_valid,mem_rsp1_valid,mem_rsp0_error,mem_rsp1_error;
  logic [47:0] mem_rsp0_data,mem_rsp1_data;
  logic error0_q,error1_q;
  always_comb begin
    in0=(req0_x<FRAME_WIDTH && req0_y<FRAME_HEIGHT);
    in1=(req1_x<FRAME_WIDTH && req1_y<FRAME_HEIGHT);
    linear0=(32'(req0_y)*32'(FRAME_WIDTH))+32'(req0_x);
    linear1=(32'(req1_y)*32'(FRAME_WIDTH))+32'(req1_x);
    index0=ADDR_BITS'(linear0);
    index1=ADDR_BITS'(linear1);
  end

  assign req0_ready=mem_ready0;
  // An out-of-range lane never consumes a bank, regardless of another
  // lane's request or the truncated index computed above.
  assign req1_ready=(req1_valid && !in1) ? rst_n : mem_ready1;

  a0_p138_dual_bank_framebuffer #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) storage (
    .clk(clk),.rst_n(rst_n),
    .req0_valid(req0_valid && in0),.req0_ready(mem_ready0),
    .req0_write(req0_write),.req0_index(index0),.req0_wdata(req0_wdata),
    .rsp0_valid(mem_rsp0_valid),.rsp0_error(mem_rsp0_error),
    .rsp0_rdata(mem_rsp0_data),
    .req1_valid(req1_valid && in1),.req1_ready(mem_ready1),
    .req1_write(req1_write),.req1_index(index1),.req1_wdata(req1_wdata),
    .rsp1_valid(mem_rsp1_valid),.rsp1_error(mem_rsp1_error),
    .rsp1_rdata(mem_rsp1_data)
  );

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      error0_q<=1'b0;
      error1_q<=1'b0;
    end else begin
      error0_q<=req0_valid && req0_ready && !in0;
      error1_q<=req1_valid && req1_ready && !in1;
    end
  end
  assign rsp0_valid=mem_rsp0_valid || error0_q;
  assign rsp1_valid=mem_rsp1_valid || error1_q;
  assign rsp0_error=mem_rsp0_error || error0_q;
  assign rsp1_error=mem_rsp1_error || error1_q;
  assign rsp0_rdata=error0_q ? 48'd0 : mem_rsp0_data;
  assign rsp1_rdata=error1_q ? 48'd0 : mem_rsp1_data;

  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || PIXELS!=FRAME_WIDTH*FRAME_HEIGHT ||
       PIXELS<2 || PIXELS>65536 ||
       ADDR_BITS<$clog2(PIXELS))
      $fatal(1,"P139 invalid pixel-port parameters");
  end
endmodule
