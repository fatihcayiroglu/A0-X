`timescale 1ns/1ps

/*
 * PROD-SEAM-P34 additive successor to the P21 writeback bank. Frozen P20
 * still arbitrates writebacks and restores exact slice-local completion.
 * One global coherence request is routed by an explicitly checked home.
 * Its accepted home is retained through the response handshake; current
 * request wires never select an outstanding response. Reclaim is independent
 * of the global probe lock and remains serviceable while local admission is
 * quarantined. Coherence rejection does not become a legacy memory fault.
 */
module a0_l2_coherent_multislice_writeback_subsystem #(
    parameter integer SLICE_COUNT = 4,
    parameter integer STORE_LANES = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT = 64,
    parameter integer GLOBAL_TAG_W = 8,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WB_RETRIES = 2,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer RETRY_W = (MAX_WB_RETRIES < 1) ? 1 : $clog2(MAX_WB_RETRIES + 1),
    parameter integer LOCAL_ATTEMPT_ID_W = WRITE_ID_W + RETRY_W,
    parameter integer SLICE_ID_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),
    parameter integer BACKEND_ATTEMPT_ID_W = SLICE_ID_W + LOCAL_ATTEMPT_ID_W,
    parameter integer COUNT_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT + 1),
    parameter integer SLICE_HASH_SHIFT = (SET_COUNT <= 1) ? 0 : $clog2(SET_COUNT),
    parameter integer COHERENCE_NODE_W = 4,
    parameter integer COHERENCE_TXN_W = 4,
    parameter integer COHERENCE_GEN_W = 2,
    parameter logic [COHERENCE_NODE_W-1:0] LOCAL_NODE_ID = '0
) (
    input logic clk,
    input logic rst_n,
    input logic [SLICE_COUNT-1:0] line_req_valid_i,
    output logic [SLICE_COUNT-1:0] line_req_ready_o,
    input logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i [0:SLICE_COUNT-1],
    input logic [LINE_ADDR_W-1:0] line_req_line_addr_i [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] line_mem_req_valid_o,
    input logic [SLICE_COUNT-1:0] line_mem_req_ready_i,
    output logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o [0:SLICE_COUNT-1],
    output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o [0:SLICE_COUNT-1],
    input logic [SLICE_COUNT-1:0] line_mem_resp_valid_i,
    input logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i [0:SLICE_COUNT-1],
    input logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i [0:SLICE_COUNT-1],
    input logic [SLICE_COUNT-1:0] line_mem_resp_fault_i,
    input logic [31:0] line_mem_resp_data_i [0:SLICE_COUNT-1][0:LINE_WORDS-1],
    output logic [SLICE_COUNT-1:0] line_resp_valid_o,
    output logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o [0:SLICE_COUNT-1],
    output logic [LINE_ADDR_W-1:0] line_resp_line_addr_o [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] line_resp_fault_o,
    output logic [31:0] line_resp_data_o [0:SLICE_COUNT-1][0:LINE_WORDS-1],
    input logic [SLICE_COUNT-1:0] store_valid_i,
    output logic [SLICE_COUNT-1:0] store_ready_o,
    input logic [STORE_LANES-1:0] store_lane_mask_i [0:SLICE_COUNT-1],
    input logic [31:0] store_word_addr_i [0:SLICE_COUNT-1][0:STORE_LANES-1],
    input logic [31:0] store_wdata_i [0:SLICE_COUNT-1][0:STORE_LANES-1],
    output logic [STORE_LANES-1:0] store_hit_mask_o [0:SLICE_COUNT-1],
    output logic [STORE_LANES-1:0] store_miss_mask_o [0:SLICE_COUNT-1],
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
    output logic protocol_error_o,

    input logic probe_req_valid_i,
    output logic probe_req_ready_o,
    input logic [SLICE_ID_W-1:0] probe_req_home_i,
    input logic probe_req_take_i,
    input logic [COHERENCE_NODE_W-1:0] probe_req_node_i,
    input logic [COHERENCE_TXN_W-1:0] probe_req_txn_i,
    input logic [LINE_ADDR_W-1:0] probe_req_line_addr_i,
    output logic probe_resp_valid_o,
    input logic probe_resp_ready_i,
    output logic [SLICE_ID_W-1:0] probe_resp_home_o,
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
    input logic [SLICE_ID_W-1:0] reclaim_home_i,
    input logic [COHERENCE_NODE_W-1:0] reclaim_node_i,
    input logic [COHERENCE_GEN_W-1:0] reclaim_generation_i,
    input logic [LINE_ADDR_W-1:0] reclaim_line_addr_i,
    input logic reclaim_dirty_i,
    input logic [31:0] reclaim_data_i [0:LINE_WORDS-1],
    input logic [SLICE_COUNT-1:0] probe_reuse_safe_i,
    input logic probe_block_i,
    output logic [SET_COUNT-1:0] coherence_block_set_o [0:SLICE_COUNT-1],
    output logic [SLICE_COUNT-1:0] remote_owned_present_o,
    output logic [SLICE_COUNT-1:0] probe_generation_exhausted_o,
    output logic coherence_protocol_error_o
);
    logic [SLICE_COUNT-1:0] slice_wb_valid;
    logic [SLICE_COUNT-1:0] slice_wb_ready;
    logic [LOCAL_ATTEMPT_ID_W-1:0] slice_wb_attempt_id [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_wb_line_addr [0:SLICE_COUNT-1];
    logic [31:0] slice_wb_data [0:SLICE_COUNT-1][0:LINE_WORDS-1];
    logic [SLICE_COUNT-1:0] slice_status_valid;
    logic [LOCAL_ATTEMPT_ID_W-1:0] slice_status_attempt_id [0:SLICE_COUNT-1];
    logic slice_status_success [0:SLICE_COUNT-1];
    logic slice_status_retryable [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] slice_protocol_error;
    logic queue_protocol_error;

    logic [SLICE_COUNT-1:0] slice_probe_valid;
    logic [SLICE_COUNT-1:0] slice_probe_ready;
    logic [SLICE_COUNT-1:0] slice_probe_resp_valid;
    logic [SLICE_COUNT-1:0] slice_probe_resp_ready;
    logic [SLICE_COUNT-1:0] slice_probe_resp_take;
    logic [COHERENCE_NODE_W-1:0] slice_probe_resp_node [0:SLICE_COUNT-1];
    logic [COHERENCE_TXN_W-1:0] slice_probe_resp_txn [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_probe_resp_line [0:SLICE_COUNT-1];
    logic [COHERENCE_GEN_W-1:0] slice_probe_resp_generation [0:SLICE_COUNT-1];
    logic [SLICE_COUNT-1:0] slice_probe_resp_hit;
    logic [SLICE_COUNT-1:0] slice_probe_resp_dirty;
    logic [31:0] slice_probe_resp_data [0:SLICE_COUNT-1][0:LINE_WORDS-1];
    logic [SLICE_COUNT-1:0] slice_reclaim_valid;
    logic [SLICE_COUNT-1:0] slice_reclaim_ready;
    logic [SLICE_COUNT-1:0] slice_coherence_error;
    logic probe_busy_q;
    logic [SLICE_ID_W-1:0] probe_home_q;
    logic probe_home_valid;
    logic reclaim_home_valid;
    logic route_error_q;

    initial begin
        if (SLICE_COUNT < 1 || (SLICE_COUNT & (SLICE_COUNT-1)) != 0)
            $fatal(1, "P34 SLICE_COUNT must be a power of two >=1");
        if (SLICE_HASH_SHIFT < 0 || SLICE_HASH_SHIFT >= LINE_ADDR_W)
            $fatal(1, "P34 SLICE_HASH_SHIFT is outside the line address");
    end

    function automatic logic [SLICE_ID_W-1:0] line_to_home(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic [SLICE_ID_W-1:0] low_bits;
        logic [SLICE_ID_W-1:0] high_bits;
        begin
            if (SLICE_COUNT <= 1) line_to_home = '0;
            else begin
                low_bits = SLICE_ID_W'(line_addr);
                high_bits = SLICE_ID_W'(line_addr >> SLICE_HASH_SHIFT);
                line_to_home = low_bits ^ high_bits;
            end
        end
    endfunction

    // Suppress the child VALID, not only top-level READY. A blocked raw probe
    // must not reserve a primitive set needed by an older READ/captured STORE.
    // Reclaim routing has no dependence on probe_block_i or probe_busy_q.
    assign probe_home_valid = integer'(probe_req_home_i) < SLICE_COUNT
        && probe_req_home_i == line_to_home(probe_req_line_addr_i);
    assign reclaim_home_valid = integer'(reclaim_home_i) < SLICE_COUNT
        && reclaim_home_i == line_to_home(reclaim_line_addr_i);

    always_comb begin
        probe_req_ready_o = 1'b0;
        probe_resp_valid_o = 1'b0;
        probe_resp_home_o = probe_home_q;
        probe_resp_take_o = 1'b0;
        probe_resp_node_o = '0;
        probe_resp_txn_o = '0;
        probe_resp_line_addr_o = '0;
        probe_resp_generation_o = '0;
        probe_resp_hit_o = 1'b0;
        probe_resp_dirty_o = 1'b0;
        for (integer word = 0; word < LINE_WORDS; word = word + 1)
            probe_resp_data_o[word] = '0;
        reclaim_ready_o = 1'b0;
        if (rst_n && !probe_busy_q && !probe_block_i && probe_home_valid) begin
            probe_req_ready_o = slice_probe_ready[integer'(probe_req_home_i)];
        end
        if (rst_n && probe_busy_q) begin
            probe_resp_valid_o = slice_probe_resp_valid[integer'(probe_home_q)];
            probe_resp_take_o = slice_probe_resp_take[integer'(probe_home_q)];
            probe_resp_node_o = slice_probe_resp_node[integer'(probe_home_q)];
            probe_resp_txn_o = slice_probe_resp_txn[integer'(probe_home_q)];
            probe_resp_line_addr_o = slice_probe_resp_line[integer'(probe_home_q)];
            probe_resp_generation_o = slice_probe_resp_generation[integer'(probe_home_q)];
            probe_resp_hit_o = slice_probe_resp_hit[integer'(probe_home_q)];
            probe_resp_dirty_o = slice_probe_resp_dirty[integer'(probe_home_q)];
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                probe_resp_data_o[word] = slice_probe_resp_data[integer'(probe_home_q)][word];
        end
        if (rst_n && reclaim_home_valid) begin
            reclaim_ready_o = slice_reclaim_ready[integer'(reclaim_home_i)];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            probe_busy_q <= 1'b0;
            probe_home_q <= '0;
            route_error_q <= 1'b0;
        end else begin
            route_error_q <= (probe_req_valid_i && !probe_home_valid)
                || (reclaim_valid_i && !reclaim_home_valid);
            if (probe_req_valid_i && probe_req_ready_o) begin
                probe_busy_q <= 1'b1;
                probe_home_q <= probe_req_home_i;
            end else if (probe_resp_valid_o && probe_resp_ready_i) begin
                probe_busy_q <= 1'b0;
            end
        end
    end

    genvar slice;
    generate
        for (slice = 0; slice < SLICE_COUNT; slice = slice + 1) begin : g_slice
            // Forwarding is independent of child READY. Keep that direction
            // explicit so the routing mux cannot create a combinational loop.
            assign slice_probe_valid[slice] = rst_n && probe_req_valid_i
                && !probe_busy_q && !probe_block_i && probe_home_valid
                && probe_req_home_i == SLICE_ID_W'(slice);
            assign slice_probe_resp_ready[slice] = rst_n && probe_busy_q
                && probe_resp_ready_i && probe_home_q == SLICE_ID_W'(slice);
            assign slice_reclaim_valid[slice] = rst_n && reclaim_valid_i
                && reclaim_home_valid && reclaim_home_i == SLICE_ID_W'(slice);

            a0_l2_coherent_recoverable_writeback_slice #(
                .STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),.SET_COUNT(SET_COUNT),
                .GLOBAL_TAG_W(GLOBAL_TAG_W),.WRITE_ID_W(WRITE_ID_W),.MAX_WB_RETRIES(MAX_WB_RETRIES),
                .WORD_SELECT_W(WORD_SELECT_W),.LINE_ADDR_W(LINE_ADDR_W),
                .RETRY_W(RETRY_W),.ATTEMPT_ID_W(LOCAL_ATTEMPT_ID_W),
                .COHERENCE_NODE_W(COHERENCE_NODE_W),.COHERENCE_TXN_W(COHERENCE_TXN_W),
                .COHERENCE_GEN_W(COHERENCE_GEN_W),.LOCAL_NODE_ID(LOCAL_NODE_ID)
            ) u_slice (
                .clk(clk),.rst_n(rst_n),
                .line_req_valid_i(line_req_valid_i[slice]),.line_req_ready_o(line_req_ready_o[slice]),
                .line_req_global_tag_i(line_req_global_tag_i[slice]),.line_req_line_addr_i(line_req_line_addr_i[slice]),
                .line_mem_req_valid_o(line_mem_req_valid_o[slice]),.line_mem_req_ready_i(line_mem_req_ready_i[slice]),
                .line_mem_req_global_tag_o(line_mem_req_global_tag_o[slice]),.line_mem_req_line_addr_o(line_mem_req_line_addr_o[slice]),
                .line_mem_resp_valid_i(line_mem_resp_valid_i[slice]),.line_mem_resp_global_tag_i(line_mem_resp_global_tag_i[slice]),
                .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i[slice]),.line_mem_resp_fault_i(line_mem_resp_fault_i[slice]),
                .line_mem_resp_data_i(line_mem_resp_data_i[slice]),
                .line_resp_valid_o(line_resp_valid_o[slice]),.line_resp_global_tag_o(line_resp_global_tag_o[slice]),
                .line_resp_line_addr_o(line_resp_line_addr_o[slice]),.line_resp_fault_o(line_resp_fault_o[slice]),
                .line_resp_data_o(line_resp_data_o[slice]),
                .store_valid_i(store_valid_i[slice]),.store_ready_o(store_ready_o[slice]),
                .store_lane_mask_i(store_lane_mask_i[slice]),.store_word_addr_i(store_word_addr_i[slice]),
                .store_wdata_i(store_wdata_i[slice]),.store_hit_mask_o(store_hit_mask_o[slice]),.store_miss_mask_o(store_miss_mask_o[slice]),
                .backend_wb_valid_o(slice_wb_valid[slice]),.backend_wb_ready_i(slice_wb_ready[slice]),
                .backend_wb_attempt_id_o(slice_wb_attempt_id[slice]),.backend_wb_line_addr_o(slice_wb_line_addr[slice]),
                .backend_wb_data_o(slice_wb_data[slice]),
                .backend_wb_status_valid_i(slice_status_valid[slice]),.backend_wb_status_attempt_id_i(slice_status_attempt_id[slice]),
                .backend_wb_status_success_i(slice_status_success[slice]),.backend_wb_status_retryable_i(slice_status_retryable[slice]),
                .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i[slice]),
                .backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o[slice]),
                .dirty_present_o(dirty_present_o[slice]),.wb_busy_o(wb_busy_o[slice]),.wb_retry_count_o(wb_retry_count_o[slice]),
                .wb_terminal_failure_o(wb_terminal_failure_o[slice]),.recovery_active_o(recovery_active_o[slice]),
                .recovery_complete_pulse_o(recovery_complete_pulse_o[slice]),.protocol_error_o(slice_protocol_error[slice]),
                .probe_req_valid_i(slice_probe_valid[slice]),.probe_req_ready_o(slice_probe_ready[slice]),
                .probe_req_take_i(probe_req_take_i),.probe_req_node_i(probe_req_node_i),.probe_req_txn_i(probe_req_txn_i),
                .probe_req_line_addr_i(probe_req_line_addr_i),
                .probe_resp_valid_o(slice_probe_resp_valid[slice]),.probe_resp_ready_i(slice_probe_resp_ready[slice]),
                .probe_resp_take_o(slice_probe_resp_take[slice]),.probe_resp_node_o(slice_probe_resp_node[slice]),
                .probe_resp_txn_o(slice_probe_resp_txn[slice]),.probe_resp_line_addr_o(slice_probe_resp_line[slice]),
                .probe_resp_generation_o(slice_probe_resp_generation[slice]),.probe_resp_hit_o(slice_probe_resp_hit[slice]),
                .probe_resp_dirty_o(slice_probe_resp_dirty[slice]),.probe_resp_data_o(slice_probe_resp_data[slice]),
                .reclaim_valid_i(slice_reclaim_valid[slice]),.reclaim_ready_o(slice_reclaim_ready[slice]),
                .reclaim_node_i(reclaim_node_i),.reclaim_generation_i(reclaim_generation_i),.reclaim_line_addr_i(reclaim_line_addr_i),
                .reclaim_dirty_i(reclaim_dirty_i),.reclaim_data_i(reclaim_data_i),
                .probe_reuse_safe_i(probe_reuse_safe_i[slice]),.probe_block_i(1'b0),
                .coherence_block_set_o(coherence_block_set_o[slice]),.remote_owned_present_o(remote_owned_present_o[slice]),
                .probe_generation_exhausted_o(probe_generation_exhausted_o[slice]),.coherence_protocol_error_o(slice_coherence_error[slice])
            );
        end
    endgenerate

    a0_l2_multislice_writeback_queue #(
        .SOURCE_COUNT(SLICE_COUNT),.LINE_WORDS(LINE_WORDS),.LINE_ADDR_W(LINE_ADDR_W),
        .LOCAL_ATTEMPT_ID_W(LOCAL_ATTEMPT_ID_W)
    ) u_queue (
        .clk(clk),.rst_n(rst_n),
        .src_valid_i(slice_wb_valid),.src_ready_o(slice_wb_ready),.src_attempt_id_i(slice_wb_attempt_id),
        .src_line_addr_i(slice_wb_line_addr),.src_data_i(slice_wb_data),
        .src_status_valid_o(slice_status_valid),.src_status_attempt_id_o(slice_status_attempt_id),
        .src_status_success_o(slice_status_success),.src_status_retryable_o(slice_status_retryable),
        .backend_valid_o(backend_wb_valid_o),.backend_ready_i(backend_wb_ready_i),
        .backend_attempt_id_o(backend_wb_attempt_id_o),.backend_line_addr_o(backend_wb_line_addr_o),.backend_data_o(backend_wb_data_o),
        .backend_status_valid_i(backend_wb_status_valid_i),.backend_status_attempt_id_i(backend_wb_status_attempt_id_i),
        .backend_status_success_i(backend_wb_status_success_i),.backend_status_retryable_i(backend_wb_status_retryable_i),
        .pending_count_o(wb_pending_count_o),.active_count_o(wb_active_count_o),.protocol_error_o(queue_protocol_error)
    );

    always_comb begin
        protocol_error_o = queue_protocol_error;
        coherence_protocol_error_o = route_error_q;
        for (integer pe = 0; pe < SLICE_COUNT; pe = pe + 1) begin
            protocol_error_o = protocol_error_o || slice_protocol_error[pe];
            coherence_protocol_error_o = coherence_protocol_error_o || slice_coherence_error[pe];
        end
    end
endmodule
