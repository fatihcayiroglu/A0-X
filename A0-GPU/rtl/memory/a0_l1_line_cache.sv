`timescale 1ns/1ps

/*
 * A0 RTL9B-1 direct-mapped L1 line-cache primitive.
 *
 * This block is intentionally isolated from the live core in RTL9B-1.
 *
 * Contract:
 *   - cacheable client is the existing MSHR line-request channel
 *   - 32-bit word addressing; LINE_WORDS words per cache line
 *   - direct-mapped, parameterized SET_COUNT
 *   - hit response is captured into one response buffer
 *   - backend responses have priority over buffered hits because the
 *     client response channel has no ready/backpressure signal
 *   - misses pass through using ready/valid and are tracked per MSHR entry
 *   - legacy stores never stall here; matching cached lines are invalidated
 *   - matching in-flight refills are marked killed on store launch
 *   - backend responses are always forwarded to the MSHR client
 *   - faulted, killed, or same-cycle store-conflicting refills are not installed
 *   - no write-allocate, dirty state, writeback, associativity, or replacement
 *
 * Tag/data arrays intentionally are not reset. Valid bits define visibility.
 */
module a0_l1_line_cache #(
    parameter integer WAVE_SIZE = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT = 64,
    parameter integer MSHR_COUNT = 2,
    parameter integer ENTRY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),
    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer SET_INDEX_W =
        (SET_COUNT <= 1) ? 1 : $clog2(SET_COUNT),
    parameter integer TAG_W =
        (SET_COUNT <= 1)
            ? LINE_ADDR_W
            : (LINE_ADDR_W - $clog2(SET_COUNT))
) (
    input logic clk,
    input logic rst_n,

    /* MSHR client request. */
    input logic line_req_valid_i,
    output logic line_req_ready_o,
    input logic [ENTRY_W-1:0] line_req_entry_i,
    input logic [LINE_ADDR_W-1:0] line_req_line_addr_i,

    /* Downstream line-memory request. */
    output logic line_mem_req_valid_o,
    input logic line_mem_req_ready_i,
    output logic [ENTRY_W-1:0] line_mem_req_entry_o,
    output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o,

    /*
     * Downstream response has no ready. It must never be dropped.
     * The response tag is preserved exactly.
     */
    input logic line_mem_resp_valid_i,
    input logic [ENTRY_W-1:0] line_mem_resp_entry_i,
    input logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i,
    input logic line_mem_resp_fault_i,
    input logic [31:0] line_mem_resp_data_i [0:LINE_WORDS-1],

    /* MSHR client response, also no ready. */
    output logic line_resp_valid_o,
    output logic [ENTRY_W-1:0] line_resp_entry_o,
    output logic [LINE_ADDR_W-1:0] line_resp_line_addr_o,
    output logic line_resp_fault_o,
    output logic [31:0] line_resp_data_o [0:LINE_WORDS-1],

    /*
     * Legacy physical-store observation.
     * Addresses are word addresses, matching the existing RTL7/RTL8 contract.
     * Store traffic itself bypasses this primitive.
     */
    input logic store_valid_i,
    input logic [WAVE_SIZE-1:0] store_lane_mask_i,
    input logic [31:0] store_word_addr_i [0:WAVE_SIZE-1]
);

    logic cache_valid_q [0:SET_COUNT-1];
    logic [TAG_W-1:0] cache_tag_q [0:SET_COUNT-1];
    logic [31:0] cache_data_q [0:SET_COUNT-1][0:LINE_WORDS-1];

    logic miss_valid_q [0:MSHR_COUNT-1];
    logic miss_kill_q [0:MSHR_COUNT-1];
    logic [LINE_ADDR_W-1:0] miss_line_q [0:MSHR_COUNT-1];

    logic hit_buf_valid_q;
    logic [ENTRY_W-1:0] hit_buf_entry_q;
    logic [LINE_ADDR_W-1:0] hit_buf_line_q;
    logic [31:0] hit_buf_data_q [0:LINE_WORDS-1];

    logic [SET_INDEX_W-1:0] req_set;
    logic [TAG_W-1:0] req_tag;
    logic req_entry_valid;
    logic req_entry_busy;
    logic req_store_conflict;
    logic req_hit;
    logic hit_accept;
    logic miss_accept;

    logic resp_track_match;
    logic resp_killed;
    logic resp_store_conflict;
    logic refill_install;

    logic [SET_INDEX_W-1:0] resp_set;
    logic [TAG_W-1:0] resp_tag;

    integer response_mux_word;

    function automatic logic entry_id_valid(
        input logic [ENTRY_W-1:0] entry_id
    );
        entry_id_valid = integer'(entry_id) < MSHR_COUNT;
    endfunction

    function automatic logic [SET_INDEX_W-1:0] line_set(
        input logic [SET_INDEX_W-1:0] set_index
    );
        begin
            if (SET_COUNT <= 1) begin
                line_set = '0;
            end else begin
                line_set = set_index;
            end
        end
    endfunction

    function automatic logic [TAG_W-1:0] line_tag(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            if (SET_COUNT <= 1) begin
                line_tag = TAG_W'(line_addr);
            end else begin
                line_tag = TAG_W'(line_addr >> $clog2(SET_COUNT));
            end
        end
    endfunction

    function automatic logic [LINE_ADDR_W-1:0] word_to_line(
        input logic [31:0] word_addr
    );
        begin
            if (LINE_WORDS <= 1) begin
                word_to_line = word_addr[LINE_ADDR_W-1:0];
            end else begin
                word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
            end
        end
    endfunction

    function automatic logic store_conflicts_line(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer lane;
        begin
            store_conflicts_line = 1'b0;
            if (store_valid_i) begin
                for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                    if (
                        store_lane_mask_i[lane]
                        && word_to_line(store_word_addr_i[lane]) == line_addr
                    ) begin
                        store_conflicts_line = 1'b1;
                    end
                end
            end
        end
    endfunction

    always_comb begin
        req_set =
            line_set(SET_INDEX_W'(line_req_line_addr_i));
        req_tag = line_tag(line_req_line_addr_i);
        req_entry_valid = entry_id_valid(line_req_entry_i);
        req_entry_busy = 1'b1;

        if (req_entry_valid) begin
            req_entry_busy = miss_valid_q[integer'(line_req_entry_i)];
        end

        req_store_conflict = store_conflicts_line(line_req_line_addr_i);

        req_hit = (
            line_req_valid_i
            && req_entry_valid
            && !req_entry_busy
            && !req_store_conflict
            && cache_valid_q[req_set]
            && cache_tag_q[req_set] == req_tag
        );

        /*
         * A buffered hit occupies the only local response slot until it is
         * actually emitted on a cycle without a backend response.
         */
        if (!line_req_valid_i || !req_entry_valid || req_entry_busy) begin
            line_req_ready_o = 1'b0;
        end else if (req_hit) begin
            line_req_ready_o = !hit_buf_valid_q;
        end else begin
            line_req_ready_o = line_mem_req_ready_i;
        end

        hit_accept = line_req_valid_i && line_req_ready_o && req_hit;
        miss_accept = line_req_valid_i && line_req_ready_o && !req_hit;

        line_mem_req_valid_o = (
            line_req_valid_i
            && req_entry_valid
            && !req_entry_busy
            && !req_hit
        );
        line_mem_req_entry_o = line_req_entry_i;
        line_mem_req_line_addr_o = line_req_line_addr_i;

        resp_track_match = 1'b0;
        resp_killed = 1'b0;

        if (entry_id_valid(line_mem_resp_entry_i)) begin
            if (
                miss_valid_q[integer'(line_mem_resp_entry_i)]
                && miss_line_q[integer'(line_mem_resp_entry_i)]
                    == line_mem_resp_line_addr_i
            ) begin
                resp_track_match = 1'b1;
                resp_killed =
                    miss_kill_q[integer'(line_mem_resp_entry_i)];
            end else if (
                miss_accept
                && line_req_entry_i == line_mem_resp_entry_i
                && line_req_line_addr_i == line_mem_resp_line_addr_i
            ) begin
                /*
                 * Same-cycle miss acceptance + response is legal because the
                 * existing MSHR explicitly supports that contract.
                 */
                resp_track_match = 1'b1;
                resp_killed = req_store_conflict;
            end
        end

        resp_store_conflict =
            store_conflicts_line(line_mem_resp_line_addr_i);

        refill_install = (
            line_mem_resp_valid_i
            && resp_track_match
            && !line_mem_resp_fault_i
            && !resp_killed
            && !resp_store_conflict
        );

        resp_set =
            line_set(SET_INDEX_W'(line_mem_resp_line_addr_i));
        resp_tag = line_tag(line_mem_resp_line_addr_i);

        /*
         * Backend response wins the no-ready response port. A buffered hit is
         * retained until a backend-response-free cycle.
         */
        line_resp_valid_o = 1'b0;
        line_resp_entry_o = '0;
        line_resp_line_addr_o = '0;
        line_resp_fault_o = 1'b0;

        for (
            response_mux_word = 0;
            response_mux_word < LINE_WORDS;
            response_mux_word = response_mux_word + 1
        ) begin
            line_resp_data_o[response_mux_word] = '0;
        end

        if (line_mem_resp_valid_i) begin
            line_resp_valid_o = 1'b1;
            line_resp_entry_o = line_mem_resp_entry_i;
            line_resp_line_addr_o = line_mem_resp_line_addr_i;
            line_resp_fault_o = line_mem_resp_fault_i;

            for (
                response_mux_word = 0;
                response_mux_word < LINE_WORDS;
                response_mux_word = response_mux_word + 1
            ) begin
                line_resp_data_o[response_mux_word] =
                    line_mem_resp_data_i[response_mux_word];
            end
        end else if (hit_buf_valid_q) begin
            line_resp_valid_o = 1'b1;
            line_resp_entry_o = hit_buf_entry_q;
            line_resp_line_addr_o = hit_buf_line_q;
            line_resp_fault_o = 1'b0;

            for (
                response_mux_word = 0;
                response_mux_word < LINE_WORDS;
                response_mux_word = response_mux_word + 1
            ) begin
                line_resp_data_o[response_mux_word] =
                    hit_buf_data_q[response_mux_word];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hit_buf_valid_q <= 1'b0;
            hit_buf_entry_q <= '0;
            hit_buf_line_q <= '0;

            for (
                integer reset_set = 0;
                reset_set < SET_COUNT;
                reset_set = reset_set + 1
            ) begin
                cache_valid_q[reset_set] <= 1'b0;
            end

            for (
                integer reset_entry = 0;
                reset_entry < MSHR_COUNT;
                reset_entry = reset_entry + 1
            ) begin
                miss_valid_q[reset_entry] <= 1'b0;
                miss_kill_q[reset_entry] <= 1'b0;
                miss_line_q[reset_entry] <= '0;
            end
        end else begin
            /*
             * A buffered hit is consumed whenever no backend response steals
             * the response port in this cycle.
             */
            if (hit_buf_valid_q && !line_mem_resp_valid_i) begin
                hit_buf_valid_q <= 1'b0;
            end

            if (hit_accept) begin
                hit_buf_valid_q <= 1'b1;
                hit_buf_entry_q <= line_req_entry_i;
                hit_buf_line_q <= line_req_line_addr_i;

                for (
                    integer hit_capture_word = 0;
                    hit_capture_word < LINE_WORDS;
                    hit_capture_word = hit_capture_word + 1
                ) begin
                    hit_buf_data_q[hit_capture_word] <=
                        cache_data_q[req_set][hit_capture_word];
                end
            end

            if (miss_accept) begin
                miss_valid_q[integer'(line_req_entry_i)] <= 1'b1;
                miss_kill_q[integer'(line_req_entry_i)] <= req_store_conflict;
                miss_line_q[integer'(line_req_entry_i)] <=
                    line_req_line_addr_i;
            end

            /*
             * A valid backend response completes the local per-entry tracking
             * even when the refill is killed. The response itself is still
             * forwarded to the MSHR through the combinational response mux.
             */
            if (line_mem_resp_valid_i && resp_track_match) begin
                miss_valid_q[integer'(line_mem_resp_entry_i)] <= 1'b0;
                miss_kill_q[integer'(line_mem_resp_entry_i)] <= 1'b0;
            end

            if (refill_install) begin
                cache_valid_q[resp_set] <= 1'b1;
                cache_tag_q[resp_set] <= resp_tag;

                for (
                    integer refill_word = 0;
                    refill_word < LINE_WORDS;
                    refill_word = refill_word + 1
                ) begin
                    cache_data_q[resp_set][refill_word] <=
                        line_mem_resp_data_i[refill_word];
                end
            end

            /*
             * Store launch invalidation is deliberately conservative. It never
             * waits for store completion. A fault may therefore leave a line
             * invalid, which is safe because it can only cause a later miss.
             *
             * This block appears after refill installation so an old cached
             * line matching a simultaneous store may conservatively invalidate
             * the set. Same-line refill installation is separately suppressed
             * by resp_store_conflict.
             */
            if (store_valid_i) begin
                for (
                    integer store_lane = 0;
                    store_lane < WAVE_SIZE;
                    store_lane = store_lane + 1
                ) begin
                    if (store_lane_mask_i[store_lane]) begin
                        if (
                            cache_valid_q[
                                line_set(
                                    SET_INDEX_W'(
                                        word_to_line(
                                            store_word_addr_i[store_lane]
                                        )
                                    )
                                )
                            ]
                            && cache_tag_q[
                                line_set(
                                    SET_INDEX_W'(
                                        word_to_line(
                                            store_word_addr_i[store_lane]
                                        )
                                    )
                                )
                            ]
                                == line_tag(
                                    word_to_line(store_word_addr_i[store_lane])
                                )
                        ) begin
                            cache_valid_q[
                                line_set(
                                    SET_INDEX_W'(
                                        word_to_line(
                                            store_word_addr_i[store_lane]
                                        )
                                    )
                                )
                            ] <= 1'b0;
                        end
                    end
                end

                /*
                 * Kill every already-accepted miss whose line is touched by
                 * the launching store. Newly accepted same-cycle misses get
                 * req_store_conflict captured directly in miss_kill_q.
                 */
                for (
                    integer kill_entry = 0;
                    kill_entry < MSHR_COUNT;
                    kill_entry = kill_entry + 1
                ) begin
                    if (
                        miss_valid_q[kill_entry]
                        && store_conflicts_line(miss_line_q[kill_entry])
                    ) begin
                        miss_kill_q[kill_entry] <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
