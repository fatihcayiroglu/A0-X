`timescale 1ns/1ps

/* PROD-SEAM-P33: resource-scoped STORE quarantine and recovery progress.
 * A persistent exact READ ledger orders home-slice/local-set resources for
 * raw-valid commits. Captured reservations survive aborted-source withdrawal
 * through STORE-only rearm, while independent new READs remain admissible.
 * Old conflicting READ/WB finishes before commit classification. Frozen P24
 * and every READ/cache/WB descendant retain global reset. Only STORE completion
 * and timeout guards reset locally after real abort and reuse safety; generation
 * identity remains live, so delayed status cannot alias a fresh attempt.
 * STORE-owned DRAIN release does not wait for unrelated READ/WB to become idle.
 * Those transactions retain real completion and full payload/identity state.
 * This does not cancel issued physical writes or roll back partially visible
 * commits. Backend reuse certificates retain their original contract.
 * Global cold reset is destructive, not a dirty-cache flush. */
module a0_production_store_commit_scoped_progress_subsystem #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32,
    parameter integer SLICE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT_PER_SLICE = 64,
    parameter integer WRITE_ID_W = 8,
    parameter integer MAX_WB_RETRIES = 2,
    parameter integer STORE_WRITE_ID_W = 8,
    parameter integer MAX_STORE_RETRIES = 2,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer CLIENT_ID_W = (CLIENT_COUNT <= 1) ? 1 : $clog2(CLIENT_COUNT),
    parameter integer GLOBAL_TAG_W = CLIENT_ID_W + LOCAL_TAG_W,
    parameter integer SLICE_ID_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),
    parameter integer SLICE_HASH_SHIFT = (SET_COUNT_PER_SLICE <= 1) ? 0 : $clog2(SET_COUNT_PER_SLICE),
    parameter integer RETRY_W = (MAX_WB_RETRIES < 1) ? 1 : $clog2(MAX_WB_RETRIES + 1),
    parameter integer LOCAL_ATTEMPT_ID_W = WRITE_ID_W + RETRY_W,
    parameter integer BACKEND_ATTEMPT_ID_W = SLICE_ID_W + LOCAL_ATTEMPT_ID_W,
    parameter integer BACKEND_READ_TAG_W = SLICE_ID_W + GLOBAL_TAG_W,
    parameter integer COUNT_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT + 1),
    parameter integer STORE_RETRY_W = (MAX_STORE_RETRIES < 1) ? 1 : $clog2(MAX_STORE_RETRIES + 1),
    parameter integer STORE_GENERATION_W = 8,
    parameter integer P29_STORE_ATTEMPT_ID_W = STORE_WRITE_ID_W + STORE_RETRY_W,
    parameter integer STORE_ATTEMPT_ID_W = STORE_GENERATION_W + P29_STORE_ATTEMPT_ID_W,
    parameter integer STORE_STATUS_TIMEOUT_CYCLES = 16,
    parameter integer STORE_STATUS_TIMER_W = (STORE_STATUS_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(STORE_STATUS_TIMEOUT_CYCLES),
    parameter integer COMMIT_PORT_ID_W = (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT),
    parameter integer CLIENT_READ_COUNT_W = ((CLIENT_COUNT * CLIENT_MAX_OUTSTANDING) < 1)
        ? 1 : $clog2(CLIENT_COUNT * CLIENT_MAX_OUTSTANDING + 1)
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

    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    output logic [COMMIT_PORT_COUNT-1:0] commit_ready_o,
    input logic [STORE_LANES-1:0] commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0] commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [31:0] commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic [1:0] backend_cmd_kind_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [BACKEND_ATTEMPT_ID_W-1:0] backend_cmd_wb_attempt_id_o,
    output logic [STORE_ATTEMPT_ID_W-1:0] backend_cmd_store_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,
    output logic [31:0] backend_cmd_data_o [0:LINE_WORDS-1],
    output logic [31:0] backend_cmd_store_word_addr_o,
    output logic [31:0] backend_cmd_store_wdata_o,

    input logic backend_read_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_read_resp_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_read_resp_line_addr_i,
    input logic backend_read_resp_fault_i,
    input logic [31:0] backend_read_resp_data_i [0:LINE_WORDS-1],
    input logic backend_wb_status_valid_i,
    input logic [BACKEND_ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,
    input logic backend_wb_status_success_i,
    input logic backend_wb_status_retryable_i,
    input logic backend_store_status_valid_i,
    input logic [STORE_ATTEMPT_ID_W-1:0] backend_store_status_attempt_id_i,
    input logic backend_store_status_success_i,
    input logic backend_store_status_retryable_i,
    input logic backend_store_status_reuse_safe_i,
    input logic backend_store_all_generations_quiescent_i,
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
    output logic commit_visibility_busy_o,
    output logic store_completion_busy_o,
    output logic [STORE_RETRY_W-1:0] store_retry_count_o,
    output logic store_terminal_failure_o,
    output logic line_resp_tag_error_o,
    output logic line_resp_overflow_o,
    output logic store_status_timeout_live_o,
    output logic [STORE_STATUS_TIMER_W-1:0] store_status_timeout_age_o,
    output logic store_status_timeout_pulse_o,
    output logic store_status_timeout_seen_o,
    output logic [COMMIT_PORT_COUNT-1:0] commit_abort_o,
    output logic commit_fault_valid_o,
    input logic commit_fault_ready_i,
    output logic [COMMIT_PORT_ID_W-1:0] commit_fault_port_id_o,
    output logic [STORE_LANES-1:0] commit_fault_lane_mask_o,
    output logic [31:0] commit_fault_word_addr_o [0:STORE_LANES-1],
    output logic [31:0] commit_fault_wdata_o [0:STORE_LANES-1],
    output logic commit_fault_store_timeout_o,
    output logic [STORE_RETRY_W-1:0] commit_fault_store_retry_count_o,
    output logic recovery_required_o,
    output logic recovery_rearm_pulse_o,
    output logic recovery_drain_active_o,
    output logic [STORE_GENERATION_W-1:0] store_generation_next_o,
    output logic store_generation_wrap_pending_o,
    output logic store_status_rejected_o,
    output logic recovery_reset_blocked_o,
    output logic [CLIENT_READ_COUNT_W-1:0] client_read_outstanding_o,
    output logic [CLIENT_COUNT-1:0] client_store_conflict_o,
    output logic [COMMIT_PORT_COUNT-1:0] commit_read_wait_o,
    output logic protocol_error_o
);
    logic store_rst_n, frontend_error, frontend_fenced, line_service_allowed;
    logic p24_error, completion_error, timeout_error, count_error_q, count_invalid;
    logic external_error, captured_reservation_valid;
    logic [0:0] p24_commit_valid, p24_commit_ready;
    logic [STORE_LANES-1:0] p24_commit_lane_mask[0:0];
    logic [31:0] p24_commit_word_addr[0:0][0:STORE_LANES-1];
    logic [31:0] p24_commit_wdata[0:0][0:STORE_LANES-1];
    logic [STORE_LANES-1:0] p24_hit[0:SLICE_COUNT-1],p24_miss[0:SLICE_COUNT-1];
    logic p24_router_busy;
    logic [CLIENT_COUNT-1:0] p24_req_valid,p24_req_ready;
    logic [CLIENT_COUNT-1:0] ordered_req_valid,ordered_req_ready,order_core_ready;
    logic [COMMIT_PORT_COUNT-1:0] ordered_commit_valid;
    logic ordering_error;
    logic p24_cmd_valid,p24_cmd_ready,p24_cmd_write;
    logic [BACKEND_READ_TAG_W-1:0] p24_read_tag;
    logic [BACKEND_ATTEMPT_ID_W-1:0] p24_wb_id;
    logic [LINE_ADDR_W-1:0] p24_line_addr;
    logic [31:0] p24_data[0:LINE_WORDS-1];

    logic word_valid,word_ready,completion_cmd_valid,completion_cmd_ready;
    logic [31:0] word_addr,word_data,completion_addr,completion_data;
    logic [P29_STORE_ATTEMPT_ID_W-1:0] completion_id;
    logic gen_cmd_valid,gen_cmd_ready,store_attempt_idle;
    logic [STORE_ATTEMPT_ID_W-1:0] gen_cmd_id;
    logic real_status_valid,real_status_success,real_status_retryable;
    logic [P29_STORE_ATTEMPT_ID_W-1:0] real_status_id;
    logic guarded_status_valid,guarded_status_success,guarded_status_retryable;
    logic [P29_STORE_ATTEMPT_ID_W-1:0] guarded_status_id;

    logic hold_valid_q,hold_store_q,select_store,select_line,store_cmd_fire;
    logic [CLIENT_READ_COUNT_W-1:0] read_count_q;
    integer accepted_reads,returned_reads,read_count_next;

    initial begin
        if(CLIENT_COUNT<1 || CLIENT_MAX_OUTSTANDING<1)
            $fatal(1,"P33 client count must be positive");
        if(CLIENT_READ_COUNT_W<$clog2(CLIENT_COUNT*CLIENT_MAX_OUTSTANDING+1)
           || CLIENT_READ_COUNT_W>31) $fatal(1,"P33 client count width");
        if(P29_STORE_ATTEMPT_ID_W!=STORE_WRITE_ID_W+STORE_RETRY_W)
            $fatal(1,"P33 whole local STORE identity width");
        if(STORE_RETRY_W!=((MAX_STORE_RETRIES<1)?1:$clog2(MAX_STORE_RETRIES+1)))
            $fatal(1,"P33 retry width");
        if(STORE_ATTEMPT_ID_W!=P29_STORE_ATTEMPT_ID_W+STORE_GENERATION_W)
            $fatal(1,"P33 external STORE identity width");
    end

    assign store_rst_n=rst_n&&!recovery_rearm_pulse_o;
    assign p24_req_valid=(rst_n&&!frontend_fenced&&!count_error_q)?ordered_req_valid:'0;
    assign order_core_ready=(rst_n&&!frontend_fenced&&!count_error_q)?p24_req_ready:'0;
    assign client_req_ready_o=ordered_req_ready;
    assign client_read_outstanding_o=read_count_q;
    assign external_error=p24_error||count_error_q||ordering_error
        ||(!recovery_rearm_pulse_o&&(completion_error||timeout_error));
    assign protocol_error_o=external_error||frontend_error||count_invalid;
    assign recovery_reset_blocked_o=recovery_required_o&&!recovery_rearm_pulse_o;

    a0_store_read_quarantine_order_guard #(
        .CLIENT_COUNT(CLIENT_COUNT),.LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),.COMMIT_PORT_COUNT(COMMIT_PORT_COUNT),
        .STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),
        .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE),.SLICE_COUNT(SLICE_COUNT),
        .WORD_SELECT_W(WORD_SELECT_W),.LINE_ADDR_W(LINE_ADDR_W),
        .SLICE_ID_W(SLICE_ID_W),.SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) u_resource_order (
        .clk(clk),.rst_n(rst_n),.client_req_valid_i(client_req_valid_i),
        .client_req_local_tag_i(client_req_local_tag_i),.client_req_line_addr_i(client_req_line_addr_i),
        .core_client_req_ready_i(order_core_ready),.client_resp_valid_i(client_resp_valid_o),
        .client_resp_local_tag_i(client_resp_local_tag_o),.client_resp_line_addr_i(client_resp_line_addr_o),
        .commit_valid_i(commit_valid_i),.commit_lane_mask_i(commit_lane_mask_i),
        .commit_word_addr_i(commit_word_addr_i),
        .captured_reservation_valid_i(captured_reservation_valid),
        .captured_reservation_lane_mask_i(commit_fault_lane_mask_o),
        .captured_reservation_word_addr_i(commit_fault_word_addr_o),
        .core_client_req_valid_o(ordered_req_valid),
        .client_req_ready_o(ordered_req_ready),.core_commit_valid_o(ordered_commit_valid),
        .request_conflict_o(client_store_conflict_o),.commit_wait_o(commit_read_wait_o),
        .protocol_error_o(ordering_error)
    );

    always_comb begin
        accepted_reads=0;returned_reads=0;
        for(integer c=0;c<CLIENT_COUNT;c=c+1) begin
            if(client_req_valid_i[c]&&client_req_ready_o[c]) accepted_reads=accepted_reads+1;
            if(client_resp_valid_o[c]) returned_reads=returned_reads+1;
        end
        read_count_next=integer'(read_count_q)+accepted_reads-returned_reads;
        count_invalid=read_count_next<0||read_count_next>CLIENT_COUNT*CLIENT_MAX_OUTSTANDING;
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin read_count_q<='0;count_error_q<=1'b0;end
        else if(count_invalid) count_error_q<=1'b1;
        else if(!count_error_q) read_count_q<=CLIENT_READ_COUNT_W'(read_count_next);
    end
    // Both possible sources retain their own offered payload under backpressure.
    // Lock selection on the first stalled offer, even if the frontend changes
    // from L2_UPDATE to MISS while an older line command remains unaccepted.
    always_comb begin
        select_store=1'b0;select_line=1'b0;
        if(rst_n) begin
            if(hold_valid_q) begin
                select_store=hold_store_q;
                select_line=!hold_store_q;
            end else if(gen_cmd_valid) select_store=1'b1;
            else if(line_service_allowed&&p24_cmd_valid) select_line=1'b1;
        end
    end
    assign gen_cmd_ready=backend_cmd_ready_i&&select_store;
    assign p24_cmd_ready=backend_cmd_ready_i&&select_line;
    assign store_cmd_fire=gen_cmd_valid&&gen_cmd_ready;
    always_comb begin
        backend_cmd_valid_o=1'b0;
        backend_cmd_kind_o=2'b00;
        backend_cmd_read_tag_o='0;backend_cmd_wb_attempt_id_o='0;
        backend_cmd_store_attempt_id_o='0;backend_cmd_line_addr_o='0;
        backend_cmd_store_word_addr_o='0;backend_cmd_store_wdata_o='0;
        for(integer w=0;w<LINE_WORDS;w=w+1) backend_cmd_data_o[w]='0;
        if(select_store) begin
            backend_cmd_valid_o=gen_cmd_valid;backend_cmd_kind_o=2'b10;
            backend_cmd_store_attempt_id_o=gen_cmd_id;
            backend_cmd_store_word_addr_o=completion_addr;
            backend_cmd_store_wdata_o=completion_data;
        end else if(select_line) begin
            backend_cmd_valid_o=p24_cmd_valid;backend_cmd_kind_o=p24_cmd_write?2'b01:2'b00;
            backend_cmd_read_tag_o=p24_read_tag;backend_cmd_wb_attempt_id_o=p24_wb_id;
            backend_cmd_line_addr_o=p24_line_addr;
            for(integer w=0;w<LINE_WORDS;w=w+1) backend_cmd_data_o[w]=p24_data[w];
        end
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin hold_valid_q<=1'b0;hold_store_q<=1'b0;end
        else if(backend_cmd_valid_o) begin
            hold_valid_q<=!backend_cmd_ready_i;
            if(!backend_cmd_ready_i) hold_store_q<=select_store;
        end
    end

    a0_store_attempt_generation_guard #(
        .LOCAL_ATTEMPT_ID_W(P29_STORE_ATTEMPT_ID_W),.GENERATION_W(STORE_GENERATION_W),
        .EXTERNAL_ATTEMPT_ID_W(STORE_ATTEMPT_ID_W)
    ) u_generation (
        .clk(clk),.rst_n(rst_n),.local_cmd_valid_i(completion_cmd_valid),
        .local_cmd_attempt_id_i(completion_id),.backend_cmd_ready_i(gen_cmd_ready),
        .backend_status_valid_i(backend_store_status_valid_i),
        .backend_status_attempt_id_i(backend_store_status_attempt_id_i),
        .backend_status_success_i(backend_store_status_success_i),
        .backend_status_retryable_i(backend_store_status_retryable_i),
        .local_timeout_live_i(store_status_timeout_live_o),
        .local_timeout_pulse_i(store_status_timeout_pulse_o),.local_rearm_i(recovery_rearm_pulse_o),
        .backend_all_generations_quiescent_i(backend_store_all_generations_quiescent_i),
        .backend_cmd_valid_o(gen_cmd_valid),.backend_cmd_attempt_id_o(gen_cmd_id),
        .local_cmd_ready_o(completion_cmd_ready),.local_status_valid_o(real_status_valid),
        .local_status_attempt_id_o(real_status_id),.local_status_success_o(real_status_success),
        .local_status_retryable_o(real_status_retryable),.next_generation_o(store_generation_next_o),
        .wrap_pending_o(store_generation_wrap_pending_o),.status_rejected_o(store_status_rejected_o),
        .attempt_idle_o(store_attempt_idle)
    );
    a0_store_word_status_timeout_guard #(
        .ATTEMPT_ID_W(P29_STORE_ATTEMPT_ID_W),.STATUS_TIMEOUT_CYCLES(STORE_STATUS_TIMEOUT_CYCLES),
        .TIMER_W(STORE_STATUS_TIMER_W)
    ) u_timeout (
        .clk(clk),.rst_n(store_rst_n),.store_cmd_fire_i(store_cmd_fire),
        .store_cmd_attempt_id_i(completion_id),.backend_status_valid_i(real_status_valid),
        .backend_status_attempt_id_i(real_status_id),.backend_status_success_i(real_status_success),
        .backend_status_retryable_i(real_status_retryable),.guarded_status_valid_o(guarded_status_valid),
        .guarded_status_attempt_id_o(guarded_status_id),.guarded_status_success_o(guarded_status_success),
        .guarded_status_retryable_o(guarded_status_retryable),.live_o(store_status_timeout_live_o),
        .age_o(store_status_timeout_age_o),.timeout_pulse_o(store_status_timeout_pulse_o),
        .timeout_seen_o(store_status_timeout_seen_o),.protocol_error_o(timeout_error)
    );
    a0_store_word_completion_guard #(
        .WRITE_ID_W(STORE_WRITE_ID_W),.MAX_RETRIES(MAX_STORE_RETRIES),
        .RETRY_W(STORE_RETRY_W),.ATTEMPT_ID_W(P29_STORE_ATTEMPT_ID_W)
    ) u_completion (
        .clk(clk),.rst_n(store_rst_n),.store_valid_i(word_valid),.store_ready_o(word_ready),
        .store_word_addr_i(word_addr),.store_wdata_i(word_data),
        .backend_store_valid_o(completion_cmd_valid),.backend_store_ready_i(completion_cmd_ready),
        .backend_store_attempt_id_o(completion_id),.backend_store_word_addr_o(completion_addr),
        .backend_store_wdata_o(completion_data),.backend_store_status_valid_i(guarded_status_valid),
        .backend_store_status_attempt_id_i(guarded_status_id),.backend_store_status_success_i(guarded_status_success),
        .backend_store_status_retryable_i(guarded_status_retryable),.busy_o(store_completion_busy_o),
        .retry_count_o(store_retry_count_o),.terminal_failure_o(store_terminal_failure_o),
        .protocol_error_o(completion_error)
    );
    a0_store_commit_scoped_recovery_frontend #(
        .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT),.STORE_LANES(STORE_LANES),.SLICE_COUNT(SLICE_COUNT),
        .STORE_RETRY_W(STORE_RETRY_W),.COMMIT_PORT_ID_W(COMMIT_PORT_ID_W)
    ) u_frontend (
        .clk(clk),.rst_n(rst_n),.commit_valid_i(ordered_commit_valid),.commit_ready_o(commit_ready_o),
        .commit_lane_mask_i(commit_lane_mask_i),.commit_word_addr_i(commit_word_addr_i),.commit_wdata_i(commit_wdata_i),
        .p24_commit_ready_i(p24_commit_ready),.p24_slice_store_hit_mask_i(p24_hit),
        .p24_slice_store_miss_mask_i(p24_miss),.p24_commit_router_busy_i(p24_router_busy),
        .store_ready_i(word_ready),.store_terminal_failure_i(store_terminal_failure_o),
        .store_timeout_seen_i(store_status_timeout_seen_o),.store_retry_count_i(store_retry_count_o),
        .backend_store_status_reuse_safe_i(backend_store_status_reuse_safe_i),.store_attempt_idle_i(store_attempt_idle),
        .protocol_error_i(external_error),
        .commit_abort_o(commit_abort_o),.commit_fault_valid_o(commit_fault_valid_o),.commit_fault_ready_i(commit_fault_ready_i),
        .commit_fault_port_id_o(commit_fault_port_id_o),.commit_fault_lane_mask_o(commit_fault_lane_mask_o),
        .commit_fault_word_addr_o(commit_fault_word_addr_o),.commit_fault_wdata_o(commit_fault_wdata_o),
        .commit_fault_store_timeout_o(commit_fault_store_timeout_o),
        .commit_fault_store_retry_count_o(commit_fault_store_retry_count_o),
        .p24_commit_valid_o(p24_commit_valid),.p24_commit_lane_mask_o(p24_commit_lane_mask),
        .p24_commit_word_addr_o(p24_commit_word_addr),.p24_commit_wdata_o(p24_commit_wdata),
        .store_valid_o(word_valid),.store_word_addr_o(word_addr),.store_wdata_o(word_data),
        .captured_reservation_valid_o(captured_reservation_valid),
        .store_rearm_pulse_o(recovery_rearm_pulse_o),.recovery_required_o(recovery_required_o),
        .recovery_drain_active_o(recovery_drain_active_o),.client_admission_fenced_o(frontend_fenced),
        .line_service_allowed_o(line_service_allowed),.busy_o(commit_visibility_busy_o),.protocol_error_o(frontend_error)
    );
    a0_production_store_commit_dirty_l2_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT),.LOCAL_TAG_W(LOCAL_TAG_W),.CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),
        .COMMIT_PORT_COUNT(1),.STORE_LANES(STORE_LANES),.SLICE_COUNT(SLICE_COUNT),.LINE_WORDS(LINE_WORDS),
        .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE),.WRITE_ID_W(WRITE_ID_W),.MAX_WB_RETRIES(MAX_WB_RETRIES),
        .WORD_SELECT_W(WORD_SELECT_W),.LINE_ADDR_W(LINE_ADDR_W),.CLIENT_ID_W(CLIENT_ID_W),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),.SLICE_ID_W(SLICE_ID_W),.SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .RETRY_W(RETRY_W),.LOCAL_ATTEMPT_ID_W(LOCAL_ATTEMPT_ID_W),.BACKEND_ATTEMPT_ID_W(BACKEND_ATTEMPT_ID_W),
        .BACKEND_READ_TAG_W(BACKEND_READ_TAG_W),.COUNT_W(COUNT_W)
    ) u_p24 (
        .clk(clk),.rst_n(rst_n),.client_req_valid_i(p24_req_valid),.client_req_ready_o(p24_req_ready),
        .client_req_local_tag_i(client_req_local_tag_i),.client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(client_resp_valid_o),.client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),.client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),.commit_valid_i(p24_commit_valid),.commit_ready_o(p24_commit_ready),
        .commit_lane_mask_i(p24_commit_lane_mask),.commit_word_addr_i(p24_commit_word_addr),.commit_wdata_i(p24_commit_wdata),
        .backend_cmd_valid_o(p24_cmd_valid),.backend_cmd_ready_i(p24_cmd_ready),.backend_cmd_write_o(p24_cmd_write),
        .backend_cmd_read_tag_o(p24_read_tag),.backend_cmd_wb_attempt_id_o(p24_wb_id),
        .backend_cmd_line_addr_o(p24_line_addr),.backend_cmd_data_o(p24_data),
        .backend_read_resp_valid_i(backend_read_resp_valid_i),.backend_read_resp_tag_i(backend_read_resp_tag_i),
        .backend_read_resp_line_addr_i(backend_read_resp_line_addr_i),.backend_read_resp_fault_i(backend_read_resp_fault_i),
        .backend_read_resp_data_i(backend_read_resp_data_i),.backend_wb_status_valid_i(backend_wb_status_valid_i),
        .backend_wb_status_attempt_id_i(backend_wb_status_attempt_id_i),.backend_wb_status_success_i(backend_wb_status_success_i),
        .backend_wb_status_retryable_i(backend_wb_status_retryable_i),
        .backend_wb_recovery_safe_valid_i(backend_wb_recovery_safe_valid_i),.backend_wb_recovery_safe_ready_o(backend_wb_recovery_safe_ready_o),
        .slice_store_hit_mask_o(p24_hit),.slice_store_miss_mask_o(p24_miss),.dirty_present_o(dirty_present_o),
        .wb_busy_o(wb_busy_o),.wb_retry_count_o(wb_retry_count_o),.wb_terminal_failure_o(wb_terminal_failure_o),
        .recovery_active_o(recovery_active_o),.recovery_complete_pulse_o(recovery_complete_pulse_o),
        .wb_pending_count_o(wb_pending_count_o),.wb_active_count_o(wb_active_count_o),.commit_router_busy_o(p24_router_busy),
        .line_resp_tag_error_o(line_resp_tag_error_o),.line_resp_overflow_o(line_resp_overflow_o),.protocol_error_o(p24_error)
    );
endmodule
