`timescale 1ns/1ps
// P113 DEVELOPMENT: progress-aware PRESENT monitoring; P106 datapath preserved.
// P106 DEVELOPMENT: P44 bytes -> P45 validated command -> P104 dual bank
// -> P47 accepted-pixel integrity -> P48 telemetry, and P46 command results
// through P49 packet-atomic fair mux. Logical ready/valid byte interface ONLY.
// P44 V1 remains legacy; P106 V2 only extends TRIANGLE with fragment state.
// No PCIe, DMA, VRAM, video PHY, physical GPU or qualified RTL here.
module a0_host_fragment_dual_bank_diagnostics_p113 #(
    parameter int MAX_COMMAND_WAIT_CYCLES=4096,
    parameter int FRAME_WIDTH=8,
    parameter int FRAME_HEIGHT=8,
    parameter int PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
    parameter int ADDR_BITS=(PIXELS<=1?1:$clog2(PIXELS))
)(
    input logic clk,rst_n,
    input logic rx_valid,
    output logic rx_ready,
    input logic [7:0] rx_byte,
    output logic tx_valid,
    input logic tx_ready,
    output logic [7:0] tx_byte,
    input logic scan_enable,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x,pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame,end_of_line,end_of_frame,frame_done,
    output logic display_bank,render_bank,display_initialized,render_initialized,
    output logic render_busy,swap_pending,scan_active,
    output logic [31:0] invalid_frame_count,
    output logic frame_crc_valid,frame_crc_error,
    output logic [31:0] frame_crc32,
    output logic [31:0] good_frames,bad_frames,aborted_frames,
    output logic [31:0] telemetry_dropped_frames,
    output logic diagnostic_fault,diagnostic_pending,
    output logic [15:0] diagnostic_active_tag,diagnostic_last_fault_tag,
    output logic [31:0] diagnostic_timeouts,diagnostic_tag_mismatches,
    output logic [31:0] diagnostic_protocol_faults,diagnostic_completed,
    output logic [31:0] diagnostic_present_pixels
);
    logic cmd_valid,cmd_ready;
    logic [1:0] cmd_opcode;
    logic [15:0] cmd_tag;
    logic [23:0] cmd_color,cmd_depth;
    logic [1:0] cmd_depth_op;
    logic cmd_depth_write,cmd_blend_enable,cmd_scissor_enable;
    logic [7:0] cmd_alpha;
    logic [15:0] cmd_scissor_x,cmd_scissor_y,cmd_scissor_w,cmd_scissor_h;
    logic signed [15:0] x0,y0,x1,y1,x2,y2;
    logic completion_valid,completion_ready,completion_error,command_busy;
    logic [15:0] completion_tag;
    logic result_tx_valid,result_tx_ready;
    logic [7:0] result_tx_byte;
    logic frame_tx_valid,frame_tx_ready;
    logic [7:0] frame_tx_byte;
    logic pending_cycle_q;
    logic [31:0] elapsed_q;

    a0_host_command_rx_p106 receiver (
        .clk(clk),.rst_n(rst_n),.in_valid(rx_valid),.in_ready(rx_ready),
        .in_byte(rx_byte),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode),.cmd_tag(cmd_tag),.cmd_color(cmd_color),
        .cmd_x0(x0),.cmd_y0(y0),.cmd_x1(x1),.cmd_y1(y1),
        .cmd_x2(x2),.cmd_y2(y2),
        .cmd_depth(cmd_depth),.cmd_depth_op(cmd_depth_op),
        .cmd_depth_write(cmd_depth_write),.cmd_blend_enable(cmd_blend_enable),
        .cmd_alpha(cmd_alpha),.cmd_scissor_enable(cmd_scissor_enable),
        .cmd_scissor_x(cmd_scissor_x),.cmd_scissor_y(cmd_scissor_y),
        .cmd_scissor_w(cmd_scissor_w),.cmd_scissor_h(cmd_scissor_h),
        .invalid_frame_count(invalid_frame_count)
    );

    a0_command_dual_bank_scanout_p104 #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXELS(PIXELS),.ADDR_BITS(ADDR_BITS),.TAG_BITS(16)
    ) graphics (
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode),.cmd_tag(cmd_tag),.cmd_color(cmd_color),
        .cmd_depth(cmd_depth),
        .cmd_x0(x0),.cmd_y0(y0),.cmd_x1(x1),.cmd_y1(y1),
        .cmd_x2(x2),.cmd_y2(y2),
        .cmd_depth_op(cmd_depth_op),.cmd_depth_write(cmd_depth_write),
        .cmd_blend_enable(cmd_blend_enable),.cmd_alpha(cmd_alpha),
        .cmd_scissor_enable(cmd_scissor_enable),
        .cmd_scissor_x(cmd_scissor_x),.cmd_scissor_y(cmd_scissor_y),
        .cmd_scissor_w(cmd_scissor_w),.cmd_scissor_h(cmd_scissor_h),
        .completion_valid(completion_valid),.completion_ready(completion_ready),
        .completion_tag(completion_tag),.completion_error(completion_error),
        .command_busy(command_busy),.scan_enable(scan_enable),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_color(pixel_color),
        .start_of_frame(start_of_frame),.end_of_line(end_of_line),
        .end_of_frame(end_of_frame),.frame_done(frame_done),
        .render_initialized(render_initialized),.render_busy(render_busy),
        .display_initialized(display_initialized),.display_bank(display_bank),
        .render_bank(render_bank),.swap_pending(swap_pending),
        .scan_active(scan_active)
    );

    // Observe the actual accepted P43/P104 transaction and completion.
    // Does not alter their ready/valid behavior or make any replay decision.
    a0_command_progress_watchdog_p113 #(
        .MAX_WAIT_CYCLES(MAX_COMMAND_WAIT_CYCLES)
    ) diagnostic_monitor (
        .clk(clk),.rst_n(rst_n),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_tag(cmd_tag),
        .cmd_opcode(cmd_opcode),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .completion_valid(completion_valid),.completion_ready(completion_ready),
        .completion_tag(completion_tag),.completion_error(completion_error),
        .fault_sticky(diagnostic_fault),.pending(diagnostic_pending),
        .active_tag(diagnostic_active_tag),.last_fault_tag(diagnostic_last_fault_tag),
        .timeout_count(diagnostic_timeouts),
        .tag_mismatch_count(diagnostic_tag_mismatches),
        .protocol_fault_count(diagnostic_protocol_faults),
        .completed_count(diagnostic_completed),
        .present_pixel_count(diagnostic_present_pixels)
    );

    a0_host_result_tx_p46 result_sender (
        .clk(clk),.rst_n(rst_n),.result_valid(completion_valid),
        .result_ready(completion_ready),.result_tag(completion_tag),
        .result_error(completion_error),.result_cycles(elapsed_q),
        .out_valid(result_tx_valid),.out_ready(result_tx_ready),
        .out_byte(result_tx_byte)
    );

    // Observe accepted pixels during a P104 one-shot scan. An external
    // deassertion of scan_enable after PRESENT does not abort P104, so do
    // NOT use scan_enable as a CRC monitor activity signal.
    a0_scanout_frame_guard_p47 #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) frame_guard (
        .clk(clk),.rst_n(rst_n),.stream_active(scan_active),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_color(pixel_color),
        .start_of_frame(start_of_frame),.end_of_line(end_of_line),
        .end_of_frame(end_of_frame),
        .frame_valid(frame_crc_valid),.frame_error(frame_crc_error),
        .frame_crc32(frame_crc32),.good_frame_count(good_frames),
        .bad_frame_count(bad_frames),.aborted_frame_count(aborted_frames)
    );

    a0_scanout_telemetry_tx_p48 telemetry_sender (
        .clk(clk),.rst_n(rst_n),.frame_valid(frame_crc_valid),
        .frame_error(frame_crc_error),.frame_crc32(frame_crc32),
        .good_frame_count(good_frames),.bad_frame_count(bad_frames),
        .aborted_frame_count(aborted_frames),
        .tx_valid(frame_tx_valid),.tx_ready(frame_tx_ready),
        .tx_byte(frame_tx_byte),.dropped_frame_events(telemetry_dropped_frames)
    );

    a0_host_tx_fair_arbiter_p49 mux (
        .clk(clk),.rst_n(rst_n),
        .result_valid(result_tx_valid),.result_ready(result_tx_ready),
        .result_byte(result_tx_byte),
        .telemetry_valid(frame_tx_valid),.telemetry_ready(frame_tx_ready),
        .telemetry_byte(frame_tx_byte),
        .host_valid(tx_valid),.host_ready(tx_ready),.host_byte(tx_byte)
    );

    // P46-defined elapsed local clock count. Can saturate on prolonged
    // completion backpressure; it is NOT an instruction execution metric.
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            pending_cycle_q <= 1'b0;
            elapsed_q <= 32'd0;
        end else if(cmd_valid && cmd_ready) begin
            pending_cycle_q <= 1'b1;
            elapsed_q <= 32'd0;
        end else if(completion_valid && completion_ready) begin
            pending_cycle_q <= 1'b0;
        end else if(pending_cycle_q && elapsed_q!=32'hffffffff) begin
            elapsed_q <= elapsed_q+32'd1;
        end
    end
endmodule
