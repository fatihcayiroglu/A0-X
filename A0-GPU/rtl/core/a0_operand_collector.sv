`timescale 1ns/1ps

module a0_operand_collector #(
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer WAVE_SIZE = 32,
    parameter integer PHYSICAL_LANES = 8,
    parameter integer REG_INDEX_W =
        (VECTOR_REG_COUNT <= 1) ? 1 : $clog2(VECTOR_REG_COUNT),
    parameter integer BEAT_COUNT =
        (WAVE_SIZE + PHYSICAL_LANES - 1) / PHYSICAL_LANES,
    parameter integer BEAT_INDEX_W =
        (BEAT_COUNT <= 1) ? 1 : $clog2(BEAT_COUNT)
) (
    input logic clk,
    input logic rst_n,

    /*
     * One decoded instruction-beat request.
     * Disabled sources are treated as architecturally absent and their
     * result data is returned as zero.
     */
    input logic req_valid,
    output logic req_ready,

    input logic req_src0_enable,
    input logic req_src1_enable,
    input logic req_src2_enable,

    input logic [REG_INDEX_W-1:0] req_src0,
    input logic [REG_INDEX_W-1:0] req_src1,
    input logic [REG_INDEX_W-1:0] req_src2,

    input logic [BEAT_INDEX_W-1:0] req_beat,

    /*
     * Completed operand set. The payload remains stable while
     * result_valid=1 and result_ready=0.
     */
    output logic result_valid,
    input logic result_ready,

    output logic [PHYSICAL_LANES*32-1:0] result_src0_data,
    output logic [PHYSICAL_LANES*32-1:0] result_src1_data,
    output logic [PHYSICAL_LANES*32-1:0] result_src2_data,

    output logic busy,
    output logic bank_conflict_cycle,

    /*
     * Banked-register-file read interface.
     * Source N maps permanently to RF read port N, which means response
     * routing needs no tag/CAM for this single-instruction collector.
     */
    output logic [2:0] rf_read_valid,
    output logic [REG_INDEX_W-1:0] rf_read_reg [0:2],
    output logic [BEAT_INDEX_W-1:0] rf_read_beat [0:2],

    input logic [2:0] rf_read_ready,
    input logic [2:0] rf_read_bank_conflict,
    input logic [2:0] rf_read_resp_valid,
    input logic [PHYSICAL_LANES*32-1:0]
        rf_read_resp_data [0:2]
);

    logic active_q;

    logic [2:0] pending_q;
    logic [2:0] inflight_q;
    logic [2:0] done_q;

    logic [REG_INDEX_W-1:0] src_reg_q [0:2];
    logic [BEAT_INDEX_W-1:0] beat_q;

    logic [PHYSICAL_LANES*32-1:0] src_data_q [0:2];

    integer comb_source_index;


    assign result_valid = active_q && (&done_q);

    /*
     * Zero-bubble ownership transfer is permitted: a new request may be
     * accepted on the same edge that the previous completed operand set
     * is consumed.
     */
    assign req_ready =
        !active_q
        || (result_valid && result_ready);

    assign busy = active_q;

    assign result_src0_data = src_data_q[0];
    assign result_src1_data = src_data_q[1];
    assign result_src2_data = src_data_q[2];


    always_comb begin

        for (
            comb_source_index = 0;
            comb_source_index < 3;
            comb_source_index = comb_source_index + 1
        ) begin

            rf_read_valid[comb_source_index] =
                active_q
                && pending_q[comb_source_index]
                && !result_valid;

            rf_read_reg[comb_source_index] = src_reg_q[comb_source_index];
            rf_read_beat[comb_source_index] = beat_q;
        end

    end


    /*
     * Conflict telemetry is intentionally separate from RF request
     * generation. rf_read_bank_conflict is combinationally derived by
     * the register file from rf_read_valid. Keeping this monitor in the
     * request-generation always_comb block creates a conservative
     * block-level dependency cycle in Verilator even though the conflict
     * indication does not feed request generation functionally.
     */
    assign bank_conflict_cycle =
        |(rf_read_valid & rf_read_bank_conflict);


    always_ff @(posedge clk) begin

        if (!rst_n) begin

            active_q <= 1'b0;

            pending_q <= '0;
            inflight_q <= '0;
            done_q <= '0;

            beat_q <= '0;

            for (
                integer seq_source_index = 0;
                seq_source_index < 3;
                seq_source_index = seq_source_index + 1
            ) begin

                src_reg_q[seq_source_index] <= '0;
                src_data_q[seq_source_index] <= '0;

            end

        end else begin

            /*
             * Read grants consume pending source requests.
             */
            for (
                integer seq_source_index = 0;
                seq_source_index < 3;
                seq_source_index = seq_source_index + 1
            ) begin

                if (
                    rf_read_valid[seq_source_index]
                    && rf_read_ready[seq_source_index]
                ) begin

                    pending_q[seq_source_index] <= 1'b0;
                    inflight_q[seq_source_index] <= 1'b1;

                end

                if (
                    rf_read_resp_valid[seq_source_index]
                    && inflight_q[seq_source_index]
                ) begin

                    src_data_q[seq_source_index]
                        <= rf_read_resp_data[seq_source_index];

                    inflight_q[seq_source_index] <= 1'b0;
                    done_q[seq_source_index] <= 1'b1;

                end
            end

            /*
             * Consume a completed operand set when no replacement request
             * is arriving on the same edge.
             */
            if (
                result_valid
                && result_ready
                && !(req_valid && req_ready)
            ) begin

                active_q <= 1'b0;
                pending_q <= '0;
                inflight_q <= '0;
                done_q <= '0;

            end

            /*
             * New request initialization is intentionally last so that it
             * owns the state on a zero-bubble result-consume/request-accept
             * handoff edge.
             */
            if (req_valid && req_ready) begin

                active_q <= 1'b1;
                beat_q <= req_beat;

                src_reg_q[0] <= req_src0;
                src_reg_q[1] <= req_src1;
                src_reg_q[2] <= req_src2;

                pending_q[0] <= req_src0_enable;
                pending_q[1] <= req_src1_enable;
                pending_q[2] <= req_src2_enable;

                inflight_q <= '0;

                done_q[0] <= !req_src0_enable;
                done_q[1] <= !req_src1_enable;
                done_q[2] <= !req_src2_enable;

                src_data_q[0] <= '0;
                src_data_q[1] <= '0;
                src_data_q[2] <= '0;

            end
        end
    end

endmodule
