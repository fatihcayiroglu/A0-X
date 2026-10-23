`timescale 1ns/1ps

/*
 * PROD-SEAM-P34 additive successor to P19. The cache-backed coherence
 * endpoint replaces only the storage primitive. Frozen P18 completion and
 * P19 recovery still own writeback completion and guard-local rearm. The
 * cache/coherence endpoint sees only the global reset, never guard_rst_n.
 */
module a0_l2_coherent_recoverable_writeback_slice #(
    parameter integer STORE_LANES=4,
    parameter integer LINE_WORDS=8,
    parameter integer SET_COUNT=64,
    parameter integer GLOBAL_TAG_W=8,
    parameter integer WRITE_ID_W=8,
    parameter integer MAX_WB_RETRIES=2,
    parameter integer WORD_SELECT_W=(LINE_WORDS<=1)?0:$clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W=32-WORD_SELECT_W,
    parameter integer RETRY_W=(MAX_WB_RETRIES<1)?1:$clog2(MAX_WB_RETRIES+1),
    parameter integer ATTEMPT_ID_W=WRITE_ID_W+RETRY_W,
    parameter integer COHERENCE_NODE_W=4,
    parameter integer COHERENCE_TXN_W=4,
    parameter integer COHERENCE_GEN_W=2,
    parameter logic [COHERENCE_NODE_W-1:0] LOCAL_NODE_ID='0
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
    output logic dirty_present_o,output logic wb_busy_o,output logic [RETRY_W-1:0] wb_retry_count_o,output logic wb_terminal_failure_o,output logic recovery_active_o,output logic recovery_complete_pulse_o,output logic protocol_error_o,

    input logic probe_req_valid_i,
    output logic probe_req_ready_o,
    input logic probe_req_take_i,
    input logic [COHERENCE_NODE_W-1:0] probe_req_node_i,
    input logic [COHERENCE_TXN_W-1:0] probe_req_txn_i,
    input logic [LINE_ADDR_W-1:0] probe_req_line_addr_i,
    output logic probe_resp_valid_o,
    input logic probe_resp_ready_i,
    output logic probe_resp_take_o,
    output logic [COHERENCE_NODE_W-1:0] probe_resp_node_o,
    output logic [COHERENCE_TXN_W-1:0] probe_resp_txn_o,
    output logic [LINE_ADDR_W-1:0] probe_resp_line_addr_o,
    output logic [COHERENCE_GEN_W-1:0] probe_resp_generation_o,
    output logic probe_resp_hit_o,
    output logic probe_resp_dirty_o,
    output logic [31:0] probe_resp_data_o [0:LINE_WORDS-1],
    input logic reclaim_valid_i,
    output logic reclaim_ready_o,
    input logic [COHERENCE_NODE_W-1:0] reclaim_node_i,
    input logic [COHERENCE_GEN_W-1:0] reclaim_generation_i,
    input logic [LINE_ADDR_W-1:0] reclaim_line_addr_i,
    input logic reclaim_dirty_i,
    input logic [31:0] reclaim_data_i [0:LINE_WORDS-1],
    input logic probe_reuse_safe_i,
    input logic probe_block_i,
    output logic [SET_COUNT-1:0] coherence_block_set_o,
    output logic remote_owned_present_o,
    output logic probe_generation_exhausted_o,
    output logic coherence_protocol_error_o
);
    logic p17_wb_valid,p17_wb_ready;
    logic [LINE_ADDR_W-1:0] p17_wb_line;
    logic [31:0] p17_wb_data [0:LINE_WORDS-1];
    logic p17_protocol_error, guard_protocol_error;
    logic guard_rst_n;

    a0_l2_coherence_probe_slice #(
        .STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),.SET_COUNT(SET_COUNT),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),.WORD_SELECT_W(WORD_SELECT_W),.LINE_ADDR_W(LINE_ADDR_W),
        .COHERENCE_NODE_W(COHERENCE_NODE_W),.COHERENCE_TXN_W(COHERENCE_TXN_W),
        .COHERENCE_GEN_W(COHERENCE_GEN_W),.LOCAL_NODE_ID(LOCAL_NODE_ID)
    ) p34_slice (
        .rst_n(rst_n),.wb_valid_o(p17_wb_valid),.wb_ready_i(p17_wb_ready),
        .wb_line_addr_o(p17_wb_line),.wb_data_o(p17_wb_data),.protocol_error_o(p17_protocol_error),.*
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

    // Coherence rejection is a separate diagnostic, not a global memory fault.
    assign protocol_error_o = p17_protocol_error || guard_protocol_error;
endmodule
