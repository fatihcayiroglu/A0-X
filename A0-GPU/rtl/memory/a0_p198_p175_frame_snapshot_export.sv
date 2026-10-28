`timescale 1ns/1ps
// P198: synthesizable AFTER-RENDER framebuffer snapshot exporter.
// Exclusively leases P175's existing register bus after a completed draw.
// It does NOT replace live BRAM, capture writes during rendering or provide
// direct physical VRAM access. Every pixel is read from actual host-visible
// RGB/depth registers, then offered to the P195 ordered write FIFO.
module a0_p198_p175_frame_snapshot_export #(
  parameter integer FRAME_WIDTH=256,FRAME_HEIGHT=256
)(
  input logic clk,rst_n,
  input logic start,
  output logic busy,done,fault,
  output logic host_req_valid,host_req_write,
  input logic host_req_ready,
  output logic [5:0] host_req_addr,
  output logic [31:0] host_req_wdata,
  input logic host_rsp_valid,host_rsp_error,
  input logic [31:0] host_rsp_rdata,
  output logic pixel_valid,
  input logic pixel_ready,
  output logic [15:0] pixel_x,pixel_y,
  output logic [47:0] pixel_data,
  output logic [31:0] queued_pixels
);
  localparam logic [3:0]
    IDLE=0,XY_REQ=1,XY_RSP=2,TRIGGER_REQ=3,TRIGGER_RSP=4,
    RGB_REQ=5,RGB_RSP=6,DEPTH_REQ=7,DEPTH_RSP=8,
    EMIT=9,COMPLETE=10,FAILED=11;
  logic [3:0] state_q;
  logic [15:0] x_q,y_q;
  logic [23:0] rgb_q,z_q;
  logic [31:0] queued_q;
  logic failed_q;

  assign busy=(state_q!=IDLE && state_q!=COMPLETE && state_q!=FAILED);
  assign done=state_q==COMPLETE;
  assign fault=failed_q;
  assign queued_pixels=queued_q;
  assign pixel_valid=rst_n && state_q==EMIT;
  assign pixel_x=x_q;
  assign pixel_y=y_q;
  assign pixel_data={rgb_q,z_q};
  assign host_req_valid=rst_n &&
    (state_q==XY_REQ || state_q==TRIGGER_REQ ||
     state_q==RGB_REQ || state_q==DEPTH_REQ);
  assign host_req_write=(state_q==XY_REQ || state_q==TRIGGER_REQ);
  assign host_req_addr=state_q==XY_REQ ? 6'd15 :
    state_q==TRIGGER_REQ ? 6'd16 :
    state_q==RGB_REQ ? 6'd18 : state_q==DEPTH_REQ ? 6'd19 : 6'd0;
  assign host_req_wdata=state_q==XY_REQ ? {y_q,x_q} :
    state_q==TRIGGER_REQ ? 32'd3 : 32'd0;

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;x_q<=0;y_q<=0;rgb_q<=0;z_q<=0;
      queued_q<=0;failed_q<=0;
    end else begin
      case(state_q)
        IDLE:if(start)begin
          x_q<=0;y_q<=0;rgb_q<=0;z_q<=0;queued_q<=0;
          failed_q<=0;state_q<=XY_REQ;
        end
        XY_REQ:if(host_req_ready)state_q<=XY_RSP;
        XY_RSP:if(host_rsp_valid)begin
          if(host_rsp_error)begin failed_q<=1;state_q<=FAILED;end
          else state_q<=TRIGGER_REQ;
        end
        TRIGGER_REQ:if(host_req_ready)state_q<=TRIGGER_RSP;
        TRIGGER_RSP:if(host_rsp_valid)begin
          if(host_rsp_error)begin failed_q<=1;state_q<=FAILED;end
          else state_q<=RGB_REQ;
        end
        RGB_REQ:if(host_req_ready)state_q<=RGB_RSP;
        RGB_RSP:if(host_rsp_valid)begin
          if(host_rsp_error || host_rsp_rdata[31:24]!=0)begin
            failed_q<=1;state_q<=FAILED;
          end else begin rgb_q<=host_rsp_rdata[23:0];state_q<=DEPTH_REQ;end
        end
        DEPTH_REQ:if(host_req_ready)state_q<=DEPTH_RSP;
        DEPTH_RSP:if(host_rsp_valid)begin
          if(host_rsp_error || host_rsp_rdata[31:24]!=0)begin
            failed_q<=1;state_q<=FAILED;
          end else begin z_q<=host_rsp_rdata[23:0];state_q<=EMIT;end
        end
        EMIT:if(pixel_ready)begin
          queued_q<=queued_q+32'd1;
          if(x_q==FRAME_WIDTH-1)begin
            if(y_q==FRAME_HEIGHT-1)state_q<=COMPLETE;
            else begin
              x_q<=0;y_q<=y_q+16'd1;state_q<=XY_REQ;
            end
          end else begin x_q<=x_q+16'd1;state_q<=XY_REQ;end
        end
        // A completed export can be restarted without resetting the P175
        // framebuffer or invalidating the already-published external bank.
        COMPLETE:if(start)begin
          x_q<=0;y_q<=0;rgb_q<=0;z_q<=0;queued_q<=0;
          failed_q<=0;state_q<=XY_REQ;
        end
        FAILED:begin end
        default:begin failed_q<=1;state_q<=FAILED;end
      endcase
    end
  end
  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       FRAME_WIDTH>256 || FRAME_HEIGHT>256 ||
       FRAME_WIDTH*FRAME_HEIGHT>65536 ||
       FRAME_WIDTH*FRAME_HEIGHT<2)
      $fatal(1,"P198 unsupported host framebuffer snapshot shape");
  end
endmodule
