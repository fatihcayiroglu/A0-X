`timescale 1ns/1ps
// P149 research link: ordered transaction IDs, reset epochs, watchdog,
// and fail-closed recovery around the genuine P148 -> P147 -> raster/RAM.
// This is SINGLE CLOCK, NOT PCIe/DMA/CDC or a hardware timeout standard.
// IDs identify accepted requests, but may be reused: (epoch,id) is a
// matching token for the host to reconcile after software link resets.
module a0_p149_epoch_tagged_host_link #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4,
  parameter integer WATCHDOG_CYCLES=512
)(
  input  logic clk,rst_n,
  input  logic link_reset,                 // synchronous soft flush
  output logic link_fault,                // latched; clear with link_reset
  input  logic req_valid,req_write,
  output logic req_ready,
  input  logic [7:0] req_id,
  input  logic [4:0] req_addr,
  input  logic [31:0] req_wdata,
  output logic rsp_valid,rsp_error,
  input  logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic [15:0] rsp_epoch,
  output logic [31:0] rsp_rdata
);
  localparam integer TAG_DEPTH=8;
  logic [7:0] ids[0:TAG_DEPTH-1];
  logic [2:0] head_q,tail_q;
  logic [3:0] used_q;
  logic [15:0] epoch_q;
  logic reset_held_q;
  logic [$clog2(WATCHDOG_CYCLES+1)-1:0] watchdog_q;
  logic fault_q;
  wire core_req_ready,core_rsp_valid,core_rsp_error;
  wire [31:0] core_rsp_data;

  wire core_reset_n=rst_n && !link_reset && !fault_q;
  wire can_send=rst_n && !link_reset && !fault_q;
  assign req_ready=can_send && (used_q<TAG_DEPTH) && core_req_ready;
  wire push=req_valid && req_ready;
  wire pop=can_send && core_rsp_valid && rsp_ready && (used_q!=0);
  assign rsp_valid=can_send && (used_q!=0) && core_rsp_valid;
  assign rsp_error=rsp_valid && core_rsp_error;
  assign rsp_rdata=rsp_valid ? core_rsp_data : 32'd0;
  assign rsp_id=rsp_valid ? ids[head_q] : 8'd0;
  assign rsp_epoch=epoch_q;
  assign link_fault=fault_q;

  a0_p148_ordered_host_queue_top #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) core(
    .clk(clk),.rst_n(core_reset_n),
    .req_valid(push),.req_write(req_write),.req_ready(core_req_ready),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(core_rsp_valid),.rsp_error(core_rsp_error),
    .rsp_ready(pop),.rsp_rdata(core_rsp_data)
  );

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      head_q<=0;tail_q<=0;used_q<=0;
      epoch_q<=0;reset_held_q<=0;watchdog_q<=0;fault_q<=0;
    end else if(link_reset) begin
      head_q<=0;tail_q<=0;used_q<=0;
      watchdog_q<=0;fault_q<=0;
      // A level-held link_reset changes the epoch ONCE, not every
      // clock it remains asserted. Physical reset establishes epoch 0.
      if(!reset_held_q)epoch_q<=epoch_q+16'd1;
      reset_held_q<=1;
    end else begin
      reset_held_q<=0;
      if(fault_q) begin
        // On timeout, fail CLOSED and cancel all accepted work. It
        // remains faulted until a deliberate soft link_reset.
        head_q<=0;tail_q<=0;used_q<=0;
        watchdog_q<=0;
      end else begin
        if(push)begin
          ids[tail_q]<=req_id;
          tail_q<=tail_q+3'd1;
        end
        if(pop)head_q<=head_q+3'd1;
        case({push,pop})
          2'b10:used_q<=used_q+4'd1;
          2'b01:used_q<=used_q-4'd1;
          default:used_q<=used_q;
        endcase
        // Do not time out a response the host is intentionally
        // holding. Only absence of the oldest *backend* response counts.
        if(used_q==0 || core_rsp_valid || pop)watchdog_q<=0;
        else if(watchdog_q>=WATCHDOG_CYCLES-1) begin
          fault_q<=1;
          watchdog_q<=0;
        end else watchdog_q<=watchdog_q+1'b1;
      end
    end
  end
  initial begin
    if(WATCHDOG_CYCLES<2 || WATCHDOG_CYCLES>65535 ||
       FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       FRAME_WIDTH*FRAME_HEIGHT<2 || FRAME_WIDTH*FRAME_HEIGHT>65536)
      $fatal(1,"P149 invalid research watchdog/geometry");
  end
endmodule
