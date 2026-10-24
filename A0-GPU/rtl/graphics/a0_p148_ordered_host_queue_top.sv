`timescale 1ns/1ps
// P148: ordered, lossless four-entry host request queue around the
// unchanged full-16-bit P147 register/command-to-BRAM engine.
// Single clock only. No PCIe, DMA, CDC, physical IO/pin assignment.
// Exactly one request is active downstream, and exactly one response is
// held until the host explicitly acknowledges it. All commands remain
// ordered; rejected commands also generate an ordered error response.
module a0_p148_ordered_host_queue_top #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4
)(
  input  logic clk, rst_n,
  input  logic req_valid,req_write,
  output logic req_ready,
  input  logic [4:0] req_addr,
  input  logic [31:0] req_wdata,
  output logic rsp_valid,rsp_error,
  input  logic rsp_ready,
  output logic [31:0] rsp_rdata
);
  localparam integer DEPTH=4;
  logic [37:0] queue[0:DEPTH-1];
  logic [1:0] head_q,tail_q;
  logic [2:0] used_q;
  logic inflight_q;
  wire core_req_ready,core_rsp_valid,core_rsp_error;
  wire [31:0] core_rsp_data;

  assign req_ready=rst_n && (used_q<DEPTH);
  wire push=req_valid && req_ready;
  wire pop=rst_n && !inflight_q && !rsp_valid &&
           (used_q!=0) && core_req_ready;
  wire [37:0] oldest=queue[head_q];
  wire core_req_write=oldest[37];
  wire [4:0] core_req_addr=oldest[36:32];
  wire [31:0] core_req_data=oldest[31:0];

  a0_p147_packed_command_top #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) core(
    .clk(clk),.rst_n(rst_n),
    .req_valid(pop),.req_ready(core_req_ready),
    .req_write(core_req_write),.req_addr(core_req_addr),
    .req_wdata(core_req_data),
    .rsp_valid(core_rsp_valid),.rsp_error(core_rsp_error),
    .rsp_rdata(core_rsp_data)
  );

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      head_q<=0;tail_q<=0;used_q<=0;inflight_q<=0;
      rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;
    end else begin
      if(push)begin
        queue[tail_q]<={req_write,req_addr,req_wdata};
        tail_q<=tail_q+2'd1;
      end
      if(pop)begin
        head_q<=head_q+2'd1;
        inflight_q<=1;
      end
      case({push,pop})
        2'b10:used_q<=used_q+3'd1;
        2'b01:used_q<=used_q-3'd1;
        default:used_q<=used_q;
      endcase
      if(inflight_q && core_rsp_valid)begin
        inflight_q<=0;
        rsp_valid<=1;
        rsp_error<=core_rsp_error;
        rsp_rdata<=core_rsp_data;
      end else if(rsp_valid && rsp_ready)begin
        rsp_valid<=0;
      end
    end
  end

  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       FRAME_WIDTH*FRAME_HEIGHT<2 || FRAME_WIDTH*FRAME_HEIGHT>65536)
      $fatal(1,"P148 unsupported framebuffer size");
  end
endmodule
