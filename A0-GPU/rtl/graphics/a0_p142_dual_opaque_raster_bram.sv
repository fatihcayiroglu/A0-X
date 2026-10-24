`timescale 1ns/1ps
// P142 research: TWO adjacent row-major pixel positions evaluated per
// clock and independently written into P139/P138's two physical BRAM banks.
// ONLY fully opaque, depth-ALWAYS, depth-writing triangle fills are
// supported. Any mode requiring a previous pixel needs a future RMW
// hazard/latency pipeline. This is NOT a P102/P140 drop-in or an actual
// board, VRAM, PCIe, scanout, or programmable shader.
module a0_p142_dual_opaque_raster_bram #(
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
    input logic scissor_enable,
    input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
    output logic initialized,busy,
    output logic [1:0] pixel_writes,
    input logic host_read_valid,
    output logic host_read_ready,
    input logic [15:0] host_read_x,host_read_y,
    output logic host_rsp_valid,host_rsp_error,
    output logic [23:0] host_rsp_color,host_rsp_depth
);
    localparam logic [1:0] IDLE=2'd0, CLEAR=2'd1, DRAW=2'd2;
    logic [1:0] state;
    logic [ADDR_BITS-1:0] scan_index;
    logic [23:0] clear_color_q,clear_depth_q,draw_color_q,draw_depth_q;
    logic signed [15:0] ax,ay,bx,by,cx,cy;
    logic negative_winding;
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

    wire scissor0,scissor1;
    a0_p59_scissor_coverage gate0(
        .pixel_x(p0_x),.pixel_y(p0_y),
        .rect_x(scissor_x_q),.rect_y(scissor_y_q),
        .rect_width(scissor_w_q),.rect_height(scissor_h_q),
        .enable(scissor_enable_q),.covered(scissor0));
    a0_p59_scissor_coverage gate1(
        .pixel_x(p1_x),.pixel_y(p1_y),
        .rect_x(scissor_x_q),.rect_y(scissor_y_q),
        .rect_width(scissor_w_q),.rect_height(scissor_h_q),
        .enable(scissor_enable_q),.covered(scissor1));

    wire write0=(state==DRAW) && scissor0 &&
        hit_edges(edge0_q,edge1_q,edge2_q,
                  ax,ay,bx,by,cx,cy,negative_winding);
    wire write1=(state==DRAW) && lane1_present && scissor1 &&
        hit_edges(lane1_e0,lane1_e1,lane1_e2,
                  ax,ay,bx,by,cx,cy,negative_winding);

    wire clear_mode=(state==CLEAR);
    wire draw_mode=(state==DRAW);
    wire last_pair=(address0+32'd2>=PIXELS);
    wire req0_valid=clear_mode || write0 ||
                    (state==IDLE && host_read_valid && host_read_ready);
    wire req1_valid=(clear_mode && lane1_present) || write1;
    wire req0_write=clear_mode || write0;
    wire req1_write=clear_mode || write1;
    wire [15:0] req0_x=(state==IDLE) ? host_read_x : p0_x;
    wire [15:0] req0_y=(state==IDLE) ? host_read_y : p0_y;
    wire [47:0] packed_pixel=clear_mode ?
        {clear_color_q,clear_depth_q} : {draw_color_q,draw_depth_q};
    wire req0_ready,req1_ready;
    wire mem_rsp0_valid,mem_rsp0_error;
    wire [47:0] mem_rsp0_data;
    logic host_read_accepted_q;
    wire mem_rsp1_valid,mem_rsp1_error;
    wire [47:0] mem_rsp1_data;

    a0_p139_xy_dual_pixel_port #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) memory(
        .clk(clk),.rst_n(rst_n),
        .req0_valid(req0_valid),.req0_ready(req0_ready),
        .req0_write(req0_write),.req0_x(req0_x),.req0_y(req0_y),
        .req0_wdata(packed_pixel),
        .rsp0_valid(mem_rsp0_valid),.rsp0_error(mem_rsp0_error),
        .rsp0_rdata(mem_rsp0_data),
        .req1_valid(req1_valid),.req1_ready(req1_ready),
        .req1_write(req1_write),.req1_x(p1_x),.req1_y(p1_y),
        .req1_wdata(packed_pixel),
        .rsp1_valid(mem_rsp1_valid),.rsp1_error(mem_rsp1_error),
        .rsp1_rdata(mem_rsp1_data)
    );

    assign clear_ready=rst_n && state==IDLE && !host_read_valid;
    assign tri_ready=rst_n && initialized && state==IDLE &&
                     !clear_valid && !host_read_valid;
    assign busy=state!=IDLE;
    assign host_read_ready=rst_n && initialized && state==IDLE &&
                           !clear_valid && !tri_valid && req0_ready;
    // Do not expose the final draw/clear write acknowledgement as a
    // spurious host read response on transition back into IDLE.
    assign host_rsp_valid=host_read_accepted_q && mem_rsp0_valid;
    assign host_rsp_error=mem_rsp0_error;
    assign {host_rsp_color,host_rsp_depth}=mem_rsp0_data;

    wire pair_accepted=req0_ready && (!req1_valid || req1_ready);
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;
            scan_index<='0;
            initialized<=1'b0;
            host_read_accepted_q<=1'b0;
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
            host_read_accepted_q<=host_read_valid && host_read_ready;
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
                    scissor_enable_q<=scissor_enable;
                    scissor_x_q<=scissor_x;scissor_y_q<=scissor_y;
                    scissor_w_q<=scissor_w;scissor_h_q<=scissor_h;
                    scan_index<=0;
                    if(triangle_area==0)
                        tri_done<=1;
                    else
                        state<=DRAW;
                end
            end else if(pair_accepted) begin
                if(draw_mode) begin
                    pixel_writes[0]<=write0;
                    pixel_writes[1]<=write1;
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

    initial begin
        if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || FRAME_WIDTH>32767 ||
           FRAME_HEIGHT>32767 || PIXELS!=FRAME_WIDTH*FRAME_HEIGHT ||
           PIXELS<2 || PIXELS>65536 || ADDR_BITS<$clog2(PIXELS))
            $fatal(1,"P142 requires bounded >=2-pixel framebuffer");
    end
endmodule
