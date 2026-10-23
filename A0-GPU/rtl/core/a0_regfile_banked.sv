`timescale 1ns/1ps

module a0_regfile_banked #(
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer WAVE_SIZE = 32,
    parameter integer PHYSICAL_LANES = 8,
    parameter integer BANK_COUNT = 4,
    parameter integer READ_PORTS = 3,
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
     * Logical read ports.
     *
     * Requests targeting different banks may be accepted together.
     * Requests targeting the same bank are accepted in port-number
     * priority order. A denied request remains the caller's
     * responsibility and must be retried while read_valid stays high.
     *
     * Accepted reads return exactly one cycle later on the matching
     * response port.
     */
    input logic [READ_PORTS-1:0] read_valid,
    input logic [REG_INDEX_W-1:0] read_reg [0:READ_PORTS-1],
    input logic [BEAT_INDEX_W-1:0] read_beat [0:READ_PORTS-1],

    output logic [READ_PORTS-1:0] read_ready,
    output logic [READ_PORTS-1:0] read_bank_conflict,

    output logic [READ_PORTS-1:0] read_resp_valid,
    output logic [PHYSICAL_LANES*32-1:0]
        read_resp_data [0:READ_PORTS-1],

    /*
     * One vector-beat writeback port.
     *
     * A bank is 1R1W, so a read and a write may target the same bank
     * in the same cycle. If they target the exact same register/beat,
     * the read response observes the newly written lanes and the old
     * value on unmasked lanes (write-through / merged bypass).
     */
    input logic write_valid,
    input logic [REG_INDEX_W-1:0] write_reg,
    input logic [BEAT_INDEX_W-1:0] write_beat,
    input logic [PHYSICAL_LANES-1:0] write_lane_mask,
    input logic [PHYSICAL_LANES*32-1:0] write_data,

    output logic write_ready
);

    localparam integer ROWS_PER_BANK =
        (VECTOR_REG_COUNT + BANK_COUNT - 1) / BANK_COUNT;

    localparam integer BEAT_DATA_W = PHYSICAL_LANES * 32;


    /*
     * Physical organization:
     *
     *   bank = architectural_register % BANK_COUNT
     *   row  = architectural_register / BANK_COUNT
     *
     * Each row/beat stores PHYSICAL_LANES 32-bit lane values.
     * Register data intentionally has no reset. Real SRAM macros do
     * not provide a cheap array reset; architectural initialization is
     * performed through the write port before use.
     */
    logic [BEAT_DATA_W-1:0] bank_mem
        [0:BANK_COUNT-1]
        [0:ROWS_PER_BANK-1]
        [0:BEAT_COUNT-1];


    integer comb_read_port;
    integer comb_earlier_port;
    integer seq_read_port;


    function automatic integer bank_of(
        input logic [REG_INDEX_W-1:0] register_index
    );
        bank_of = integer'(register_index) % BANK_COUNT;
    endfunction


    function automatic integer row_of(
        input logic [REG_INDEX_W-1:0] register_index
    );
        row_of = integer'(register_index) / BANK_COUNT;
    endfunction


    function automatic logic address_valid(
        input logic [REG_INDEX_W-1:0] register_index,
        input logic [BEAT_INDEX_W-1:0] beat_index
    );
        address_valid = (
            integer'(register_index) < VECTOR_REG_COUNT
            && integer'(beat_index) < BEAT_COUNT
        );
    endfunction


    /*
     * Merge a lane-masked write into one complete beat word.
     *
     * Keeping the physical memory update as one whole-word assignment
     * is deliberate. It avoids multiple nonblocking writes to slices
     * of the same unpacked-memory element, which is both harder for
     * synthesis tools to recognize as a single SRAM write and triggers
     * a V3Delayed elaboration failure in Verilator 5.032.
     */
    function automatic logic [BEAT_DATA_W-1:0] merge_lanes(
        input logic [BEAT_DATA_W-1:0] old_value,
        input logic [BEAT_DATA_W-1:0] new_value,
        input logic [PHYSICAL_LANES-1:0] lane_mask
    );
        integer lane_index;
        begin
            merge_lanes = old_value;
            for (
                lane_index = 0;
                lane_index < PHYSICAL_LANES;
                lane_index = lane_index + 1
            ) begin
                if (lane_mask[lane_index]) begin
                    merge_lanes[lane_index*32 +: 32] =
                        new_value[lane_index*32 +: 32];
                end
            end
        end
    endfunction


    /*
     * Read-bank arbitration.
     *
     * Port priority is deterministic and bounded for the intended
     * operand-collector client: once a source is granted the collector
     * removes it from the request set, so another conflicting source
     * advances on the following cycle.
     */
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
                        && bank_of(read_reg[comb_earlier_port])
                            == bank_of(read_reg[comb_read_port])
                    ) begin

                        read_ready[comb_read_port] = 1'b0;
                        read_bank_conflict[comb_read_port] = 1'b1;

                    end
                end
            end
        end

        write_ready = address_valid(write_reg, write_beat);
    end


    /*
     * One-cycle synchronous read response and masked writeback.
     *
     * Each logical response port has exactly one sequential assignment
     * site. The physical memory also has exactly one whole-word write
     * site. This makes the 1R1W contract explicit to tools and keeps
     * bypass semantics deterministic.
     *
     * The physical unpacked-memory write intentionally uses a blocking
     * assignment in this clocked process. Verilator 5.032 routes a
     * variable-index nonblocking write to an unpacked memory through
     * V3Delayed and raises an internal multiple-write error. Procedural
     * ordering is safe here: response data is computed first and exact
     * same-address read/write behavior is explicitly defined by the
     * merged bypass above.
     */
    always_ff @(posedge clk) begin

        if (!rst_n) begin

            for (
                seq_read_port = 0;
                seq_read_port < READ_PORTS;
                seq_read_port = seq_read_port + 1
            ) begin
                read_resp_valid[seq_read_port] <= 1'b0;
                read_resp_data[seq_read_port] <= '0;
            end

        end else begin

            for (
                seq_read_port = 0;
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
                        && write_reg == read_reg[seq_read_port]
                        && write_beat == read_beat[seq_read_port]
                    ) begin

                        read_resp_data[seq_read_port] <= merge_lanes(
                            bank_mem[
                                bank_of(read_reg[seq_read_port])
                            ][
                                row_of(read_reg[seq_read_port])
                            ][
                                integer'(read_beat[seq_read_port])
                            ],
                            write_data,
                            write_lane_mask
                        );

                    end else begin

                        read_resp_data[seq_read_port] <= bank_mem[
                            bank_of(read_reg[seq_read_port])
                        ][
                            row_of(read_reg[seq_read_port])
                        ][
                            integer'(read_beat[seq_read_port])
                        ];

                    end
                end
            end

            if (write_valid && write_ready) begin

                bank_mem[
                    bank_of(write_reg)
                ][
                    row_of(write_reg)
                ][
                    integer'(write_beat)
                ] <= merge_lanes(
                    bank_mem[
                        bank_of(write_reg)
                    ][
                        row_of(write_reg)
                    ][
                        integer'(write_beat)
                    ],
                    write_data,
                    write_lane_mask
                );

            end
        end
    end


    /*
     * Parameter checks are simulation/elaboration guards only.
     */
    initial begin
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
