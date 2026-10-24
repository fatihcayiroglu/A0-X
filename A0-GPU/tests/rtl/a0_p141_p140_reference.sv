`timescale 1ns/1ps
// P140 RESEARCH TRIAL: P136 triangle raster + P59 scissor + P68 depth +
// P135 RGB blend, now backed by ACTUAL P139/P138 synchronous FPGA BRAM.
// One color/depth pixel read-modify-write at a time. Stalls the raster over
// a memory read edge and commits on a later write edge when depth passes.
// Host debug reads are synchronous ready/valid, not legacy P102 async reads.
// NOT a P102 drop-in, production VRAM or 2 shaded pixels/clock renderer.
module a0_p140_raster_bram_trial_p141_reference #(
    parameter integer FRAME_WIDTH=4,
    parameter integer FRAME_HEIGHT=4,
    parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
)(
    input logic clk,rst_n,
    input logic clear_valid,
    output logic clear_ready,
    input logic [23:0] clear_color,clear_depth,
    output logic clear_done,
    input logic tri_valid,
    output logic tri_ready,
    input logic signed [15:0] x0,y0,x1,y1,x2,y2,
    input logic [23:0] tri_color,tri_depth,
    input logic [1:0] depth_compare_op,
    input logic depth_write,blend_enable,
    input logic [7:0] source_alpha,
    input logic scissor_enable,
    input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
    output logic tri_done,initialized,busy,pixel_wrote,
    input logic host_read_valid,
    output logic host_read_ready,
    input logic [15:0] host_read_x,host_read_y,
    output logic host_rsp_valid,host_rsp_error,
    output logic [23:0] host_rsp_color,host_rsp_depth
);
    logic clearing;
    logic [15:0] clear_x_q,clear_y_q;
    logic [23:0] clear_color_q,clear_depth_q;
    logic [23:0] tri_color_q,tri_depth_q;
    logic [1:0] depth_op_q;
    logic depth_write_q,blend_enable_q,scissor_enable_q;
    logic [7:0] source_alpha_q;
    logic [15:0] scissor_x_q,scissor_y_q,scissor_w_q,scissor_h_q;

    logic raster_ready,raster_pixel_valid,raster_done,raster_pixel_ready;
    logic [15:0] raster_x,raster_y;
    logic scissor_pass,depth_pass;
    logic [23:0] blended_color;
    // 0 = issue BRAM read for a covered pixel; 1 = commit/reject it.
    logic waiting_commit;
    logic mem_req0_valid,mem_req0_write,mem_req0_ready;
    logic [15:0] mem_req0_x,mem_req0_y;
    logic [47:0] mem_req0_data;
    logic mem_rsp0_valid,mem_rsp0_error;
    logic [47:0] mem_rsp0_data;
    logic [23:0] stored_color,stored_depth;
    logic take_read,take_write,can_advance,clear_last;
    wire launch_clear=clear_valid && clear_ready;
    wire launch_tri=tri_valid && tri_ready;

    assign clear_ready=rst_n && !clearing && raster_ready && !waiting_commit;
    assign tri_ready=rst_n && initialized && !clearing && !clear_valid &&
                     raster_ready && !waiting_commit;
    assign busy=clearing || !raster_ready || waiting_commit;
    assign tri_done=rst_n && raster_done;
    assign clear_last=(clear_x_q==FRAME_WIDTH-1 &&
                       clear_y_q==FRAME_HEIGHT-1);

    a0_triangle_coverage_p38 #(
      .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) raster (
      .clk(clk),.rst_n(rst_n),.tri_valid(launch_tri),
      .tri_ready(raster_ready),
      .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
      .pixel_valid(raster_pixel_valid),.pixel_ready(raster_pixel_ready),
      .pixel_x(raster_x),.pixel_y(raster_y),.done(raster_done)
    );

    a0_p59_scissor_coverage scissor (
      .pixel_x(raster_x),.pixel_y(raster_y),
      .rect_x(scissor_x_q),.rect_y(scissor_y_q),
      .rect_width(scissor_w_q),.rect_height(scissor_h_q),
      .enable(scissor_enable_q),.covered(scissor_pass)
    );
    assign stored_color=mem_rsp0_data[47:24];
    assign stored_depth=mem_rsp0_data[23:0];
    a0_p68_depth_compare depth_test (
      .incoming_depth(tri_depth_q),.stored_depth(stored_depth),
      .compare_op(depth_op_q),
      .candidate_valid(raster_pixel_valid && waiting_commit &&
                       mem_rsp0_valid && !mem_rsp0_error && scissor_pass),
      .accept(depth_pass)
    );
    a0_p70_rgb_blend blend (
      .source_rgb(tri_color_q),.destination_rgb(stored_color),
      .source_alpha(source_alpha_q),.blend_enable(blend_enable_q),
      .output_rgb(blended_color)
    );

    assign take_read=!clearing && !waiting_commit && raster_pixel_valid;
    assign take_write=!clearing && waiting_commit &&
                      raster_pixel_valid && mem_rsp0_valid &&
                      !mem_rsp0_error && depth_pass;
    assign mem_req0_valid=clearing || take_read || take_write;
    assign mem_req0_write=clearing || take_write;
    assign mem_req0_x=clearing ? clear_x_q : raster_x;
    assign mem_req0_y=clearing ? clear_y_q : raster_y;
    assign mem_req0_data=clearing ? {clear_color_q,clear_depth_q} :
                     {blended_color,depth_write_q ? tri_depth_q : stored_depth};
    // Keep covered scan position stable during memory read. Reject a
    // depth-failed pixel without a write, but advance after read response.
    assign can_advance=waiting_commit && mem_rsp0_valid &&
                       !mem_rsp0_error && (!depth_pass || mem_req0_ready);
    assign raster_pixel_ready=can_advance;

    a0_p139_xy_dual_pixel_port #(
      .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) memory (
      .clk(clk),.rst_n(rst_n),
      .req0_valid(mem_req0_valid),.req0_ready(mem_req0_ready),
      .req0_write(mem_req0_write),.req0_x(mem_req0_x),
      .req0_y(mem_req0_y),.req0_wdata(mem_req0_data),
      .rsp0_valid(mem_rsp0_valid),.rsp0_error(mem_rsp0_error),
      .rsp0_rdata(mem_rsp0_data),
      .req1_valid(host_read_valid),.req1_ready(host_read_ready),
      .req1_write(1'b0),.req1_x(host_read_x),.req1_y(host_read_y),
      .req1_wdata(48'd0),
      .rsp1_valid(host_rsp_valid),.rsp1_error(host_rsp_error),
      .rsp1_rdata({host_rsp_color,host_rsp_depth})
    );

    always_ff @(posedge clk) begin
      if(!rst_n) begin
        clearing<=0;
        clear_x_q<=0;clear_y_q<=0;
        clear_color_q<=0;clear_depth_q<=0;
        clear_done<=0;pixel_wrote<=0;initialized<=0;
        waiting_commit<=0;
        tri_color_q<=0;tri_depth_q<=0;depth_op_q<=0;
        depth_write_q<=0;blend_enable_q<=0;scissor_enable_q<=0;
        source_alpha_q<=0;
        scissor_x_q<=0;scissor_y_q<=0;scissor_w_q<=0;scissor_h_q<=0;
      end else begin
        clear_done<=0;
        pixel_wrote<=0;
        if(clearing && mem_req0_ready) begin
          if(clear_last) begin
            clearing<=0;
            initialized<=1;
            clear_done<=1;
            clear_x_q<=0;clear_y_q<=0;
          end else if(clear_x_q==FRAME_WIDTH-1) begin
            clear_x_q<=0;clear_y_q<=clear_y_q+1'b1;
          end else clear_x_q<=clear_x_q+1'b1;
        end else if(launch_clear) begin
          clearing<=1;initialized<=0;
          clear_color_q<=clear_color;clear_depth_q<=clear_depth;
          clear_x_q<=0;clear_y_q<=0;
        end else if(launch_tri) begin
          tri_color_q<=tri_color;tri_depth_q<=tri_depth;
          depth_op_q<=depth_compare_op;
          depth_write_q<=depth_write;
          blend_enable_q<=blend_enable;
          source_alpha_q<=source_alpha;
          scissor_enable_q<=scissor_enable;
          scissor_x_q<=scissor_x;scissor_y_q<=scissor_y;
          scissor_w_q<=scissor_w;scissor_h_q<=scissor_h;
        end

        if(take_read && mem_req0_ready)
          waiting_commit<=1;
        if(waiting_commit && can_advance) begin
          if(take_write)pixel_wrote<=1;
          waiting_commit<=0;
        end
      end
    end

    initial begin
      if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
         PIXELS!=FRAME_WIDTH*FRAME_HEIGHT || PIXELS<2 ||
         PIXELS>65536 || FRAME_WIDTH>32767 || FRAME_HEIGHT>32767)
        $fatal(1,"P140 unsupported research framebuffer");
    end
endmodule
