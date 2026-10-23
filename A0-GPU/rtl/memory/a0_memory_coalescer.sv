`timescale 1ns/1ps

module a0_memory_coalescer #(
    parameter integer WAVE_SIZE = 32,
    parameter integer ADDRESS_WIDTH = 32,

    /*
     * Experimental transaction geometry.
     *
     * Current SIM8 default:
     *
     *     8 x 32-bit words
     *     = 32 bytes
     *
     * This is NOT architecturally frozen.
     */
    parameter integer TRANSACTION_WORDS = 8
) (
    input logic [WAVE_SIZE-1:0]
        lane_mask,

    input logic [ADDRESS_WIDTH-1:0]
        word_addr [0:WAVE_SIZE-1],

    output logic [
        $clog2(WAVE_SIZE + 1)-1:0
    ] lane_requests,

    output logic [
        $clog2(WAVE_SIZE + 1)-1:0
    ] unique_words,

    output logic [
        $clog2(WAVE_SIZE + 1)-1:0
    ] transaction_count,

    /*
     * Deterministic transaction list.
     *
     * Transactions are emitted in first-active-lane
     * discovery order.
     */
    output logic [WAVE_SIZE-1:0]
        segment_valid,

    output logic [ADDRESS_WIDTH-1:0]
        segment_id [0:WAVE_SIZE-1]
);

    localparam integer COUNT_WIDTH =
        $clog2(WAVE_SIZE + 1);

    integer lane;
    integer previous;
    integer slot;

    integer request_count_int;
    integer unique_count_int;
    integer transaction_count_int;

    logic unique_word;
    logic unique_segment;


    always_comb begin

        lane_requests = '0;
        unique_words = '0;
        transaction_count = '0;

        segment_valid = '0;

        request_count_int = 0;
        unique_count_int = 0;
        transaction_count_int = 0;

        unique_word = 1'b0;
        unique_segment = 1'b0;


        for (
            slot = 0;
            slot < WAVE_SIZE;
            slot = slot + 1
        ) begin
            segment_id[slot] = '0;
        end


        /*
         * One pass over logical lanes.
         *
         * A lane contributes only when lane_mask is set.
         */
        for (
            lane = 0;
            lane < WAVE_SIZE;
            lane = lane + 1
        ) begin

            if (lane_mask[lane]) begin

                request_count_int =
                    request_count_int + 1;

                unique_word = 1'b1;
                unique_segment = 1'b1;


                /*
                 * Search only earlier active lanes.
                 *
                 * First occurrence defines uniqueness and
                 * deterministic transaction ordering.
                 */
                for (
                    previous = 0;
                    previous < WAVE_SIZE;
                    previous = previous + 1
                ) begin

                    if (
                        previous < lane
                        && lane_mask[previous]
                    ) begin

                        if (
                            word_addr[previous]
                            == word_addr[lane]
                        ) begin
                            unique_word = 1'b0;
                        end


                        if (
                            (
                                word_addr[previous]
                                / TRANSACTION_WORDS
                            )
                            ==
                            (
                                word_addr[lane]
                                / TRANSACTION_WORDS
                            )
                        ) begin
                            unique_segment = 1'b0;
                        end
                    end
                end


                if (unique_word) begin
                    unique_count_int =
                        unique_count_int + 1;
                end


                if (unique_segment) begin

                    segment_valid[
                        transaction_count_int
                    ] = 1'b1;

                    segment_id[
                        transaction_count_int
                    ] = (
                        word_addr[lane]
                        / TRANSACTION_WORDS
                    );

                    transaction_count_int =
                        transaction_count_int + 1;
                end
            end
        end


        lane_requests =
            COUNT_WIDTH'(
                request_count_int
            );

        unique_words =
            COUNT_WIDTH'(
                unique_count_int
            );

        transaction_count =
            COUNT_WIDTH'(
                transaction_count_int
            );
    end

endmodule
