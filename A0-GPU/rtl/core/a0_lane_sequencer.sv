`timescale 1ns/1ps

module a0_lane_sequencer #(
    parameter integer WAVE_SIZE = 32,
    parameter integer PHYSICAL_LANES = 8
) (
    input logic clk,
    input logic rst_n,

    /*
     * Physical sequencing clock-enable.
     *
     * When low, sequencing state is preserved.
     */
    input logic advance_enable,

    /*
     * Launch one logical vector operation.
     *
     * start is accepted only while idle.
     */
    input logic start,

    /*
     * Logical-wave execution masks.
     */
    input logic [WAVE_SIZE-1:0]
        exec_mask,

    input logic pred_enable,

    input logic [WAVE_SIZE-1:0]
        pred_mask,

    /*
     * Sequencer status.
     */
    output logic busy,
    output logic done,
    output logic beat_valid,

    /*
     * WAVE_SIZE bits are sufficient to encode
     * every possible physical beat index.
     *
     * For the current WAVE_SIZE=32 this is
     * a five-bit value.
     */
    output logic [$clog2(WAVE_SIZE)-1:0]
        beat_index,

    /*
     * Which physical slots correspond to a real
     * logical lane in the current beat.
     *
     * physical_active_mask additionally applies
     * EXEC and optional predicate masking.
     */
    output logic [PHYSICAL_LANES-1:0]
        physical_valid_mask,

    output logic [PHYSICAL_LANES-1:0]
        physical_active_mask,

    /*
     * Logical lane represented by each physical
     * SIMD slot in the current beat.
     */
    output logic [$clog2(WAVE_SIZE)-1:0]
        logical_lane [0:PHYSICAL_LANES-1]
);

    localparam integer BEAT_COUNT =
        (
            WAVE_SIZE
            + PHYSICAL_LANES
            - 1
        )
        / PHYSICAL_LANES;


    integer physical_lane;
    integer logical_index;


    /*
     * Beat progression.
     *
     * done is a one-cycle pulse after the final
     * physical beat of one logical operation.
     */
    always_ff @(posedge clk) begin

        if (!rst_n) begin

            busy <= 1'b0;
            done <= 1'b0;
            beat_index <= '0;

        end else if (advance_enable) begin

            /*
             * done is one enabled-cycle completion pulse.
             *
             * If execution is paused while done is high,
             * preserve it until the core resumes and can
             * consume the completion.
             */
            done <= 1'b0;


            if (!busy) begin

                if (start) begin

                    busy <= 1'b1;
                    beat_index <= '0;
                end

            end else begin

                if (
                    beat_index
                    ==
                    $clog2(WAVE_SIZE)'(
                        BEAT_COUNT - 1
                    )
                ) begin

                    busy <= 1'b0;
                    done <= 1'b1;

                end else begin

                    beat_index <=
                        beat_index + 1'b1;
                end
            end
        end
    end


    /*
     * Physical-to-logical lane mapping for the
     * currently visible beat.
     */
    always_comb begin

        beat_valid = busy;

        physical_valid_mask = '0;
        physical_active_mask = '0;


        for (
            physical_lane = 0;
            physical_lane < PHYSICAL_LANES;
            physical_lane = physical_lane + 1
        ) begin

            logical_index = (
                integer'(beat_index)
                * PHYSICAL_LANES
                + physical_lane
            );


            logical_lane[physical_lane] = (
                logical_index[
                    $clog2(WAVE_SIZE)-1:0
                ]
            );


            if (
                busy
                && logical_index < WAVE_SIZE
            ) begin

                physical_valid_mask[
                    physical_lane
                ] = 1'b1;


                if (
                    exec_mask[
                        logical_index
                    ]
                    && (
                        !pred_enable
                        || pred_mask[
                            logical_index
                        ]
                    )
                ) begin

                    physical_active_mask[
                        physical_lane
                    ] = 1'b1;
                end
            end
        end
    end

endmodule
