`timescale 1ns/1ps

/* P34 additive coherence passthrough successor. The inherited data path,
 * fabric/router/arbiter, identity and reset behavior below are unchanged.
 * Probe/reclaim routing and coherence diagnostics are explicit and separate.
 */

/*
 * PROD-SEAM-P22: logical multi-client line fabric composed with the frozen
 * P21 multi-slice recoverable dirty/writeback bank.
 *
 * Request identity remains {client_id, local_tag} through the line-slice
 * fabric and is opaque to each dirty slice. Slice-local store updates are an
 * explicit bounded seam in P22; global production store-commit fanout is not
 * invented here.
 */
module a0_mc_noc_coherent_multislice_writeback_subsystem #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,
    parameter integer SLICE_COUNT = 4,
    parameter integer STORE_LANES_PER_SLICE = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT_PER_SLICE = 64,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WB_RETRIES = 2,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer CLIENT_ID_W = (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),
    parameter integer GLOBAL_TAG_W = CLIENT_ID_W + LOCAL_TAG_W,
    parameter integer SLICE_ID_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),
    parameter integer SLICE_HASH_SHIFT = (SET_COUNT_PER_SLICE <= 1) ? 0 : $clog2(SET_COUNT_PER_SLICE),
    parameter integer RETRY_W = (MAX_WB_RETRIES < 1) ? 1 : $clog2(MAX_WB_RETRIES + 1),
    parameter integer LOCAL_ATTEMPT_ID_W = WRITE_ID_W + RETRY_W,
    parameter integer BACKEND_ATTEMPT_ID_W = SLICE_ID_W + LOCAL_ATTEMPT_ID_W,
    parameter integer COUNT_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT + 1),
    parameter integer COHERENCE_NODE_W = 4,
    parameter integer COHERENCE_TXN_W = 4,
    parameter integer COHERENCE_GEN_W = 2,
    parameter logic [COHERENCE_NODE_W-1:0] LOCAL_NODE_ID = '0
) (
    input logic clk,
    input logic rst_n,

    input logic [CLIENT_COUNT-1:0] client_req_valid_i,
    output logic [CLIENT_COUNT-1:0] client_req_ready_o,
    input logic [LOCAL_TAG_W-1:0] client_req_local_tag_i [0:CLIENT_COUNT-1],
    input logic [LINE_ADDR_W-1:0] client_req_line_addr_i [0:CLIENT_COUNT-1],

    output logic [CLIENT_COUNT-1:0] client_resp_valid_o,
    output logic [LOCAL_TAG_W-1:0] client_resp_local_tag_o [0:CLIENT_COUNT-1],
    output logic [LINE_ADDR_W-1:0] client_resp_line_addr_o [0:CLIENT_COUNT-1],
    output logic client_resp_fault_o [0:CLIENT_COUNT-1],
    output logic [31:0] client_resp_data_o [0:CLIENT_COUNT-1][0:LINE_WORDS-1],

    input logic [SLICE_COUNT-1:0] slice_store_valid_i,
    output logic [SLICE_COUNT-1:0] slice_store_ready_o,
    input logic [STORE_LANES_PER_SLICE-1:0] slice_store_lane_mask_i [0:SLICE_COUNT-1],
    input logic [31:0] slice_store_word_addr_i [0:SLICE_COUNT-1][0:STORE_LANES_PER_SLICE-1],
    input logic [31:0] slice_store_wdata_i [0:SLICE_COUNT-1][0:STORE_LANES_PER_SLICE-1],
    output logic [STORE_LANES_PER_SLICE-1:0] slice_store_hit_mask_o [0:SLICE_COUNT-1],
    output logic [STORE_LANES_PER_SLICE-1:0] slice_store_miss_mask_o [0:SLICE_COUNT-1],

    output logic [SLICE_COUNT-1:0] line_mem_req_valid_o,
    input logic [SLICE_COUNT-1:0] line_mem_req_ready_i,
    output logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o [0:SLICE_COUNT-1],
    output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o [0:SLICE_COUNT-1],
    input logic [SLICE_COUNT-1:0] line_mem_resp_valid_i,
    input logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i [0:SLICE_COUNT-1],
    input logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i [0:SLICE_COUNT-1],
    input logic [SLICE_COUNT-1:0] line_mem_resp_fault_i,
    input logic [31:0] line_mem_resp_data_i [0:SLICE_COUNT-1][0:LINE_WORDS-1],

    output logic backend_wb_valid_o,
    input logic backend_wb_ready_i,
    output logic [BACKEND_ATTEMPT_ID_W-1:0] backend_wb_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_wb_line_addr_o,
    output logic [31:0] backend_wb_data_o [0:LINE_WORDS-1],
    input logic backend_wb_status_valid_i,
    input logic [BACKEND_ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,
    input logic backend_wb_status_success_i,
    input logic backend_wb_status_retryable_i,
    input logic [SLICE_COUNT-1:0] backend_wb_recovery_safe_valid_i,
    output logic [SLICE_COUNT-1:0] backend_wb_recovery_safe_ready_o,

    output logic [SLICE_COUNT-1:0] dirty_present_o,
    output logic [SLICE_COUNT-1:0] wb_busy_o,
    output logic [RETRY_W-1:0] wb_retry_count_o [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] wb_terminal_failure_o,
    output logic [SLICE_COUNT-1:0] recovery_active_o,
    output logic [SLICE_COUNT-1:0] recovery_complete_pulse_o,
    output logic [COUNT_W-1:0] wb_pending_count_o,
    output logic [COUNT_W-1:0] wb_active_count_o,
    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o,
    output logic protocol_error_o,

    input logic probe_req_valid_i,
    output logic probe_req_ready_o,
    input logic probe_req_take_i,
    input logic [COHERENCE_NODE_W-1:0] probe_req_node_i,
    input logic [COHERENCE_TXN_W-1:0] probe_req_txn_i,
    input logic [SLICE_ID_W-1:0] probe_req_home_i,
    input logic [LINE_ADDR_W-1:0] probe_req_line_addr_i,

    output logic probe_resp_valid_o,
    input logic probe_resp_ready_i,
    output logic probe_resp_take_o,
    output logic [COHERENCE_NODE_W-1:0] probe_resp_node_o,
    output logic [COHERENCE_TXN_W-1:0] probe_resp_txn_o,
    output logic [SLICE_ID_W-1:0] probe_resp_home_o,
    output logic [LINE_ADDR_W-1:0] probe_resp_line_addr_o,
    output logic [COHERENCE_GEN_W-1:0] probe_resp_generation_o,
    output logic probe_resp_hit_o,
    output logic probe_resp_dirty_o,
    output logic [31:0] probe_resp_data_o [0:LINE_WORDS-1],

    input logic reclaim_valid_i,
    output logic reclaim_ready_o,
    input logic [COHERENCE_NODE_W-1:0] reclaim_node_i,
    input logic [COHERENCE_GEN_W-1:0] reclaim_generation_i,
    input logic [SLICE_ID_W-1:0] reclaim_home_i,
    input logic [LINE_ADDR_W-1:0] reclaim_line_addr_i,
    input logic reclaim_dirty_i,
    input logic [31:0] reclaim_data_i [0:LINE_WORDS-1],

    input logic [SLICE_COUNT-1:0] probe_reuse_safe_i,
    input logic probe_block_i,
    output logic [SET_COUNT_PER_SLICE-1:0] coherence_block_set_o [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] remote_owned_present_o,
    output logic [SLICE_COUNT-1:0] probe_generation_exhausted_o,
    output logic coherence_protocol_error_o
);
    logic [SLICE_COUNT-1:0] slice_req_valid;
    logic [SLICE_COUNT-1:0] slice_req_ready;
    logic [GLOBAL_TAG_W-1:0] slice_req_global_tag [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_req_line_addr [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] slice_resp_valid;
    logic [GLOBAL_TAG_W-1:0] slice_resp_global_tag [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_resp_line_addr [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] slice_resp_fault_packed;
    logic slice_resp_fault [0:SLICE_COUNT-1];
    logic [31:0] slice_resp_data [0:SLICE_COUNT-1][0:LINE_WORDS-1];

    genvar fault_slice;
    generate
        for (fault_slice = 0; fault_slice < SLICE_COUNT; fault_slice = fault_slice + 1) begin : g_fault_bridge
            assign slice_resp_fault[fault_slice] = slice_resp_fault_packed[fault_slice];
        end
    endgenerate

    initial begin
        if (SLICE_COUNT < 1 || (SLICE_COUNT & (SLICE_COUNT - 1)) != 0)
            $fatal(1, "P22 SLICE_COUNT must be a power of two >=1");
        if (GLOBAL_TAG_W != CLIENT_ID_W + LOCAL_TAG_W)
            $fatal(1, "P22 GLOBAL_TAG_W inconsistent");
    end

    a0_line_slice_fabric #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LINE_WORDS(LINE_WORDS),
        .SLICE_COUNT(SLICE_COUNT),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) u_fabric (
        .clk(clk),.rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i),.client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),.client_req_line_addr_i(client_req_line_addr_i),
        .slice_req_valid_o(slice_req_valid),.slice_req_ready_i(slice_req_ready),
        .slice_req_global_tag_o(slice_req_global_tag),.slice_req_line_addr_o(slice_req_line_addr),
        .slice_resp_valid_i(slice_resp_valid),.slice_resp_global_tag_i(slice_resp_global_tag),
        .slice_resp_line_addr_i(slice_resp_line_addr),.slice_resp_fault_i(slice_resp_fault),.slice_resp_data_i(slice_resp_data),
        .client_resp_valid_o(client_resp_valid_o),.client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),.client_resp_fault_o(client_resp_fault_o),.client_resp_data_o(client_resp_data_o),
        .line_resp_tag_error_o(line_resp_tag_error_o),.line_resp_overflow_o(line_resp_overflow_o)
    );

    a0_l2_coherent_multislice_writeback_subsystem #(
        .SLICE_COUNT(SLICE_COUNT),
        .STORE_LANES(STORE_LANES_PER_SLICE),
        .LINE_WORDS(LINE_WORDS),
        .SET_COUNT(SET_COUNT_PER_SLICE),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .WRITE_ID_W(WRITE_ID_W),
        .MAX_WB_RETRIES(MAX_WB_RETRIES),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .COHERENCE_NODE_W(COHERENCE_NODE_W),
        .COHERENCE_TXN_W(COHERENCE_TXN_W),
        .COHERENCE_GEN_W(COHERENCE_GEN_W),
        .LOCAL_NODE_ID(LOCAL_NODE_ID)
    ) u_l2 (
        .clk(clk),.rst_n(rst_n),
        .line_req_valid_i(slice_req_valid),.line_req_ready_o(slice_req_ready),
        .line_req_global_tag_i(slice_req_global_tag),.line_req_line_addr_i(slice_req_line_addr),
        .line_mem_req_valid_o(line_mem_req_valid_o),.line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_global_tag_o(line_mem_req_global_tag_o),.line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),.line_mem_resp_global_tag_i(line_mem_resp_global_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),.line_mem_resp_fault_i(line_mem_resp_fault_i),.line_mem_resp_data_i(line_mem_resp_data_i),
        .line_resp_valid_o(slice_resp_valid),.line_resp_global_tag_o(slice_resp_global_tag),
        .line_resp_line_addr_o(slice_resp_line_addr),.line_resp_fault_o(slice_resp_fault_packed),.line_resp_data_o(slice_resp_data),
        .store_valid_i(slice_store_valid_i),.store_ready_o(slice_store_ready_o),
        .store_lane_mask_i(slice_store_lane_mask_i),.store_word_addr_i(slice_store_word_addr_i),.store_wdata_i(slice_store_wdata_i),
        .store_hit_mask_o(slice_store_hit_mask_o),.store_miss_mask_o(slice_store_miss_mask_o),
        .backend_wb_valid_o(backend_wb_valid_o),.backend_wb_ready_i(backend_wb_ready_i),
        .backend_wb_attempt_id_o(backend_wb_attempt_id_o),.backend_wb_line_addr_o(backend_wb_line_addr_o),.backend_wb_data_o(backend_wb_data_o),
        .backend_wb_status_valid_i(backend_wb_status_valid_i),.backend_wb_status_attempt_id_i(backend_wb_status_attempt_id_i),
        .backend_wb_status_success_i(backend_wb_status_success_i),.backend_wb_status_retryable_i(backend_wb_status_retryable_i),
        .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i),.backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o),
        .dirty_present_o(dirty_present_o),.wb_busy_o(wb_busy_o),.wb_retry_count_o(wb_retry_count_o),
        .wb_terminal_failure_o(wb_terminal_failure_o),.recovery_active_o(recovery_active_o),.recovery_complete_pulse_o(recovery_complete_pulse_o),
        .wb_pending_count_o(wb_pending_count_o),.wb_active_count_o(wb_active_count_o),.protocol_error_o(protocol_error_o),
        .probe_req_valid_i(probe_req_valid_i),
        .probe_req_ready_o(probe_req_ready_o),
        .probe_req_take_i(probe_req_take_i),
        .probe_req_node_i(probe_req_node_i),
        .probe_req_txn_i(probe_req_txn_i),
        .probe_req_home_i(probe_req_home_i),
        .probe_req_line_addr_i(probe_req_line_addr_i),
        .probe_resp_valid_o(probe_resp_valid_o),
        .probe_resp_ready_i(probe_resp_ready_i),
        .probe_resp_take_o(probe_resp_take_o),
        .probe_resp_node_o(probe_resp_node_o),
        .probe_resp_txn_o(probe_resp_txn_o),
        .probe_resp_home_o(probe_resp_home_o),
        .probe_resp_line_addr_o(probe_resp_line_addr_o),
        .probe_resp_generation_o(probe_resp_generation_o),
        .probe_resp_hit_o(probe_resp_hit_o),
        .probe_resp_dirty_o(probe_resp_dirty_o),
        .probe_resp_data_o(probe_resp_data_o),
        .reclaim_valid_i(reclaim_valid_i),
        .reclaim_ready_o(reclaim_ready_o),
        .reclaim_node_i(reclaim_node_i),
        .reclaim_generation_i(reclaim_generation_i),
        .reclaim_home_i(reclaim_home_i),
        .reclaim_line_addr_i(reclaim_line_addr_i),
        .reclaim_dirty_i(reclaim_dirty_i),
        .reclaim_data_i(reclaim_data_i),
        .probe_reuse_safe_i(probe_reuse_safe_i),
        .probe_block_i(probe_block_i),
        .coherence_block_set_o(coherence_block_set_o),
        .remote_owned_present_o(remote_owned_present_o),
        .probe_generation_exhausted_o(probe_generation_exhausted_o),
        .coherence_protocol_error_o(coherence_protocol_error_o)
    );
endmodule

