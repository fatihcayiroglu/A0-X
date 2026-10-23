`timescale 1ns/1ps

module a0_wave_context_file_tb;

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

    logic [WAVE_ID_W-1:0] read_wave_id;
    logic [SCALAR_REG_INDEX_W-1:0] scalar_read_reg;
    logic [SCALAR_REG_INDEX_W-1:0] scalar_read_reg1;
    logic [PREDICATE_INDEX_W-1:0] predicate_read_reg;
    logic [SCALAR_PREDICATE_INDEX_W-1:0]
        scalar_predicate_read_reg;
    logic [RECONV_INDEX_W-1:0] reconv_read_index;

    logic read_valid;
    logic [PC_W-1:0] read_pc;
    logic [WAVE_SIZE-1:0] read_exec_mask;
    logic [RECONV_SP_W-1:0] read_reconv_sp;
    logic read_halted;
    logic read_blocked;
    logic read_memory_waiting;
    logic read_barrier_waiting;
    logic [WAVE_ID_W-1:0] read_vrf_context_id;

    logic [31:0] scalar_read_data;
    logic [31:0] scalar_read_data1;
    logic [WAVE_SIZE-1:0] predicate_read_data;
    logic scalar_predicate_read_data;

    logic [WAVE_SIZE-1:0] reconv_read_parent_mask;
    logic [WAVE_SIZE-1:0] reconv_read_else_mask;
    logic reconv_read_else_entered;

    logic [WAVE_ID_W-1:0] debug_read_wave_id;
    logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_read_reg;
    logic [PREDICATE_INDEX_W-1:0] debug_predicate_read_reg;
    logic debug_read_valid;
    logic [PC_W-1:0] debug_read_pc;
    logic [WAVE_SIZE-1:0] debug_read_exec_mask;
    logic debug_read_halted;
    logic [31:0] debug_scalar_read_data;
    logic [WAVE_SIZE-1:0] debug_predicate_read_data;

    logic [RESIDENT_WAVES-1:0] valid_mask;
    logic [PC_W-1:0] pc_by_wave [0:RESIDENT_WAVES-1];
    logic [RESIDENT_WAVES-1:0] ready_mask;
    logic [RESIDENT_WAVES-1:0] halted_mask;
    logic [RESIDENT_WAVES-1:0] blocked_mask;
    logic [RESIDENT_WAVES-1:0] memory_waiting_mask;
    logic [RESIDENT_WAVES-1:0] barrier_waiting_mask;


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

        .read_wave_id(read_wave_id),
        .scalar_read_reg(scalar_read_reg),
        .scalar_read_reg1(scalar_read_reg1),
        .predicate_read_reg(predicate_read_reg),
        .scalar_predicate_read_reg(scalar_predicate_read_reg),
        .reconv_read_index(reconv_read_index),

        .read_valid(read_valid),
        .read_pc(read_pc),
        .read_exec_mask(read_exec_mask),
        .read_reconv_sp(read_reconv_sp),
        .read_halted(read_halted),
        .read_blocked(read_blocked),
        .read_memory_waiting(read_memory_waiting),
        .read_barrier_waiting(read_barrier_waiting),
        .read_vrf_context_id(read_vrf_context_id),

        .scalar_read_data(scalar_read_data),
        .scalar_read_data1(scalar_read_data1),
        .predicate_read_data(predicate_read_data),
        .scalar_predicate_read_data(scalar_predicate_read_data),

        .reconv_read_parent_mask(reconv_read_parent_mask),
        .reconv_read_else_mask(reconv_read_else_mask),
        .reconv_read_else_entered(reconv_read_else_entered),

        .debug_read_wave_id(debug_read_wave_id),
        .debug_scalar_read_reg(debug_scalar_read_reg),
        .debug_predicate_read_reg(debug_predicate_read_reg),
        .debug_read_valid(debug_read_valid),
        .debug_read_pc(debug_read_pc),
        .debug_read_exec_mask(debug_read_exec_mask),
        .debug_read_halted(debug_read_halted),
        .debug_scalar_read_data(debug_scalar_read_data),
        .debug_predicate_read_data(debug_predicate_read_data),

        .valid_mask(valid_mask),
        .pc_by_wave(pc_by_wave),
        .ready_mask(ready_mask),
        .halted_mask(halted_mask),
        .blocked_mask(blocked_mask),
        .memory_waiting_mask(memory_waiting_mask),
        .barrier_waiting_mask(barrier_waiting_mask)
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
        input logic [WAVE_SIZE-1:0] initial_exec,
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
                $fatal(1, "allocation unexpectedly not ready wave=%0d", wave_id);
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            clear_writes();
        end
    endtask


    task automatic write_state(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [PC_W-1:0] new_pc,
        input logic [WAVE_SIZE-1:0] new_exec,
        input logic [RECONV_SP_W-1:0] new_sp,
        input logic halted_value,
        input logic blocked_value,
        input logic memory_value,
        input logic barrier_value
    );
        begin
            @(negedge clk);
            clear_writes();
            state_write_valid = 1'b1;
            state_write_wave_id = wave_id;
            state_write_pc = new_pc;
            state_write_exec_mask = new_exec;
            state_write_reconv_sp = new_sp;
            state_write_halted = halted_value;
            state_write_blocked = blocked_value;
            state_write_memory_waiting = memory_value;
            state_write_barrier_waiting = barrier_value;

            @(posedge clk);
            #1;
            @(negedge clk);
            clear_writes();
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

        read_wave_id = '0;
        scalar_read_reg = '0;
        scalar_read_reg1 = '0;
        predicate_read_reg = '0;
        scalar_predicate_read_reg = '0;
        reconv_read_index = '0;

        debug_read_wave_id = '0;
        debug_scalar_read_reg = '0;
        debug_predicate_read_reg = '0;

        clear_writes();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (
            valid_mask != 4'b0000
            || ready_mask != 4'b0000
        ) begin
            $fatal(1, "reset aggregate masks are not empty");
        end

        $display("RTL7_CTX_RESET_CONTROL=PASS");

        allocate_wave(
            2'd0,
            6'd3,
            32'hFFFF_00FF,
            2'd2
        );

        allocate_wave(
            2'd1,
            6'd11,
            32'h0F0F_F0F0,
            2'd1
        );

        #1;
        if (
            valid_mask != 4'b0011
            || ready_mask != 4'b0011
        ) begin
            $fatal(1, "allocated waves not visible/ready");
        end

        alloc_wave_id = 2'd1;
        #1;
        if (alloc_ready) begin
            $fatal(1, "occupied slot incorrectly reports alloc_ready");
        end

        if (
            pc_by_wave[0] != 6'd3
            || pc_by_wave[1] != 6'd11
        ) begin
            $fatal(1, "per-wave PC view mismatch after allocation");
        end

        $display("RTL7_CTX_PC_VECTOR=PASS");
        $display("RTL7_CTX_ALLOCATE=PASS");

        /*
         * Distinct architectural payloads in two resident waves.
         */
        @(negedge clk);
        scalar_write_valid = 1'b1;
        scalar_write_wave_id = 2'd0;
        scalar_write_reg = 3'd3;
        scalar_write_data = 32'h1111_AAAA;
        @(posedge clk);
        #1;
        @(negedge clk);
        scalar_write_valid = 1'b0;

        @(negedge clk);
        scalar_write_valid = 1'b1;
        scalar_write_wave_id = 2'd1;
        scalar_write_reg = 3'd3;
        scalar_write_data = 32'h2222_BBBB;
        @(posedge clk);
        #1;
        @(negedge clk);
        scalar_write_valid = 1'b0;

        @(negedge clk);
        predicate_write_valid = 1'b1;
        predicate_write_wave_id = 2'd0;
        predicate_write_reg = 2'd2;
        predicate_write_data = 32'hAA55_AA55;
        @(posedge clk);
        #1;
        @(negedge clk);
        predicate_write_valid = 1'b0;

        @(negedge clk);
        predicate_write_valid = 1'b1;
        predicate_write_wave_id = 2'd1;
        predicate_write_reg = 2'd2;
        predicate_write_data = 32'h55AA_55AA;
        @(posedge clk);
        #1;
        @(negedge clk);
        predicate_write_valid = 1'b0;

        @(negedge clk);
        scalar_predicate_write_valid = 1'b1;
        scalar_predicate_write_wave_id = 2'd0;
        scalar_predicate_write_reg = 2'd1;
        scalar_predicate_write_data = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        scalar_predicate_write_valid = 1'b0;

        @(negedge clk);
        scalar_predicate_write_valid = 1'b1;
        scalar_predicate_write_wave_id = 2'd1;
        scalar_predicate_write_reg = 2'd1;
        scalar_predicate_write_data = 1'b0;
        @(posedge clk);
        #1;
        @(negedge clk);
        scalar_predicate_write_valid = 1'b0;

        /*
         * Wave 0 gets one live reconvergence entry.
         */
        @(negedge clk);
        reconv_write_valid = 1'b1;
        reconv_write_wave_id = 2'd0;
        reconv_write_index = 2'd0;
        reconv_write_parent_mask = 32'hFFFF_FFFF;
        reconv_write_else_mask = 32'h0000_FFFF;
        reconv_write_else_entered = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        reconv_write_valid = 1'b0;

        write_state(
            2'd0,
            6'd19,
            32'h00FF_00FF,
            3'd1,
            1'b0,
            1'b0,
            1'b0,
            1'b0
        );

        read_wave_id = 2'd0;
        scalar_read_reg = 3'd3;
        scalar_read_reg1 = 3'd3;
        predicate_read_reg = 2'd2;
        scalar_predicate_read_reg = 2'd1;
        reconv_read_index = 2'd0;
        #1;

        if (
            !read_valid
            || read_pc != 6'd19
            || read_exec_mask != 32'h00FF_00FF
            || read_reconv_sp != 3'd1
            || read_vrf_context_id != 2'd2
            || read_halted
            || read_blocked
            || read_memory_waiting
            || read_barrier_waiting
            || scalar_read_data != 32'h1111_AAAA
            || scalar_read_data1 != 32'h1111_AAAA
            || predicate_read_data != 32'hAA55_AA55
            || !scalar_predicate_read_data
        ) begin
            $fatal(1, "wave 0 context restore mismatch");
        end

        if (
            reconv_read_parent_mask != 32'hFFFF_FFFF
            || reconv_read_else_mask != 32'h0000_FFFF
            || !reconv_read_else_entered
        ) begin
            $fatal(1, "wave 0 reconvergence restore mismatch");
        end

        read_wave_id = 2'd1;
        #1;

        if (
            !read_valid
            || read_pc != 6'd11
            || read_exec_mask != 32'h0F0F_F0F0
            || read_vrf_context_id != 2'd1
            || read_halted
            || read_blocked
            || read_memory_waiting
            || read_barrier_waiting
            || scalar_read_data != 32'h2222_BBBB
            || scalar_read_data1 != 32'h2222_BBBB
            || predicate_read_data != 32'h55AA_55AA
            || scalar_predicate_read_data
        ) begin
            $fatal(1, "wave 1 context isolation mismatch");
        end

        $display("RTL7_CTX_ISOLATION=PASS");
        $display("RTL7_CTX_RECONV=PASS");
        $display("RTL7_CTX_VRF_OWNERSHIP=PASS");

        /*
         * Ready-mask contract: every architectural block reason removes a
         * resident wave from scheduler readiness.
         */
        write_state(
            2'd1,
            6'd11,
            32'h0F0F_F0F0,
            3'd0,
            1'b0,
            1'b1,
            1'b0,
            1'b0
        );

        read_wave_id = 2'd1;
        #1;
        if (
            ready_mask != 4'b0001
            || blocked_mask != 4'b0010
            || !read_valid
            || !read_blocked
            || read_halted
            || read_memory_waiting
            || read_barrier_waiting
        ) begin
            $fatal(1, "blocked wave read/aggregate state mismatch");
        end

        write_state(
            2'd0,
            6'd19,
            32'h00FF_00FF,
            3'd1,
            1'b0,
            1'b0,
            1'b1,
            1'b0
        );

        read_wave_id = 2'd0;
        #1;
        if (
            ready_mask != 4'b0000
            || memory_waiting_mask != 4'b0001
            || !read_valid
            || !read_memory_waiting
            || read_halted
            || read_blocked
            || read_barrier_waiting
        ) begin
            $fatal(1, "memory-waiting wave read/aggregate state mismatch");
        end

        write_state(
            2'd0,
            6'd19,
            32'h00FF_00FF,
            3'd1,
            1'b0,
            1'b0,
            1'b0,
            1'b0
        );

        write_state(
            2'd1,
            6'd11,
            32'h0F0F_F0F0,
            3'd0,
            1'b0,
            1'b0,
            1'b0,
            1'b1
        );

        read_wave_id = 2'd1;
        #1;
        if (
            ready_mask != 4'b0001
            || barrier_waiting_mask != 4'b0010
            || !read_valid
            || !read_barrier_waiting
            || read_halted
            || read_blocked
            || read_memory_waiting
        ) begin
            $fatal(1, "barrier-waiting wave read/aggregate state mismatch");
        end

        write_state(
            2'd1,
            6'd11,
            32'h0F0F_F0F0,
            3'd0,
            1'b1,
            1'b0,
            1'b0,
            1'b0
        );

        read_wave_id = 2'd1;
        debug_read_wave_id = 2'd1;
        debug_scalar_read_reg = 3'd3;
        debug_predicate_read_reg = 2'd2;
        #1;
        if (
            ready_mask != 4'b0001
            || halted_mask != 4'b0010
            || !read_valid
            || !read_halted
            || read_blocked
            || read_memory_waiting
            || read_barrier_waiting
        ) begin
            $fatal(1, "halted wave read/aggregate state mismatch");
        end

        if (
            !debug_read_valid
            || debug_read_pc != 6'd11
            || debug_read_exec_mask != 32'h0F0F_F0F0
            || !debug_read_halted
            || debug_scalar_read_data != 32'h2222_BBBB
            || debug_predicate_read_data != 32'h55AA_55AA
        ) begin
            $fatal(1, "debug readback mismatch for halted wave");
        end

        $display("RTL7_CTX_READY_MASK=PASS");

        @(negedge clk);
        clear_writes();
        release_valid = 1'b1;
        release_wave_id = 2'd1;
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_writes();

        debug_read_wave_id = 2'd1;
        #1;
        if (
            valid_mask != 4'b0001
            || halted_mask != 4'b0000
            || debug_read_valid
            || debug_read_pc != '0
            || debug_read_exec_mask != '0
            || debug_read_halted
            || debug_scalar_read_data != '0
            || debug_predicate_read_data != '0
        ) begin
            $fatal(1, "release did not invalidate/mask wave 1 debug state");
        end

        alloc_wave_id = 2'd1;
        #1;
        if (!alloc_ready) begin
            $fatal(1, "released slot did not become allocatable");
        end

        $display("RTL7_CTX_RELEASE=PASS");
        $display("RTL7_CONTEXT_FILE_TB=PASS");

        $finish;
    end

endmodule
