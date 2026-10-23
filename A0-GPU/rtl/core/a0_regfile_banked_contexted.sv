`timescale 1ns/1ps

/*
 * A0-RTL7B context-qualified banked vector register file.
 *
 * Logical architectural register addresses are extended with a resident
 * vector-context id before bank/row selection:
 *
 *     physical_index = context * VECTOR_REG_COUNT + logical_register
 *
 * The physical banking contract is therefore shared across resident waves
 * without duplicating one complete operand path per context.
 */
module a0_regfile_banked_contexted #(
    parameter integer CONTEXT_COUNT = 4,
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer WAVE_SIZE = 32,
    parameter integer PHYSICAL_LANES = 8,
    parameter integer BANK_COUNT = 4,
    parameter integer READ_PORTS = 3,

    parameter integer CONTEXT_INDEX_W =
        (CONTEXT_COUNT <= 1) ? 1 : $clog2(CONTEXT_COUNT),
    parameter integer REG_INDEX_W =
        (VECTOR_REG_COUNT <= 1) ? 1 : $clog2(VECTOR_REG_COUNT),
    parameter integer BEAT_COUNT =
        (WAVE_SIZE + PHYSICAL_LANES - 1) / PHYSICAL_LANES,
    parameter integer BEAT_INDEX_W =
        (BEAT_COUNT <= 1) ? 1 : $clog2(BEAT_COUNT),
    parameter integer PHYSICAL_REG_COUNT =
        CONTEXT_COUNT * VECTOR_REG_COUNT
) (
    input logic clk,
    input logic rst_n,

    input logic [READ_PORTS-1:0] read_valid,
    input logic [CONTEXT_INDEX_W-1:0]
        read_context [0:READ_PORTS-1],
    input logic [REG_INDEX_W-1:0]
        read_reg [0:READ_PORTS-1],
    input logic [BEAT_INDEX_W-1:0]
        read_beat [0:READ_PORTS-1],

    output logic [READ_PORTS-1:0] read_ready,
    output logic [READ_PORTS-1:0] read_bank_conflict,

    output logic [READ_PORTS-1:0] read_resp_valid,
    output logic [PHYSICAL_LANES*32-1:0]
        read_resp_data [0:READ_PORTS-1],

    input logic write_valid,
    input logic [CONTEXT_INDEX_W-1:0] write_context,
    input logic [REG_INDEX_W-1:0] write_reg,
    input logic [BEAT_INDEX_W-1:0] write_beat,
    input logic [PHYSICAL_LANES-1:0] write_lane_mask,
    input logic [PHYSICAL_LANES*32-1:0] write_data,

    output logic write_ready
);

    localparam integer ROWS_PER_BANK =
        (PHYSICAL_REG_COUNT + BANK_COUNT - 1) / BANK_COUNT;

    localparam integer BEAT_DATA_W = PHYSICAL_LANES * 32;

    logic [BEAT_DATA_W-1:0] bank_mem
        [0:BANK_COUNT-1]
        [0:ROWS_PER_BANK-1]
        [0:BEAT_COUNT-1];

    integer comb_read_port;
    integer comb_earlier_port;


    function automatic integer physical_index(
        input logic [CONTEXT_INDEX_W-1:0] context_index,
        input logic [REG_INDEX_W-1:0] register_index
    );
        physical_index =
            integer'(context_index) * VECTOR_REG_COUNT
            + integer'(register_index);
    endfunction


    function automatic integer bank_of(
        input logic [CONTEXT_INDEX_W-1:0] context_index,
        input logic [REG_INDEX_W-1:0] register_index
    );
        bank_of =
            physical_index(context_index, register_index)
            % BANK_COUNT;
    endfunction


    function automatic integer row_of(
        input logic [CONTEXT_INDEX_W-1:0] context_index,
        input logic [REG_INDEX_W-1:0] register_index
    );
        row_of =
            physical_index(context_index, register_index)
            / BANK_COUNT;
    endfunction


    function automatic logic address_valid(
        input logic [CONTEXT_INDEX_W-1:0] context_index,
        input logic [REG_INDEX_W-1:0] register_index,
        input logic [BEAT_INDEX_W-1:0] beat_index
    );
        address_valid = (
            integer'(context_index) < CONTEXT_COUNT
            && integer'(register_index) < VECTOR_REG_COUNT
            && integer'(beat_index) < BEAT_COUNT
        );
    endfunction


    function automatic logic [BEAT_DATA_W-1:0] merge_lanes(
        input logic [BEAT_DATA_W-1:0] old_data,
        input logic [BEAT_DATA_W-1:0] new_data,
        input logic [PHYSICAL_LANES-1:0] lane_mask
    );
        logic [BEAT_DATA_W-1:0] merged;
        integer lane_index;
        begin
            merged = old_data;

            for (
                lane_index = 0;
                lane_index < PHYSICAL_LANES;
                lane_index = lane_index + 1
            ) begin
                if (lane_mask[lane_index]) begin
                    merged[lane_index*32 +: 32] =
                        new_data[lane_index*32 +: 32];
                end
            end

            merge_lanes = merged;
        end
    endfunction


    always_comb begin

        read_ready = '0;
        read_bank_conflict = '0;

        for (
            comb_read_port = 0;
            comb_read_port < READ_PORTS;
            comb_read_port = comb_read_port + 1
        ) begin

            if (
                read_valid[comb_read_port]
                && address_valid(
                    read_context[comb_read_port],
                    read_reg[comb_read_port],
                    read_beat[comb_read_port]
                )
            ) begin

                read_ready[comb_read_port] = 1'b1;

                for (
                    comb_earlier_port = 0;
                    comb_earlier_port < comb_read_port;
                    comb_earlier_port = comb_earlier_port + 1
                ) begin

                    if (
                        read_ready[comb_earlier_port]
                        && bank_of(
                            read_context[comb_earlier_port],
                            read_reg[comb_earlier_port]
                        )
                            == bank_of(
                                read_context[comb_read_port],
                                read_reg[comb_read_port]
                            )
                    ) begin
                        read_ready[comb_read_port] = 1'b0;
                        read_bank_conflict[comb_read_port] = 1'b1;
                    end
                end
            end
        end

        write_ready = address_valid(
            write_context,
            write_reg,
            write_beat
        );
    end


    always_ff @(posedge clk) begin

        if (!rst_n) begin

            for (
                integer seq_read_port = 0;
                seq_read_port < READ_PORTS;
                seq_read_port = seq_read_port + 1
            ) begin
                read_resp_valid[seq_read_port] <= 1'b0;
                read_resp_data[seq_read_port] <= '0;
            end

        end else begin

            for (
                integer seq_read_port = 0;
                seq_read_port < READ_PORTS;
                seq_read_port = seq_read_port + 1
            ) begin

                read_resp_valid[seq_read_port] <=
                    read_valid[seq_read_port]
                    && read_ready[seq_read_port];

                if (
                    read_valid[seq_read_port]
                    && read_ready[seq_read_port]
                ) begin

                    if (
                        write_valid
                        && write_ready
                        && write_context
                            == read_context[seq_read_port]
                        && write_reg
                            == read_reg[seq_read_port]
                        && write_beat
                            == read_beat[seq_read_port]
                    ) begin

                        read_resp_data[seq_read_port] <= merge_lanes(
                            bank_mem[
                                bank_of(
                                    read_context[seq_read_port],
                                    read_reg[seq_read_port]
                                )
                            ][
                                row_of(
                                    read_context[seq_read_port],
                                    read_reg[seq_read_port]
                                )
                            ][
                                integer'(read_beat[seq_read_port])
                            ],
                            write_data,
                            write_lane_mask
                        );

                    end else begin

                        read_resp_data[seq_read_port] <= bank_mem[
                            bank_of(
                                read_context[seq_read_port],
                                read_reg[seq_read_port]
                            )
                        ][
                            row_of(
                                read_context[seq_read_port],
                                read_reg[seq_read_port]
                            )
                        ][
                            integer'(read_beat[seq_read_port])
                        ];
                    end
                end
            end

            if (write_valid && write_ready) begin

                bank_mem[
                    bank_of(write_context, write_reg)
                ][
                    row_of(write_context, write_reg)
                ][
                    integer'(write_beat)
                ] <= merge_lanes(
                    bank_mem[
                        bank_of(write_context, write_reg)
                    ][
                        row_of(write_context, write_reg)
                    ][
                        integer'(write_beat)
                    ],
                    write_data,
                    write_lane_mask
                );
            end
        end
    end


    initial begin
        if (CONTEXT_COUNT <= 0) begin
            $fatal(1, "CONTEXT_COUNT must be positive");
        end
        if (VECTOR_REG_COUNT <= 0) begin
            $fatal(1, "VECTOR_REG_COUNT must be positive");
        end
        if (WAVE_SIZE <= 0) begin
            $fatal(1, "WAVE_SIZE must be positive");
        end
        if (PHYSICAL_LANES <= 0) begin
            $fatal(1, "PHYSICAL_LANES must be positive");
        end
        if (BANK_COUNT <= 0) begin
            $fatal(1, "BANK_COUNT must be positive");
        end
        if (READ_PORTS <= 0) begin
            $fatal(1, "READ_PORTS must be positive");
        end
    end

endmodule
