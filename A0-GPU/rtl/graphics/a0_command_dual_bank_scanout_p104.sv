`timescale 1ns/1ps
// P104 EXPERIMENTAL: P43 serialized commands -> TWO P102 color/depth banks
// -> P42 one-shot scanout. After a PRESENT bank flip, commands can render
// the opposite bank WHILE the front frame drains. PENDING swaps wait for the
// prior frame's last accepted beat; no front-buffer writes / mixed frames.
// This is NOT an external VRAM, physical display output, or qualified RTL.
module a0_command_dual_bank_scanout_p104 #(
    parameter int FRAME_WIDTH=8,
    parameter int FRAME_HEIGHT=8,
    parameter int PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
    parameter int ADDR_BITS=(PIXELS<=1?1:$clog2(PIXELS)),
    parameter int TAG_BITS=16
)(
    input logic clk,rst_n,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [1:0] cmd_opcode,
    input logic [TAG_BITS-1:0] cmd_tag,
    input logic [23:0] cmd_color,cmd_depth,
    input logic signed [15:0] cmd_x0,cmd_y0,cmd_x1,cmd_y1,cmd_x2,cmd_y2,
    input logic [1:0] cmd_depth_op,
    input logic cmd_depth_write,cmd_blend_enable,
    input logic [7:0] cmd_alpha,
    input logic cmd_scissor_enable,
    input logic [15:0] cmd_scissor_x,cmd_scissor_y,cmd_scissor_w,cmd_scissor_h,
    output logic completion_valid,
    input logic completion_ready,
    output logic [TAG_BITS-1:0] completion_tag,
    output logic completion_error,
    output logic command_busy,
    input logic scan_enable,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x,pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame,end_of_line,end_of_frame,frame_done,
    output logic render_initialized,render_busy,
    output logic display_initialized,display_bank,render_bank,
    output logic swap_pending,scan_active
);
    logic clear_valid,clear_ready,clear_done;
    logic tri_valid,tri_ready,tri_done;
    logic swap_valid,swap_ready,swap_done;
    logic [23:0] clear_color,tri_color;
    logic signed [15:0] x0,y0,x1,y1,x2,y2;
    logic [23:0] depth_q;
    logic [1:0] depth_op_q;
    logic depth_write_q,blend_q,scissor_enable_q;
    logic [7:0] alpha_q;
    logic [15:0] scissor_x_q,scissor_y_q,scissor_w_q,scissor_h_q;
    logic [1:0] initialized,backend_busy,bank_clear_ready,bank_tri_ready;
    logic [1:0] bank_clear_done,bank_tri_done,bank_read_valid;
    logic [23:0] bank_read_color [0:1];
    logic [23:0] bank_read_depth [0:1];
    logic [1:0] bank_pixel_wrote;
    logic [15:0] read_x,read_y;
    logic scan_read_en,scan_read_valid,scan_frame_done;
    logic [ADDR_BITS-1:0] scan_read_addr;
    logic [23:0] scan_read_data;
    logic swap_pending_q,scan_active_q,display_bank_q;
    logic swap_accept,swap_commit,scan_running;

    assign display_bank=display_bank_q;
    assign render_bank=~display_bank_q;
    assign render_initialized=initialized[render_bank];
    assign display_initialized=initialized[display_bank];
    assign render_busy=backend_busy[render_bank];
    assign swap_pending=swap_pending_q;
    assign scan_active=scan_active_q;
    // Back bank is accessible during a front-bank scan. P43 serializes
    // commands and will not accept a new command before response retirement.
    assign clear_ready=rst_n && !swap_pending_q && bank_clear_ready[render_bank];
    assign clear_done=bank_clear_done[render_bank];
    assign tri_ready=rst_n && !swap_pending_q && bank_tri_ready[render_bank];
    assign tri_done=bank_tri_done[render_bank];
    // Permission is needed only for accepting PRESENT. Once accepted, neither
    // withdrawing scan_enable nor pixel_ready can cause a partial bank flip.
    assign swap_ready=rst_n && scan_enable && !swap_pending_q &&
                      render_initialized && !render_busy;
    assign swap_accept=swap_valid && swap_ready;
    // The scanout must not issue a speculative next-frame read on the
    // cycle that frame_done is observed; drop enable for that single cycle.
    assign scan_running=scan_active_q && !scan_frame_done;
    assign swap_commit=rst_n && swap_pending_q &&
                       (!scan_active_q || scan_frame_done);
    assign read_x=16'(int'(scan_read_addr)%FRAME_WIDTH);
    assign read_y=16'(int'(scan_read_addr)/FRAME_WIDTH);

    a0_graphics_command_frontend_p43 #(.TAG_BITS(TAG_BITS)) frontend (
        .clk(clk),.rst_n(rst_n),.render_initialized(render_initialized),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_opcode(cmd_opcode),
        .cmd_tag(cmd_tag),.cmd_color(cmd_color),
        .cmd_x0(cmd_x0),.cmd_y0(cmd_y0),.cmd_x1(cmd_x1),.cmd_y1(cmd_y1),
        .cmd_x2(cmd_x2),.cmd_y2(cmd_y2),
        .completion_valid(completion_valid),.completion_ready(completion_ready),
        .completion_tag(completion_tag),.completion_error(completion_error),
        .busy(command_busy),
        .clear_valid(clear_valid),.clear_ready(clear_ready),.clear_done(clear_done),
        .clear_color(clear_color),
        .tri_valid(tri_valid),.tri_ready(tri_ready),.tri_done(tri_done),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
        .tri_color(tri_color),
        .swap_valid(swap_valid),.swap_ready(swap_ready),.swap_done(swap_done)
    );

    genvar b;
    generate
        for(b=0;b<2;b=b+1) begin : gen_color_depth_bank
            wire own_back=(render_bank==1'(b));
            a0_triangle_scissor_depth_blend_p102 #(
                .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
                .PIXELS(PIXELS),.ADDR_BITS(ADDR_BITS)
            ) buffer (
                .clk(clk),.rst_n(rst_n),
                .clear_valid(clear_valid && clear_ready && own_back),
                .clear_ready(bank_clear_ready[b]),.clear_color(clear_color),
                .clear_depth(depth_q),.clear_done(bank_clear_done[b]),
                .tri_valid(tri_valid && tri_ready && own_back),
                .tri_ready(bank_tri_ready[b]),
                .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
                .tri_color(tri_color),.tri_depth(depth_q),
                .depth_compare_op(depth_op_q),.depth_write(depth_write_q),
                .blend_enable(blend_q),.source_alpha(alpha_q),
                .scissor_enable(scissor_enable_q),
                .scissor_x(scissor_x_q),.scissor_y(scissor_y_q),
                .scissor_w(scissor_w_q),.scissor_h(scissor_h_q),
                .tri_done(bank_tri_done[b]),.initialized(initialized[b]),
                .busy(backend_busy[b]),.read_x(read_x),.read_y(read_y),
                .read_valid(bank_read_valid[b]),
                .read_color(bank_read_color[b]),.read_depth(bank_read_depth[b]),
                .pixel_wrote(bank_pixel_wrote[b])
            );
        end
    endgenerate

    // The P102 debug read is asynchronous. This register is an adapter to
    // P42's one-outstanding-read scan protocol, NOT a physical memory model.
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            scan_read_valid<=1'b0;
            scan_read_data<='0;
            depth_q<=24'h0;depth_op_q<=2'h0;
            depth_write_q<=1'b0;blend_q<=1'b0;alpha_q<='0;
            scissor_enable_q<=1'b0;
            scissor_x_q<='0;scissor_y_q<='0;
            scissor_w_q<='0;scissor_h_q<='0;
            display_bank_q<=1'b0;
            swap_pending_q<=1'b0;
            scan_active_q<=1'b0;
            swap_done<=1'b0;
        end else begin
            scan_read_valid<=scan_read_en && bank_read_valid[display_bank_q];
            if(scan_read_en && bank_read_valid[display_bank_q])
                scan_read_data<=bank_read_color[display_bank_q];
            swap_done<=1'b0;
            if(swap_commit) begin
                display_bank_q<=~display_bank_q;
                swap_pending_q<=1'b0;
                scan_active_q<=1'b1;
                swap_done<=1'b1;
            end else begin
                if(swap_accept) swap_pending_q<=1'b1;
                if(scan_frame_done) scan_active_q<=1'b0;
            end
            if(cmd_valid && cmd_ready) begin
                depth_q<=cmd_depth;depth_op_q<=cmd_depth_op;
                depth_write_q<=cmd_depth_write;blend_q<=cmd_blend_enable;
                alpha_q<=cmd_alpha;scissor_enable_q<=cmd_scissor_enable;
                scissor_x_q<=cmd_scissor_x;scissor_y_q<=cmd_scissor_y;
                scissor_w_q<=cmd_scissor_w;scissor_h_q<=cmd_scissor_h;
            end
        end
    end
    a0_sync_frame_scanout_p42 #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXELS(PIXELS),.ADDR_BITS(ADDR_BITS)
    ) scanout (
        .clk(clk),.rst_n(rst_n),.enable(scan_running),
        .framebuffer_initialized(display_initialized),
        .read_en(scan_read_en),.read_addr(scan_read_addr),
        .read_valid(scan_read_valid),.read_data(scan_read_data),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_color(pixel_color),
        .start_of_frame(start_of_frame),.end_of_line(end_of_line),
        .end_of_frame(end_of_frame),.frame_done(scan_frame_done)
    );
    assign frame_done=scan_frame_done;
    initial begin
        if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || FRAME_WIDTH>32767 ||
           FRAME_HEIGHT>32767 || PIXELS != FRAME_WIDTH*FRAME_HEIGHT ||
           PIXELS>65536 || ADDR_BITS<(PIXELS<=1?1:$clog2(PIXELS)))
            $fatal(1,"P104 invalid framebuffer dimensions");
    end
endmodule
