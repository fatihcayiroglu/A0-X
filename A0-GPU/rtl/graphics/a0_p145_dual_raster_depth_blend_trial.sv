`timescale 1ns/1ps
// P146 EXPERIMENTAL: overlap completed pair response and next pair issue.
// P145's P143 two row-major signed incremental edge
// coverage candidates feed P144's two-lane depth test + RGB alpha blend
// over real synchronous P139/P138 FPGA BRAM. Hold a pair until the
// registered P144 completion pulse before advancing either edge state;
// P144 read and write take separate beats. Supports ALWAYS/LESS/
// LESS_EQUAL depth, depth-write toggle, exact alpha, and scissor.
// Memory errors latch a reset-cleared FAULT. NOT a P102/P132 drop-in,
// physical VRAM, PCIe device, display renderer or programmable shader.
module a0_p145_dual_raster_depth_blend_trial #(
    parameter integer FRAME_WIDTH=4,
    parameter integer FRAME_HEIGHT=4,
    parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
    parameter integer ADDR_BITS=PIXELS<=1 ? 1 : $clog2(PIXELS)
)(
    input logic clk,rst_n,
    input logic clear_valid,
    output logic clear_ready,clear_done,
    input logic [23:0] clear_color,clear_depth,
    input logic tri_valid,
    output logic tri_ready,tri_done,
    input logic signed [15:0] x0,y0,x1,y1,x2,y2,
    input logic [23:0] tri_color,tri_depth,
    input logic [1:0] depth_compare_op,
    input logic depth_write,blend_enable,
    input logic [7:0] source_alpha,
    input logic scissor_enable,
    input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
    output logic initialized,busy,fault,
    output logic [1:0] pixel_writes,
    input logic host_read_valid,
    output logic host_read_ready,
    input logic [15:0] host_read_x,host_read_y,
    output logic host_rsp_valid,host_rsp_error,
    output logic [23:0] host_rsp_color,host_rsp_depth
);
    localparam logic [1:0] IDLE=2'd0, CLEAR=2'd1, DRAW=2'd2, FAULT=2'd3;
    logic [1:0] state;
    logic [ADDR_BITS-1:0] scan_index;
    logic [23:0] clear_color_q,clear_depth_q,draw_color_q,draw_depth_q;
    logic signed [15:0] ax,ay,bx,by,cx,cy;
    logic negative_winding;
    logic [1:0] depth_op_q;
    logic depth_write_q,blend_enable_q;
    logic [7:0] alpha_q;
    logic pair_inflight_q;
    logic scissor_enable_q;
    logic [15:0] scissor_x_q,scissor_y_q,scissor_w_q,scissor_h_q;

    // P143: three 36-bit raw oriented edge values for the first pixel
    // of a pair, and each row's x=0 origin. A second pixel is obtained
    // with a signed addition, including when a pair crosses row bounds.
    logic signed [35:0] edge0_q,edge1_q,edge2_q;
    logic signed [35:0] row0_q,row1_q,row2_q;
    logic signed [17:0] step_x0,step_x1,step_x2;
    logic signed [17:0] step_y0,step_y1,step_y2;
    logic signed [35:0] launch_e0,launch_e1,launch_e2;
    logic signed [17:0] launch_x0,launch_x1,launch_x2;
    logic signed [17:0] launch_y0,launch_y1,launch_y2;
    logic signed [35:0] lane1_e0,lane1_e1,lane1_e2;
    logic signed [35:0] lane1_row0,lane1_row1,lane1_row2;
    logic signed [35:0] next_e0,next_e1,next_e2;
    logic signed [35:0] next_row0,next_row1,next_row2;

    wire [31:0] address0=32'(scan_index);
    wire [31:0] address1=address0+32'd1;
    wire lane1_present=address1<PIXELS;
    wire [15:0] p0_x=16'(address0 % FRAME_WIDTH);
    wire [15:0] p0_y=16'(address0 / FRAME_WIDTH);
    wire [15:0] p1_x=16'(address1 % FRAME_WIDTH);
    wire [15:0] p1_y=16'(address1 / FRAME_WIDTH);

    function automatic logic signed [35:0] edge_at(
        input logic signed [15:0] vx0,vy0,vx1,vy1,
        input logic signed [16:0] px2,py2
    );
        logic signed [16:0] dx,dy;
        logic signed [17:0] rx,ry;
        logic signed [34:0] px,py;
        begin
            dx=$signed(vx1)-$signed(vx0);
            dy=$signed(vy1)-$signed(vy0);
            rx=$signed(px2)-($signed(vx0)*18'sd2);
            ry=$signed(py2)-($signed(vy0)*18'sd2);
            px=dx*ry;
            py=dy*rx;
            edge_at=$signed(px)-$signed(py);
        end
    endfunction
    function automatic logic top_left(
        input logic signed [15:0] xa,ya,xb,yb
    );
        top_left=(yb<ya) || ((yb==ya) && (xb>xa));
    endfunction
    function automatic logic hit_edges(
        input logic signed [35:0] e0,e1,e2,
        input logic signed [15:0] vx0,vy0,vx1,vy1,vx2,vy2,
        input logic negative
    );
        begin
            if(negative)
                hit_edges=((e0<0) || ((e0==0) && top_left(vx1,vy1,vx0,vy0))) &&
                          ((e1<0) || ((e1==0) && top_left(vx2,vy2,vx1,vy1))) &&
                          ((e2<0) || ((e2==0) && top_left(vx0,vy0,vx2,vy2)));
            else
                hit_edges=((e0>0) || ((e0==0) && top_left(vx0,vy0,vx1,vy1))) &&
                          ((e1>0) || ((e1==0) && top_left(vx1,vy1,vx2,vy2))) &&
                          ((e2>0) || ((e2==0) && top_left(vx2,vy2,vx0,vy0)));
        end
    endfunction

    logic signed [35:0] triangle_area;
    always_comb begin
        triangle_area=edge_at(x0,y0,x1,y1,
                              $signed(x2)*17'sd2,$signed(y2)*17'sd2);
        // Raw edge origins are independent of winding selection. Only
        // triangle setup uses multiplication; active scan uses adders.
        launch_e0=edge_at(x0,y0,x1,y1,17'sd1,17'sd1);
        launch_e1=edge_at(x1,y1,x2,y2,17'sd1,17'sd1);
        launch_e2=edge_at(x2,y2,x0,y0,17'sd1,17'sd1);
        launch_x0=-($signed(y1)-$signed(y0))*18'sd2;
        launch_x1=-($signed(y2)-$signed(y1))*18'sd2;
        launch_x2=-($signed(y0)-$signed(y2))*18'sd2;
        launch_y0=($signed(x1)-$signed(x0))*18'sd2;
        launch_y1=($signed(x2)-$signed(x1))*18'sd2;
        launch_y2=($signed(x0)-$signed(x2))*18'sd2;
    end
    always_comb begin
        // Step to lane1, which may be the next row's first pixel.
        if(p0_x==FRAME_WIDTH-1) begin
            lane1_row0=row0_q+step_y0;
            lane1_row1=row1_q+step_y1;
            lane1_row2=row2_q+step_y2;
            lane1_e0=lane1_row0;lane1_e1=lane1_row1;lane1_e2=lane1_row2;
        end else begin
            lane1_row0=row0_q;lane1_row1=row1_q;lane1_row2=row2_q;
            lane1_e0=edge0_q+step_x0;
            lane1_e1=edge1_q+step_x1;
            lane1_e2=edge2_q+step_x2;
        end
        // Step once more to the next pair's lane0 position; the
        // intermediate row start is used for odd-width crossings.
        if(p1_x==FRAME_WIDTH-1) begin
            next_row0=lane1_row0+step_y0;
            next_row1=lane1_row1+step_y1;
            next_row2=lane1_row2+step_y2;
            next_e0=next_row0;next_e1=next_row1;next_e2=next_row2;
        end else begin
            next_row0=lane1_row0;next_row1=lane1_row1;next_row2=lane1_row2;
            next_e0=lane1_e0+step_x0;
            next_e1=lane1_e1+step_x1;
            next_e2=lane1_e2+step_x2;
        end
    end

    // P146: P144's registered completion is visible after P144 is idle.
    // Launch the next pair on the same acceptance edge, except after
    // errors or at the final pair. Preserve the original edge updates.
    wire clear_mode=(state==CLEAR);
    wire draw_mode=(state==DRAW);
    wire last_pair=(address0+32'd2>=PIXELS);
    wire rmw_op_ready,rmw_rsp_valid,rmw_rsp_error;
    wire [1:0] rmw_pixel_writes;
    wire lookahead_issue=(clear_mode || draw_mode) && pair_inflight_q &&
                           rmw_rsp_valid && !rmw_rsp_error && !last_pair &&
                           rmw_op_ready;
    wire [31:0] issue_address0=address0+(lookahead_issue?32'd2:32'd0);
    wire [31:0] issue_address1=issue_address0+32'd1;
    wire issue_lane1_present=issue_address1<PIXELS;
    wire [15:0] issue_x0=16'(issue_address0%FRAME_WIDTH);
    wire [15:0] issue_y0=16'(issue_address0/FRAME_WIDTH);
    wire [15:0] issue_x1=16'(issue_address1%FRAME_WIDTH);
    wire [15:0] issue_y1=16'(issue_address1/FRAME_WIDTH);
    wire signed [35:0] issue_e0=lookahead_issue?next_e0:edge0_q;
    wire signed [35:0] issue_e1=lookahead_issue?next_e1:edge1_q;
    wire signed [35:0] issue_e2=lookahead_issue?next_e2:edge2_q;
    wire signed [35:0] issue_row0=lookahead_issue?next_row0:row0_q;
    wire signed [35:0] issue_row1=lookahead_issue?next_row1:row1_q;
    wire signed [35:0] issue_row2=lookahead_issue?next_row2:row2_q;
    wire signed [35:0] issue_lane1_e0=
         (issue_x0==FRAME_WIDTH-1)?(issue_row0+step_y0):(issue_e0+step_x0);
    wire signed [35:0] issue_lane1_e1=
         (issue_x0==FRAME_WIDTH-1)?(issue_row1+step_y1):(issue_e1+step_x1);
    wire signed [35:0] issue_lane1_e2=
         (issue_x0==FRAME_WIDTH-1)?(issue_row2+step_y2):(issue_e2+step_x2);

    wire scissor0,scissor1;
    a0_p59_scissor_coverage gate0(
        .pixel_x(issue_x0),.pixel_y(issue_y0),
        .rect_x(scissor_x_q),.rect_y(scissor_y_q),
        .rect_width(scissor_w_q),.rect_height(scissor_h_q),
        .enable(scissor_enable_q),.covered(scissor0));
    a0_p59_scissor_coverage gate1(
        .pixel_x(issue_x1),.pixel_y(issue_y1),
        .rect_x(scissor_x_q),.rect_y(scissor_y_q),
        .rect_width(scissor_w_q),.rect_height(scissor_h_q),
        .enable(scissor_enable_q),.covered(scissor1));

    wire write0=(state==DRAW) && scissor0 &&
        hit_edges(issue_e0,issue_e1,issue_e2,
                  ax,ay,bx,by,cx,cy,negative_winding);
    wire write1=(state==DRAW) && issue_lane1_present && scissor1 &&
        hit_edges(issue_lane1_e0,issue_lane1_e1,issue_lane1_e2,
                  ax,ay,bx,by,cx,cy,negative_winding);

    wire rmw_host_ready;
    wire eligible_host=(state==IDLE) && !clear_valid && !tri_valid;
    // The P144 packet interface serializes reads and simultaneous
    // conditional dual writes. Two adjacent linear pixels are opposite
    // bank parity even when an odd-width frame crosses a row boundary.
    a0_p144_dual_depth_blend_rmw #(
      .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) memory(
      .clk(clk),.rst_n(rst_n),
      .op_valid((state==CLEAR || state==DRAW) &&
                (!pair_inflight_q || lookahead_issue)),
      .op_ready(rmw_op_ready),.op_clear(clear_mode),
      .lane0_valid(clear_mode || write0),
      .lane1_valid((clear_mode && issue_lane1_present) || write1),
      .lane0_x(issue_x0),.lane0_y(issue_y0),
      .lane1_x(issue_x1),.lane1_y(issue_y1),
      .source_rgb(clear_mode ? clear_color_q : draw_color_q),
      .source_depth(clear_mode ? clear_depth_q : draw_depth_q),
      .depth_compare_op(depth_op_q),.depth_write(depth_write_q),
      .blend_enable(blend_enable_q),.source_alpha(alpha_q),
      .rsp_valid(rmw_rsp_valid),.rsp_error(rmw_rsp_error),
      .rsp_pixel_written(rmw_pixel_writes),
      .host_read_valid(host_read_valid && eligible_host),
      .host_read_ready(rmw_host_ready),
      .host_read_x(host_read_x),.host_read_y(host_read_y),
      .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
      .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
    );

    assign clear_ready=rst_n && state==IDLE && !host_read_valid;
    assign tri_ready=rst_n && initialized && state==IDLE &&
                     !clear_valid && !host_read_valid;
    assign busy=state!=IDLE;
    assign host_read_ready=rst_n && initialized && eligible_host && rmw_host_ready;
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;
            scan_index<='0;
            initialized<=1'b0;
            pair_inflight_q<=1'b0;
            fault<=1'b0;
            depth_op_q<=0;depth_write_q<=0;blend_enable_q<=0;alpha_q<=0;
            clear_done<=1'b0;tri_done<=1'b0;pixel_writes<='0;
            clear_color_q<='0;clear_depth_q<='0;
            draw_color_q<='0;draw_depth_q<='0;
            ax<=0;ay<=0;bx<=0;by<=0;cx<=0;cy<=0;
            negative_winding<=1'b0;
            edge0_q<=0;edge1_q<=0;edge2_q<=0;
            row0_q<=0;row1_q<=0;row2_q<=0;
            step_x0<=0;step_x1<=0;step_x2<=0;
            step_y0<=0;step_y1<=0;step_y2<=0;
            scissor_enable_q<=0;
            scissor_x_q<=0;scissor_y_q<=0;
            scissor_w_q<=0;scissor_h_q<=0;
        end else begin
            clear_done<=0;
            tri_done<=0;
            pixel_writes<=0;
            // P144 independently tags accepted host reads; no internal write
            // completion is exposed on the host response channel.
            if(state==IDLE) begin
                if(clear_valid && clear_ready) begin
                    clear_color_q<=clear_color;
                    clear_depth_q<=clear_depth;
                    initialized<=0;
                    scan_index<=0;
                    state<=CLEAR;
                end else if(tri_valid && tri_ready) begin
                    ax<=x0;ay<=y0;bx<=x1;by<=y1;cx<=x2;cy<=y2;
                    negative_winding<=triangle_area<0;
                    edge0_q<=launch_e0;edge1_q<=launch_e1;edge2_q<=launch_e2;
                    row0_q<=launch_e0;row1_q<=launch_e1;row2_q<=launch_e2;
                    step_x0<=launch_x0;step_x1<=launch_x1;step_x2<=launch_x2;
                    step_y0<=launch_y0;step_y1<=launch_y1;step_y2<=launch_y2;
                    draw_color_q<=tri_color;draw_depth_q<=tri_depth;
                    depth_op_q<=depth_compare_op;
                    depth_write_q<=depth_write;
                    blend_enable_q<=blend_enable;
                    alpha_q<=source_alpha;
                    scissor_enable_q<=scissor_enable;
                    scissor_x_q<=scissor_x;scissor_y_q<=scissor_y;
                    scissor_w_q<=scissor_w;scissor_h_q<=scissor_h;
                    scan_index<=0;
                    if(triangle_area==0)
                        tri_done<=1;
                    else
                        state<=DRAW;
                end
            end else if(state==CLEAR || state==DRAW) begin
                if(!pair_inflight_q && rmw_op_ready)
                    pair_inflight_q<=1'b1;
                if(pair_inflight_q && rmw_rsp_valid) begin
                    pair_inflight_q<=lookahead_issue;
                    if(rmw_rsp_error) begin
                        // Never skip/advance a failed memory operation.
                        // Fail closed and latch a reset-recoverable fault.
                        state<=FAULT;
                        fault<=1'b1;
                    end else begin
                        if(draw_mode) begin
                            pixel_writes<=rmw_pixel_writes;
                            if(!last_pair) begin
                                edge0_q<=next_e0;edge1_q<=next_e1;edge2_q<=next_e2;
                                row0_q<=next_row0;row1_q<=next_row1;row2_q<=next_row2;
                            end
                        end
                        if(last_pair) begin
                            scan_index<=0;
                            state<=IDLE;
                            if(clear_mode) begin
                                initialized<=1;
                                clear_done<=1;
                            end else tri_done<=1;
                        end else
                            scan_index<=ADDR_BITS'(address0+32'd2);
                    end
                end
            end
        end
    end

    initial begin
        if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || FRAME_WIDTH>32767 ||
           FRAME_HEIGHT>32767 || PIXELS!=FRAME_WIDTH*FRAME_HEIGHT ||
           PIXELS<2 || PIXELS>65536 || ADDR_BITS<$clog2(PIXELS))
            $fatal(1,"P142 requires bounded >=2-pixel framebuffer");
    end
endmodule
