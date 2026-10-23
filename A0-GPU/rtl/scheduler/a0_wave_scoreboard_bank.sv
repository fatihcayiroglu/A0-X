`timescale 1ns/1ps

/*
 * A0-RTL7B wave-qualified scoreboard ownership.
 *
 * One logical scoreboard is retained per resident wave. Only the selected
 * wave receives query/reserve/release events, but busy state is not shared
 * between waves. This keeps register dependency ownership wave-local while
 * preserving the proven RTL5B scoreboard semantics.
 */
module a0_wave_scoreboard_bank #(
    parameter integer RESIDENT_WAVES = 4,
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer PREDICATE_REG_COUNT = 16,
    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES)
) (
    input logic clk,
    input logic rst_n,

    input logic query_valid,
    input logic [WAVE_ID_W-1:0] query_wave,

    input logic query_vector_src0_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0] query_vector_src0,
    input logic query_vector_src1_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0] query_vector_src1,
    input logic query_vector_src2_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0] query_vector_src2,
    input logic query_vector_dst_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0] query_vector_dst,
    input logic query_predicate_src_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0] query_predicate_src,
    input logic query_predicate_dst_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0] query_predicate_dst,

    input logic reserve_valid,
    input logic [WAVE_ID_W-1:0] reserve_wave,
    input logic reserve_vector_dst_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0] reserve_vector_dst,
    input logic reserve_predicate_dst_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0] reserve_predicate_dst,

    input logic release_valid,
    input logic [WAVE_ID_W-1:0] release_wave,
    input logic release_vector_dst_enable,
    input logic [$clog2(VECTOR_REG_COUNT)-1:0] release_vector_dst,
    input logic release_predicate_dst_enable,
    input logic [$clog2(PREDICATE_REG_COUNT)-1:0] release_predicate_dst,

    /* Explicit context teardown clears any stale reservations. */
    input logic clear_valid,
    input logic [WAVE_ID_W-1:0] clear_wave,

    output logic vector_raw_hazard,
    output logic vector_waw_hazard,
    output logic predicate_raw_hazard,
    output logic predicate_waw_hazard,
    output logic any_hazard,
    output logic issue_allowed,

    output logic [VECTOR_REG_COUNT-1:0]
        vector_busy_by_wave [0:RESIDENT_WAVES-1],
    output logic [PREDICATE_REG_COUNT-1:0]
        predicate_busy_by_wave [0:RESIDENT_WAVES-1]
);

    logic vector_raw_hazard_wave [0:RESIDENT_WAVES-1];
    logic vector_waw_hazard_wave [0:RESIDENT_WAVES-1];
    logic predicate_raw_hazard_wave [0:RESIDENT_WAVES-1];
    logic predicate_waw_hazard_wave [0:RESIDENT_WAVES-1];
    logic any_hazard_wave [0:RESIDENT_WAVES-1];
    logic issue_allowed_wave [0:RESIDENT_WAVES-1];

    genvar wave_index;


    function automatic logic wave_id_valid(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        wave_id_valid = integer'(wave_id) < RESIDENT_WAVES;
    endfunction


    generate
        for (
            wave_index = 0;
            wave_index < RESIDENT_WAVES;
            wave_index = wave_index + 1
        ) begin : scoreboards

            logic scoreboard_rst_n;

            assign scoreboard_rst_n =
                rst_n
                && !(
                    clear_valid
                    && wave_id_valid(clear_wave)
                    && integer'(clear_wave) == wave_index
                );

            a0_scoreboard #(
                .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
                .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT)
            ) scoreboard (
                .clk(clk),
                .rst_n(scoreboard_rst_n),

                .query_valid(
                    query_valid
                    && wave_id_valid(query_wave)
                    && integer'(query_wave) == wave_index
                ),
                .query_vector_src0_enable(query_vector_src0_enable),
                .query_vector_src0(query_vector_src0),
                .query_vector_src1_enable(query_vector_src1_enable),
                .query_vector_src1(query_vector_src1),
                .query_vector_src2_enable(query_vector_src2_enable),
                .query_vector_src2(query_vector_src2),
                .query_vector_dst_enable(query_vector_dst_enable),
                .query_vector_dst(query_vector_dst),
                .query_predicate_src_enable(query_predicate_src_enable),
                .query_predicate_src(query_predicate_src),
                .query_predicate_dst_enable(query_predicate_dst_enable),
                .query_predicate_dst(query_predicate_dst),

                .reserve_valid(
                    reserve_valid
                    && wave_id_valid(reserve_wave)
                    && integer'(reserve_wave) == wave_index
                ),
                .reserve_vector_dst_enable(reserve_vector_dst_enable),
                .reserve_vector_dst(reserve_vector_dst),
                .reserve_predicate_dst_enable(reserve_predicate_dst_enable),
                .reserve_predicate_dst(reserve_predicate_dst),

                .release_valid(
                    release_valid
                    && wave_id_valid(release_wave)
                    && integer'(release_wave) == wave_index
                ),
                .release_vector_dst_enable(release_vector_dst_enable),
                .release_vector_dst(release_vector_dst),
                .release_predicate_dst_enable(release_predicate_dst_enable),
                .release_predicate_dst(release_predicate_dst),

                .vector_raw_hazard(vector_raw_hazard_wave[wave_index]),
                .vector_waw_hazard(vector_waw_hazard_wave[wave_index]),
                .predicate_raw_hazard(predicate_raw_hazard_wave[wave_index]),
                .predicate_waw_hazard(predicate_waw_hazard_wave[wave_index]),
                .any_hazard(any_hazard_wave[wave_index]),
                .issue_allowed(issue_allowed_wave[wave_index]),
                .vector_busy(vector_busy_by_wave[wave_index]),
                .predicate_busy(predicate_busy_by_wave[wave_index])
            );
        end
    endgenerate


    always_comb begin
        vector_raw_hazard = 1'b0;
        vector_waw_hazard = 1'b0;
        predicate_raw_hazard = 1'b0;
        predicate_waw_hazard = 1'b0;
        any_hazard = 1'b0;
        issue_allowed = 1'b0;

        if (wave_id_valid(query_wave)) begin
            vector_raw_hazard =
                vector_raw_hazard_wave[query_wave];
            vector_waw_hazard =
                vector_waw_hazard_wave[query_wave];
            predicate_raw_hazard =
                predicate_raw_hazard_wave[query_wave];
            predicate_waw_hazard =
                predicate_waw_hazard_wave[query_wave];
            any_hazard =
                any_hazard_wave[query_wave];
            issue_allowed =
                issue_allowed_wave[query_wave];
        end
    end

endmodule
