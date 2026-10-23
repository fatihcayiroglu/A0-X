`timescale 1ns/1ps

/*
 * A0-RTL8C whole-wave store queue foundation.
 *
 * Contract:
 *   - stores enqueue as complete wave-sized transactions after address/data build
 *   - entries drain strictly FIFO
 *   - at most one live queued store per resident wave
 *   - full queue applies backpressure
 *   - drain is a valid/ready handshake; backend completion is owned by the core
 *   - an exact word-address probe reports overlap with any queued store
 *   - a cache-line probe reports ordering conflicts using LINE_WORDS geometry
 *
 * RTL8C-4 uses the cache-line probe for safe load bypass/hold decisions.
 * Exact-word/source metadata feeds RTL8C-5 age-qualified forwarding.
 */
module a0_store_queue #(
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer RESIDENT_WAVES = 4,
    parameter integer WAVE_SIZE = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer STORE_SEQ_W = 64,

    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer CONTEXT_ID_W = WAVE_ID_W,
    parameter integer PTR_W =
        (STORE_QUEUE_DEPTH <= 1) ? 1 : $clog2(STORE_QUEUE_DEPTH),
    parameter integer OCCUPANCY_W =
        (STORE_QUEUE_DEPTH <= 1) ? 1 : $clog2(STORE_QUEUE_DEPTH + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic enqueue_valid_i,
    output logic enqueue_ready_o,
    output logic enqueue_fire_o,
    input logic [WAVE_ID_W-1:0] enqueue_wave_i,
    input logic [CONTEXT_ID_W-1:0] enqueue_context_i,
    input logic [STORE_SEQ_W-1:0] enqueue_seq_i,
    input logic [WAVE_SIZE-1:0] enqueue_lane_mask_i,
    input logic [31:0] enqueue_word_addr_i [0:WAVE_SIZE-1],
    input logic [31:0] enqueue_wdata_i [0:WAVE_SIZE-1],

    output logic drain_valid_o,
    input logic drain_ready_i,
    output logic drain_fire_o,
    output logic [WAVE_ID_W-1:0] drain_wave_o,
    output logic [CONTEXT_ID_W-1:0] drain_context_o,
    output logic [STORE_SEQ_W-1:0] drain_seq_o,
    output logic [WAVE_SIZE-1:0] drain_lane_mask_o,
    output logic [31:0] drain_word_addr_o [0:WAVE_SIZE-1],
    output logic [31:0] drain_wdata_o [0:WAVE_SIZE-1],

    input logic probe_valid_i,
    input logic [WAVE_SIZE-1:0] probe_lane_mask_i,
    input logic [31:0] probe_word_addr_i [0:WAVE_SIZE-1],
    input logic [STORE_SEQ_W-1:0] probe_seq_boundary_i,
    output logic probe_conflict_o,
    output logic [WAVE_SIZE-1:0] probe_conflict_lane_mask_o,
    output logic probe_line_conflict_o,
    output logic [WAVE_SIZE-1:0] probe_line_conflict_lane_mask_o,
    output logic [WAVE_SIZE-1:0] probe_source_valid_lane_mask_o,
    output logic [WAVE_SIZE-1:0] probe_source_ambiguous_lane_mask_o,
    output logic [STORE_SEQ_W-1:0]
        probe_source_seq_o [0:WAVE_SIZE-1],
    output logic [31:0] probe_source_wdata_o [0:WAVE_SIZE-1],

    output logic [OCCUPANCY_W-1:0] occupancy_o,
    output logic full_o,
    output logic empty_o,
    output logic [RESIDENT_WAVES-1:0] active_wave_mask_o,
    output logic enqueue_stall_o
);

    logic entry_valid_q [0:STORE_QUEUE_DEPTH-1];
    logic [WAVE_ID_W-1:0] entry_wave_q [0:STORE_QUEUE_DEPTH-1];
    logic [CONTEXT_ID_W-1:0] entry_context_q [0:STORE_QUEUE_DEPTH-1];
    logic [STORE_SEQ_W-1:0] entry_seq_q [0:STORE_QUEUE_DEPTH-1];
    logic [WAVE_SIZE-1:0] entry_lane_mask_q [0:STORE_QUEUE_DEPTH-1];
    logic [31:0] entry_word_addr_q
        [0:STORE_QUEUE_DEPTH-1][0:WAVE_SIZE-1];
    logic [31:0] entry_wdata_q
        [0:STORE_QUEUE_DEPTH-1][0:WAVE_SIZE-1];

    logic [PTR_W-1:0] head_q;
    logic [PTR_W-1:0] tail_q;
    logic [OCCUPANCY_W-1:0] count_q;
    logic enqueue_wave_in_range;

    function automatic logic [PTR_W-1:0] next_ptr(
        input logic [PTR_W-1:0] ptr
    );
        begin
            if (integer'(ptr) == STORE_QUEUE_DEPTH - 1) begin
                next_ptr = '0;
            end else begin
                next_ptr = ptr + 1'b1;
            end
        end
    endfunction


    /*
     * RTL8C-4 ordering uses the same line geometry as the MSHR load path.
     * Exact-word probing also provides the RTL8C-5 forwarding source.
     */
    function automatic logic [31:0] line_tag(
        input logic [31:0] word_addr
    );
        begin
            if (LINE_WORDS <= 1) begin
                line_tag = word_addr;
            end else begin
                line_tag = word_addr >> $clog2(LINE_WORDS);
            end
        end
    endfunction


    assign occupancy_o = count_q;
    assign empty_o = count_q == '0;
    assign full_o = integer'(count_q) == STORE_QUEUE_DEPTH;

    always_comb begin
        active_wave_mask_o = '0;

        for (
            int active_entry = 0;
            active_entry < STORE_QUEUE_DEPTH;
            active_entry = active_entry + 1
        ) begin
            if (
                entry_valid_q[active_entry]
                && integer'(entry_wave_q[active_entry]) < RESIDENT_WAVES
            ) begin
                active_wave_mask_o[
                    integer'(entry_wave_q[active_entry])
                ] = 1'b1;
            end
        end
    end

    always_comb begin
        enqueue_wave_in_range =
            integer'(enqueue_wave_i) < RESIDENT_WAVES;

        enqueue_ready_o = (
            !full_o
            && enqueue_wave_in_range
            && !active_wave_mask_o[integer'(enqueue_wave_i)]
        );

        enqueue_fire_o = enqueue_valid_i && enqueue_ready_o;
        enqueue_stall_o = enqueue_valid_i && !enqueue_ready_o;
    end

    /*
     * Valid/payload depend only on queue state. Keep the ready-dependent
     * handshake pulse structurally separate so upstream ready logic cannot
     * form a false combinational dependency through this payload block.
     */
    assign drain_fire_o = drain_valid_o && drain_ready_i;

    always_comb begin
        drain_valid_o = (
            !empty_o
            && entry_valid_q[integer'(head_q)]
        );

        drain_wave_o = '0;
        drain_context_o = '0;
        drain_seq_o = '0;
        drain_lane_mask_o = '0;

        for (
            int clear_lane = 0;
            clear_lane < WAVE_SIZE;
            clear_lane = clear_lane + 1
        ) begin
            drain_word_addr_o[clear_lane] = '0;
            drain_wdata_o[clear_lane] = '0;
        end

        if (drain_valid_o) begin
            drain_wave_o = entry_wave_q[integer'(head_q)];
            drain_context_o = entry_context_q[integer'(head_q)];
            drain_seq_o = entry_seq_q[integer'(head_q)];
            drain_lane_mask_o = entry_lane_mask_q[integer'(head_q)];

            for (
                int drain_lane = 0;
                drain_lane < WAVE_SIZE;
                drain_lane = drain_lane + 1
            ) begin
                drain_word_addr_o[drain_lane] =
                    entry_word_addr_q[integer'(head_q)][drain_lane];
                drain_wdata_o[drain_lane] =
                    entry_wdata_q[integer'(head_q)][drain_lane];
            end
        end
    end

    always_comb begin
        probe_conflict_o = 1'b0;
        probe_conflict_lane_mask_o = '0;
        probe_line_conflict_o = 1'b0;
        probe_line_conflict_lane_mask_o = '0;
        probe_source_valid_lane_mask_o = '0;
        probe_source_ambiguous_lane_mask_o = '0;

        for (
            int source_clear_lane = 0;
            source_clear_lane < WAVE_SIZE;
            source_clear_lane = source_clear_lane + 1
        ) begin
            probe_source_seq_o[source_clear_lane] = '0;
            probe_source_wdata_o[source_clear_lane] = '0;
        end

        if (probe_valid_i) begin
            for (
                int probe_lane = 0;
                probe_lane < WAVE_SIZE;
                probe_lane = probe_lane + 1
            ) begin
                if (probe_lane_mask_i[probe_lane]) begin
                    for (
                        int probe_entry = 0;
                        probe_entry < STORE_QUEUE_DEPTH;
                        probe_entry = probe_entry + 1
                    ) begin
                        if (entry_valid_q[probe_entry]) begin
                            for (
                                int store_lane = 0;
                                store_lane < WAVE_SIZE;
                                store_lane = store_lane + 1
                            ) begin
                                if (
                                    entry_lane_mask_q[
                                        probe_entry
                                    ][store_lane]
                                ) begin
                                    if (
                                        probe_word_addr_i[probe_lane]
                                        == entry_word_addr_q[
                                            probe_entry
                                        ][store_lane]
                                    ) begin
                                        probe_conflict_o = 1'b1;
                                        probe_conflict_lane_mask_o[
                                            probe_lane
                                        ] = 1'b1;

                                        /*
                                         * RTL8C-5A source selection is age
                                         * qualified and chooses the youngest
                                         * store that is still older than the
                                         * load's exclusive sequence boundary.
                                         * Raw queue slot order is irrelevant.
                                         */
                                        if (
                                            entry_seq_q[probe_entry]
                                                < probe_seq_boundary_i
                                        ) begin
                                            if (
                                                !probe_source_valid_lane_mask_o[
                                                    probe_lane
                                                ]
                                                || entry_seq_q[probe_entry]
                                                    > probe_source_seq_o[
                                                        probe_lane
                                                    ]
                                            ) begin
                                                probe_source_valid_lane_mask_o[
                                                    probe_lane
                                                ] = 1'b1;
                                                probe_source_ambiguous_lane_mask_o[
                                                    probe_lane
                                                ] = 1'b0;
                                                probe_source_seq_o[probe_lane] =
                                                    entry_seq_q[probe_entry];
                                                probe_source_wdata_o[probe_lane] =
                                                    entry_wdata_q[
                                                        probe_entry
                                                    ][store_lane];

                                            end else if (
                                                entry_seq_q[probe_entry]
                                                    == probe_source_seq_o[
                                                        probe_lane
                                                    ]
                                            ) begin
                                                /*
                                                 * Multiple active lanes from
                                                 * one store target the same
                                                 * word. Backend lane ordering
                                                 * is not architecturally
                                                 * defined yet, so forwarding
                                                 * must treat the source as
                                                 * ambiguous.
                                                 */
                                                probe_source_ambiguous_lane_mask_o[
                                                    probe_lane
                                                ] = 1'b1;
                                            end
                                        end
                                    end

                                    if (
                                        line_tag(
                                            probe_word_addr_i[probe_lane]
                                        )
                                        == line_tag(
                                            entry_word_addr_q[
                                                probe_entry
                                            ][store_lane]
                                        )
                                    ) begin
                                        probe_line_conflict_o = 1'b1;
                                        probe_line_conflict_lane_mask_o[
                                            probe_lane
                                        ] = 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;

            for (
                int reset_entry = 0;
                reset_entry < STORE_QUEUE_DEPTH;
                reset_entry = reset_entry + 1
            ) begin
                entry_valid_q[reset_entry] <= 1'b0;
                entry_wave_q[reset_entry] <= '0;
                entry_context_q[reset_entry] <= '0;
                entry_seq_q[reset_entry] <= '0;
                entry_lane_mask_q[reset_entry] <= '0;

                for (
                    int reset_lane = 0;
                    reset_lane < WAVE_SIZE;
                    reset_lane = reset_lane + 1
                ) begin
                    entry_word_addr_q[reset_entry][reset_lane] <= '0;
                    entry_wdata_q[reset_entry][reset_lane] <= '0;
                end
            end

        end else begin
            if (drain_fire_o) begin
                entry_valid_q[integer'(head_q)] <= 1'b0;
                entry_lane_mask_q[integer'(head_q)] <= '0;
                head_q <= next_ptr(head_q);
            end

            if (enqueue_fire_o) begin
                entry_valid_q[integer'(tail_q)] <= 1'b1;
                entry_wave_q[integer'(tail_q)] <= enqueue_wave_i;
                entry_context_q[integer'(tail_q)] <= enqueue_context_i;
                entry_seq_q[integer'(tail_q)] <= enqueue_seq_i;
                entry_lane_mask_q[integer'(tail_q)] <= enqueue_lane_mask_i;

                for (
                    int enqueue_lane = 0;
                    enqueue_lane < WAVE_SIZE;
                    enqueue_lane = enqueue_lane + 1
                ) begin
                    entry_word_addr_q[integer'(tail_q)][enqueue_lane] <=
                        enqueue_word_addr_i[enqueue_lane];
                    entry_wdata_q[integer'(tail_q)][enqueue_lane] <=
                        enqueue_wdata_i[enqueue_lane];
                end

                tail_q <= next_ptr(tail_q);
            end

            case ({enqueue_fire_o, drain_fire_o})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule
