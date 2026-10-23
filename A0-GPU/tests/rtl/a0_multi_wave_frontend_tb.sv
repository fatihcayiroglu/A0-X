`timescale 1ns/1ps

module a0_multi_wave_frontend_tb;

    localparam integer RESIDENT_WAVES = 4;
    localparam integer PROGRAM_WORDS = 64;
    localparam integer WAVE_SIZE = 32;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;

    localparam integer WAVE_ID_W = 2;
    localparam integer PC_W = 6;
    localparam integer SCALAR_REG_INDEX_W = 3;
    localparam integer PREDICATE_INDEX_W = 2;
    localparam integer SCALAR_PREDICATE_INDEX_W = 2;
    localparam integer RECONV_SP_W = 3;
    localparam integer RECONV_INDEX_W = 2;
    localparam integer WAVE_COUNT_W = 3;

    logic clk;
    logic rst_n;

    logic alloc_valid;
    logic [WAVE_ID_W-1:0] alloc_wave_id;
    logic alloc_ready;
    logic [PC_W-1:0] alloc_pc;
    logic [WAVE_SIZE-1:0] alloc_exec_mask;
    logic [WAVE_ID_W-1:0] alloc_vrf_context_id;

    logic release_valid;
    logic [WAVE_ID_W-1:0] release_wave_id;

    logic state_write_valid;
    logic [WAVE_ID_W-1:0] state_write_wave_id;
    logic [PC_W-1:0] state_write_pc;
    logic [WAVE_SIZE-1:0] state_write_exec_mask;
    logic [RECONV_SP_W-1:0] state_write_reconv_sp;
    logic state_write_halted;
    logic state_write_blocked;
    logic state_write_memory_waiting;
    logic state_write_barrier_waiting;

    logic scalar_write_valid;
    logic [WAVE_ID_W-1:0] scalar_write_wave_id;
    logic [SCALAR_REG_INDEX_W-1:0] scalar_write_reg;
    logic [31:0] scalar_write_data;

    logic predicate_write_valid;
    logic [WAVE_ID_W-1:0] predicate_write_wave_id;
    logic [PREDICATE_INDEX_W-1:0] predicate_write_reg;
    logic [WAVE_SIZE-1:0] predicate_write_data;

    logic scalar_predicate_write_valid;
    logic [WAVE_ID_W-1:0] scalar_predicate_write_wave_id;
    logic [SCALAR_PREDICATE_INDEX_W-1:0]
        scalar_predicate_write_reg;
    logic scalar_predicate_write_data;

    logic reconv_write_valid;
    logic [WAVE_ID_W-1:0] reconv_write_wave_id;
    logic [RECONV_INDEX_W-1:0] reconv_write_index;
    logic [WAVE_SIZE-1:0] reconv_write_parent_mask;
    logic [WAVE_SIZE-1:0] reconv_write_else_mask;
    logic reconv_write_else_entered;

    logic [3:0] external_block_mask_i;
    logic [3:0] memory_ready_mask_i;
    logic [3:0] non_memory_ready_mask_i;
    logic [3:0] memory_stalled_mask_i;
    logic [3:0] merge_ready_mask_i;

    logic [7:0] mshr_occupancy_i;
    logic [7:0] mshr_capacity_i;

    logic policy_override_valid_i;
    logic [WAVE_ID_W-1:0] policy_override_wave_i;
    logic grant_fire_i;

    logic [SCALAR_REG_INDEX_W-1:0] selected_scalar_read_reg;
    logic [SCALAR_REG_INDEX_W-1:0] selected_scalar_read_reg1;
    logic [PREDICATE_INDEX_W-1:0] selected_predicate_read_reg;
    logic [SCALAR_PREDICATE_INDEX_W-1:0]
        selected_scalar_predicate_read_reg;
    logic [RECONV_INDEX_W-1:0] selected_reconv_read_index;

    logic [WAVE_ID_W-1:0] debug_read_wave_id_i;
    logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_read_reg_i;
    logic [PREDICATE_INDEX_W-1:0] debug_predicate_read_reg_i;
    logic debug_read_valid_o;
    logic [PC_W-1:0] debug_read_pc_o;
    logic [WAVE_SIZE-1:0] debug_read_exec_mask_o;
    logic debug_read_halted_o;
    logic [31:0] debug_scalar_read_data_o;
    logic [WAVE_SIZE-1:0] debug_predicate_read_data_o;

    logic grant_valid_o;
    logic [WAVE_ID_W-1:0] grant_wave_o;
    logic policy_override_accepted_o;

    logic selected_context_valid_o;
    logic [PC_W-1:0] selected_pc_o;
    logic [WAVE_SIZE-1:0] selected_exec_mask_o;
    logic [RECONV_SP_W-1:0] selected_reconv_sp_o;
    logic selected_halted_o;
    logic selected_blocked_o;
    logic selected_memory_waiting_o;
    logic selected_barrier_waiting_o;
    logic [WAVE_ID_W-1:0] selected_vrf_context_id_o;

    logic [31:0] selected_scalar_read_data_o;
    logic [31:0] selected_scalar_read_data1_o;
    logic [WAVE_SIZE-1:0] selected_predicate_read_data_o;
    logic selected_scalar_predicate_read_data_o;

    logic [WAVE_SIZE-1:0] selected_reconv_parent_mask_o;
    logic [WAVE_SIZE-1:0] selected_reconv_else_mask_o;
    logic selected_reconv_else_entered_o;

    logic [3:0] valid_mask_o;
    logic [PC_W-1:0] pc_by_wave_o [0:RESIDENT_WAVES-1];
    logic [3:0] architectural_ready_mask_o;
    logic [3:0] scheduler_ready_mask_o;
    logic [3:0] halted_mask_o;
    logic [3:0] blocked_mask_o;
    logic [3:0] memory_waiting_mask_o;
    logic [3:0] barrier_waiting_mask_o;

    logic pressure_high_o;
    logic [3:0] merge_ready_visible_o;

    logic [WAVE_COUNT_W-1:0] ready_count_o;
    logic [WAVE_COUNT_W-1:0] memory_ready_count_o;
    logic [WAVE_COUNT_W-1:0] non_memory_ready_count_o;
    logic [WAVE_COUNT_W-1:0] memory_stalled_count_o;
    logic [WAVE_COUNT_W-1:0] merge_ready_count_o;
    logic [WAVE_ID_W-1:0] rr_cursor_o;


    a0_multi_wave_frontend #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .WAVE_SIZE(WAVE_SIZE),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .SCALAR_PREDICATE_REG_COUNT(
            SCALAR_PREDICATE_REG_COUNT
        ),
        .RECONV_STACK_DEPTH(RECONV_STACK_DEPTH)
    ) dut (
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
        .state_write_memory_waiting(state_write_memory_waiting),
        .state_write_barrier_waiting(state_write_barrier_waiting),

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
        .reconv_write_parent_mask(reconv_write_parent_mask),
        .reconv_write_else_mask(reconv_write_else_mask),
        .reconv_write_else_entered(reconv_write_else_entered),

        .external_block_mask_i(external_block_mask_i),

        .memory_ready_mask_i(memory_ready_mask_i),
        .non_memory_ready_mask_i(non_memory_ready_mask_i),
        .memory_stalled_mask_i(memory_stalled_mask_i),
        .merge_ready_mask_i(merge_ready_mask_i),

        .mshr_occupancy_i(mshr_occupancy_i),
        .mshr_capacity_i(mshr_capacity_i),

        .policy_override_valid_i(policy_override_valid_i),
        .policy_override_wave_i(policy_override_wave_i),

        .grant_fire_i(grant_fire_i),

        .selected_scalar_read_reg(selected_scalar_read_reg),
        .selected_scalar_read_reg1(selected_scalar_read_reg1),
        .selected_predicate_read_reg(selected_predicate_read_reg),
        .selected_scalar_predicate_read_reg(
            selected_scalar_predicate_read_reg
        ),
        .selected_reconv_read_index(selected_reconv_read_index),

        .debug_read_wave_id_i(debug_read_wave_id_i),
        .debug_scalar_read_reg_i(debug_scalar_read_reg_i),
        .debug_predicate_read_reg_i(debug_predicate_read_reg_i),
        .debug_read_valid_o(debug_read_valid_o),
        .debug_read_pc_o(debug_read_pc_o),
        .debug_read_exec_mask_o(debug_read_exec_mask_o),
        .debug_read_halted_o(debug_read_halted_o),
        .debug_scalar_read_data_o(debug_scalar_read_data_o),
        .debug_predicate_read_data_o(debug_predicate_read_data_o),

        .grant_valid_o(grant_valid_o),
        .grant_wave_o(grant_wave_o),
        .policy_override_accepted_o(
            policy_override_accepted_o
        ),

        .selected_context_valid_o(selected_context_valid_o),
        .selected_pc_o(selected_pc_o),
        .selected_exec_mask_o(selected_exec_mask_o),
        .selected_reconv_sp_o(selected_reconv_sp_o),
        .selected_halted_o(selected_halted_o),
        .selected_blocked_o(selected_blocked_o),
        .selected_memory_waiting_o(
            selected_memory_waiting_o
        ),
        .selected_barrier_waiting_o(
            selected_barrier_waiting_o
        ),
        .selected_vrf_context_id_o(
            selected_vrf_context_id_o
        ),

        .selected_scalar_read_data_o(
            selected_scalar_read_data_o
        ),
        .selected_scalar_read_data1_o(
            selected_scalar_read_data1_o
        ),
        .selected_predicate_read_data_o(
            selected_predicate_read_data_o
        ),
        .selected_scalar_predicate_read_data_o(
            selected_scalar_predicate_read_data_o
        ),

        .selected_reconv_parent_mask_o(
            selected_reconv_parent_mask_o
        ),
        .selected_reconv_else_mask_o(
            selected_reconv_else_mask_o
        ),
        .selected_reconv_else_entered_o(
            selected_reconv_else_entered_o
        ),

        .valid_mask_o(valid_mask_o),
        .pc_by_wave_o(pc_by_wave_o),
        .architectural_ready_mask_o(
            architectural_ready_mask_o
        ),
        .scheduler_ready_mask_o(scheduler_ready_mask_o),
        .halted_mask_o(halted_mask_o),
        .blocked_mask_o(blocked_mask_o),
        .memory_waiting_mask_o(memory_waiting_mask_o),
        .barrier_waiting_mask_o(barrier_waiting_mask_o),

        .pressure_high_o(pressure_high_o),
        .merge_ready_visible_o(merge_ready_visible_o),
        .ready_count_o(ready_count_o),
        .memory_ready_count_o(memory_ready_count_o),
        .non_memory_ready_count_o(non_memory_ready_count_o),
        .memory_stalled_count_o(memory_stalled_count_o),
        .merge_ready_count_o(merge_ready_count_o),
        .rr_cursor_o(rr_cursor_o)
    );


    always #5 clk = ~clk;


    task automatic clear_writes;
        begin
            alloc_valid = 1'b0;
            release_valid = 1'b0;
            state_write_valid = 1'b0;
            scalar_write_valid = 1'b0;
            predicate_write_valid = 1'b0;
            scalar_predicate_write_valid = 1'b0;
            reconv_write_valid = 1'b0;
        end
    endtask


    task automatic allocate_wave(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [PC_W-1:0] initial_pc,
        input logic [31:0] initial_exec,
        input logic [WAVE_ID_W-1:0] vrf_id
    );
        begin
            @(negedge clk);
            clear_writes();
            alloc_valid = 1'b1;
            alloc_wave_id = wave_id;
            alloc_pc = initial_pc;
            alloc_exec_mask = initial_exec;
            alloc_vrf_context_id = vrf_id;
            #1;
            if (!alloc_ready) begin
                $fatal(1, "frontend allocation not ready wave=%0d", wave_id);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_writes();
        end
    endtask


    task automatic write_scalar(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            scalar_write_valid = 1'b1;
            scalar_write_wave_id = wave_id;
            scalar_write_reg = 3'd2;
            scalar_write_data = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            scalar_write_valid = 1'b0;
        end
    endtask




    task automatic write_wave0_aux_payload;
        begin
            @(negedge clk);
            predicate_write_valid = 1'b1;
            predicate_write_wave_id = 2'd0;
            predicate_write_reg = 2'd1;
            predicate_write_data = 32'hA5A5_5A5A;
            @(posedge clk);
            #1;
            @(negedge clk);
            predicate_write_valid = 1'b0;

            scalar_predicate_write_valid = 1'b1;
            scalar_predicate_write_wave_id = 2'd0;
            scalar_predicate_write_reg = 2'd1;
            scalar_predicate_write_data = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            scalar_predicate_write_valid = 1'b0;

            reconv_write_valid = 1'b1;
            reconv_write_wave_id = 2'd0;
            reconv_write_index = 2'd0;
            reconv_write_parent_mask = 32'hFFFF_0000;
            reconv_write_else_mask = 32'h0000_FFFF;
            reconv_write_else_entered = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            reconv_write_valid = 1'b0;
        end
    endtask


    task automatic set_memory_wait(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic waiting
    );
        begin
            @(negedge clk);
            state_write_valid = 1'b1;
            state_write_wave_id = wave_id;
            state_write_pc =
                (wave_id == 2'd0)
                    ? 6'd1
                    : (
                        (wave_id == 2'd1)
                            ? 6'd5
                            : 6'd9
                    );
            state_write_exec_mask = 32'hFFFF_FFFF;
            state_write_reconv_sp = '0;
            state_write_halted = 1'b0;
            state_write_blocked = 1'b0;
            state_write_memory_waiting = waiting;
            state_write_barrier_waiting = 1'b0;
            @(posedge clk);
            #1;
            @(negedge clk);
            state_write_valid = 1'b0;
        end
    endtask


    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        alloc_wave_id = '0;
        alloc_pc = '0;
        alloc_exec_mask = '0;
        alloc_vrf_context_id = '0;

        release_wave_id = '0;

        state_write_wave_id = '0;
        state_write_pc = '0;
        state_write_exec_mask = '0;
        state_write_reconv_sp = '0;
        state_write_halted = 1'b0;
        state_write_blocked = 1'b0;
        state_write_memory_waiting = 1'b0;
        state_write_barrier_waiting = 1'b0;

        scalar_write_wave_id = '0;
        scalar_write_reg = '0;
        scalar_write_data = '0;

        predicate_write_wave_id = '0;
        predicate_write_reg = '0;
        predicate_write_data = '0;

        scalar_predicate_write_wave_id = '0;
        scalar_predicate_write_reg = '0;
        scalar_predicate_write_data = 1'b0;

        reconv_write_wave_id = '0;
        reconv_write_index = '0;
        reconv_write_parent_mask = '0;
        reconv_write_else_mask = '0;
        reconv_write_else_entered = 1'b0;

        external_block_mask_i = '0;

        memory_ready_mask_i = 4'b0111;
        non_memory_ready_mask_i = 4'b0000;
        memory_stalled_mask_i = '0;
        merge_ready_mask_i = '0;

        mshr_occupancy_i = '0;
        mshr_capacity_i = 8'd4;

        policy_override_valid_i = 1'b0;
        policy_override_wave_i = '0;
        grant_fire_i = 1'b0;

        selected_scalar_read_reg = 3'd2;
        selected_scalar_read_reg1 = 3'd2;
        selected_predicate_read_reg = 2'd1;
        selected_scalar_predicate_read_reg = 2'd1;
        selected_reconv_read_index = 2'd0;

        debug_read_wave_id_i = 2'd0;
        debug_scalar_read_reg_i = 3'd2;
        debug_predicate_read_reg_i = 2'd1;

        clear_writes();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        allocate_wave(2'd0, 6'd1, 32'hFFFF_FFFF, 2'd0);
        allocate_wave(2'd1, 6'd5, 32'h0FFF_FFFF, 2'd1);
        allocate_wave(2'd2, 6'd9, 32'h00FF_FFFF, 2'd2);

        write_scalar(2'd0, 32'h0000_1111);
        write_scalar(2'd1, 32'h0000_2222);
        write_scalar(2'd2, 32'h0000_3333);
        write_wave0_aux_payload();

        #1;
        if (
            valid_mask_o != 4'b0111
            || architectural_ready_mask_o != 4'b0111
            || scheduler_ready_mask_o != 4'b0111
            || halted_mask_o != 4'b0000
            || blocked_mask_o != 4'b0000
            || memory_waiting_mask_o != 4'b0000
            || barrier_waiting_mask_o != 4'b0000
        ) begin
            $fatal(1, "frontend resident/ready masks mismatch");
        end

        if (
            !grant_valid_o
            || grant_wave_o != 2'd0
            || !selected_context_valid_o
            || selected_pc_o != 6'd1
            || selected_exec_mask_o != 32'hFFFF_FFFF
            || selected_reconv_sp_o != '0
            || selected_halted_o
            || selected_blocked_o
            || selected_memory_waiting_o
            || selected_barrier_waiting_o
            || selected_vrf_context_id_o != 2'd0
            || selected_scalar_read_data_o != 32'h0000_1111
            || selected_scalar_read_data1_o != 32'h0000_1111
            || selected_predicate_read_data_o != 32'hA5A5_5A5A
            || !selected_scalar_predicate_read_data_o
            || selected_reconv_parent_mask_o != 32'hFFFF_0000
            || selected_reconv_else_mask_o != 32'h0000_FFFF
            || !selected_reconv_else_entered_o
        ) begin
            $fatal(1, "selected context 0 restore mismatch");
        end

        if (
            !debug_read_valid_o
            || debug_read_pc_o != 6'd1
            || debug_read_exec_mask_o != 32'hFFFF_FFFF
            || debug_read_halted_o
            || debug_scalar_read_data_o != 32'h0000_1111
            || debug_predicate_read_data_o != 32'hA5A5_5A5A
        ) begin
            $fatal(1, "frontend debug readback mismatch for wave 0");
        end

        if (
            pc_by_wave_o[0] != 6'd1
            || pc_by_wave_o[1] != 6'd5
            || pc_by_wave_o[2] != 6'd9
        ) begin
            $fatal(1, "frontend per-wave PC vector mismatch");
        end

        $display("RTL7_FRONTEND_PC_VECTOR=PASS");
        $display("RTL7_FRONTEND_SELECTED_CONTEXT=PASS");

        /*
         * External execution blockage is scheduler-only; the architectural
         * context remains ready but selection moves to wave 1.
         */
        external_block_mask_i = 4'b0001;
        #1;

        if (
            architectural_ready_mask_o != 4'b0111
            || scheduler_ready_mask_o != 4'b0110
            || grant_wave_o != 2'd1
            || selected_pc_o != 6'd5
            || selected_vrf_context_id_o != 2'd1
            || selected_scalar_read_data_o != 32'h0000_2222
        ) begin
            $fatal(1, "external blocker did not select wave 1");
        end

        $display("RTL7_FRONTEND_EXTERNAL_BLOCK=PASS");

        /*
         * Architectural memory wait removes wave 1 as well; with wave 0
         * externally blocked, wave 2 must be selected.
         */
        set_memory_wait(2'd1, 1'b1);
        #1;

        if (
            architectural_ready_mask_o != 4'b0101
            || scheduler_ready_mask_o != 4'b0100
            || memory_waiting_mask_o != 4'b0010
            || blocked_mask_o != 4'b0000
            || halted_mask_o != 4'b0000
            || barrier_waiting_mask_o != 4'b0000
            || grant_wave_o != 2'd2
            || selected_pc_o != 6'd9
            || selected_vrf_context_id_o != 2'd2
            || selected_scalar_read_data_o != 32'h0000_3333
        ) begin
            $fatal(1, "memory-waiting context was not skipped");
        end

        $display("RTL7_FRONTEND_ARCH_BLOCK=PASS");

        /*
         * Policy override cannot escape scheduler readiness.
         */
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        #1;

        if (
            policy_override_accepted_o
            || grant_wave_o != 2'd2
        ) begin
            $fatal(1, "override selected externally blocked wave");
        end

        external_block_mask_i = '0;
        #1;

        if (
            !policy_override_accepted_o
            || grant_wave_o != 2'd0
            || selected_pc_o != 6'd1
        ) begin
            $fatal(1, "ready policy override not reflected in context view");
        end

        $display("RTL7_FRONTEND_POLICY_BOUNDARY=PASS");

        /*
         * Consuming the override advances reference cursor. Wave 1 remains
         * memory-waiting, so subsequent LRR selection from cursor=1 is wave 2.
         */
        grant_fire_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        grant_fire_i = 1'b0;
        policy_override_valid_i = 1'b0;
        #1;

        if (
            rr_cursor_o != 2'd1
            || grant_wave_o != 2'd2
        ) begin
            $fatal(1, "frontend scheduler/context handoff mismatch");
        end

        $display("RTL7_FRONTEND_GRANT_HANDOFF=PASS");

        /*
         * SIM17 policy metadata is visible at the same boundary but does not
         * alter LRR unless a policy override is explicitly supplied.
         */
        memory_ready_mask_i = 4'b0101;
        non_memory_ready_mask_i = 4'b0000;
        memory_stalled_mask_i = 4'b1010;
        merge_ready_mask_i = 4'b0100;
        mshr_occupancy_i = 8'd2;
        mshr_capacity_i = 8'd4;
        #1;

        if (
            !pressure_high_o
            || merge_ready_visible_o != 4'b0100
            || ready_count_o != 3'd2
            || memory_ready_count_o != 3'd2
            || non_memory_ready_count_o != 3'd0
            || memory_stalled_count_o != 3'd1
            || merge_ready_count_o != 3'd1
        ) begin
            $fatal(1, "frontend policy telemetry mismatch");
        end

        $display("RTL7_FRONTEND_POLICY_METADATA=PASS");

        /*
         * Release wave 2; scheduler must immediately stop selecting it.
         */
        @(negedge clk);
        release_valid = 1'b1;
        release_wave_id = 2'd2;
        @(posedge clk);
        #1;
        @(negedge clk);
        release_valid = 1'b0;
        #1;

        if (
            valid_mask_o != 4'b0011
            || scheduler_ready_mask_o != 4'b0001
            || grant_wave_o != 2'd0
        ) begin
            $fatal(1, "released wave remained scheduler-visible");
        end

        $display("RTL7_FRONTEND_RELEASE=PASS");
        $display("RTL7_MULTI_WAVE_FRONTEND_TB=PASS");

        $finish;
    end

endmodule
