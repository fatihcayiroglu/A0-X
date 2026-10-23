`timescale 1ns/1ps

/*
 * A0-RTL7B shared operand collector + context-qualified banked VRF.
 *
 * Only the resident-vector context is added to the RTL6B operand path.
 * Logical dependency metadata remains V0..V63 and is therefore unchanged.
 */
module a0_vector_operand_path_contexted #(
    parameter integer CONTEXT_COUNT = 4,
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer WAVE_SIZE = 32,
    parameter integer PHYSICAL_LANES = 8,
    parameter integer BANK_COUNT = 4,

    parameter integer CONTEXT_INDEX_W =
        (CONTEXT_COUNT <= 1) ? 1 : $clog2(CONTEXT_COUNT),
    parameter integer REG_INDEX_W =
        (VECTOR_REG_COUNT <= 1) ? 1 : $clog2(VECTOR_REG_COUNT),
    parameter integer BEAT_COUNT =
        (WAVE_SIZE + PHYSICAL_LANES - 1) / PHYSICAL_LANES,
    parameter integer BEAT_INDEX_W =
        (BEAT_COUNT <= 1) ? 1 : $clog2(BEAT_COUNT)
) (
    input logic clk,
    input logic rst_n,

    input logic req_valid,
    output logic req_ready,

    input logic [CONTEXT_INDEX_W-1:0] req_context,

    input logic req_src0_enable,
    input logic req_src1_enable,
    input logic req_src2_enable,

    input logic [REG_INDEX_W-1:0] req_src0,
    input logic [REG_INDEX_W-1:0] req_src1,
    input logic [REG_INDEX_W-1:0] req_src2,
    input logic [BEAT_INDEX_W-1:0] req_beat,

    output logic result_valid,
    input logic result_ready,

    output logic [PHYSICAL_LANES*32-1:0] result_src0_data,
    output logic [PHYSICAL_LANES*32-1:0] result_src1_data,
    output logic [PHYSICAL_LANES*32-1:0] result_src2_data,

    output logic busy,
    output logic bank_conflict_cycle,

    input logic write_valid,
    input logic [CONTEXT_INDEX_W-1:0] write_context,
    input logic [REG_INDEX_W-1:0] write_reg,
    input logic [BEAT_INDEX_W-1:0] write_beat,
    input logic [PHYSICAL_LANES-1:0] write_lane_mask,
    input logic [PHYSICAL_LANES*32-1:0] write_data,
    output logic write_ready
);

    logic [2:0] rf_read_valid;
    logic [REG_INDEX_W-1:0] rf_read_reg [0:2];
    logic [BEAT_INDEX_W-1:0] rf_read_beat [0:2];
    logic [CONTEXT_INDEX_W-1:0] rf_read_context [0:2];

    logic [2:0] rf_read_ready;
    logic [2:0] rf_read_bank_conflict;
    logic [2:0] rf_read_resp_valid;
    logic [PHYSICAL_LANES*32-1:0]
        rf_read_resp_data [0:2];

    logic [CONTEXT_INDEX_W-1:0] active_context_q;

    integer context_port;


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_context_q <= '0;
        end else if (req_valid && req_ready) begin
            active_context_q <= req_context;
        end
    end


    always_comb begin
        for (
            context_port = 0;
            context_port < 3;
            context_port = context_port + 1
        ) begin
            rf_read_context[context_port] = active_context_q;
        end
    end


    a0_operand_collector #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .REG_INDEX_W(REG_INDEX_W),
        .BEAT_COUNT(BEAT_COUNT),
        .BEAT_INDEX_W(BEAT_INDEX_W)
    ) operand_collector (
        .clk(clk),
        .rst_n(rst_n),

        .req_valid(req_valid),
        .req_ready(req_ready),

        .req_src0_enable(req_src0_enable),
        .req_src1_enable(req_src1_enable),
        .req_src2_enable(req_src2_enable),

        .req_src0(req_src0),
        .req_src1(req_src1),
        .req_src2(req_src2),
        .req_beat(req_beat),

        .result_valid(result_valid),
        .result_ready(result_ready),

        .result_src0_data(result_src0_data),
        .result_src1_data(result_src1_data),
        .result_src2_data(result_src2_data),

        .busy(busy),
        .bank_conflict_cycle(bank_conflict_cycle),

        .rf_read_valid(rf_read_valid),
        .rf_read_reg(rf_read_reg),
        .rf_read_beat(rf_read_beat),
        .rf_read_ready(rf_read_ready),
        .rf_read_bank_conflict(rf_read_bank_conflict),
        .rf_read_resp_valid(rf_read_resp_valid),
        .rf_read_resp_data(rf_read_resp_data)
    );


    a0_regfile_banked_contexted #(
        .CONTEXT_COUNT(CONTEXT_COUNT),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(BANK_COUNT),
        .READ_PORTS(3),
        .CONTEXT_INDEX_W(CONTEXT_INDEX_W),
        .REG_INDEX_W(REG_INDEX_W),
        .BEAT_COUNT(BEAT_COUNT),
        .BEAT_INDEX_W(BEAT_INDEX_W)
    ) vector_register_file (
        .clk(clk),
        .rst_n(rst_n),

        .read_valid(rf_read_valid),
        .read_context(rf_read_context),
        .read_reg(rf_read_reg),
        .read_beat(rf_read_beat),
        .read_ready(rf_read_ready),
        .read_bank_conflict(rf_read_bank_conflict),
        .read_resp_valid(rf_read_resp_valid),
        .read_resp_data(rf_read_resp_data),

        .write_valid(write_valid),
        .write_context(write_context),
        .write_reg(write_reg),
        .write_beat(write_beat),
        .write_lane_mask(write_lane_mask),
        .write_data(write_data),
        .write_ready(write_ready)
    );

endmodule
