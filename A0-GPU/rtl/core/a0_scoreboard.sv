`timescale 1ns/1ps

module a0_scoreboard #(
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer PREDICATE_REG_COUNT = 16
) (
    input logic clk,
    input logic rst_n,

    /*
     * Dependency query for one candidate instruction.
     */
    input logic query_valid,

    input logic query_vector_src0_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_src0,

    input logic query_vector_src1_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_src1,

    input logic query_vector_src2_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_src2,

    input logic query_vector_dst_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_dst,

    input logic query_predicate_src_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        query_predicate_src,

    input logic query_predicate_dst_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        query_predicate_dst,

    /*
     * Reservation on successful issue.
     */
    input logic reserve_valid,

    input logic reserve_vector_dst_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0]
        reserve_vector_dst,

    input logic reserve_predicate_dst_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        reserve_predicate_dst,

    /*
     * Release on architectural completion/retirement.
     */
    input logic release_valid,

    input logic release_vector_dst_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0]
        release_vector_dst,

    input logic release_predicate_dst_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        release_predicate_dst,

    output logic vector_raw_hazard,
    output logic vector_waw_hazard,

    output logic predicate_raw_hazard,
    output logic predicate_waw_hazard,

    output logic any_hazard,
    output logic issue_allowed,

    output logic [VECTOR_REG_COUNT-1:0]
        vector_busy,

    output logic [PREDICATE_REG_COUNT-1:0]
        predicate_busy
);


    /*
     * A0-RTL5B Phase 1 hazard classification.
     *
     * RAW:
     * candidate reads a destination that is still busy.
     *
     * WAW:
     * candidate wants to write a destination that is
     * already reserved.
     *
     * WAR is intentionally outside this first contract.
     */
    always_comb begin

        vector_raw_hazard = (
            query_valid
            && (
                (
                    query_vector_src0_enable
                    && vector_busy[
                        query_vector_src0
                    ]
                )
                || (
                    query_vector_src1_enable
                    && vector_busy[
                        query_vector_src1
                    ]
                )
                || (
                    query_vector_src2_enable
                    && vector_busy[
                        query_vector_src2
                    ]
                )
            )
        );

        vector_waw_hazard = (
            query_valid
            && query_vector_dst_enable
            && vector_busy[
                query_vector_dst
            ]
        );

        predicate_raw_hazard = (
            query_valid
            && query_predicate_src_enable
            && predicate_busy[
                query_predicate_src
            ]
        );

        predicate_waw_hazard = (
            query_valid
            && query_predicate_dst_enable
            && predicate_busy[
                query_predicate_dst
            ]
        );

        any_hazard = (
            vector_raw_hazard
            || vector_waw_hazard
            || predicate_raw_hazard
            || predicate_waw_hazard
        );

        issue_allowed = (
            query_valid
            && !any_hazard
        );
    end


    /*
     * Busy-state ownership.
     *
     * Release is processed before reserve.
     * Therefore, if the same destination is released and
     * reserved in one cycle, the new reservation remains
     * busy after that clock edge.
     *
     * Same-cycle retirement-to-issue bypass policy is NOT
     * frozen by RTL5B Phase 1.
     */
    always_ff @(posedge clk) begin

        if (!rst_n) begin

            vector_busy <= '0;
            predicate_busy <= '0;

        end else begin

            if (release_valid) begin

                if (
                    release_vector_dst_enable
                ) begin

                    vector_busy[
                        release_vector_dst
                    ] <= 1'b0;
                end

                if (
                    release_predicate_dst_enable
                ) begin

                    predicate_busy[
                        release_predicate_dst
                    ] <= 1'b0;
                end
            end


            if (reserve_valid) begin

                if (
                    reserve_vector_dst_enable
                ) begin

                    vector_busy[
                        reserve_vector_dst
                    ] <= 1'b1;
                end

                if (
                    reserve_predicate_dst_enable
                ) begin

                    predicate_busy[
                        reserve_predicate_dst
                    ] <= 1'b1;
                end
            end
        end
    end

endmodule
