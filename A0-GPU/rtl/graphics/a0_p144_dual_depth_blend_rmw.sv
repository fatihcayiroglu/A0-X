`timescale 1ns/1ps
// P144: actual TWO-LANE depth-test + RGB-alpha-blend BRAM RMW micro-engine.
// Explicit two-beat issue: (1) both reads, (2) both conditional writes.
// A packet must have in-bounds, DIFFERENT-bank valid addresses, otherwise
// it fails atomically with no writes. Inactive lanes consume no bank.
// Accepted host reads use lane0 ONLY while idle and are tagged separately.
// Still standalone: not wired to P142 raster/P132/PCIe/physical VRAM.
module a0_p144_dual_depth_blend_rmw #(
  parameter integer FRAME_WIDTH=4,
  parameter integer FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
)(
  input  logic clk, rst_n,
  input  logic op_valid,
  output logic op_ready,
  input  logic op_clear,
  input  logic lane0_valid,lane1_valid,
  input  logic [15:0] lane0_x,lane0_y,lane1_x,lane1_y,
  input  logic [23:0] source_rgb,source_depth,
  input  logic [1:0] depth_compare_op,
  input  logic depth_write,blend_enable,
  input  logic [7:0] source_alpha,
  output logic rsp_valid,rsp_error,
  output logic [1:0] rsp_pixel_written,

  input  logic host_read_valid,
  output logic host_read_ready,
  input  logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  logic busy_q;
  logic [15:0] x0_q,y0_q,x1_q,y1_q;
  logic [1:0] mask_q,depth_op_q;
  logic [23:0] color_q,depth_q;
  logic depth_write_q,blend_enable_q;
  logic [7:0] alpha_q;
  logic host_tag_q;
  wire in0=(lane0_x<FRAME_WIDTH && lane0_y<FRAME_HEIGHT);
  wire in1=(lane1_x<FRAME_WIDTH && lane1_y<FRAME_HEIGHT);
  wire [31:0] idx0=32'(lane0_y)*32'(FRAME_WIDTH)+32'(lane0_x);
  wire [31:0] idx1=32'(lane1_y)*32'(FRAME_WIDTH)+32'(lane1_x);
  wire same_bank=(idx0[0]==idx1[0]);
  wire valid_packet=(!lane0_valid || in0) &&
                    (!lane1_valid || in1) &&
                    !(lane0_valid && lane1_valid && same_bank);

  assign op_ready=rst_n && !busy_q;
  assign host_read_ready=rst_n && !busy_q && !op_valid;

  wire fire_op=op_valid && op_ready;
  wire good_fire=fire_op && valid_packet;

  logic mem0_req_valid,mem1_req_valid,mem0_write,mem1_write;
  logic [15:0] mem0_x,mem0_y,mem1_x,mem1_y;
  logic [47:0] mem0_wdata,mem1_wdata;
  wire mem0_ready,mem1_ready;
  wire mem0_rsp_valid,mem1_rsp_valid,mem0_rsp_error,mem1_rsp_error;
  wire [47:0] mem0_rsp_data,mem1_rsp_data;
  wire read_beat_valid=busy_q &&
        (!mask_q[0] || (mem0_rsp_valid && !mem0_rsp_error)) &&
        (!mask_q[1] || (mem1_rsp_valid && !mem1_rsp_error));

  wire depth0_pass,depth1_pass;
  wire [23:0] blend0,blend1;
  a0_p68_depth_compare depth0(
    .incoming_depth(depth_q),.stored_depth(mem0_rsp_data[23:0]),
    .compare_op(depth_op_q),.candidate_valid(read_beat_valid && mask_q[0]),
    .accept(depth0_pass)
  );
  a0_p68_depth_compare depth1(
    .incoming_depth(depth_q),.stored_depth(mem1_rsp_data[23:0]),
    .compare_op(depth_op_q),.candidate_valid(read_beat_valid && mask_q[1]),
    .accept(depth1_pass)
  );
  a0_p70_rgb_blend rgb0(
    .source_rgb(color_q),.destination_rgb(mem0_rsp_data[47:24]),
    .source_alpha(alpha_q),.blend_enable(blend_enable_q),
    .output_rgb(blend0)
  );
  a0_p70_rgb_blend rgb1(
    .source_rgb(color_q),.destination_rgb(mem1_rsp_data[47:24]),
    .source_alpha(alpha_q),.blend_enable(blend_enable_q),
    .output_rgb(blend1)
  );

  always_comb begin
    mem0_req_valid=1'b0; mem1_req_valid=1'b0;
    mem0_write=1'b0;mem1_write=1'b0;
    mem0_x=0;mem0_y=0;mem1_x=0;mem1_y=0;
    mem0_wdata=0;mem1_wdata=0;

    if(busy_q) begin
      // Commit stage. No next packet may enter while read data is live.
      mem0_req_valid=read_beat_valid && mask_q[0] && depth0_pass;
      mem1_req_valid=read_beat_valid && mask_q[1] && depth1_pass;
      mem0_write=1'b1;mem1_write=1'b1;
      mem0_x=x0_q;mem0_y=y0_q;mem1_x=x1_q;mem1_y=y1_q;
      mem0_wdata={blend0,depth_write_q ? depth_q : mem0_rsp_data[23:0]};
      mem1_wdata={blend1,depth_write_q ? depth_q : mem1_rsp_data[23:0]};
    end else if(good_fire) begin
      // Clear is a direct, no-read write. Other modes take concurrent
      // registered reads, followed by the write beat on the next clock.
      mem0_req_valid=lane0_valid;
      mem1_req_valid=lane1_valid;
      mem0_write=op_clear;mem1_write=op_clear;
      mem0_x=lane0_x;mem0_y=lane0_y;
      mem1_x=lane1_x;mem1_y=lane1_y;
      mem0_wdata={source_rgb,source_depth};
      mem1_wdata={source_rgb,source_depth};
    end else if(host_read_valid && host_read_ready) begin
      mem0_req_valid=1'b1;
      mem0_x=host_read_x;mem0_y=host_read_y;
    end
  end

  a0_p139_xy_dual_pixel_port #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) banks(
    .clk(clk),.rst_n(rst_n),
    .req0_valid(mem0_req_valid),.req0_ready(mem0_ready),
    .req0_write(mem0_write),.req0_x(mem0_x),.req0_y(mem0_y),
    .req0_wdata(mem0_wdata),.rsp0_valid(mem0_rsp_valid),
    .rsp0_error(mem0_rsp_error),.rsp0_rdata(mem0_rsp_data),
    .req1_valid(mem1_req_valid),.req1_ready(mem1_ready),
    .req1_write(mem1_write),.req1_x(mem1_x),.req1_y(mem1_y),
    .req1_wdata(mem1_wdata),.rsp1_valid(mem1_rsp_valid),
    .rsp1_error(mem1_rsp_error),.rsp1_rdata(mem1_rsp_data)
  );

  assign host_rsp_valid=host_tag_q && mem0_rsp_valid;
  assign host_rsp_error=host_tag_q && mem0_rsp_error;
  assign {host_rsp_color,host_rsp_depth}=
         host_rsp_valid ? mem0_rsp_data : 48'd0;

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      busy_q<=1'b0;
      mask_q<=0;
      x0_q<=0;y0_q<=0;x1_q<=0;y1_q<=0;
      color_q<=0;depth_q<=0;depth_op_q<=0;
      depth_write_q<=0;blend_enable_q<=0;alpha_q<=0;
      rsp_valid<=0;rsp_error<=0;rsp_pixel_written<=0;
      host_tag_q<=0;
    end else begin
      rsp_valid<=0;rsp_error<=0;rsp_pixel_written<=0;
      host_tag_q<=host_read_valid && host_read_ready;
      if(busy_q) begin
        // Exactly one in-flight two-lane RMW packet. BRAM data from
        // preceding read edge is consumed before the next request.
        busy_q<=0;
        rsp_valid<=1;
        rsp_error<=!read_beat_valid ||
                   (mem0_req_valid && !mem0_ready) ||
                   (mem1_req_valid && !mem1_ready);
        if(read_beat_valid && mem0_ready && mem1_ready)
          rsp_pixel_written<={mem1_req_valid,mem0_req_valid};
      end else if(fire_op) begin
        if(!valid_packet) begin
          rsp_valid<=1;
          rsp_error<=1;
        end else if(op_clear) begin
          rsp_valid<=1;
          rsp_error<=!mem0_ready || !mem1_ready;
          if(mem0_ready && mem1_ready)
            rsp_pixel_written<={lane1_valid,lane0_valid};
        end else begin
          busy_q<=1;
          mask_q<={lane1_valid,lane0_valid};
          x0_q<=lane0_x;y0_q<=lane0_y;
          x1_q<=lane1_x;y1_q<=lane1_y;
          color_q<=source_rgb;depth_q<=source_depth;
          depth_op_q<=depth_compare_op;
          depth_write_q<=depth_write;
          blend_enable_q<=blend_enable;
          alpha_q<=source_alpha;
        end
      end
    end
  end

  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       PIXELS!=FRAME_WIDTH*FRAME_HEIGHT ||
       PIXELS<2 || PIXELS>65536)
      $fatal(1,"P144 unsupported framebuffer geometry");
  end
endmodule
