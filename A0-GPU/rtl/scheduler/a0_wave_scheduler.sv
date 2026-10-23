`timescale 1ns/1ps

/*
 * A0-RTL7A resident-wave scheduler reference block.
 *
 * Hardware policy in RTL7A is deliberately simple:
 *
 *   1. Deterministic loose round-robin (LRR) reference selection.
 *   2. Optional external policy override, accepted only when the requested
 *      wave is currently ready.
 *   3. If the override is absent/invalid/unready, selection falls back to LRR.
 *
 * This keeps the correctness baseline independent from the SIM17 adaptive-v1
 * research policy while exposing the metadata that a later RTL8 policy block
 * needs: MSHR pressure, memory-stalled waves, ready non-memory waves and
 * same-line merge opportunities.
 *
 * The LRR cursor advances only when grant_fire_i is asserted. Backpressure
 * therefore leaves the selected wave stable.
 */
module a0_wave_scheduler #(
    parameter integer RESIDENT_WAVES = 4,
    parameter integer PRESSURE_COUNT_W = 8,

    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer WAVE_COUNT_W =
        (RESIDENT_WAVES <= 1)
            ? 1
            : $clog2(RESIDENT_WAVES + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic [RESIDENT_WAVES-1:0] ready_mask_i,

    /*
     * Policy metadata. RTL7A reference selection does not hardwire
     * adaptive-v1; the metadata is exposed as telemetry and for an external
     * policy override boundary.
     */
    input logic [RESIDENT_WAVES-1:0] memory_ready_mask_i,
    input logic [RESIDENT_WAVES-1:0] non_memory_ready_mask_i,
    input logic [RESIDENT_WAVES-1:0] memory_stalled_mask_i,
    input logic [RESIDENT_WAVES-1:0] merge_ready_mask_i,

    input logic [PRESSURE_COUNT_W-1:0] mshr_occupancy_i,
    input logic [PRESSURE_COUNT_W-1:0] mshr_capacity_i,

    input logic policy_override_valid_i,
    input logic [WAVE_ID_W-1:0] policy_override_wave_i,

    /*
     * The selected wave is consumed only when grant_fire_i=1.
     */
    input logic grant_fire_i,

    output logic grant_valid_o,
    output logic [WAVE_ID_W-1:0] grant_wave_o,

    output logic lrr_candidate_valid_o,
    output logic [WAVE_ID_W-1:0] lrr_candidate_wave_o,
    output logic policy_override_accepted_o,

    output logic pressure_high_o,
    output logic [RESIDENT_WAVES-1:0] merge_ready_visible_o,

    output logic [WAVE_COUNT_W-1:0] ready_count_o,
    output logic [WAVE_COUNT_W-1:0] memory_ready_count_o,
    output logic [WAVE_COUNT_W-1:0] non_memory_ready_count_o,
    output logic [WAVE_COUNT_W-1:0] memory_stalled_count_o,
    output logic [WAVE_COUNT_W-1:0] merge_ready_count_o,

    output logic [WAVE_ID_W-1:0] rr_cursor_o
);

    logic [WAVE_ID_W-1:0] rr_cursor_q;

    logic [PRESSURE_COUNT_W:0] occupancy_doubled;

    logic lrr_found;

    integer scan_offset;
    integer scan_index;


    function automatic logic wave_id_valid(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        wave_id_valid =
            integer'(wave_id) < RESIDENT_WAVES;
    endfunction


    function automatic logic wave_ready(
        input logic [RESIDENT_WAVES-1:0] mask,
        input logic [WAVE_ID_W-1:0] wave_id
    );
        begin
            if (integer'(wave_id) < RESIDENT_WAVES) begin
                wave_ready = mask[integer'(wave_id)];
            end else begin
                wave_ready = 1'b0;
            end
        end
    endfunction


    function automatic logic [WAVE_COUNT_W-1:0] count_mask(
        input logic [RESIDENT_WAVES-1:0] mask
    );
        integer count_index;
        logic [WAVE_COUNT_W-1:0] count_value;
        begin
            count_value = '0;

            for (
                count_index = 0;
                count_index < RESIDENT_WAVES;
                count_index = count_index + 1
            ) begin
                if (mask[count_index]) begin
                    count_value =
                        count_value + WAVE_COUNT_W'(1);
                end
            end

            count_mask = count_value;
        end
    endfunction


    assign rr_cursor_o = rr_cursor_q;

    assign occupancy_doubled =
        ({1'b0, mshr_occupancy_i} << 1);

    assign pressure_high_o =
        (mshr_capacity_i != '0)
        && (
            occupancy_doubled
            >= {1'b0, mshr_capacity_i}
        );

    assign merge_ready_visible_o =
        merge_ready_mask_i
        & ready_mask_i
        & memory_ready_mask_i;

    assign ready_count_o =
        count_mask(ready_mask_i);

    assign memory_ready_count_o =
        count_mask(
            memory_ready_mask_i
            & ready_mask_i
        );

    assign non_memory_ready_count_o =
        count_mask(
            non_memory_ready_mask_i
            & ready_mask_i
        );

    assign memory_stalled_count_o =
        count_mask(memory_stalled_mask_i);

    assign merge_ready_count_o =
        count_mask(merge_ready_visible_o);


    always_comb begin

        lrr_candidate_valid_o = 1'b0;
        lrr_candidate_wave_o = '0;

        lrr_found = 1'b0;
        scan_index = 0;

        for (
            scan_offset = 0;
            scan_offset < RESIDENT_WAVES;
            scan_offset = scan_offset + 1
        ) begin

            scan_index =
                integer'(rr_cursor_q)
                + scan_offset;

            if (scan_index >= RESIDENT_WAVES) begin
                scan_index =
                    scan_index - RESIDENT_WAVES;
            end

            if (
                !lrr_found
                && ready_mask_i[scan_index]
            ) begin

                lrr_candidate_valid_o = 1'b1;
                lrr_candidate_wave_o =
                    WAVE_ID_W'(scan_index);
                lrr_found = 1'b1;

            end
        end

        grant_valid_o = lrr_candidate_valid_o;
        grant_wave_o = lrr_candidate_wave_o;
        policy_override_accepted_o = 1'b0;

        if (
            policy_override_valid_i
            && wave_id_valid(policy_override_wave_i)
            && wave_ready(
                ready_mask_i,
                policy_override_wave_i
            )
        ) begin

            grant_valid_o = 1'b1;
            grant_wave_o = policy_override_wave_i;
            policy_override_accepted_o = 1'b1;

        end

    end


    always_ff @(posedge clk) begin

        if (!rst_n) begin

            rr_cursor_q <= '0;

        end else if (
            grant_fire_i
            && grant_valid_o
        ) begin

            if (
                integer'(grant_wave_o)
                == RESIDENT_WAVES - 1
            ) begin

                rr_cursor_q <= '0;

            end else begin

                rr_cursor_q <=
                    grant_wave_o
                    + WAVE_ID_W'(1);

            end

        end

    end

endmodule
