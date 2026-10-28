`timescale 1ns/1ps
// P210: abstract one-clock pixel stream with ready/valid backpressure.
// The actual P209 scanout EBR is read only through P209's real independent
// pixel port. Producer publication is delayed until the previous complete
// frame's LAST pixel is consumed, preventing mixed-epoch frames.
// This is NOT HDMI/DP timing or a display PHY.
module a0_p210_frame_boundary_stream #(
  parameter integer WORDS=1024,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy,
  input logic pixel_ready,
  output logic pixel_valid,
  output logic [47:0] pixel_data,
  output logic [9:0] pixel_index,
  output logic [31:0] pixel_epoch,
  output logic frame_start,frame_end
);
  localparam logic [2:0] WAIT_FIRST=0,SCAN_REQ=1,SCAN_RSP=2,
    PRESENT=3,BOUNDARY=4,PUBLISH=5,SETTLE=6,FAILED=7;
  logic [2:0] state_q;
  logic local_fault_q,publish_queued_q,front_started_q;
  logic [9:0] read_index_q,out_index_q;
  logic [47:0] out_pixel_q;
  logic [31:0] out_epoch_q;
  logic out_valid_q;
  logic [15:0] settle_cycles_q;
  wire low_fault,low_busy,low_host_ready,low_scan_ready,low_scan_valid;
  wire [7:0] low_host_rdata;
  wire [47:0] low_scan_pixel;
  wire [31:0] low_scan_epoch;
  wire internal_publish=state_q==PUBLISH;
  wire is_publish_write=host_write && host_addr==6'h31;
  wire external_relay=host_valid && !is_publish_write &&
    !local_fault_q && state_q!=FAILED &&
    state_q!=PUBLISH && state_q!=SETTLE &&
    (!publish_queued_q || !host_write);
  wire low_host_valid=internal_publish || external_relay;
  wire low_host_write=internal_publish ? 1'b1 : host_write;
  wire [5:0] low_host_addr=internal_publish ? 6'h31 : host_addr;
  wire [7:0] low_host_wdata=internal_publish ? 8'h01 : host_wdata;
  wire low_scan_req=state_q==SCAN_REQ && !local_fault_q && !low_fault;
  wire host_can_access=state_q!=FAILED && state_q!=PUBLISH &&
      state_q!=SETTLE && !local_fault_q && !low_fault;
  wire host_publish_accept=is_publish_write &&
      !publish_queued_q && !low_busy && host_can_access;
  wire forward_ready=low_host_ready && host_can_access;
  assign host_ready=rst_n && (is_publish_write ?
      (forward_ready && host_publish_accept) :
      (forward_ready && (!publish_queued_q || !host_write)));
  assign host_rdata=low_host_rdata;
  assign fault=local_fault_q || low_fault;
  assign busy=low_busy || publish_queued_q ||
      state_q==PUBLISH || state_q==SETTLE;
  assign pixel_valid=out_valid_q && !fault;
  assign pixel_data=out_pixel_q;
  assign pixel_index=out_index_q;
  assign pixel_epoch=out_epoch_q;
  assign frame_start=pixel_valid && out_index_q==10'd0;
  assign frame_end=pixel_valid && out_index_q==10'(WORDS-1);

  a0_p209_independent_scanout #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) scanout(
    .clk(clk),.rst_n(rst_n),
    .host_valid(low_host_valid),.host_write(low_host_write),
    .host_addr(low_host_addr),.host_wdata(low_host_wdata),
    .host_ready(low_host_ready),.host_rdata(low_host_rdata),
    .fault(low_fault),.busy(low_busy),
    .scan_req_valid(low_scan_req),.scan_word_index(read_index_q),
    .scan_req_ready(low_scan_ready),.scan_rsp_valid(low_scan_valid),
    .scan_rsp_pixel(low_scan_pixel),.scan_rsp_epoch(low_scan_epoch)
  );
  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=WAIT_FIRST;local_fault_q<=0;publish_queued_q<=0;
      front_started_q<=0;read_index_q<=0;out_index_q<=0;
      out_pixel_q<=0;out_epoch_q<=0;out_valid_q<=0;
      settle_cycles_q<=0;
    end else begin
      if(low_fault)begin
        local_fault_q<=1;state_q<=FAILED;out_valid_q<=0;
      end else begin
        if(host_valid && host_write && host_ready &&
           is_publish_write)begin
          if(host_wdata!=8'h01)local_fault_q<=1;
          else publish_queued_q<=1;
        end
        case(state_q)
          WAIT_FIRST:if(publish_queued_q)state_q<=PUBLISH;
          SCAN_REQ:if(low_scan_ready)state_q<=SCAN_RSP;
          SCAN_RSP:if(low_scan_valid)begin
            out_pixel_q<=low_scan_pixel;
            out_epoch_q<=low_scan_epoch;
            out_index_q<=read_index_q;
            out_valid_q<=1;
            state_q<=PRESENT;
          end
          PRESENT:if(out_valid_q && pixel_ready)begin
            out_valid_q<=0;
            if(read_index_q==WORDS-1)state_q<=BOUNDARY;
            else begin
              read_index_q<=read_index_q+10'd1;
              state_q<=SCAN_REQ;
            end
          end
          BOUNDARY:begin
            read_index_q<=0;
            if(publish_queued_q)state_q<=PUBLISH;
            else state_q<=SCAN_REQ;
          end
          PUBLISH:if(low_host_ready)begin
            publish_queued_q<=0;
            settle_cycles_q<=0;
            state_q<=SETTLE;
          end
          SETTLE:begin
            if(settle_cycles_q>=16'd2 && low_scan_ready)begin
              front_started_q<=1;read_index_q<=0;
              state_q<=SCAN_REQ;
            end else if(settle_cycles_q>=16'd1024)begin
              local_fault_q<=1;state_q<=FAILED;
            end else settle_cycles_q<=settle_cycles_q+16'd1;
          end
          FAILED:begin end
          default:begin local_fault_q<=1;state_q<=FAILED;end
        endcase
      end
      if(local_fault_q)begin state_q<=FAILED;out_valid_q<=0;end
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       BASE_WORD_ADDR>32'hffff_ffff-2*WORDS ||
       RESPONSE_TIMEOUT<64)
      $fatal(1,"P210 unsupported frame boundary geometry");
  end
endmodule
