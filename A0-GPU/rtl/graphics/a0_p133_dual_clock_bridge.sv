`timescale 1ns/1ps
// P133: bounded two-clock request/response crossing into unchanged P132.
// Single global reset. Not a PCIe/AXI or board-qualified interface.
module a0_p133_dual_clock_bridge #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4
)(
  input wire host_clk,
  input wire gpu_clk,
  input wire rst_n,
  input wire h_req_valid,
  output wire h_req_ready,
  input wire h_req_write,
  input wire [7:0] h_req_addr,
  input wire [31:0] h_req_wdata,
  output wire h_rsp_valid,
  input wire h_rsp_ready,
  output wire [31:0] h_rsp_rdata,
  output wire h_rsp_error
);
  (* async_reg = "true" *) reg [1:0] host_rst_release;
  (* async_reg = "true" *) reg [1:0] gpu_rst_release;
  always @(posedge host_clk or negedge rst_n) begin
    if (!rst_n) host_rst_release <= 0;
    else host_rst_release <= {host_rst_release[0], 1'b1};
  end
  always @(posedge gpu_clk or negedge rst_n) begin
    if (!rst_n) gpu_rst_release <= 0;
    else gpu_rst_release <= {gpu_rst_release[0], 1'b1};
  end
  wire hrst_n=host_rst_release[1];
  wire grst_n=gpu_rst_release[1];

  wire [40:0] command_out;
  wire command_valid, command_ready;
  a0_p133_async_fifo #(.WIDTH(41),.ADDR_BITS(2)) request_fifo(
    .wclk(host_clk),.wrst_n(hrst_n),
    .wvalid(h_req_valid),.wready(h_req_ready),
    .wdata({h_req_write,h_req_addr,h_req_wdata}),
    .rclk(gpu_clk),.rrst_n(grst_n),
    .rvalid(command_valid),.rready(command_ready),
    .rdata(command_out)
  );
  wire [31:0] gpu_rsp_data;
  wire gpu_rsp_valid,gpu_rsp_ready,gpu_rsp_error;
  a0_p132_command_bus #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) device(
    .clk(gpu_clk),.rst_n(grst_n),
    .req_valid(command_valid),.req_ready(command_ready),
    .req_write(command_out[40]),.req_addr(command_out[39:32]),
    .req_wdata(command_out[31:0]),
    .rsp_valid(gpu_rsp_valid),.rsp_ready(gpu_rsp_ready),
    .rsp_rdata(gpu_rsp_data),.rsp_error(gpu_rsp_error)
  );
  wire [32:0] response_out;
  a0_p133_async_fifo #(.WIDTH(33),.ADDR_BITS(2)) response_fifo(
    .wclk(gpu_clk),.wrst_n(grst_n),
    .wvalid(gpu_rsp_valid),.wready(gpu_rsp_ready),
    .wdata({gpu_rsp_error,gpu_rsp_data}),
    .rclk(host_clk),.rrst_n(hrst_n),
    .rvalid(h_rsp_valid),.rready(h_rsp_ready),
    .rdata(response_out)
  );
  assign h_rsp_error=response_out[32];
  assign h_rsp_rdata=response_out[31:0];
endmodule
