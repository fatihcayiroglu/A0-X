`timescale 1ns/1ps
// A0-X P41 EXPERIMENTAL: independently owned render and scanout banks.
//
// Two instances of the P39 local RGB888 framebuffer are deliberately retained
// to prevent scanout reads and rasterizer writes from sharing a bank. The
// displayed bank never receives CLEAR/TRIANGLE commands. The hidden bank is
// exclusively writable until a swap request is accepted.
//
// Swaps are accepted only with a completed and idle hidden framebuffer. Once
// accepted, that bank is frozen until commit. A commit occurs after the last
// pixel of the current displayed frame has transferred, or immediately while
// display scanning is disabled or no display frame exists yet. A commit gates
// P40 enable LOW for one cycle: P40 drops any prefetched next-frame pixel,
// resets read coordinates and restarts the next frame at (0,0) on the new bank.
//
// This is on-chip demonstrator RTL, NOT DRAM arbitration, VRAM, a display PHY,
// VSync timing, tear-free physical monitor output, or production GPU integration.
module a0_triangle_double_buffer_display_p41 #(
    parameter int FRAME_WIDTH  = 8,
    parameter int FRAME_HEIGHT = 8
) (
    input  logic clk,
    input  logic rst_n,

    // Commands are routed only to the current hidden/render bank.
    input  logic clear_valid,
    output logic clear_ready,
    input  logic [23:0] clear_color,
    output logic clear_done,
    input  logic tri_valid,
    output logic tri_ready,
    input  logic signed [15:0] x0, y0, x1, y1, x2, y2,
    input  logic [23:0] tri_color,
    output logic tri_done,
    output logic render_initialized,
    output logic render_busy,

    // To display the completed hidden frame, request one swap handshake.
    // swap_ready is low while raster/clear is active or another swap is pending.
    input  logic swap_valid,
    output logic swap_ready,
    output logic swap_pending,
    output logic swap_done,
    output logic display_bank,
    output logic render_bank,
    output logic display_initialized,

    // RGB888 ready/valid stream from the P40 scanout module.
    input  logic scan_enable,
    output logic pixel_valid,
    input  logic pixel_ready,
    output logic [15:0] pixel_x,
    output logic [15:0] pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame,
    output logic end_of_line,
    output logic end_of_frame,
    output logic frame_done
);
    logic display_bank_q;
    logic swap_pending_q;
    logic [1:0] fb_initialized;
    logic [1:0] fb_busy;
    logic [1:0] fb_clear_ready;
    logic [1:0] fb_tri_ready;
    logic [1:0] fb_clear_done;
    logic [1:0] fb_tri_done;
    logic [23:0] fb_read_color [0:1];
    logic [15:0] scan_read_x, scan_read_y;
    logic swap_accept, swap_commit;
    logic scan_active;

    // Reset selects bank 0 as a (not-yet-initialized) front, bank 1 as back.
    assign display_bank = display_bank_q;
    assign render_bank = ~display_bank_q;
    assign display_initialized = fb_initialized[display_bank_q];
    assign render_initialized  = fb_initialized[~display_bank_q];
    assign render_busy = fb_busy[~display_bank_q];

    assign clear_ready = rst_n && !swap_pending_q && fb_clear_ready[~display_bank_q];
    assign tri_ready   = rst_n && !swap_pending_q && fb_tri_ready[~display_bank_q];
    assign clear_done  = fb_clear_done[~display_bank_q];
    assign tri_done    = fb_tri_done[~display_bank_q];

    // Commands and SWAP are mutually exclusive within one acceptance cycle.
    // No implicit frame completion: the command producer owns that decision.
    assign swap_ready = rst_n && !swap_pending_q && render_initialized &&
                        !render_busy && !clear_valid && !tri_valid;
    assign swap_accept = swap_valid && swap_ready;
    assign swap_pending = swap_pending_q;

    // Holding the original source bank stable until the accepted end-of-frame
    // keeps the current frame immutable during all ready/valid stalls.
    // If scan_enable goes low (or no front exists), P40 aborts its partial
    // transfer and we can safely commit immediately.
    assign swap_commit = rst_n && swap_pending_q &&
                         (!scan_enable || !display_initialized || frame_done);
    assign scan_active = scan_enable && !swap_commit;

    // Exactly one private P39 framebuffer can accept render commands.
    // No bank ever receives write commands while it is selected for scanout.
    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : gen_framebank
            wire own_render = (render_bank == 1'(g));
            wire clear_fire = clear_valid && clear_ready && own_render;
            wire tri_fire = tri_valid && tri_ready && own_render;
            a0_triangle_framebuffer_p39 #(
                .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
            ) framebuffer (
                .clk(clk), .rst_n(rst_n),
                .clear_valid(clear_fire), .clear_ready(fb_clear_ready[g]),
                .clear_color(clear_color), .clear_done(fb_clear_done[g]),
                .tri_valid(tri_fire), .tri_ready(fb_tri_ready[g]),
                .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
                .tri_color(tri_color), .tri_done(fb_tri_done[g]),
                .read_x(scan_read_x), .read_y(scan_read_y),
                .read_color(fb_read_color[g]),
                .initialized(fb_initialized[g]), .busy(fb_busy[g])
            );
        end
    endgenerate

    a0_frame_scanout_p40 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
    ) scanout (
        .clk(clk), .rst_n(rst_n), .enable(scan_active),
        .framebuffer_initialized(display_initialized),
        .read_x(scan_read_x), .read_y(scan_read_y),
        .read_color(fb_read_color[display_bank_q]),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_color(pixel_color),
        .start_of_frame(start_of_frame), .end_of_line(end_of_line),
        .end_of_frame(end_of_frame), .frame_done(frame_done)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            display_bank_q <= 1'b0;
            swap_pending_q <= 1'b0;
            swap_done <= 1'b0;
        end else begin
            swap_done <= 1'b0;
            if (swap_commit) begin
                display_bank_q <= ~display_bank_q;
                swap_pending_q <= 1'b0;
                swap_done <= 1'b1;
            end else if (swap_accept) begin
                swap_pending_q <= 1'b1;
            end
        end
    end
endmodule
