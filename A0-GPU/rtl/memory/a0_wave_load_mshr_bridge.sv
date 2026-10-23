`timescale 1ns/1ps

/*
 * A0-RTL8B wave-load -> line-MSHR bridge.
 *
 * One architectural VLOADX arrives as a wave-sized set of validated word
 * addresses. The bridge keeps one logical load transaction per resident wave,
 * decomposes each transaction into LINE_WORDS cache-line requests, and feeds
 * those requests into the proven RTL8A a0_mshr_table.
 *
 * Important contracts:
 *   - multiple resident waves may own logical loads concurrently
 *   - one wave may allocate multiple MSHR entries when its lanes span lines
 *   - same-line lanes of one wave are grouped into one waiter
 *   - same-line waiters from different waves merge in a0_mshr_table
 *   - table/backend responses may return out of order
 *   - line completions are accumulated into a wave-sized result buffer
 *   - the architectural wave completion is emitted only after every active
 *     lane of that load has completed (or faulted)
 *
 * Stores intentionally do not pass through this bridge in RTL8B.
 */
module a0_wave_load_mshr_bridge #(
    parameter integer MSHR_COUNT = 2,
    parameter integer RESIDENT_WAVES = 4,
    parameter integer WAVE_SIZE = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer STORE_SEQ_W = 64,
    parameter integer PEER_STORE_SOURCE_COUNT = 1,

    parameter integer ENTRY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),
    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer CONTEXT_ID_W = WAVE_ID_W,
    parameter integer VECTOR_REG_INDEX_W =
        (VECTOR_REG_COUNT <= 1) ? 1 : $clog2(VECTOR_REG_COUNT),
    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer OCCUPANCY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT + 1)
) (
    input logic clk,
    input logic rst_n,

    /* Whole-wave VLOADX enqueue after indexed-address construction. */
    input logic load_valid_i,
    output logic load_ready_o,
    output logic load_fire_o,
    input logic [WAVE_ID_W-1:0] load_wave_i,
    input logic [CONTEXT_ID_W-1:0] load_context_i,
    input logic [VECTOR_REG_INDEX_W-1:0] load_dst_i,
    input logic [WAVE_SIZE-1:0] load_lane_mask_i,
    input logic [31:0] load_word_addr_i [0:WAVE_SIZE-1],

    /* RTL8C-5B provisional store-forwarding inputs. */
    input logic [WAVE_SIZE-1:0] load_forward_valid_lane_mask_i,
    input logic [STORE_SEQ_W-1:0]
        load_forward_seq_i [0:WAVE_SIZE-1],
    input logic [31:0] load_forward_data_i [0:WAVE_SIZE-1],

    input logic store_resolve_valid_i,
    input logic [STORE_SEQ_W-1:0] store_resolve_seq_i,
    input logic store_resolve_fault_i,

    /* Wrapper-filtered peer raw/pending metadata. */
    input logic [PEER_STORE_SOURCE_COUNT-1:0]
        ordering_store_valid_i,
    input logic [WAVE_SIZE-1:0]
        ordering_store_lane_mask_i [0:PEER_STORE_SOURCE_COUNT-1],
    input logic [31:0] ordering_store_word_addr_i
        [0:PEER_STORE_SOURCE_COUNT-1][0:WAVE_SIZE-1],

    /* Matched success/fault close metadata; self is not filtered. */
    input logic [PEER_STORE_SOURCE_COUNT-1:0]
        terminal_store_valid_i,
    input logic [WAVE_SIZE-1:0]
        terminal_store_lane_mask_i [0:PEER_STORE_SOURCE_COUNT-1],
    input logic [31:0] terminal_store_word_addr_i
        [0:PEER_STORE_SOURCE_COUNT-1][0:WAVE_SIZE-1],

    /* External line-fill request/response interface. */
    output logic miss_req_valid_o,
    input logic miss_req_ready_i,
    output logic [ENTRY_W-1:0] miss_req_entry_o,
    output logic [LINE_ADDR_W-1:0] miss_req_line_addr_o,

    input logic miss_resp_valid_i,
    input logic [ENTRY_W-1:0] miss_resp_entry_i,
    input logic [LINE_ADDR_W-1:0] miss_resp_line_addr_i,
    input logic miss_resp_fault_i,
    input logic [31:0] miss_resp_line_data_i [0:LINE_WORDS-1],

    output logic response_tag_error_o,

    /* One completed architectural load transaction at a time. */
    output logic complete_valid_o,
    input logic complete_ready_i,
    output logic [WAVE_ID_W-1:0] complete_wave_o,
    output logic [CONTEXT_ID_W-1:0] complete_context_o,
    output logic [VECTOR_REG_INDEX_W-1:0] complete_dst_o,
    output logic [WAVE_SIZE-1:0] complete_lane_mask_o,
    output logic complete_fault_o,
    output logic [31:0] complete_data_o [0:WAVE_SIZE-1],

    /* Verification / scheduler-facing telemetry. */
    output logic [OCCUPANCY_W-1:0] occupancy_o,
    output logic full_o,
    output logic empty_o,
    output logic [RESIDENT_WAVES-1:0] active_wave_mask_o,
    output logic allocation_event_o,
    output logic merge_event_o,
    output logic allocator_stall_o,
    output logic forward_dependency_active_o
);

    logic wave_active_q [0:RESIDENT_WAVES-1];
    logic [CONTEXT_ID_W-1:0] wave_context_q [0:RESIDENT_WAVES-1];
    logic [VECTOR_REG_INDEX_W-1:0] wave_dst_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] wave_expected_mask_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] wave_pending_mask_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] wave_completed_mask_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] wave_forward_wait_mask_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] wave_forward_success_mask_q [0:RESIDENT_WAVES-1];
    logic [STORE_SEQ_W-1:0] wave_forward_seq_q
        [0:RESIDENT_WAVES-1]
        [0:WAVE_SIZE-1];
    logic wave_fault_q [0:RESIDENT_WAVES-1];
    logic [31:0] wave_addr_q
        [0:RESIDENT_WAVES-1]
        [0:WAVE_SIZE-1];
    logic [31:0] wave_data_q
        [0:RESIDENT_WAVES-1]
        [0:WAVE_SIZE-1];

    logic [WAVE_ID_W-1:0] alloc_rr_q;

    logic allocator_wave_found;
    logic [WAVE_ID_W-1:0] allocator_wave;
    logic allocator_lane_found;
    logic [LINE_ADDR_W-1:0] allocator_line_addr;
    logic [WAVE_SIZE-1:0] allocator_line_lane_mask;
    logic [WORD_SELECT_W-1:0]
        allocator_lane_word_select [0:WAVE_SIZE-1];

    logic mshr_req_valid;
    logic mshr_req_ready;
    logic mshr_req_fire;
    logic mshr_req_allocated;
    logic mshr_req_merged;
    logic mshr_req_blocked_draining_unused;
    logic mshr_req_duplicate_waiter_unused;
    logic [ENTRY_W-1:0] mshr_req_entry;

    logic mshr_resp_accept_unused;
    logic mshr_resp_tag_error;

    logic mshr_complete_valid;
    logic mshr_complete_ready;
    logic [ENTRY_W-1:0] mshr_complete_entry_unused;
    logic [WAVE_ID_W-1:0] mshr_complete_wave;
    logic [CONTEXT_ID_W-1:0] mshr_complete_context;
    logic [VECTOR_REG_INDEX_W-1:0] mshr_complete_dst;
    logic [WAVE_SIZE-1:0] mshr_complete_lane_mask;
    logic [WORD_SELECT_W-1:0]
        mshr_complete_lane_word_select [0:WAVE_SIZE-1];
    logic mshr_complete_fault;
    logic [31:0] mshr_complete_line_data [0:LINE_WORDS-1];

    logic [MSHR_COUNT-1:0] mshr_valid_mask;
    /* Historical TB alias; the source of truth is mshr_valid_mask. */
    logic [MSHR_COUNT-1:0] mshr_valid_mask_unused;
    logic [MSHR_COUNT-1:0] mshr_issued_mask_unused;
    logic [MSHR_COUNT-1:0] mshr_response_ready_mask_unused;

    logic [MSHR_COUNT-1:0] merge_quarantine_q;
    logic [MSHR_COUNT-1:0] merge_quarantine_set;
    logic [LINE_ADDR_W-1:0] mshr_entry_line_q [0:MSHR_COUNT-1];
    logic allocator_pending_found;
    logic allocator_candidate_lane_found;
    logic [LINE_ADDR_W-1:0] allocator_candidate_line_addr;

    logic complete_wave_found;
    logic [WAVE_ID_W-1:0] complete_wave;

    integer active_scan;
    integer alloc_scan_offset;
    integer alloc_scan_wave;
    integer allocator_group_lane;
    integer complete_scan;
    integer complete_output_lane;
    integer candidate_lane_scan;
    integer quarantine_set_entry;


    function automatic logic peer_store_conflicts_line(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer source;
        integer lane;
        begin
            peer_store_conflicts_line = 1'b0;
            for (source = 0;
                 source < PEER_STORE_SOURCE_COUNT;
                 source = source + 1) begin
                if (ordering_store_valid_i[source]) begin
                    for (lane = 0; lane < WAVE_SIZE;
                         lane = lane + 1) begin
                        if (ordering_store_lane_mask_i[source][lane]
                            && ordering_store_word_addr_i[source][lane]
                                [31:WORD_SELECT_W] == line_addr)
                            peer_store_conflicts_line = 1'b1;
                    end
                end
            end
        end
    endfunction


    function automatic logic quarantined_line(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer entry;
        begin
            quarantined_line = 1'b0;
            for (entry = 0; entry < MSHR_COUNT;
                 entry = entry + 1) begin
                if (merge_quarantine_q[entry]
                    && mshr_valid_mask[entry]
                    && mshr_entry_line_q[entry] == line_addr)
                    quarantined_line = 1'b1;
            end
        end
    endfunction


    function automatic logic terminal_store_matches_line(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer source;
        integer lane;
        begin
            terminal_store_matches_line = 1'b0;
            for (source = 0;
                 source < PEER_STORE_SOURCE_COUNT;
                 source = source + 1) begin
                if (terminal_store_valid_i[source]) begin
                    for (lane = 0; lane < WAVE_SIZE;
                         lane = lane + 1) begin
                        if (terminal_store_lane_mask_i[source][lane]
                            && terminal_store_word_addr_i[source][lane]
                                [31:WORD_SELECT_W] == line_addr)
                            terminal_store_matches_line = 1'b1;
                    end
                end
            end
        end
    endfunction


    function automatic logic candidate_line_blocked(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        candidate_line_blocked =
            peer_store_conflicts_line(line_addr)
            || quarantined_line(line_addr);
    endfunction


    function automatic logic wave_id_valid(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        wave_id_valid = integer'(wave_id) < RESIDENT_WAVES;
    endfunction


    /* A logical wave can own at most one outstanding VLOADX in RTL8B. */
    always_comb begin
        load_ready_o = 1'b0;
        if (wave_id_valid(load_wave_i)) begin
            load_ready_o =
                !wave_active_q[integer'(load_wave_i)]
                && load_lane_mask_i != '0;
        end
        load_fire_o = load_valid_i && load_ready_o;
    end


    always_comb begin
        active_wave_mask_o = '0;
        forward_dependency_active_o = 1'b0;

        for (
            active_scan = 0;
            active_scan < RESIDENT_WAVES;
            active_scan = active_scan + 1
        ) begin
            active_wave_mask_o[active_scan] = wave_active_q[active_scan];
            if (
                wave_active_q[active_scan]
                && wave_forward_wait_mask_q[active_scan] != '0
            ) begin
                forward_dependency_active_o = 1'b1;
            end
        end
    end


    /*
     * Work-conserving round-robin allocator.  Within each wave it scans past
     * peer-store/quarantined lines, then scans later waves.  Pending lanes are
     * removed only after the unchanged MSHR table actually accepts a request.
     */
    always_comb begin
        allocator_wave_found = 1'b0;
        allocator_wave = '0;
        allocator_pending_found = 1'b0;
        allocator_lane_found = 1'b0;
        allocator_line_addr = '0;
        allocator_line_lane_mask = '0;
        alloc_scan_wave = 0;
        allocator_candidate_lane_found = 1'b0;
        allocator_candidate_line_addr = '0;

        for (allocator_group_lane = 0;
             allocator_group_lane < WAVE_SIZE;
             allocator_group_lane = allocator_group_lane + 1) begin
            allocator_lane_word_select[allocator_group_lane] = '0;
        end

        for (alloc_scan_offset = 0;
             alloc_scan_offset < RESIDENT_WAVES;
             alloc_scan_offset = alloc_scan_offset + 1) begin
            alloc_scan_wave = integer'(alloc_rr_q) + alloc_scan_offset;
            if (alloc_scan_wave >= RESIDENT_WAVES)
                alloc_scan_wave = alloc_scan_wave - RESIDENT_WAVES;

            allocator_candidate_lane_found = 1'b0;
            allocator_candidate_line_addr = '0;
            if (wave_active_q[alloc_scan_wave]
                && wave_pending_mask_q[alloc_scan_wave] != '0)
                allocator_pending_found = 1'b1;

            if (!allocator_wave_found
                && wave_active_q[alloc_scan_wave]
                && wave_pending_mask_q[alloc_scan_wave] != '0) begin
                for (candidate_lane_scan = 0;
                     candidate_lane_scan < WAVE_SIZE;
                     candidate_lane_scan = candidate_lane_scan + 1) begin
                    if (!allocator_candidate_lane_found
                        && wave_pending_mask_q[alloc_scan_wave][
                            candidate_lane_scan
                        ]) begin
                        allocator_candidate_line_addr =
                            wave_addr_q[alloc_scan_wave][
                                candidate_lane_scan
                            ][31:WORD_SELECT_W];
                        if (!candidate_line_blocked(
                            wave_addr_q[alloc_scan_wave][
                                candidate_lane_scan
                            ][31:WORD_SELECT_W]
                        )) begin
                            allocator_candidate_lane_found = 1'b1;
                        end
                    end
                end

                if (allocator_candidate_lane_found) begin
                    allocator_wave_found = 1'b1;
                    allocator_wave = WAVE_ID_W'(alloc_scan_wave);
                    allocator_lane_found = 1'b1;
                    allocator_line_addr = allocator_candidate_line_addr;
                end
            end
        end

        if (allocator_wave_found && allocator_lane_found) begin
            for (allocator_group_lane = 0;
                 allocator_group_lane < WAVE_SIZE;
                 allocator_group_lane = allocator_group_lane + 1) begin
                if (wave_pending_mask_q[integer'(allocator_wave)][
                        allocator_group_lane
                    ]
                    && wave_addr_q[integer'(allocator_wave)][
                        allocator_group_lane
                    ][31:WORD_SELECT_W] == allocator_line_addr) begin
                    allocator_line_lane_mask[allocator_group_lane] = 1'b1;
                    allocator_lane_word_select[allocator_group_lane] =
                        wave_addr_q[integer'(allocator_wave)][
                            allocator_group_lane
                        ][WORD_SELECT_W-1:0];
                end
            end
        end
    end


    /* Store resolve gets a quiet allocator cycle for fault re-arm. */
    assign mshr_req_valid = (
        allocator_wave_found
        && allocator_lane_found
        && !store_resolve_valid_i
    );

    assign allocation_event_o = mshr_req_fire && mshr_req_allocated;
    assign merge_event_o = mshr_req_fire && mshr_req_merged;
    assign allocator_stall_o =
        (allocator_pending_found && !allocator_wave_found)
        || (mshr_req_valid && !mshr_req_ready);
    assign response_tag_error_o = mshr_resp_tag_error;
    assign mshr_valid_mask_unused = mshr_valid_mask;


    /*
     * The table's completion payload is always accepted into per-wave storage
     * when the target waiter metadata still matches the active transaction.
     */
    assign mshr_complete_ready =
        mshr_complete_valid
        && wave_id_valid(mshr_complete_wave)
        && wave_active_q[integer'(mshr_complete_wave)]
        && wave_context_q[integer'(mshr_complete_wave)]
            == mshr_complete_context
        && wave_dst_q[integer'(mshr_complete_wave)]
            == mshr_complete_dst;


    /* Lowest resident-wave ID wins the architectural completion output. */
    always_comb begin
        complete_wave_found = 1'b0;
        complete_wave = '0;

        for (
            complete_scan = 0;
            complete_scan < RESIDENT_WAVES;
            complete_scan = complete_scan + 1
        ) begin
            if (
                !complete_wave_found
                && wave_active_q[complete_scan]
                && wave_pending_mask_q[complete_scan] == '0
                && wave_forward_wait_mask_q[complete_scan] == '0
                && (
                    wave_completed_mask_q[complete_scan]
                    | wave_forward_success_mask_q[complete_scan]
                ) == wave_expected_mask_q[complete_scan]
            ) begin
                complete_wave_found = 1'b1;
                complete_wave = WAVE_ID_W'(complete_scan);
            end
        end

        complete_valid_o = complete_wave_found;
        complete_wave_o = complete_wave;
        complete_context_o = '0;
        complete_dst_o = '0;
        complete_lane_mask_o = '0;
        complete_fault_o = 1'b0;

        for (
            complete_output_lane = 0;
            complete_output_lane < WAVE_SIZE;
            complete_output_lane = complete_output_lane + 1
        ) begin
            complete_data_o[complete_output_lane] = '0;
        end

        if (complete_wave_found) begin
            complete_context_o = wave_context_q[integer'(complete_wave)];
            complete_dst_o = wave_dst_q[integer'(complete_wave)];
            complete_lane_mask_o =
                wave_expected_mask_q[integer'(complete_wave)];
            complete_fault_o = wave_fault_q[integer'(complete_wave)];

            for (
                complete_output_lane = 0;
                complete_output_lane < WAVE_SIZE;
                complete_output_lane = complete_output_lane + 1
            ) begin
                complete_data_o[complete_output_lane] =
                    wave_data_q[
                        integer'(complete_wave)
                    ][complete_output_lane];
            end
        end
    end


    /* Terminal-cycle close mask is sampled while pending still blocks. */
    always_comb begin
        merge_quarantine_set = '0;
        for (quarantine_set_entry = 0; quarantine_set_entry < MSHR_COUNT;
             quarantine_set_entry = quarantine_set_entry + 1) begin
            merge_quarantine_set[quarantine_set_entry] =
                mshr_valid_mask[quarantine_set_entry]
                && terminal_store_matches_line(
                    mshr_entry_line_q[quarantine_set_entry]
                );
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            merge_quarantine_q <= '0;
            for (integer quarantine_entry = 0; quarantine_entry < MSHR_COUNT;
                 quarantine_entry = quarantine_entry + 1)
                mshr_entry_line_q[quarantine_entry] <= '0;
        end else begin
            for (integer quarantine_entry = 0; quarantine_entry < MSHR_COUNT;
                 quarantine_entry = quarantine_entry + 1) begin
                if (mshr_req_fire && mshr_req_allocated
                    && mshr_req_entry == ENTRY_W'(quarantine_entry)) begin
                    mshr_entry_line_q[quarantine_entry] <=
                        allocator_line_addr;
                    merge_quarantine_q[quarantine_entry] <= 1'b0;
                end else if (!mshr_valid_mask[quarantine_entry]) begin
                    merge_quarantine_q[quarantine_entry] <= 1'b0;
                end else if (merge_quarantine_set[quarantine_entry]) begin
                    merge_quarantine_q[quarantine_entry] <= 1'b1;
                end
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            alloc_rr_q <= '0;

            for (
                integer reset_wave = 0;
                reset_wave < RESIDENT_WAVES;
                reset_wave = reset_wave + 1
            ) begin
                wave_active_q[reset_wave] <= 1'b0;
                wave_context_q[reset_wave] <= '0;
                wave_dst_q[reset_wave] <= '0;
                wave_expected_mask_q[reset_wave] <= '0;
                wave_pending_mask_q[reset_wave] <= '0;
                wave_completed_mask_q[reset_wave] <= '0;
                wave_forward_wait_mask_q[reset_wave] <= '0;
                wave_forward_success_mask_q[reset_wave] <= '0;
                wave_fault_q[reset_wave] <= 1'b0;

                for (
                    integer reset_lane = 0;
                    reset_lane < WAVE_SIZE;
                    reset_lane = reset_lane + 1
                ) begin
                    wave_addr_q[reset_wave][reset_lane] <= '0;
                    wave_data_q[reset_wave][reset_lane] <= '0;
                    wave_forward_seq_q[reset_wave][reset_lane] <= '0;
                end
            end
        end else begin
            if (load_fire_o) begin
                wave_active_q[integer'(load_wave_i)] <= 1'b1;
                wave_context_q[integer'(load_wave_i)] <= load_context_i;
                wave_dst_q[integer'(load_wave_i)] <= load_dst_i;
                wave_expected_mask_q[integer'(load_wave_i)] <= load_lane_mask_i;
                wave_pending_mask_q[integer'(load_wave_i)] <=
                    load_lane_mask_i & ~load_forward_valid_lane_mask_i;
                wave_completed_mask_q[integer'(load_wave_i)] <= '0;
                wave_forward_wait_mask_q[integer'(load_wave_i)] <=
                    load_lane_mask_i & load_forward_valid_lane_mask_i;
                wave_forward_success_mask_q[integer'(load_wave_i)] <= '0;
                wave_fault_q[integer'(load_wave_i)] <= 1'b0;

                for (
                    integer load_lane = 0;
                    load_lane < WAVE_SIZE;
                    load_lane = load_lane + 1
                ) begin
                    wave_addr_q[
                        integer'(load_wave_i)
                    ][load_lane] <= load_word_addr_i[load_lane];
                    wave_forward_seq_q[
                        integer'(load_wave_i)
                    ][load_lane] <= load_forward_seq_i[load_lane];

                    if (
                        load_lane_mask_i[load_lane]
                        && load_forward_valid_lane_mask_i[load_lane]
                    ) begin
                        wave_data_q[
                            integer'(load_wave_i)
                        ][load_lane] <= load_forward_data_i[load_lane];
                    end else begin
                        wave_data_q[
                            integer'(load_wave_i)
                        ][load_lane] <= '0;
                    end
                end
            end

            /*
             * Source success commits provisional data inside the logical load.
             * Source fault discards it and re-arms that lane for normal MSHR
             * access to the pre-store memory value.
             */
            if (store_resolve_valid_i) begin
                for (
                    integer resolve_wave = 0;
                    resolve_wave < RESIDENT_WAVES;
                    resolve_wave = resolve_wave + 1
                ) begin
                    if (wave_active_q[resolve_wave]) begin
                        for (
                            integer resolve_lane = 0;
                            resolve_lane < WAVE_SIZE;
                            resolve_lane = resolve_lane + 1
                        ) begin
                            if (
                                wave_forward_wait_mask_q[resolve_wave][resolve_lane]
                                && wave_forward_seq_q[resolve_wave][resolve_lane]
                                    == store_resolve_seq_i
                            ) begin
                                wave_forward_wait_mask_q[
                                    resolve_wave
                                ][resolve_lane] <= 1'b0;

                                if (store_resolve_fault_i) begin
                                    wave_pending_mask_q[
                                        resolve_wave
                                    ][resolve_lane] <= 1'b1;
                                    wave_data_q[
                                        resolve_wave
                                    ][resolve_lane] <= '0;
                                end else begin
                                    wave_forward_success_mask_q[
                                        resolve_wave
                                    ][resolve_lane] <= 1'b1;
                                end
                            end
                        end
                    end
                end
            end

            if (mshr_req_fire) begin
                wave_pending_mask_q[integer'(allocator_wave)] <=
                    wave_pending_mask_q[integer'(allocator_wave)]
                    & ~allocator_line_lane_mask;

                if (
                    integer'(allocator_wave) == RESIDENT_WAVES - 1
                ) begin
                    alloc_rr_q <= '0;
                end else begin
                    alloc_rr_q <= allocator_wave + WAVE_ID_W'(1);
                end
            end

            if (mshr_complete_valid && mshr_complete_ready) begin
                wave_completed_mask_q[integer'(mshr_complete_wave)] <=
                    wave_completed_mask_q[integer'(mshr_complete_wave)]
                    | mshr_complete_lane_mask;

                if (mshr_complete_fault) begin
                    wave_fault_q[integer'(mshr_complete_wave)] <= 1'b1;
                end else begin
                    for (
                        integer table_completion_lane = 0;
                        table_completion_lane < WAVE_SIZE;
                        table_completion_lane = table_completion_lane + 1
                    ) begin
                        if (mshr_complete_lane_mask[table_completion_lane]) begin
                            wave_data_q[
                                integer'(mshr_complete_wave)
                            ][table_completion_lane] <=
                                mshr_complete_line_data[
                                    integer'(
                                        mshr_complete_lane_word_select[
                                            table_completion_lane
                                        ]
                                    )
                                ];
                        end
                    end
                end
            end

            if (complete_valid_o && complete_ready_i) begin
                wave_active_q[integer'(complete_wave_o)] <= 1'b0;
                wave_expected_mask_q[integer'(complete_wave_o)] <= '0;
                wave_pending_mask_q[integer'(complete_wave_o)] <= '0;
                wave_completed_mask_q[integer'(complete_wave_o)] <= '0;
                wave_forward_wait_mask_q[integer'(complete_wave_o)] <= '0;
                wave_forward_success_mask_q[integer'(complete_wave_o)] <= '0;
                wave_fault_q[integer'(complete_wave_o)] <= 1'b0;
            end
        end
    end


    a0_mshr_table #(
        .MSHR_COUNT(MSHR_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(LINE_WORDS),
        .LINE_ADDR_W(LINE_ADDR_W),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT)
    ) mshr_table (
        .clk(clk),
        .rst_n(rst_n),

        .req_valid_i(mshr_req_valid),
        .req_ready_o(mshr_req_ready),
        .req_line_addr_i(allocator_line_addr),
        .req_wave_i(allocator_wave),
        .req_context_i(wave_context_q[integer'(allocator_wave)]),
        .req_dst_i(wave_dst_q[integer'(allocator_wave)]),
        .req_lane_mask_i(allocator_line_lane_mask),
        .req_lane_word_select_i(allocator_lane_word_select),
        .req_fire_o(mshr_req_fire),
        .req_allocated_o(mshr_req_allocated),
        .req_merged_o(mshr_req_merged),
        .req_blocked_draining_o(mshr_req_blocked_draining_unused),
        .req_duplicate_waiter_o(mshr_req_duplicate_waiter_unused),
        .req_entry_o(mshr_req_entry),

        .miss_req_valid_o(miss_req_valid_o),
        .miss_req_ready_i(miss_req_ready_i),
        .miss_req_entry_o(miss_req_entry_o),
        .miss_req_line_addr_o(miss_req_line_addr_o),

        .resp_valid_i(miss_resp_valid_i),
        .resp_entry_i(miss_resp_entry_i),
        .resp_line_addr_i(miss_resp_line_addr_i),
        .resp_fault_i(miss_resp_fault_i),
        .resp_line_data_i(miss_resp_line_data_i),
        .resp_accept_o(mshr_resp_accept_unused),
        .resp_tag_error_o(mshr_resp_tag_error),

        .complete_valid_o(mshr_complete_valid),
        .complete_ready_i(mshr_complete_ready),
        .complete_entry_o(mshr_complete_entry_unused),
        .complete_wave_o(mshr_complete_wave),
        .complete_context_o(mshr_complete_context),
        .complete_dst_o(mshr_complete_dst),
        .complete_lane_mask_o(mshr_complete_lane_mask),
        .complete_lane_word_select_o(mshr_complete_lane_word_select),
        .complete_fault_o(mshr_complete_fault),
        .complete_line_data_o(mshr_complete_line_data),

        .occupancy_o(occupancy_o),
        .full_o(full_o),
        .empty_o(empty_o),
        .valid_mask_o(mshr_valid_mask),
        .issued_mask_o(mshr_issued_mask_unused),
        .response_ready_mask_o(mshr_response_ready_mask_unused)
    );

endmodule
