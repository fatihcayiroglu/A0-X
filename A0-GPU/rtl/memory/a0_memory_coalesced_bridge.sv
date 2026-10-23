`timescale 1ns/1ps

module a0_memory_coalesced_bridge #(
    parameter integer WAVE_SIZE = 32,
    parameter integer ADDRESS_WIDTH = 32,

    /*
     * Experimental / unfrozen transaction geometry.
     */
    parameter integer TRANSACTION_WORDS = 8
) (
    input logic clk,
    input logic rst_n,

    /*
     * Architectural wave-side request.
     *
     * This matches the RTL2 memory boundary.
     */
    input logic up_req_valid,
    input logic up_req_write,

    input logic [WAVE_SIZE-1:0]
        up_req_lane_mask,

    input logic [ADDRESS_WIDTH-1:0]
        up_req_addr [0:WAVE_SIZE-1],

    input logic [31:0]
        up_req_wdata [0:WAVE_SIZE-1],

    /*
     * Architectural response back to the wave.
     */
    output logic up_resp_valid,
    output logic up_resp_fault,

    output logic [31:0]
        up_resp_rdata [0:WAVE_SIZE-1],

    /*
     * Coalesced physical transaction side.
     *
     * One segment transaction is outstanding
     * at a time in RTL3B.
     */
    output logic txn_req_valid,
    output logic txn_req_write,

    output logic [ADDRESS_WIDTH-1:0]
        txn_segment_id,

    output logic [WAVE_SIZE-1:0]
        txn_lane_mask,

    output logic [ADDRESS_WIDTH-1:0]
        txn_word_addr [0:WAVE_SIZE-1],

    output logic [31:0]
        txn_wdata [0:WAVE_SIZE-1],

    input logic txn_resp_valid,
    input logic txn_resp_fault,

    input logic [31:0]
        txn_resp_rdata [0:WAVE_SIZE-1]
);

    localparam integer COUNT_WIDTH =
        $clog2(WAVE_SIZE + 1);

    localparam integer INDEX_WIDTH =
        (WAVE_SIZE <= 1)
            ? 1
            : $clog2(WAVE_SIZE);

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_PREPARE,
        STATE_ISSUE,
        STATE_WAIT
    } bridge_state_t;


    bridge_state_t state;


    logic request_write;

    logic [WAVE_SIZE-1:0]
        request_lane_mask;

    logic [ADDRESS_WIDTH-1:0]
        request_addr [0:WAVE_SIZE-1];

    logic [31:0]
        request_wdata [0:WAVE_SIZE-1];


    logic [COUNT_WIDTH-1:0]
        coalesced_lane_requests_unused;

    logic [COUNT_WIDTH-1:0]
        coalesced_unique_words_unused;

    logic [COUNT_WIDTH-1:0]
        coalesced_transaction_count;

    logic [WAVE_SIZE-1:0]
        coalesced_segment_valid_unused;

    logic [ADDRESS_WIDTH-1:0]
        coalesced_segment_id [0:WAVE_SIZE-1];


    /*
     * Must represent both 0..WAVE_SIZE-1
     * segment indices and WAVE_SIZE as the
     * completed transaction count.
     */
    logic [INDEX_WIDTH-1:0]
        segment_index;


    integer lane;


    a0_memory_coalescer #(
        .WAVE_SIZE(
            WAVE_SIZE
        ),
        .ADDRESS_WIDTH(
            ADDRESS_WIDTH
        ),
        .TRANSACTION_WORDS(
            TRANSACTION_WORDS
        )
    ) coalescer (
        .lane_mask(
            request_lane_mask
        ),

        .word_addr(
            request_addr
        ),

        .lane_requests(
            coalesced_lane_requests_unused
        ),

        .unique_words(
            coalesced_unique_words_unused
        ),

        .transaction_count(
            coalesced_transaction_count
        ),

        .segment_valid(
            coalesced_segment_valid_unused
        ),

        .segment_id(
            coalesced_segment_id
        )
    );


    always_ff @(posedge clk) begin

        if (!rst_n) begin

            state <= STATE_IDLE;

            request_write <= 1'b0;
            request_lane_mask <= '0;

            segment_index <= '0;

            up_resp_valid <= 1'b0;
            up_resp_fault <= 1'b0;

            txn_req_valid <= 1'b0;
            txn_req_write <= 1'b0;

            txn_segment_id <= '0;
            txn_lane_mask <= '0;


            for (
                lane = 0;
                lane < WAVE_SIZE;
                lane = lane + 1
            ) begin

                request_addr[lane] <= '0;
                request_wdata[lane] <= '0;

                up_resp_rdata[lane] <= 32'b0;

                txn_word_addr[lane] <= '0;
                txn_wdata[lane] <= '0;
            end

        end else begin

            /*
             * Response/request valid signals are pulses.
             */
            up_resp_valid <= 1'b0;
            up_resp_fault <= 1'b0;

            txn_req_valid <= 1'b0;


            case (state)

                STATE_IDLE: begin

                    if (up_req_valid) begin

                        request_write <=
                            up_req_write;

                        request_lane_mask <=
                            up_req_lane_mask;


                        /*
                         * Clear accumulated read response
                         * for the new architectural request.
                         */
                        for (
                            lane = 0;
                            lane < WAVE_SIZE;
                            lane = lane + 1
                        ) begin

                            request_addr[lane] <=
                                up_req_addr[lane];

                            request_wdata[lane] <=
                                up_req_wdata[lane];

                            up_resp_rdata[lane] <=
                                32'b0;
                        end


                        state <= STATE_PREPARE;
                    end
                end


                /*
                 * One cycle is deliberately reserved after
                 * latching the wave request so the
                 * combinational coalescer operates on stable
                 * registered request state.
                 */
                STATE_PREPARE: begin

                    segment_index <= '0;

                    if (
                        coalesced_transaction_count
                        == '0
                    ) begin

                        /*
                         * Defensive zero-lane behavior.
                         *
                         * The current wave core normally
                         * suppresses zero-active-lane memory
                         * requests before this boundary.
                         */
                        up_resp_valid <= 1'b1;

                        state <= STATE_IDLE;

                    end else begin

                        state <= STATE_ISSUE;
                    end
                end


                STATE_ISSUE: begin

                    txn_req_valid <= 1'b1;
                    txn_req_write <= request_write;

                    txn_segment_id <=
                        coalesced_segment_id[
                            segment_index
                        ];

                    txn_lane_mask <= '0;


                    for (
                        lane = 0;
                        lane < WAVE_SIZE;
                        lane = lane + 1
                    ) begin

                        txn_word_addr[lane] <=
                            request_addr[lane];

                        txn_wdata[lane] <=
                            request_wdata[lane];


                        if (
                            request_lane_mask[lane]
                            &&
                            (
                                request_addr[lane]
                                / TRANSACTION_WORDS
                            )
                            ==
                            coalesced_segment_id[
                                segment_index
                            ]
                        ) begin

                            txn_lane_mask[lane] <=
                                1'b1;
                        end
                    end


                    state <= STATE_WAIT;
                end


                STATE_WAIT: begin

                    if (txn_resp_valid) begin

                        if (txn_resp_fault) begin

                            /*
                             * Fail the whole architectural
                             * memory request if one physical
                             * transaction faults.
                             */
                            up_resp_fault <= 1'b1;
                            up_resp_valid <= 1'b1;

                            state <= STATE_IDLE;

                        end else begin

                            /*
                             * Reconstruct the logical wave
                             * load response from each
                             * transaction's lane subset.
                             */
                            if (!request_write) begin

                                for (
                                    lane = 0;
                                    lane < WAVE_SIZE;
                                    lane = lane + 1
                                ) begin

                                    if (
                                        txn_lane_mask[lane]
                                    ) begin

                                        up_resp_rdata[
                                            lane
                                        ] <=
                                            txn_resp_rdata[
                                                lane
                                            ];
                                    end
                                end
                            end


                            if (
                                (
                                    COUNT_WIDTH'(segment_index)
                                    + COUNT_WIDTH'(1)
                                )
                                ==
                                coalesced_transaction_count
                            ) begin

                                /*
                                 * All physical transactions
                                 * belonging to this logical
                                 * request are complete.
                                 */
                                up_resp_valid <= 1'b1;

                                state <= STATE_IDLE;

                            end else begin

                                segment_index <=
                                    segment_index
                                    + 1'b1;

                                state <= STATE_ISSUE;
                            end
                        end
                    end
                end


                default: begin

                    state <= STATE_IDLE;

                    up_resp_fault <= 1'b1;
                    up_resp_valid <= 1'b1;
                end

            endcase
        end
    end

endmodule
