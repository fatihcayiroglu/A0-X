`timescale 1ns/1ps

/*
 * A0-RTL8A non-blocking-memory MSHR foundation.
 *
 * Contract:
 *   - one entry per distinct outstanding cache line
 *   - same-line requests merge into the existing open entry
 *   - at most one waiter per resident wave per entry in RTL8A
 *   - new entries may wait internally until the downstream miss port accepts
 *   - backend responses are routed by {entry,line} and may return out of order
 *   - a completed entry drains one waiter at a time before the slot is reused
 *   - requests targeting a line already in completion-drain are backpressured;
 *     RTL8A never creates a duplicate live entry for the same line
 *
 * The table was proven independently in RTL8A. RTL8B now reuses the same
 * primitive behind the live wave-load bridge; the allocation/merge/response
 * contract remains self-contained and independently regressible.
 */
module a0_mshr_table #(
    parameter integer MSHR_COUNT = 4,
    parameter integer RESIDENT_WAVES = 4,
    parameter integer WAVE_SIZE = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer LINE_ADDR_W = 29,
    parameter integer VECTOR_REG_COUNT = 64,

    parameter integer ENTRY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),
    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer CONTEXT_ID_W = WAVE_ID_W,
    parameter integer VECTOR_REG_INDEX_W =
        (VECTOR_REG_COUNT <= 1) ? 1 : $clog2(VECTOR_REG_COUNT),
    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS),
    parameter integer OCCUPANCY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT + 1)
) (
    input logic clk,
    input logic rst_n,

    /* Frontend allocation / same-line merge request. */
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [LINE_ADDR_W-1:0] req_line_addr_i,
    input logic [WAVE_ID_W-1:0] req_wave_i,
    input logic [CONTEXT_ID_W-1:0] req_context_i,
    input logic [VECTOR_REG_INDEX_W-1:0] req_dst_i,
    input logic [WAVE_SIZE-1:0] req_lane_mask_i,
    input logic [WORD_SELECT_W-1:0]
        req_lane_word_select_i [0:WAVE_SIZE-1],

    output logic req_fire_o,
    output logic req_allocated_o,
    output logic req_merged_o,
    output logic req_blocked_draining_o,
    output logic req_duplicate_waiter_o,
    output logic [ENTRY_W-1:0] req_entry_o,

    /* One downstream miss-request issue port. */
    output logic miss_req_valid_o,
    input logic miss_req_ready_i,
    output logic [ENTRY_W-1:0] miss_req_entry_o,
    output logic [LINE_ADDR_W-1:0] miss_req_line_addr_o,

    /*
     * Backend response. The response tag must echo both the entry ID and line
     * address. Mismatches are rejected without consuming the live entry.
     */
    input logic resp_valid_i,
    input logic [ENTRY_W-1:0] resp_entry_i,
    input logic [LINE_ADDR_W-1:0] resp_line_addr_i,
    input logic resp_fault_i,
    input logic [31:0] resp_line_data_i [0:LINE_WORDS-1],

    output logic resp_accept_o,
    output logic resp_tag_error_o,

    /* Completion-drain port: one merged waiter per handshake. */
    output logic complete_valid_o,
    input logic complete_ready_i,
    output logic [ENTRY_W-1:0] complete_entry_o,
    output logic [WAVE_ID_W-1:0] complete_wave_o,
    output logic [CONTEXT_ID_W-1:0] complete_context_o,
    output logic [VECTOR_REG_INDEX_W-1:0] complete_dst_o,
    output logic [WAVE_SIZE-1:0] complete_lane_mask_o,
    output logic [WORD_SELECT_W-1:0]
        complete_lane_word_select_o [0:WAVE_SIZE-1],
    output logic complete_fault_o,
    output logic [31:0] complete_line_data_o [0:LINE_WORDS-1],

    /* Capacity / scheduler-facing telemetry. */
    output logic [OCCUPANCY_W-1:0] occupancy_o,
    output logic full_o,
    output logic empty_o,
    output logic [MSHR_COUNT-1:0] valid_mask_o,
    output logic [MSHR_COUNT-1:0] issued_mask_o,
    output logic [MSHR_COUNT-1:0] response_ready_mask_o
);

    logic entry_valid_q [0:MSHR_COUNT-1];
    logic entry_issued_q [0:MSHR_COUNT-1];
    logic entry_response_ready_q [0:MSHR_COUNT-1];
    logic entry_fault_q [0:MSHR_COUNT-1];
    logic [LINE_ADDR_W-1:0] entry_line_q [0:MSHR_COUNT-1];
    logic [31:0] entry_line_data_q
        [0:MSHR_COUNT-1]
        [0:LINE_WORDS-1];

    logic waiter_valid_q
        [0:MSHR_COUNT-1]
        [0:RESIDENT_WAVES-1];
    logic [CONTEXT_ID_W-1:0] waiter_context_q
        [0:MSHR_COUNT-1]
        [0:RESIDENT_WAVES-1];
    logic [VECTOR_REG_INDEX_W-1:0] waiter_dst_q
        [0:MSHR_COUNT-1]
        [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] waiter_lane_mask_q
        [0:MSHR_COUNT-1]
        [0:RESIDENT_WAVES-1];
    logic [WORD_SELECT_W-1:0] waiter_lane_word_select_q
        [0:MSHR_COUNT-1]
        [0:RESIDENT_WAVES-1]
        [0:WAVE_SIZE-1];

    logic open_match_found;
    logic [ENTRY_W-1:0] open_match_entry;
    logic draining_match_found;
    logic free_found;
    logic [ENTRY_W-1:0] free_entry;
    logic req_wave_valid;
    logic duplicate_waiter;

    logic miss_found;
    logic [ENTRY_W-1:0] miss_entry;

    logic complete_entry_found;
    logic [ENTRY_W-1:0] complete_entry;
    logic complete_wave_found;
    logic [WAVE_ID_W-1:0] complete_wave;
    logic complete_last_waiter;

    logic response_entry_valid;
    logic response_entry_live;
    logic response_tag_match;
    logic response_issue_accepted_same_cycle;

    integer aggregate_entry;
    integer lookup_entry;
    integer miss_search_entry;
    integer completion_entry_scan;
    integer completion_wave_scan;
    integer completion_lane;
    integer completion_word;


    function automatic logic entry_id_valid(
        input logic [ENTRY_W-1:0] entry_id
    );
        entry_id_valid = integer'(entry_id) < MSHR_COUNT;
    endfunction


    function automatic logic wave_id_valid(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        wave_id_valid = integer'(wave_id) < RESIDENT_WAVES;
    endfunction


    always_comb begin
        valid_mask_o = '0;
        issued_mask_o = '0;
        response_ready_mask_o = '0;
        occupancy_o = '0;

        for (
            aggregate_entry = 0;
            aggregate_entry < MSHR_COUNT;
            aggregate_entry = aggregate_entry + 1
        ) begin
            valid_mask_o[aggregate_entry] = entry_valid_q[aggregate_entry];
            issued_mask_o[aggregate_entry] =
                entry_valid_q[aggregate_entry]
                && entry_issued_q[aggregate_entry];
            response_ready_mask_o[aggregate_entry] =
                entry_valid_q[aggregate_entry]
                && entry_response_ready_q[aggregate_entry];

            if (entry_valid_q[aggregate_entry]) begin
                occupancy_o = occupancy_o + OCCUPANCY_W'(1);
            end
        end

        full_o = occupancy_o == OCCUPANCY_W'(MSHR_COUNT);
        empty_o = occupancy_o == '0;
    end


    /*
     * Allocation lookup. An entry in response-drain still owns its line tag,
     * so a request to that line must wait instead of allocating a duplicate.
     */
    always_comb begin
        open_match_found = 1'b0;
        open_match_entry = '0;
        draining_match_found = 1'b0;
        free_found = 1'b0;
        free_entry = '0;

        for (
            lookup_entry = 0;
            lookup_entry < MSHR_COUNT;
            lookup_entry = lookup_entry + 1
        ) begin
            if (
                !open_match_found
                && entry_valid_q[lookup_entry]
                && !entry_response_ready_q[lookup_entry]
                && entry_line_q[lookup_entry] == req_line_addr_i
            ) begin
                open_match_found = 1'b1;
                open_match_entry = ENTRY_W'(lookup_entry);
            end

            if (
                !draining_match_found
                && entry_valid_q[lookup_entry]
                && entry_response_ready_q[lookup_entry]
                && entry_line_q[lookup_entry] == req_line_addr_i
            ) begin
                draining_match_found = 1'b1;
            end

            if (
                !free_found
                && !entry_valid_q[lookup_entry]
            ) begin
                free_found = 1'b1;
                free_entry = ENTRY_W'(lookup_entry);
            end
        end

        req_wave_valid = wave_id_valid(req_wave_i);
        duplicate_waiter = 1'b0;

        if (
            open_match_found
            && req_wave_valid
        ) begin
            duplicate_waiter = waiter_valid_q[
                integer'(open_match_entry)
            ][integer'(req_wave_i)];
        end

        req_blocked_draining_o =
            req_valid_i
            && draining_match_found;

        req_duplicate_waiter_o =
            req_valid_i
            && open_match_found
            && duplicate_waiter;

        req_ready_o =
            req_wave_valid
            && req_lane_mask_i != '0
            && !draining_match_found
            && (
                (
                    open_match_found
                    && !duplicate_waiter
                )
                || (
                    !open_match_found
                    && free_found
                )
            );

        req_fire_o = req_valid_i && req_ready_o;
        req_merged_o = req_fire_o && open_match_found;
        req_allocated_o = req_fire_o && !open_match_found;

        if (open_match_found) begin
            req_entry_o = open_match_entry;
        end else begin
            req_entry_o = free_entry;
        end
    end


    /* Oldest physical-entry index wins the single downstream issue port. */
    always_comb begin
        miss_found = 1'b0;
        miss_entry = '0;
        miss_req_valid_o = 1'b0;
        miss_req_entry_o = '0;
        miss_req_line_addr_o = '0;

        for (
            miss_search_entry = 0;
            miss_search_entry < MSHR_COUNT;
            miss_search_entry = miss_search_entry + 1
        ) begin
            if (
                !miss_found
                && entry_valid_q[miss_search_entry]
                && !entry_issued_q[miss_search_entry]
                && !entry_response_ready_q[miss_search_entry]
            ) begin
                miss_found = 1'b1;
                miss_entry = ENTRY_W'(miss_search_entry);
            end
        end

        if (miss_found) begin
            miss_req_valid_o = 1'b1;
            miss_req_entry_o = miss_entry;
            miss_req_line_addr_o = entry_line_q[integer'(miss_entry)];
        end
    end


    assign response_entry_valid = entry_id_valid(resp_entry_i);

    always_comb begin
        response_entry_live = 1'b0;
        response_tag_match = 1'b0;
        response_issue_accepted_same_cycle = 1'b0;

        if (response_entry_valid) begin
            response_entry_live = entry_valid_q[integer'(resp_entry_i)];
            response_issue_accepted_same_cycle =
                miss_req_valid_o
                && miss_req_ready_i
                && miss_req_entry_o == resp_entry_i;

            response_tag_match =
                response_entry_live
                && (
                    entry_issued_q[integer'(resp_entry_i)]
                    || response_issue_accepted_same_cycle
                )
                && !entry_response_ready_q[integer'(resp_entry_i)]
                && entry_line_q[integer'(resp_entry_i)]
                    == resp_line_addr_i;
        end

        resp_accept_o = resp_valid_i && response_tag_match;
        resp_tag_error_o = resp_valid_i && !response_tag_match;
    end


    /* Completion arbitration: lowest response-ready entry, then lowest wave. */
    always_comb begin
        complete_entry_found = 1'b0;
        complete_entry = '0;

        for (
            completion_entry_scan = 0;
            completion_entry_scan < MSHR_COUNT;
            completion_entry_scan = completion_entry_scan + 1
        ) begin
            if (
                !complete_entry_found
                && entry_valid_q[completion_entry_scan]
                && entry_response_ready_q[completion_entry_scan]
            ) begin
                complete_entry_found = 1'b1;
                complete_entry = ENTRY_W'(completion_entry_scan);
            end
        end

        complete_wave_found = 1'b0;
        complete_wave = '0;

        if (complete_entry_found) begin
            for (
                completion_wave_scan = 0;
                completion_wave_scan < RESIDENT_WAVES;
                completion_wave_scan = completion_wave_scan + 1
            ) begin
                if (
                    !complete_wave_found
                    && waiter_valid_q[
                        integer'(complete_entry)
                    ][completion_wave_scan]
                ) begin
                    complete_wave_found = 1'b1;
                    complete_wave = WAVE_ID_W'(completion_wave_scan);
                end
            end
        end

        complete_valid_o =
            complete_entry_found
            && complete_wave_found;
        complete_entry_o = complete_entry;
        complete_wave_o = complete_wave;
        complete_context_o = '0;
        complete_dst_o = '0;
        complete_lane_mask_o = '0;
        complete_fault_o = 1'b0;

        for (
            completion_lane = 0;
            completion_lane < WAVE_SIZE;
            completion_lane = completion_lane + 1
        ) begin
            complete_lane_word_select_o[completion_lane] = '0;
        end

        for (
            completion_word = 0;
            completion_word < LINE_WORDS;
            completion_word = completion_word + 1
        ) begin
            complete_line_data_o[completion_word] = '0;
        end

        if (complete_valid_o) begin
            complete_context_o = waiter_context_q[
                integer'(complete_entry)
            ][integer'(complete_wave)];
            complete_dst_o = waiter_dst_q[
                integer'(complete_entry)
            ][integer'(complete_wave)];
            complete_lane_mask_o = waiter_lane_mask_q[
                integer'(complete_entry)
            ][integer'(complete_wave)];
            complete_fault_o = entry_fault_q[integer'(complete_entry)];

            for (
                completion_lane = 0;
                completion_lane < WAVE_SIZE;
                completion_lane = completion_lane + 1
            ) begin
                complete_lane_word_select_o[completion_lane] =
                    waiter_lane_word_select_q[
                        integer'(complete_entry)
                    ][integer'(complete_wave)][completion_lane];
            end

            for (
                completion_word = 0;
                completion_word < LINE_WORDS;
                completion_word = completion_word + 1
            ) begin
                complete_line_data_o[completion_word] =
                    entry_line_data_q[
                        integer'(complete_entry)
                    ][completion_word];
            end
        end

        complete_last_waiter = 1'b0;
        if (complete_valid_o) begin
            complete_last_waiter = 1'b1;
            for (
                completion_wave_scan = 0;
                completion_wave_scan < RESIDENT_WAVES;
                completion_wave_scan = completion_wave_scan + 1
            ) begin
                if (
                    completion_wave_scan != integer'(complete_wave)
                    && waiter_valid_q[
                        integer'(complete_entry)
                    ][completion_wave_scan]
                ) begin
                    complete_last_waiter = 1'b0;
                end
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (
                integer reset_entry = 0;
                reset_entry < MSHR_COUNT;
                reset_entry = reset_entry + 1
            ) begin
                entry_valid_q[reset_entry] <= 1'b0;
                entry_issued_q[reset_entry] <= 1'b0;
                entry_response_ready_q[reset_entry] <= 1'b0;
                entry_fault_q[reset_entry] <= 1'b0;
                entry_line_q[reset_entry] <= '0;

                for (
                    integer reset_word = 0;
                    reset_word < LINE_WORDS;
                    reset_word = reset_word + 1
                ) begin
                    entry_line_data_q[reset_entry][reset_word] <= '0;
                end

                for (
                    integer reset_wave = 0;
                    reset_wave < RESIDENT_WAVES;
                    reset_wave = reset_wave + 1
                ) begin
                    waiter_valid_q[reset_entry][reset_wave] <= 1'b0;
                    waiter_context_q[reset_entry][reset_wave] <= '0;
                    waiter_dst_q[reset_entry][reset_wave] <= '0;
                    waiter_lane_mask_q[reset_entry][reset_wave] <= '0;

                    for (
                        integer reset_lane = 0;
                        reset_lane < WAVE_SIZE;
                        reset_lane = reset_lane + 1
                    ) begin
                        waiter_lane_word_select_q[
                            reset_entry
                        ][reset_wave][reset_lane] <= '0;
                    end
                end
            end
        end else begin
            /* Allocate a new unique line or merge a second resident wave. */
            if (req_fire_o) begin
                if (req_allocated_o) begin
                    entry_valid_q[integer'(req_entry_o)] <= 1'b1;
                    entry_issued_q[integer'(req_entry_o)] <= 1'b0;
                    entry_response_ready_q[integer'(req_entry_o)] <= 1'b0;
                    entry_fault_q[integer'(req_entry_o)] <= 1'b0;
                    entry_line_q[integer'(req_entry_o)] <= req_line_addr_i;
                end

                waiter_valid_q[
                    integer'(req_entry_o)
                ][integer'(req_wave_i)] <= 1'b1;
                waiter_context_q[
                    integer'(req_entry_o)
                ][integer'(req_wave_i)] <= req_context_i;
                waiter_dst_q[
                    integer'(req_entry_o)
                ][integer'(req_wave_i)] <= req_dst_i;
                waiter_lane_mask_q[
                    integer'(req_entry_o)
                ][integer'(req_wave_i)] <= req_lane_mask_i;

                for (
                    integer request_lane = 0;
                    request_lane < WAVE_SIZE;
                    request_lane = request_lane + 1
                ) begin
                    waiter_lane_word_select_q[
                        integer'(req_entry_o)
                    ][integer'(req_wave_i)][request_lane]
                        <= req_lane_word_select_i[request_lane];
                end
            end

            if (miss_req_valid_o && miss_req_ready_i) begin
                entry_issued_q[integer'(miss_req_entry_o)] <= 1'b1;
            end

            if (resp_accept_o) begin
                entry_response_ready_q[integer'(resp_entry_i)] <= 1'b1;
                entry_fault_q[integer'(resp_entry_i)] <= resp_fault_i;

                for (
                    integer response_word = 0;
                    response_word < LINE_WORDS;
                    response_word = response_word + 1
                ) begin
                    entry_line_data_q[
                        integer'(resp_entry_i)
                    ][response_word] <= resp_line_data_i[response_word];
                end
            end

            if (complete_valid_o && complete_ready_i) begin
                waiter_valid_q[
                    integer'(complete_entry_o)
                ][integer'(complete_wave_o)] <= 1'b0;

                if (complete_last_waiter) begin
                    entry_valid_q[integer'(complete_entry_o)] <= 1'b0;
                    entry_issued_q[integer'(complete_entry_o)] <= 1'b0;
                    entry_response_ready_q[
                        integer'(complete_entry_o)
                    ] <= 1'b0;
                    entry_fault_q[integer'(complete_entry_o)] <= 1'b0;
                end
            end
        end
    end

endmodule
