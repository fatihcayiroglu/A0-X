`timescale 1ns/1ps

/*
 * A0 RTL9D-2 shared L2 line-cache foundation.
 *
 * The primitive is isolated from production wiring in RTL9D-2.
 *
 * Key properties:
 *   - direct mapped / parameterized SET_COUNT
 *   - opaque GLOBAL_TAG_W request/response identity
 *   - parameterized non-blocking MISS_COUNT tracker
 *   - backend responses may return out of order
 *   - one-entry buffered hit response
 *   - backend response priority on the no-ready response channel
 *   - physical-store observation invalidates cached lines
 *   - physical stores kill matching outstanding refills
 *   - faulted/killed/untracked refills never install
 *   - no same-line miss merging yet
 *   - no write allocation, dirty state, writeback, coherence or translation
 */
module a0_l2_line_cache #(
    parameter integer STORE_LANES = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT = 256,
    parameter integer GLOBAL_TAG_W = 4,
    parameter integer MISS_COUNT = 16,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),

    parameter integer LINE_ADDR_W =
        32 - WORD_SELECT_W,

    parameter integer SET_INDEX_W =
        (SET_COUNT <= 1) ? 1 : $clog2(SET_COUNT),

    parameter integer TAG_W =
        (SET_COUNT <= 1)
            ? LINE_ADDR_W
            : (
                LINE_ADDR_W
                - $clog2(SET_COUNT)
            ),

    parameter integer MISS_INDEX_W =
        (MISS_COUNT <= 1) ? 1 : $clog2(MISS_COUNT)
) (
    input logic clk,
    input logic rst_n,

    /*
     * Upstream requester-tagged line request.
     */
    input logic line_req_valid_i,
    output logic line_req_ready_o,

    input logic [GLOBAL_TAG_W-1:0]
        line_req_global_tag_i,

    input logic [LINE_ADDR_W-1:0]
        line_req_line_addr_i,

    /*
     * Downstream memory request.
     */
    output logic line_mem_req_valid_o,
    input logic line_mem_req_ready_i,

    output logic [GLOBAL_TAG_W-1:0]
        line_mem_req_global_tag_o,

    output logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o,

    /*
     * Downstream memory response.
     *
     * No response ready/backpressure exists in the current line contract.
     */
    input logic line_mem_resp_valid_i,

    input logic [GLOBAL_TAG_W-1:0]
        line_mem_resp_global_tag_i,

    input logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i,

    input logic line_mem_resp_fault_i,

    input logic [31:0]
        line_mem_resp_data_i [0:LINE_WORDS-1],

    /*
     * Upstream line response.
     */
    output logic line_resp_valid_o,

    output logic [GLOBAL_TAG_W-1:0]
        line_resp_global_tag_o,

    output logic [LINE_ADDR_W-1:0]
        line_resp_line_addr_o,

    output logic line_resp_fault_o,

    output logic [31:0]
        line_resp_data_o [0:LINE_WORDS-1],

    /*
     * Physical-store observation.
     *
     * Store addresses are 32-bit word addresses.
     */
    input logic store_valid_i,

    input logic [STORE_LANES-1:0]
        store_lane_mask_i,

    input logic [31:0]
        store_word_addr_i [0:STORE_LANES-1]
);

    logic cache_valid_q [0:SET_COUNT-1];

    logic [TAG_W-1:0]
        cache_tag_q [0:SET_COUNT-1];

    logic [31:0]
        cache_data_q
            [0:SET_COUNT-1]
            [0:LINE_WORDS-1];


    logic miss_valid_q [0:MISS_COUNT-1];

    logic [GLOBAL_TAG_W-1:0]
        miss_global_tag_q [0:MISS_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        miss_line_q [0:MISS_COUNT-1];

    logic miss_kill_q [0:MISS_COUNT-1];


    logic hit_buf_valid_q;

    logic [GLOBAL_TAG_W-1:0]
        hit_buf_global_tag_q;

    logic [LINE_ADDR_W-1:0]
        hit_buf_line_q;

    logic [31:0]
        hit_buf_data_q [0:LINE_WORDS-1];


    logic [SET_INDEX_W-1:0] req_set;
    logic [TAG_W-1:0] req_tag;

    logic req_store_conflict;
    logic req_hit;
    logic req_tag_busy;

    logic miss_free_found;
    logic [MISS_INDEX_W-1:0] miss_free_slot;

    logic hit_accept;
    logic miss_accept;


    logic resp_track_match;
    logic [MISS_INDEX_W-1:0] resp_match_slot;
    logic resp_killed;
    logic resp_store_conflict;
    logic refill_install;

    logic [SET_INDEX_W-1:0] resp_set;
    logic [TAG_W-1:0] resp_tag;


    integer scan_miss;
    integer reset_set;
    integer reset_miss;
    integer response_word;
    integer hit_capture_word;
    integer refill_word;
    integer store_lane;
    integer kill_miss;


    initial begin
        if (STORE_LANES < 1) begin
            $fatal(
                1,
                "RTL9D2 STORE_LANES must be >= 1"
            );
        end

        if (LINE_WORDS < 1) begin
            $fatal(
                1,
                "RTL9D2 LINE_WORDS must be >= 1"
            );
        end

        if (
            (
                LINE_WORDS
                & (LINE_WORDS - 1)
            ) != 0
        ) begin
            $fatal(
                1,
                "RTL9D2 LINE_WORDS must be a power of two"
            );
        end

        if (SET_COUNT < 1) begin
            $fatal(
                1,
                "RTL9D2 SET_COUNT must be >= 1"
            );
        end

        if (
            (
                SET_COUNT
                & (SET_COUNT - 1)
            ) != 0
        ) begin
            $fatal(
                1,
                "RTL9D2 SET_COUNT must be a power of two"
            );
        end

        if (GLOBAL_TAG_W < 1) begin
            $fatal(
                1,
                "RTL9D2 GLOBAL_TAG_W must be >= 1"
            );
        end

        if (MISS_COUNT < 1) begin
            $fatal(
                1,
                "RTL9D2 MISS_COUNT must be >= 1"
            );
        end
    end


    function automatic logic [TAG_W-1:0]
        line_tag(
            input logic [LINE_ADDR_W-1:0] line_addr
        );
        begin
            if (SET_COUNT <= 1) begin
                line_tag =
                    TAG_W'(line_addr);
            end else begin
                line_tag =
                    TAG_W'(
                        line_addr
                        >> $clog2(SET_COUNT)
                    );
            end
        end
    endfunction


    function automatic logic [LINE_ADDR_W-1:0]
        word_to_line(
            input logic [31:0] word_addr
        );
        begin
            if (LINE_WORDS <= 1) begin
                word_to_line =
                    word_addr[
                        LINE_ADDR_W-1:0
                    ];
            end else begin
                word_to_line =
                    LINE_ADDR_W'(
                        word_addr
                        >> WORD_SELECT_W
                    );
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
                for (
                    lane = 0;
                    lane < STORE_LANES;
                    lane = lane + 1
                ) begin
                    if (
                        store_lane_mask_i[lane]
                        && word_to_line(
                            store_word_addr_i[lane]
                        ) == line_addr
                    ) begin
                        store_conflicts_line = 1'b1;
                    end
                end
            end
        end
    endfunction


    always_comb begin
        if (SET_COUNT <= 1) begin
            req_set = '0;
        end else begin
            req_set =
                SET_INDEX_W'(
                    line_req_line_addr_i
                );
        end

        req_tag =
            line_tag(
                line_req_line_addr_i
            );

        req_store_conflict =
            store_conflicts_line(
                line_req_line_addr_i
            );

        req_tag_busy = 1'b0;

        miss_free_found = 1'b0;
        miss_free_slot = '0;

        for (
            scan_miss = 0;
            scan_miss < MISS_COUNT;
            scan_miss = scan_miss + 1
        ) begin
            if (
                miss_valid_q[scan_miss]
                && miss_global_tag_q[scan_miss]
                    == line_req_global_tag_i
            ) begin
                req_tag_busy = 1'b1;
            end

            if (
                !miss_free_found
                && !miss_valid_q[scan_miss]
            ) begin
                miss_free_found = 1'b1;

                miss_free_slot =
                    MISS_INDEX_W'(scan_miss);
            end
        end

        req_hit = (
            line_req_valid_i
            && !req_tag_busy
            && !req_store_conflict
            && cache_valid_q[req_set]
            && cache_tag_q[req_set]
                == req_tag
        );

        line_req_ready_o = 1'b0;

        if (
            line_req_valid_i
            && !req_tag_busy
        ) begin
            if (req_hit) begin
                /*
                 * A held hit can be replaced on a cycle where it is being
                 * emitted. A backend response prevents emission and therefore
                 * also prevents replacement of an already-full hit buffer.
                 */
                line_req_ready_o = (
                    !hit_buf_valid_q
                    || !line_mem_resp_valid_i
                );
            end else begin
                line_req_ready_o = (
                    miss_free_found
                    && line_mem_req_ready_i
                );
            end
        end

        hit_accept = (
            line_req_valid_i
            && line_req_ready_o
            && req_hit
        );

        miss_accept = (
            line_req_valid_i
            && line_req_ready_o
            && !req_hit
        );

        line_mem_req_valid_o = (
            line_req_valid_i
            && !req_tag_busy
            && !req_hit
            && miss_free_found
        );

        line_mem_req_global_tag_o =
            line_req_global_tag_i;

        line_mem_req_line_addr_o =
            line_req_line_addr_i;


        resp_track_match = 1'b0;
        resp_match_slot = '0;
        resp_killed = 1'b0;

        for (
            scan_miss = 0;
            scan_miss < MISS_COUNT;
            scan_miss = scan_miss + 1
        ) begin
            if (
                !resp_track_match
                && miss_valid_q[scan_miss]
                && miss_global_tag_q[scan_miss]
                    == line_mem_resp_global_tag_i
                && miss_line_q[scan_miss]
                    == line_mem_resp_line_addr_i
            ) begin
                resp_track_match = 1'b1;

                resp_match_slot =
                    MISS_INDEX_W'(scan_miss);

                resp_killed =
                    miss_kill_q[scan_miss];
            end
        end

        /*
         * Same-cycle backend completion for a just-accepted miss is legal.
         * It is treated as tracked even though the sequential valid bit has
         * not yet become visible.
         */
        if (
            !resp_track_match
            && miss_accept
            && line_mem_resp_valid_i
            && line_req_global_tag_i
                == line_mem_resp_global_tag_i
            && line_req_line_addr_i
                == line_mem_resp_line_addr_i
        ) begin
            resp_track_match = 1'b1;
            resp_match_slot = miss_free_slot;
            resp_killed = req_store_conflict;
        end

        resp_store_conflict =
            store_conflicts_line(
                line_mem_resp_line_addr_i
            );

        if (SET_COUNT <= 1) begin
            resp_set = '0;
        end else begin
            resp_set =
                SET_INDEX_W'(
                    line_mem_resp_line_addr_i
                );
        end

        resp_tag =
            line_tag(
                line_mem_resp_line_addr_i
            );

        refill_install = (
            line_mem_resp_valid_i
            && resp_track_match
            && !line_mem_resp_fault_i
            && !resp_killed
            && !resp_store_conflict
        );


        /*
         * Backend responses have priority because there is no upstream ready
         * signal. Buffered hits remain pending until a backend-response-free
         * cycle.
         */
        line_resp_valid_o = 1'b0;
        line_resp_global_tag_o = '0;
        line_resp_line_addr_o = '0;
        line_resp_fault_o = 1'b0;

        for (
            response_word = 0;
            response_word < LINE_WORDS;
            response_word = response_word + 1
        ) begin
            line_resp_data_o[
                response_word
            ] = '0;
        end

        if (
            rst_n
            && line_mem_resp_valid_i
        ) begin
            line_resp_valid_o = 1'b1;

            line_resp_global_tag_o =
                line_mem_resp_global_tag_i;

            line_resp_line_addr_o =
                line_mem_resp_line_addr_i;

            line_resp_fault_o =
                line_mem_resp_fault_i;

            for (
                response_word = 0;
                response_word < LINE_WORDS;
                response_word = response_word + 1
            ) begin
                line_resp_data_o[
                    response_word
                ] =
                    line_mem_resp_data_i[
                        response_word
                    ];
            end
        end else if (
            rst_n
            && hit_buf_valid_q
        ) begin
            line_resp_valid_o = 1'b1;

            line_resp_global_tag_o =
                hit_buf_global_tag_q;

            line_resp_line_addr_o =
                hit_buf_line_q;

            line_resp_fault_o = 1'b0;

            for (
                response_word = 0;
                response_word < LINE_WORDS;
                response_word = response_word + 1
            ) begin
                line_resp_data_o[
                    response_word
                ] =
                    hit_buf_data_q[
                        response_word
                    ];
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hit_buf_valid_q <= 1'b0;
            hit_buf_global_tag_q <= '0;
            hit_buf_line_q <= '0;

            for (
                reset_set = 0;
                reset_set < SET_COUNT;
                reset_set = reset_set + 1
            ) begin
                cache_valid_q[
                    reset_set
                ] <= 1'b0;
            end

            for (
                reset_miss = 0;
                reset_miss < MISS_COUNT;
                reset_miss = reset_miss + 1
            ) begin
                miss_valid_q[
                    reset_miss
                ] <= 1'b0;

                miss_global_tag_q[
                    reset_miss
                ] <= '0;

                miss_line_q[
                    reset_miss
                ] <= '0;

                miss_kill_q[
                    reset_miss
                ] <= 1'b0;
            end
        end else begin

            /*
             * Consume a buffered hit whenever a backend response does not
             * occupy the response channel.
             */
            if (
                hit_buf_valid_q
                && !line_mem_resp_valid_i
            ) begin
                hit_buf_valid_q <= 1'b0;
            end

            /*
             * Same-edge replacement is legal when the old hit is emitted.
             */
            if (hit_accept) begin
                hit_buf_valid_q <= 1'b1;

                hit_buf_global_tag_q <=
                    line_req_global_tag_i;

                hit_buf_line_q <=
                    line_req_line_addr_i;

                for (
                    hit_capture_word = 0;
                    hit_capture_word < LINE_WORDS;
                    hit_capture_word =
                        hit_capture_word + 1
                ) begin
                    hit_buf_data_q[
                        hit_capture_word
                    ] <=
                        cache_data_q[
                            req_set
                        ][
                            hit_capture_word
                        ];
                end
            end


            /*
             * Allocate an explicit miss slot only when the backend request
             * handshake succeeds.
             */
            if (miss_accept) begin
                miss_valid_q[
                    miss_free_slot
                ] <= 1'b1;

                miss_global_tag_q[
                    miss_free_slot
                ] <=
                    line_req_global_tag_i;

                miss_line_q[
                    miss_free_slot
                ] <=
                    line_req_line_addr_i;

                miss_kill_q[
                    miss_free_slot
                ] <=
                    req_store_conflict;
            end


            /*
             * Every tracked response retires its miss slot, including faulted
             * and store-killed responses.
             *
             * This block intentionally follows miss allocation so an
             * immediate same-cycle response clears a just-accepted slot.
             */
            if (
                line_mem_resp_valid_i
                && resp_track_match
            ) begin
                miss_valid_q[
                    resp_match_slot
                ] <= 1'b0;

                miss_kill_q[
                    resp_match_slot
                ] <= 1'b0;
            end


            if (refill_install) begin
                cache_valid_q[
                    resp_set
                ] <= 1'b1;

                cache_tag_q[
                    resp_set
                ] <=
                    resp_tag;

                for (
                    refill_word = 0;
                    refill_word < LINE_WORDS;
                    refill_word =
                        refill_word + 1
                ) begin
                    cache_data_q[
                        resp_set
                    ][
                        refill_word
                    ] <=
                        line_mem_resp_data_i[
                            refill_word
                        ];
                end
            end


            /*
             * Physical-store launch invalidation.
             *
             * This intentionally appears after refill-install updates.
             * A same-line refill is already suppressed by resp_store_conflict.
             * A same-set/different-line collision may conservatively leave the
             * newly written set invalid, which is safe and causes only a later
             * miss rather than stale-data visibility.
             */
            if (store_valid_i) begin
                for (
                    store_lane = 0;
                    store_lane < STORE_LANES;
                    store_lane = store_lane + 1
                ) begin
                    if (
                        store_lane_mask_i[
                            store_lane
                        ]
                    ) begin
                        if (
                            cache_valid_q[
                                (
                                    (SET_COUNT <= 1)
                                        ? SET_INDEX_W'(0)
                                        : SET_INDEX_W'(
                                            word_to_line(
                                                store_word_addr_i[
                                                    store_lane
                                                ]
                                            )
                                        )
                                )
                            ]
                            && cache_tag_q[
                                (
                                    (SET_COUNT <= 1)
                                        ? SET_INDEX_W'(0)
                                        : SET_INDEX_W'(
                                            word_to_line(
                                                store_word_addr_i[
                                                    store_lane
                                                ]
                                            )
                                        )
                                )
                            ]
                                == line_tag(
                                    word_to_line(
                                        store_word_addr_i[
                                            store_lane
                                        ]
                                    )
                                )
                        ) begin
                            cache_valid_q[
                                (
                                    (SET_COUNT <= 1)
                                        ? SET_INDEX_W'(0)
                                        : SET_INDEX_W'(
                                            word_to_line(
                                                store_word_addr_i[
                                                    store_lane
                                                ]
                                            )
                                        )
                                )
                            ] <= 1'b0;
                        end
                    end
                end


                /*
                 * Kill every already-accepted refill touching a stored line.
                 * Same-cycle new misses capture req_store_conflict directly.
                 */
                for (
                    kill_miss = 0;
                    kill_miss < MISS_COUNT;
                    kill_miss = kill_miss + 1
                ) begin
                    if (
                        miss_valid_q[kill_miss]
                        && store_conflicts_line(
                            miss_line_q[
                                kill_miss
                            ]
                        )
                    ) begin
                        miss_kill_q[
                            kill_miss
                        ] <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
