`timescale 1ns/1ps
// P212: bridge unchanged P210 frame-fenced physical EBR producer to a
// separately clocked pixel consumer through a lossless Gray-pointer FIFO.
// The P210 final-pixel fence now means FIFO *enqueue*, not sink consumption.
// Every pixel is tagged with its 10-bit index and 32-bit epoch so downstream
// can detect frame boundaries without mixing generations.
module a0_p212_async_frame_queue #(
  parameter integer WORDS=1024,
  parameter integer FIFO_ADDR_BITS=6,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic host_clk,pixel_clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy,
  input logic pixel_ready,
  output logic pixel_valid,pixel_fault,
  output logic [47:0] pixel_data,
  output logic [9:0] pixel_index,
  output logic [31:0] pixel_epoch,
  output logic frame_start,frame_end
);
  wire source_fault,source_busy,source_valid,queue_wr_ready;
  wire [47:0] source_data;
  wire [9:0] source_index;
  wire [31:0] source_epoch;
  wire source_start,source_end;
  wire [91:0] fifo_data;
  wire fifo_valid;
  (* async_reg="true" *) logic pix_fault_meta_q,pix_fault_q;
  assign fault=source_fault;
  assign busy=source_busy || !queue_wr_ready;
  assign pixel_fault=pix_fault_q;
  assign pixel_valid=fifo_valid && !pix_fault_q;
  assign {frame_end,frame_start,pixel_epoch,pixel_index,pixel_data}=
    pixel_valid ? fifo_data : 92'd0;
  a0_p210_frame_boundary_stream #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) source(
    .clk(host_clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(source_fault),.busy(source_busy),
    .pixel_ready(queue_wr_ready),.pixel_valid(source_valid),
    .pixel_data(source_data),.pixel_index(source_index),
    .pixel_epoch(source_epoch),.frame_start(source_start),
    .frame_end(source_end)
  );
  a0_p212_gray_async_fifo #(.WIDTH(92),.ADDR_BITS(FIFO_ADDR_BITS)) queue(
    .wr_clk(host_clk),.rd_clk(pixel_clk),.rst_n(rst_n),
    .wr_valid(source_valid && !source_fault),
    .wr_ready(queue_wr_ready),
    .wr_data({source_end,source_start,source_epoch,source_index,source_data}),
    .rd_valid(fifo_valid),.rd_ready(pixel_ready && !pix_fault_q),
    .rd_data(fifo_data)
  );
  always_ff @(posedge pixel_clk or negedge rst_n)begin
    if(!rst_n)begin pix_fault_meta_q<=0;pix_fault_q<=0;end
    else begin pix_fault_meta_q<=source_fault;pix_fault_q<=pix_fault_meta_q;end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0))
      $fatal(1,"P212 unsupported frame words");
  end
endmodule
