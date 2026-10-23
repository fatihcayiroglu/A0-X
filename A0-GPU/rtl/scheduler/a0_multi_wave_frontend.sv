`timescale 1ns/1ps

/*
 * A0-RTL7A multi-wave frontend/context-selection boundary.
 *
 * This wrapper connects resident architectural contexts to the reference
 * scheduler. It does not execute instructions. Instead, it establishes the
 * exact selected-context interface that RTL7B will connect to the existing
 * a0_wave_core execution machinery.
 */
module a0_multi_wave_frontend #(
    parameter integer RESIDENT_WAVES = 4,
    parameter integer PROGRAM_WORDS = 256,
    parameter integer WAVE_SIZE = 32,
    parameter integer SCALAR_REG_COUNT = 32,
    parameter integer PREDICATE_REG_COUNT = 16,
    parameter integer SCALAR_PREDICATE_REG_COUNT = 16,
    parameter integer RECONV_STACK_DEPTH = 16,
    parameter integer PRESSURE_COUNT_W = 8,

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
    parameter integer VRF_CONTEXT_ID_W = WAVE_ID_W,
    parameter integer WAVE_COUNT_W =
        (RESIDENT_WAVES <= 1)
            ? 1
            : $clog2(RESIDENT_WAVES + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic alloc_valid,
    input logic [WAVE_ID_W-1:0] alloc_wave_id,
    output logic alloc_ready,
    input logic [PC_W-1:0] alloc_pc,
    input logic [WAVE_SIZE-1:0] alloc_exec_mask,
    input logic [VRF_CONTEXT_ID_W-1:0] alloc_vrf_context_id,

    input logic release_valid,
    input logic [WAVE_ID_W-1:0] release_wave_id,

    input logic state_write_valid,
    input logic [WAVE_ID_W-1:0] state_write_wave_id,
    input logic [PC_W-1:0] state_write_pc,
    input logic [WAVE_SIZE-1:0] state_write_exec_mask,
    input logic [RECONV_SP_W-1:0] state_write_reconv_sp,
    input logic state_write_halted,
    input logic state_write_blocked,
    input logic state_write_memory_waiting,
    input logic state_write_barrier_waiting,

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

    input logic reconv_write_valid,
    input logic [WAVE_ID_W-1:0] reconv_write_wave_id,
    input logic [RECONV_INDEX_W-1:0] reconv_write_index,
    input logic [WAVE_SIZE-1:0] reconv_write_parent_mask,
    input logic [WAVE_SIZE-1:0] reconv_write_else_mask,
    input logic reconv_write_else_entered,

    /*
     * External execution/resource blockers are separate from architectural
     * context blockers so RTL7B/RTL8 can inject pipeline/resource readiness.
     */
    input logic [RESIDENT_WAVES-1:0] external_block_mask_i,

    input logic [RESIDENT_WAVES-1:0] memory_ready_mask_i,
    input logic [RESIDENT_WAVES-1:0] non_memory_ready_mask_i,
    input logic [RESIDENT_WAVES-1:0] memory_stalled_mask_i,
    input logic [RESIDENT_WAVES-1:0] merge_ready_mask_i,

    input logic [PRESSURE_COUNT_W-1:0] mshr_occupancy_i,
    input logic [PRESSURE_COUNT_W-1:0] mshr_capacity_i,

    input logic policy_override_valid_i,
    input logic [WAVE_ID_W-1:0] policy_override_wave_i,

    input logic grant_fire_i,

    input logic [SCALAR_REG_INDEX_W-1:0] selected_scalar_read_reg,
    input logic [SCALAR_REG_INDEX_W-1:0] selected_scalar_read_reg1,
    input logic [PREDICATE_INDEX_W-1:0] selected_predicate_read_reg,
    input logic [SCALAR_PREDICATE_INDEX_W-1:0]
        selected_scalar_predicate_read_reg,
    input logic [RECONV_INDEX_W-1:0] selected_reconv_read_index,

    input logic [WAVE_ID_W-1:0] debug_read_wave_id_i,
    input logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_read_reg_i,
    input logic [PREDICATE_INDEX_W-1:0] debug_predicate_read_reg_i,

    output logic debug_read_valid_o,
    output logic [PC_W-1:0] debug_read_pc_o,
    output logic [WAVE_SIZE-1:0] debug_read_exec_mask_o,
    output logic debug_read_halted_o,
    output logic [31:0] debug_scalar_read_data_o,
    output logic [WAVE_SIZE-1:0] debug_predicate_read_data_o,

    output logic grant_valid_o,
    output logic [WAVE_ID_W-1:0] grant_wave_o,
    output logic policy_override_accepted_o,

    output logic selected_context_valid_o,
    output logic [PC_W-1:0] selected_pc_o,
    output logic [WAVE_SIZE-1:0] selected_exec_mask_o,
    output logic [RECONV_SP_W-1:0] selected_reconv_sp_o,
    output logic selected_halted_o,
    output logic selected_blocked_o,
    output logic selected_memory_waiting_o,
    output logic selected_barrier_waiting_o,
    output logic [VRF_CONTEXT_ID_W-1:0]
        selected_vrf_context_id_o,

    output logic [31:0] selected_scalar_read_data_o,
    output logic [31:0] selected_scalar_read_data1_o,
    output logic [WAVE_SIZE-1:0] selected_predicate_read_data_o,
    output logic selected_scalar_predicate_read_data_o,

    output logic [WAVE_SIZE-1:0] selected_reconv_parent_mask_o,
    output logic [WAVE_SIZE-1:0] selected_reconv_else_mask_o,
    output logic selected_reconv_else_entered_o,

    output logic [RESIDENT_WAVES-1:0] valid_mask_o,
    output logic [PC_W-1:0] pc_by_wave_o [0:RESIDENT_WAVES-1],
    output logic [RESIDENT_WAVES-1:0] architectural_ready_mask_o,
    output logic [RESIDENT_WAVES-1:0] scheduler_ready_mask_o,
    output logic [RESIDENT_WAVES-1:0] halted_mask_o,
    output logic [RESIDENT_WAVES-1:0] blocked_mask_o,
    output logic [RESIDENT_WAVES-1:0] memory_waiting_mask_o,
    output logic [RESIDENT_WAVES-1:0] barrier_waiting_mask_o,

    output logic pressure_high_o,
    output logic [RESIDENT_WAVES-1:0] merge_ready_visible_o,
    output logic [WAVE_COUNT_W-1:0] ready_count_o,
    output logic [WAVE_COUNT_W-1:0] memory_ready_count_o,
    output logic [WAVE_COUNT_W-1:0] non_memory_ready_count_o,
    output logic [WAVE_COUNT_W-1:0] memory_stalled_count_o,
    output logic [WAVE_COUNT_W-1:0] merge_ready_count_o,
    output logic [WAVE_ID_W-1:0] rr_cursor_o
);

    logic selected_context_raw_valid;

    logic [RESIDENT_WAVES-1:0] memory_stalled_valid_mask;

    logic lrr_candidate_valid_unused;
    logic [WAVE_ID_W-1:0] lrr_candidate_wave_unused;


    assign scheduler_ready_mask_o =
        architectural_ready_mask_o
        & ~external_block_mask_i;

    assign selected_context_valid_o =
        grant_valid_o
        && selected_context_raw_valid;

    assign memory_stalled_valid_mask =
        memory_stalled_mask_i
        & valid_mask_o;


    a0_wave_context_file #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .WAVE_SIZE(WAVE_SIZE),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .SCALAR_PREDICATE_REG_COUNT(
            SCALAR_PREDICATE_REG_COUNT
        ),
        .RECONV_STACK_DEPTH(RECONV_STACK_DEPTH)
    ) context_file (
        .clk(clk),
        .rst_n(rst_n),

        .alloc_valid(alloc_valid),
        .alloc_wave_id(alloc_wave_id),
        .alloc_ready(alloc_ready),
        .alloc_pc(alloc_pc),
        .alloc_exec_mask(alloc_exec_mask),
        .alloc_vrf_context_id(alloc_vrf_context_id),

        .release_valid(release_valid),
        .release_wave_id(release_wave_id),

        .state_write_valid(state_write_valid),
        .state_write_wave_id(state_write_wave_id),
        .state_write_pc(state_write_pc),
        .state_write_exec_mask(state_write_exec_mask),
        .state_write_reconv_sp(state_write_reconv_sp),
        .state_write_halted(state_write_halted),
        .state_write_blocked(state_write_blocked),
        .state_write_memory_waiting(
            state_write_memory_waiting
        ),
        .state_write_barrier_waiting(
            state_write_barrier_waiting
        ),

        .scalar_write_valid(scalar_write_valid),
        .scalar_write_wave_id(scalar_write_wave_id),
        .scalar_write_reg(scalar_write_reg),
        .scalar_write_data(scalar_write_data),

        .predicate_write_valid(predicate_write_valid),
        .predicate_write_wave_id(predicate_write_wave_id),
        .predicate_write_reg(predicate_write_reg),
        .predicate_write_data(predicate_write_data),

        .scalar_predicate_write_valid(
            scalar_predicate_write_valid
        ),
        .scalar_predicate_write_wave_id(
            scalar_predicate_write_wave_id
        ),
        .scalar_predicate_write_reg(
            scalar_predicate_write_reg
        ),
        .scalar_predicate_write_data(
            scalar_predicate_write_data
        ),

        .reconv_write_valid(reconv_write_valid),
        .reconv_write_wave_id(reconv_write_wave_id),
        .reconv_write_index(reconv_write_index),
        .reconv_write_parent_mask(
            reconv_write_parent_mask
        ),
        .reconv_write_else_mask(reconv_write_else_mask),
        .reconv_write_else_entered(
            reconv_write_else_entered
        ),

        .read_wave_id(grant_wave_o),
        .scalar_read_reg(selected_scalar_read_reg),
        .scalar_read_reg1(selected_scalar_read_reg1),
        .predicate_read_reg(selected_predicate_read_reg),
        .scalar_predicate_read_reg(
            selected_scalar_predicate_read_reg
        ),
        .reconv_read_index(selected_reconv_read_index),

        .read_valid(selected_context_raw_valid),
        .read_pc(selected_pc_o),
        .read_exec_mask(selected_exec_mask_o),
        .read_reconv_sp(selected_reconv_sp_o),
        .read_halted(selected_halted_o),
        .read_blocked(selected_blocked_o),
        .read_memory_waiting(selected_memory_waiting_o),
        .read_barrier_waiting(selected_barrier_waiting_o),
        .read_vrf_context_id(selected_vrf_context_id_o),

        .scalar_read_data(selected_scalar_read_data_o),
        .scalar_read_data1(selected_scalar_read_data1_o),
        .predicate_read_data(
            selected_predicate_read_data_o
        ),
        .scalar_predicate_read_data(
            selected_scalar_predicate_read_data_o
        ),

        .reconv_read_parent_mask(
            selected_reconv_parent_mask_o
        ),
        .reconv_read_else_mask(
            selected_reconv_else_mask_o
        ),
        .reconv_read_else_entered(
            selected_reconv_else_entered_o
        ),

        .debug_read_wave_id(debug_read_wave_id_i),
        .debug_scalar_read_reg(debug_scalar_read_reg_i),
        .debug_predicate_read_reg(debug_predicate_read_reg_i),
        .debug_read_valid(debug_read_valid_o),
        .debug_read_pc(debug_read_pc_o),
        .debug_read_exec_mask(debug_read_exec_mask_o),
        .debug_read_halted(debug_read_halted_o),
        .debug_scalar_read_data(debug_scalar_read_data_o),
        .debug_predicate_read_data(debug_predicate_read_data_o),

        .valid_mask(valid_mask_o),
        .pc_by_wave(pc_by_wave_o),
        .ready_mask(architectural_ready_mask_o),
        .halted_mask(halted_mask_o),
        .blocked_mask(blocked_mask_o),
        .memory_waiting_mask(memory_waiting_mask_o),
        .barrier_waiting_mask(barrier_waiting_mask_o)
    );


    a0_wave_scheduler #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .PRESSURE_COUNT_W(PRESSURE_COUNT_W)
    ) scheduler (
        .clk(clk),
        .rst_n(rst_n),

        .ready_mask_i(scheduler_ready_mask_o),
        .memory_ready_mask_i(memory_ready_mask_i),
        .non_memory_ready_mask_i(non_memory_ready_mask_i),
        .memory_stalled_mask_i(
            memory_stalled_valid_mask
        ),
        .merge_ready_mask_i(merge_ready_mask_i),

        .mshr_occupancy_i(mshr_occupancy_i),
        .mshr_capacity_i(mshr_capacity_i),

        .policy_override_valid_i(policy_override_valid_i),
        .policy_override_wave_i(policy_override_wave_i),

        .grant_fire_i(grant_fire_i),

        .grant_valid_o(grant_valid_o),
        .grant_wave_o(grant_wave_o),

        .lrr_candidate_valid_o(
            lrr_candidate_valid_unused
        ),
        .lrr_candidate_wave_o(
            lrr_candidate_wave_unused
        ),
        .policy_override_accepted_o(
            policy_override_accepted_o
        ),

        .pressure_high_o(pressure_high_o),
        .merge_ready_visible_o(merge_ready_visible_o),

        .ready_count_o(ready_count_o),
        .memory_ready_count_o(memory_ready_count_o),
        .non_memory_ready_count_o(
            non_memory_ready_count_o
        ),
        .memory_stalled_count_o(
            memory_stalled_count_o
        ),
        .merge_ready_count_o(merge_ready_count_o),

        .rr_cursor_o(rr_cursor_o)
    );

endmodule
