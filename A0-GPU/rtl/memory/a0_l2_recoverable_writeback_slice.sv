`timescale 1ns/1ps

/* PROD-SEAM-P19 composition: frozen P17 dirty slice + frozen P18 completion guard + recovery controller. */
module a0_l2_recoverable_writeback_slice #(
    parameter integer STORE_LANES=4,
    parameter integer LINE_WORDS=8,
    parameter integer SET_COUNT=64,
    parameter integer GLOBAL_TAG_W=8,
    parameter integer WRITE_ID_W=8,
    parameter integer MAX_WB_RETRIES=2,
    parameter integer WORD_SELECT_W=(LINE_WORDS<=1)?0:$clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W=32-WORD_SELECT_W,
    parameter integer RETRY_W=(MAX_WB_RETRIES<1)?1:$clog2(MAX_WB_RETRIES+1),
    parameter integer ATTEMPT_ID_W=WRITE_ID_W+RETRY_W
) (
    input logic clk,input logic rst_n,
    input logic line_req_valid_i,output logic line_req_ready_o,input logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i,input logic [LINE_ADDR_W-1:0] line_req_line_addr_i,
    output logic line_mem_req_valid_o,input logic line_mem_req_ready_i,output logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o,output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o,
    input logic line_mem_resp_valid_i,input logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i,input logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i,input logic line_mem_resp_fault_i,input logic [31:0] line_mem_resp_data_i [0:LINE_WORDS-1],
    output logic line_resp_valid_o,output logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o,output logic [LINE_ADDR_W-1:0] line_resp_line_addr_o,output logic line_resp_fault_o,output logic [31:0] line_resp_data_o [0:LINE_WORDS-1],
    input logic store_valid_i,output logic store_ready_o,input logic [STORE_LANES-1:0] store_lane_mask_i,input logic [31:0] store_word_addr_i [0:STORE_LANES-1],input logic [31:0] store_wdata_i [0:STORE_LANES-1],output logic [STORE_LANES-1:0] store_hit_mask_o,output logic [STORE_LANES-1:0] store_miss_mask_o,
    output logic backend_wb_valid_o,input logic backend_wb_ready_i,output logic [ATTEMPT_ID_W-1:0] backend_wb_attempt_id_o,output logic [LINE_ADDR_W-1:0] backend_wb_line_addr_o,output logic [31:0] backend_wb_data_o [0:LINE_WORDS-1],
    input logic backend_wb_status_valid_i,input logic [ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,input logic backend_wb_status_success_i,input logic backend_wb_status_retryable_i,
    input logic backend_wb_recovery_safe_valid_i,output logic backend_wb_recovery_safe_ready_o,
    output logic dirty_present_o,output logic wb_busy_o,output logic [RETRY_W-1:0] wb_retry_count_o,output logic wb_terminal_failure_o,output logic recovery_active_o,output logic recovery_complete_pulse_o,output logic protocol_error_o
);
    logic p17_wb_valid,p17_wb_ready;
    logic [LINE_ADDR_W-1:0] p17_wb_line;
    logic [31:0] p17_wb_data [0:LINE_WORDS-1];
    logic p17_protocol_error, guard_protocol_error;
    logic guard_rst_n;

    a0_l2_dirty_writeback_slice #(.STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),.SET_COUNT(SET_COUNT),.GLOBAL_TAG_W(GLOBAL_TAG_W)) p17_slice (
        .rst_n(rst_n),.wb_valid_o(p17_wb_valid),.wb_ready_i(p17_wb_ready),.wb_line_addr_o(p17_wb_line),.wb_data_o(p17_wb_data),.protocol_error_o(p17_protocol_error),.*
    );

    a0_l2_writeback_completion_guard #(.LINE_WORDS(LINE_WORDS),.LINE_ADDR_W(LINE_ADDR_W),.WRITE_ID_W(WRITE_ID_W),.MAX_RETRIES(MAX_WB_RETRIES),.RETRY_W(RETRY_W),.ATTEMPT_ID_W(ATTEMPT_ID_W)) p18_guard (
        .rst_n(guard_rst_n),.victim_wb_valid_i(p17_wb_valid),.victim_wb_ready_o(p17_wb_ready),.victim_wb_line_addr_i(p17_wb_line),.victim_wb_data_i(p17_wb_data),
        .busy_o(wb_busy_o),.retry_count_o(wb_retry_count_o),.terminal_failure_o(wb_terminal_failure_o),.protocol_error_o(guard_protocol_error),.*
    );

    a0_l2_writeback_recovery_controller recovery (
        .clk(clk),.rst_n(rst_n),.wb_terminal_failure_i(wb_terminal_failure_o),
        .backend_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i),.backend_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o),
        .guard_rst_n_o(guard_rst_n),.recovery_active_o(recovery_active_o),.recovery_complete_pulse_o(recovery_complete_pulse_o)
    );

    assign protocol_error_o = p17_protocol_error || guard_protocol_error;
endmodule
