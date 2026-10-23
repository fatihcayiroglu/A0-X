`timescale 1ns/1ps

/*
 * A0-RTL7A resident-wave architectural context storage.
 *
 * This module establishes the context boundary needed before a single-wave
 * execution engine can be shared by multiple resident waves.
 *
 * Control state is reset. Large architectural data arrays intentionally are
 * not reset, matching the SRAM-friendly policy already used by the banked
 * vector register file. A launch/restore path must initialize any scalar or
 * predicate data before it is consumed.
 *
 * The vector register file itself is not duplicated here. vrf_context_id is
 * an ownership/mapping token for the later RTL7B physical-VRF expansion:
 *
 *     physical vector namespace = {vrf_context_id, logical V register}
 *
 * RTL7A stores and restores that token but does not yet change
 * a0_regfile_banked addressing.
 */
module a0_wave_context_file #(
    parameter integer RESIDENT_WAVES = 4,
    parameter integer PROGRAM_WORDS = 256,
    parameter integer WAVE_SIZE = 32,
    parameter integer SCALAR_REG_COUNT = 32,
    parameter integer PREDICATE_REG_COUNT = 16,
    parameter integer SCALAR_PREDICATE_REG_COUNT = 16,
    parameter integer RECONV_STACK_DEPTH = 16,

    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer PC_W =
        (PROGRAM_WORDS <= 1) ? 1 : $clog2(PROGRAM_WORDS),
    parameter integer SCALAR_REG_INDEX_W =
        (SCALAR_REG_COUNT <= 1) ? 1 : $clog2(SCALAR_REG_COUNT),
    parameter integer PREDICATE_INDEX_W =
        (PREDICATE_REG_COUNT <= 1) ? 1 : $clog2(PREDICATE_REG_COUNT),
    parameter integer SCALAR_PREDICATE_INDEX_W =
        (SCALAR_PREDICATE_REG_COUNT <= 1)
            ? 1
            : $clog2(SCALAR_PREDICATE_REG_COUNT),
    parameter integer RECONV_SP_W =
        (RECONV_STACK_DEPTH <= 1)
            ? 1
            : $clog2(RECONV_STACK_DEPTH + 1),
    parameter integer RECONV_INDEX_W =
        (RECONV_STACK_DEPTH <= 1)
            ? 1
            : $clog2(RECONV_STACK_DEPTH),
    parameter integer VRF_CONTEXT_ID_W = WAVE_ID_W
) (
    input logic clk,
    input logic rst_n,

    /*
     * Explicit-slot allocation.
     *
     * alloc_ready is asserted only for an in-range free slot.
     * Allocation initializes control state but intentionally does not
     * bulk-clear scalar/predicate/reconvergence payload arrays.
     */
    input logic alloc_valid,
    input logic [WAVE_ID_W-1:0] alloc_wave_id,
    output logic alloc_ready,

    input logic [PC_W-1:0] alloc_pc,
    input logic [WAVE_SIZE-1:0] alloc_exec_mask,
    input logic [VRF_CONTEXT_ID_W-1:0] alloc_vrf_context_id,

    input logic release_valid,
    input logic [WAVE_ID_W-1:0] release_wave_id,

    /*
     * Whole control-state checkpoint update.
     *
     * A later RTL7B wave-core integration will drive this on architectural
     * retirement/context-yield boundaries.
     */
    input logic state_write_valid,
    input logic [WAVE_ID_W-1:0] state_write_wave_id,
    input logic [PC_W-1:0] state_write_pc,
    input logic [WAVE_SIZE-1:0] state_write_exec_mask,
    input logic [RECONV_SP_W-1:0] state_write_reconv_sp,
    input logic state_write_halted,
    input logic state_write_blocked,
    input logic state_write_memory_waiting,
    input logic state_write_barrier_waiting,

    /*
     * Scalar and predicate architectural state.
     * One write of each class may occur per cycle.
     */
    input logic scalar_write_valid,
    input logic [WAVE_ID_W-1:0] scalar_write_wave_id,
    input logic [SCALAR_REG_INDEX_W-1:0] scalar_write_reg,
    input logic [31:0] scalar_write_data,

    input logic predicate_write_valid,
    input logic [WAVE_ID_W-1:0] predicate_write_wave_id,
    input logic [PREDICATE_INDEX_W-1:0] predicate_write_reg,
    input logic [WAVE_SIZE-1:0] predicate_write_data,

    input logic scalar_predicate_write_valid,
    input logic [WAVE_ID_W-1:0] scalar_predicate_write_wave_id,
    input logic [SCALAR_PREDICATE_INDEX_W-1:0]
        scalar_predicate_write_reg,
    input logic scalar_predicate_write_data,

    /*
     * Structured-divergence stack entry write.
     * The stack pointer is part of state_write_*; entry payload is written
     * separately so save/restore can be sequenced without a huge wide port.
     */
    input logic reconv_write_valid,
    input logic [WAVE_ID_W-1:0] reconv_write_wave_id,
    input logic [RECONV_INDEX_W-1:0] reconv_write_index,
    input logic [WAVE_SIZE-1:0] reconv_write_parent_mask,
    input logic [WAVE_SIZE-1:0] reconv_write_else_mask,
    input logic reconv_write_else_entered,

    /*
     * One combinational context read/view port.
     */
    input logic [WAVE_ID_W-1:0] read_wave_id,
    input logic [SCALAR_REG_INDEX_W-1:0] scalar_read_reg,
    input logic [SCALAR_REG_INDEX_W-1:0] scalar_read_reg1,
    input logic [PREDICATE_INDEX_W-1:0] predicate_read_reg,
    input logic [SCALAR_PREDICATE_INDEX_W-1:0]
        scalar_predicate_read_reg,
    input logic [RECONV_INDEX_W-1:0] reconv_read_index,

    output logic read_valid,
    output logic [PC_W-1:0] read_pc,
    output logic [WAVE_SIZE-1:0] read_exec_mask,
    output logic [RECONV_SP_W-1:0] read_reconv_sp,
    output logic read_halted,
    output logic read_blocked,
    output logic read_memory_waiting,
    output logic read_barrier_waiting,
    output logic [VRF_CONTEXT_ID_W-1:0] read_vrf_context_id,

    output logic [31:0] scalar_read_data,
    output logic [31:0] scalar_read_data1,
    output logic [WAVE_SIZE-1:0] predicate_read_data,
    output logic scalar_predicate_read_data,

    output logic [WAVE_SIZE-1:0] reconv_read_parent_mask,
    output logic [WAVE_SIZE-1:0] reconv_read_else_mask,
    output logic reconv_read_else_entered,

    /* Independent architectural debug/readback view. */
    input logic [WAVE_ID_W-1:0] debug_read_wave_id,
    input logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_read_reg,
    input logic [PREDICATE_INDEX_W-1:0] debug_predicate_read_reg,

    output logic debug_read_valid,
    output logic [PC_W-1:0] debug_read_pc,
    output logic [WAVE_SIZE-1:0] debug_read_exec_mask,
    output logic debug_read_halted,
    output logic [31:0] debug_scalar_read_data,
    output logic [WAVE_SIZE-1:0] debug_predicate_read_data,

    /*
     * Scheduler-facing aggregate state.
     */
    output logic [RESIDENT_WAVES-1:0] valid_mask,
    output logic [PC_W-1:0] pc_by_wave [0:RESIDENT_WAVES-1],
    output logic [RESIDENT_WAVES-1:0] ready_mask,
    output logic [RESIDENT_WAVES-1:0] halted_mask,
    output logic [RESIDENT_WAVES-1:0] blocked_mask,
    output logic [RESIDENT_WAVES-1:0] memory_waiting_mask,
    output logic [RESIDENT_WAVES-1:0] barrier_waiting_mask
);

    logic valid_q [0:RESIDENT_WAVES-1];
    logic halted_q [0:RESIDENT_WAVES-1];
    logic blocked_q [0:RESIDENT_WAVES-1];
    logic memory_waiting_q [0:RESIDENT_WAVES-1];
    logic barrier_waiting_q [0:RESIDENT_WAVES-1];

    logic [PC_W-1:0] pc_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0] exec_mask_q [0:RESIDENT_WAVES-1];
    logic [RECONV_SP_W-1:0] reconv_sp_q [0:RESIDENT_WAVES-1];
    logic [VRF_CONTEXT_ID_W-1:0]
        vrf_context_id_q [0:RESIDENT_WAVES-1];

    logic [31:0] scalar_regs_q
        [0:RESIDENT_WAVES-1]
        [0:SCALAR_REG_COUNT-1];

    logic [WAVE_SIZE-1:0] predicate_regs_q
        [0:RESIDENT_WAVES-1]
        [0:PREDICATE_REG_COUNT-1];

    logic scalar_predicate_regs_q
        [0:RESIDENT_WAVES-1]
        [0:SCALAR_PREDICATE_REG_COUNT-1];

    logic [WAVE_SIZE-1:0] reconv_parent_mask_q
        [0:RESIDENT_WAVES-1]
        [0:RECONV_STACK_DEPTH-1];

    logic [WAVE_SIZE-1:0] reconv_else_mask_q
        [0:RESIDENT_WAVES-1]
        [0:RECONV_STACK_DEPTH-1];

    logic reconv_else_entered_q
        [0:RESIDENT_WAVES-1]
        [0:RECONV_STACK_DEPTH-1];

    integer aggregate_wave;


    function automatic logic wave_id_valid(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        wave_id_valid =
            integer'(wave_id) < RESIDENT_WAVES;
    endfunction


    function automatic logic context_valid(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        begin
            if (integer'(wave_id) < RESIDENT_WAVES) begin
                context_valid = valid_q[integer'(wave_id)];
            end else begin
                context_valid = 1'b0;
            end
        end
    endfunction


    function automatic logic wave_slot_free(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        begin
            if (integer'(wave_id) < RESIDENT_WAVES) begin
                wave_slot_free = !valid_q[integer'(wave_id)];
            end else begin
                wave_slot_free = 1'b0;
            end
        end
    endfunction


    function automatic logic scalar_reg_valid(
        input logic [SCALAR_REG_INDEX_W-1:0] reg_index
    );
        scalar_reg_valid =
            integer'(reg_index) < SCALAR_REG_COUNT;
    endfunction


    function automatic logic predicate_reg_valid(
        input logic [PREDICATE_INDEX_W-1:0] reg_index
    );
        predicate_reg_valid =
            integer'(reg_index) < PREDICATE_REG_COUNT;
    endfunction


    function automatic logic scalar_predicate_reg_valid(
        input logic [SCALAR_PREDICATE_INDEX_W-1:0] reg_index
    );
        scalar_predicate_reg_valid =
            integer'(reg_index) < SCALAR_PREDICATE_REG_COUNT;
    endfunction


    function automatic logic reconv_index_valid(
        input logic [RECONV_INDEX_W-1:0] stack_index
    );
        reconv_index_valid =
            integer'(stack_index) < RECONV_STACK_DEPTH;
    endfunction


    always_comb begin

        valid_mask = '0;
        ready_mask = '0;

        for (
            aggregate_wave = 0;
            aggregate_wave < RESIDENT_WAVES;
            aggregate_wave = aggregate_wave + 1
        ) begin
            pc_by_wave[aggregate_wave] = pc_q[aggregate_wave];
        end
        halted_mask = '0;
        blocked_mask = '0;
        memory_waiting_mask = '0;
        barrier_waiting_mask = '0;

        for (
            aggregate_wave = 0;
            aggregate_wave < RESIDENT_WAVES;
            aggregate_wave = aggregate_wave + 1
        ) begin

            valid_mask[aggregate_wave] =
                valid_q[aggregate_wave];

            halted_mask[aggregate_wave] =
                valid_q[aggregate_wave]
                && halted_q[aggregate_wave];

            blocked_mask[aggregate_wave] =
                valid_q[aggregate_wave]
                && blocked_q[aggregate_wave];

            memory_waiting_mask[aggregate_wave] =
                valid_q[aggregate_wave]
                && memory_waiting_q[aggregate_wave];

            barrier_waiting_mask[aggregate_wave] =
                valid_q[aggregate_wave]
                && barrier_waiting_q[aggregate_wave];

            ready_mask[aggregate_wave] =
                valid_q[aggregate_wave]
                && !halted_q[aggregate_wave]
                && !blocked_q[aggregate_wave]
                && !memory_waiting_q[aggregate_wave]
                && !barrier_waiting_q[aggregate_wave];

        end

        alloc_ready =
            wave_slot_free(alloc_wave_id);

    end


    /*
     * Control-view read path.
     *
     * Keep this block independent from scalar/predicate/reconvergence index
     * inputs. The selected instruction is decoded from read_pc and then uses
     * those decoded indices to read architectural data. Mixing both paths in
     * one always_comb makes tools conservatively see a false combinational
     * cycle: PC -> decode index -> context read block -> PC.
     */
    always_comb begin

        read_valid = 1'b0;
        read_pc = '0;
        read_exec_mask = '0;
        read_reconv_sp = '0;
        read_halted = 1'b0;
        read_blocked = 1'b0;
        read_memory_waiting = 1'b0;
        read_barrier_waiting = 1'b0;
        read_vrf_context_id = '0;

        if (context_valid(read_wave_id)) begin
            read_valid = 1'b1;
            read_pc = pc_q[read_wave_id];
            read_exec_mask = exec_mask_q[read_wave_id];
            read_reconv_sp = reconv_sp_q[read_wave_id];
            read_halted = halted_q[read_wave_id];
            read_blocked = blocked_q[read_wave_id];
            read_memory_waiting =
                memory_waiting_q[read_wave_id];
            read_barrier_waiting =
                barrier_waiting_q[read_wave_id];
            read_vrf_context_id =
                vrf_context_id_q[read_wave_id];
        end

    end


    /*
     * Indexed architectural-data view.
     *
     * This block may depend on decoded register/predicate indices, but it does
     * not drive the control-view signals that produced those indices.
     */
    always_comb begin

        scalar_read_data = '0;
        scalar_read_data1 = '0;
        predicate_read_data = '0;
        scalar_predicate_read_data = 1'b0;

        reconv_read_parent_mask = '0;
        reconv_read_else_mask = '0;
        reconv_read_else_entered = 1'b0;

        if (context_valid(read_wave_id)) begin

            if (scalar_reg_valid(scalar_read_reg)) begin
                scalar_read_data =
                    scalar_regs_q[
                        read_wave_id
                    ][scalar_read_reg];
            end

            if (scalar_reg_valid(scalar_read_reg1)) begin
                scalar_read_data1 =
                    scalar_regs_q[
                        read_wave_id
                    ][scalar_read_reg1];
            end

            if (predicate_reg_valid(predicate_read_reg)) begin
                predicate_read_data =
                    predicate_regs_q[
                        read_wave_id
                    ][predicate_read_reg];
            end

            if (
                scalar_predicate_reg_valid(
                    scalar_predicate_read_reg
                )
            ) begin
                scalar_predicate_read_data =
                    scalar_predicate_regs_q[
                        read_wave_id
                    ][scalar_predicate_read_reg];
            end

            if (reconv_index_valid(reconv_read_index)) begin
                reconv_read_parent_mask =
                    reconv_parent_mask_q[
                        read_wave_id
                    ][reconv_read_index];

                reconv_read_else_mask =
                    reconv_else_mask_q[
                        read_wave_id
                    ][reconv_read_index];

                reconv_read_else_entered =
                    reconv_else_entered_q[
                        read_wave_id
                    ][reconv_read_index];
            end

        end

    end

    always_comb begin
        debug_read_valid = 1'b0;
        debug_read_pc = '0;
        debug_read_exec_mask = '0;
        debug_read_halted = 1'b0;
        debug_scalar_read_data = '0;
        debug_predicate_read_data = '0;

        if (
            wave_id_valid(debug_read_wave_id)
            && valid_q[debug_read_wave_id]
        ) begin
            debug_read_valid = 1'b1;
            debug_read_pc = pc_q[debug_read_wave_id];
            debug_read_exec_mask = exec_mask_q[debug_read_wave_id];
            debug_read_halted = halted_q[debug_read_wave_id];

            if (scalar_reg_valid(debug_scalar_read_reg)) begin
                debug_scalar_read_data = scalar_regs_q[
                    debug_read_wave_id
                ][debug_scalar_read_reg];
            end

            if (predicate_reg_valid(debug_predicate_read_reg)) begin
                debug_predicate_read_data = predicate_regs_q[
                    debug_read_wave_id
                ][debug_predicate_read_reg];
            end
        end
    end


    /*
     * Control state uses nonblocking assignments.
     *
     * Large dynamically indexed payload arrays use one blocking write site
     * inside this clocked process. This mirrors the deliberate Verilator
     * 5.032 / SRAM-inference workaround already used by a0_regfile_banked.
     */
    always_ff @(posedge clk) begin

        if (!rst_n) begin

            for (
                integer reset_wave = 0;
                reset_wave < RESIDENT_WAVES;
                reset_wave = reset_wave + 1
            ) begin

                valid_q[reset_wave] <= 1'b0;
                halted_q[reset_wave] <= 1'b0;
                blocked_q[reset_wave] <= 1'b0;
                memory_waiting_q[reset_wave] <= 1'b0;
                barrier_waiting_q[reset_wave] <= 1'b0;

                pc_q[reset_wave] <= '0;
                exec_mask_q[reset_wave] <= '0;
                reconv_sp_q[reset_wave] <= '0;
                vrf_context_id_q[reset_wave] <= '0;

            end

        end else begin

            if (
                release_valid
                && wave_id_valid(release_wave_id)
            ) begin

                valid_q[release_wave_id] <= 1'b0;
                halted_q[release_wave_id] <= 1'b0;
                blocked_q[release_wave_id] <= 1'b0;
                memory_waiting_q[release_wave_id] <= 1'b0;
                barrier_waiting_q[release_wave_id] <= 1'b0;

                pc_q[release_wave_id] <= '0;
                exec_mask_q[release_wave_id] <= '0;
                reconv_sp_q[release_wave_id] <= '0;
                vrf_context_id_q[release_wave_id] <= '0;

            end

            if (
                alloc_valid
                && alloc_ready
            ) begin

                valid_q[alloc_wave_id] <= 1'b1;
                halted_q[alloc_wave_id] <= 1'b0;
                blocked_q[alloc_wave_id] <= 1'b0;
                memory_waiting_q[alloc_wave_id] <= 1'b0;
                barrier_waiting_q[alloc_wave_id] <= 1'b0;

                pc_q[alloc_wave_id] <= alloc_pc;
                exec_mask_q[alloc_wave_id] <= alloc_exec_mask;
                reconv_sp_q[alloc_wave_id] <= '0;
                vrf_context_id_q[alloc_wave_id]
                    <= alloc_vrf_context_id;

            end

            if (
                state_write_valid
                && context_valid(state_write_wave_id)
                && !(
                    release_valid
                    && release_wave_id == state_write_wave_id
                )
            ) begin

                pc_q[state_write_wave_id] <= state_write_pc;
                exec_mask_q[state_write_wave_id]
                    <= state_write_exec_mask;
                reconv_sp_q[state_write_wave_id]
                    <= state_write_reconv_sp;

                halted_q[state_write_wave_id]
                    <= state_write_halted;
                blocked_q[state_write_wave_id]
                    <= state_write_blocked;
                memory_waiting_q[state_write_wave_id]
                    <= state_write_memory_waiting;
                barrier_waiting_q[state_write_wave_id]
                    <= state_write_barrier_waiting;

            end

            if (
                scalar_write_valid
                && context_valid(scalar_write_wave_id)
                && scalar_reg_valid(scalar_write_reg)
            ) begin

                scalar_regs_q[
                    scalar_write_wave_id
                ][scalar_write_reg] <= scalar_write_data;

            end

            if (
                predicate_write_valid
                && context_valid(predicate_write_wave_id)
                && predicate_reg_valid(predicate_write_reg)
            ) begin

                predicate_regs_q[
                    predicate_write_wave_id
                ][predicate_write_reg] <= predicate_write_data;

            end

            if (
                scalar_predicate_write_valid
                && context_valid(
                    scalar_predicate_write_wave_id
                )
                && scalar_predicate_reg_valid(
                    scalar_predicate_write_reg
                )
            ) begin

                scalar_predicate_regs_q[
                    scalar_predicate_write_wave_id
                ][scalar_predicate_write_reg]
                    <= scalar_predicate_write_data;

            end

            if (
                reconv_write_valid
                && context_valid(reconv_write_wave_id)
                && reconv_index_valid(reconv_write_index)
            ) begin

                reconv_parent_mask_q[
                    reconv_write_wave_id
                ][reconv_write_index]
                    <= reconv_write_parent_mask;

                reconv_else_mask_q[
                    reconv_write_wave_id
                ][reconv_write_index]
                    <= reconv_write_else_mask;

                reconv_else_entered_q[
                    reconv_write_wave_id
                ][reconv_write_index]
                    <= reconv_write_else_entered;

            end

        end

    end

endmodule
