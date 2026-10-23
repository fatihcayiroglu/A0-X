`timescale 1ns/1ps

module a0_multi_wave_core_rtl7b_tb;

    localparam integer RESIDENT_WAVES = 2;
    localparam integer WAVE_SIZE = 8;
    localparam integer PHYSICAL_LANES = 4;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;
    localparam integer PROGRAM_WORDS = 16;

    localparam integer WAVE_ID_W = 1;
    localparam integer PC_W = 4;
    localparam integer VECTOR_REG_INDEX_W = 3;
    localparam integer SCALAR_REG_INDEX_W = 3;
    localparam integer PREDICATE_INDEX_W = 2;
    localparam integer MSHR_LINE_WORDS = 8;
    localparam integer MSHR_ENTRY_W = 1;
    localparam integer MSHR_LINE_ADDR_W = 29;
    localparam integer MSHR_OCCUPANCY_W = 2;

    localparam logic [7:0] OP_VADD    = 8'h01;
    localparam logic [7:0] OP_SADD    = 8'h40;
    localparam logic [7:0] OP_VCMP_LT = 8'h61;
    localparam logic [7:0] OP_HALT    = 8'hFF;

    logic clk;
    logic rst_n;
    logic run_enable;

    logic program_we;
    logic [PC_W-1:0] program_waddr;
    logic [63:0] program_wdata;

    logic alloc_valid;
    logic [WAVE_ID_W-1:0] alloc_wave_id;
    logic alloc_ready;
    logic [PC_W-1:0] alloc_pc;
    logic [WAVE_SIZE-1:0] alloc_exec_mask;
    logic [WAVE_ID_W-1:0] alloc_vrf_context_id;

    logic release_valid;
    logic [WAVE_ID_W-1:0] release_wave_id;

    logic scalar_we;
    logic [WAVE_ID_W-1:0] scalar_wwave;
    logic [SCALAR_REG_INDEX_W-1:0] scalar_wreg;
    logic [31:0] scalar_wdata;

    logic predicate_we;
    logic [WAVE_ID_W-1:0] predicate_wwave;
    logic [PREDICATE_INDEX_W-1:0] predicate_wreg;
    logic [WAVE_SIZE-1:0] predicate_wdata;

    logic vector_we;
    logic [WAVE_ID_W-1:0] vector_wcontext;
    logic [VECTOR_REG_INDEX_W-1:0] vector_wreg;
    logic [$clog2(WAVE_SIZE)-1:0] vector_wlane;
    logic [31:0] vector_wdata;

    logic mem_req_valid_o;
    logic mem_req_write_o;
    logic [WAVE_ID_W-1:0] mem_req_wave_o;
    logic [WAVE_ID_W-1:0] mem_req_context_o;
    logic [WAVE_SIZE-1:0] mem_req_lane_mask_o;
    logic [31:0] mem_req_addr_o [0:WAVE_SIZE-1];
    logic [31:0] mem_req_wdata_o [0:WAVE_SIZE-1];

    logic mem_resp_valid_i;
    logic [WAVE_ID_W-1:0] mem_resp_wave_i;
    logic [WAVE_ID_W-1:0] mem_resp_context_i;
    logic mem_resp_fault_i;
    logic [31:0] mem_resp_rdata_i [0:WAVE_SIZE-1];

    logic mshr_mem_req_valid_unused;
    logic [MSHR_ENTRY_W-1:0] mshr_mem_req_entry_unused;
    logic [MSHR_LINE_ADDR_W-1:0] mshr_mem_req_line_addr_unused;
    logic [31:0] mshr_mem_resp_line_data_zero [0:MSHR_LINE_WORDS-1]
        = '{default: '0};
    logic [MSHR_OCCUPANCY_W-1:0] mshr_occupancy_unused;
    logic mshr_full_unused;
    logic mshr_merge_event_unused;
    logic [RESIDENT_WAVES-1:0] mshr_active_wave_mask_unused;
    logic mshr_tag_error_unused;

    logic memory_outstanding_o;
    logic memory_tag_error_o;

    logic policy_override_valid_i;
    logic [WAVE_ID_W-1:0] policy_override_wave_i;

    logic [WAVE_ID_W-1:0] debug_vector_context_i;
    logic [VECTOR_REG_INDEX_W-1:0] debug_vector_reg_i;
    logic [$clog2(WAVE_SIZE)-1:0] debug_vector_lane_i;
    logic [31:0] debug_vector_data_o;

    logic [WAVE_ID_W-1:0] debug_context_i;
    logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_reg_i;
    logic [PREDICATE_INDEX_W-1:0] debug_predicate_reg_i;
    logic debug_context_valid_o;
    logic [PC_W-1:0] debug_pc_o;
    logic [WAVE_SIZE-1:0] debug_exec_mask_o;
    logic debug_halted_o;
    logic [31:0] debug_scalar_data_o;
    logic [WAVE_SIZE-1:0] debug_predicate_data_o;

    logic retire_valid_o;
    logic [WAVE_ID_W-1:0] retire_wave_o;
    logic [PC_W-1:0] retire_pc_o;

    logic engine_busy_o;
    logic faulted_o;
    logic [RESIDENT_WAVES-1:0] valid_mask_o;
    logic [RESIDENT_WAVES-1:0] ready_mask_o;
    logic [RESIDENT_WAVES-1:0] halted_mask_o;
    logic [WAVE_ID_W-1:0] rr_cursor_o;
    logic all_halted_o;

    integer cycle_count;
    integer retire_count;
    integer bank_conflict_cycles;
    integer lane;

    logic pause_done;
    logic [WAVE_ID_W-1:0] pause_cursor_snapshot;

    logic [WAVE_ID_W-1:0] expected_retire_wave [0:7];
    logic [PC_W-1:0] expected_retire_pc [0:7];


    function automatic logic [63:0] encode_instruction(
        input logic [7:0] opcode,
        input logic [3:0] flags,
        input logic [5:0] dst,
        input logic [5:0] src0,
        input logic [5:0] src1,
        input logic [5:0] src2,
        input logic [3:0] pred,
        input logic [23:0] imm24
    );
        encode_instruction = {
            opcode,
            flags,
            dst,
            src0,
            src1,
            src2,
            pred,
            imm24
        };
    endfunction


    logic store_terminal_valid_unused;
    logic store_terminal_fault_unused;

    a0_multi_wave_core #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .SCALAR_PREDICATE_REG_COUNT(SCALAR_PREDICATE_REG_COUNT),
        .RECONV_STACK_DEPTH(RECONV_STACK_DEPTH),
        .GLOBAL_MEMORY_WORDS(256),
        .ENABLE_LOAD_MSHR(0),
        .PROGRAM_WORDS(PROGRAM_WORDS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_enable(run_enable),
        .program_we(program_we),
        .program_waddr(program_waddr),
        .program_wdata(program_wdata),
        .alloc_valid(alloc_valid),
        .alloc_wave_id(alloc_wave_id),
        .alloc_ready(alloc_ready),
        .alloc_pc(alloc_pc),
        .alloc_exec_mask(alloc_exec_mask),
        .alloc_vrf_context_id(alloc_vrf_context_id),
        .release_valid(release_valid),
        .release_wave_id(release_wave_id),
        .scalar_we(scalar_we),
        .scalar_wwave(scalar_wwave),
        .scalar_wreg(scalar_wreg),
        .scalar_wdata(scalar_wdata),
        .predicate_we(predicate_we),
        .predicate_wwave(predicate_wwave),
        .predicate_wreg(predicate_wreg),
        .predicate_wdata(predicate_wdata),
        .vector_we(vector_we),
        .vector_wcontext(vector_wcontext),
        .vector_wreg(vector_wreg),
        .vector_wlane(vector_wlane),
        .vector_wdata(vector_wdata),

        .mem_req_valid_o(mem_req_valid_o),
        .mem_req_write_o(mem_req_write_o),
        .mem_req_wave_o(mem_req_wave_o),
        .mem_req_context_o(mem_req_context_o),
        .mem_req_lane_mask_o(mem_req_lane_mask_o),
        .mem_req_addr_o(mem_req_addr_o),
        .mem_req_wdata_o(mem_req_wdata_o),

        .mem_resp_valid_i(mem_resp_valid_i),
        .mem_resp_wave_i(mem_resp_wave_i),
        .mem_resp_context_i(mem_resp_context_i),
        .mem_resp_fault_i(mem_resp_fault_i),
        .mem_resp_rdata_i(mem_resp_rdata_i),

        .mshr_mem_req_valid_o(mshr_mem_req_valid_unused),
        .mshr_mem_req_ready_i(1'b0),
        .mshr_mem_req_entry_o(mshr_mem_req_entry_unused),
        .mshr_mem_req_line_addr_o(mshr_mem_req_line_addr_unused),
        .mshr_mem_resp_valid_i(1'b0),
        .mshr_mem_resp_entry_i('0),
        .mshr_mem_resp_line_addr_i('0),
        .mshr_mem_resp_fault_i(1'b0),
        .mshr_mem_resp_line_data_i(mshr_mem_resp_line_data_zero),
        .mshr_occupancy_o(mshr_occupancy_unused),
        .mshr_full_o(mshr_full_unused),
        .mshr_merge_event_o(mshr_merge_event_unused),
        .mshr_active_wave_mask_o(mshr_active_wave_mask_unused),
        .mshr_tag_error_o(mshr_tag_error_unused),

        .memory_outstanding_o(memory_outstanding_o),
        .memory_tag_error_o(memory_tag_error_o),

        .policy_override_valid_i(policy_override_valid_i),
        .policy_override_wave_i(policy_override_wave_i),
        .debug_vector_context_i(debug_vector_context_i),
        .debug_vector_reg_i(debug_vector_reg_i),
        .debug_vector_lane_i(debug_vector_lane_i),
        .debug_vector_data_o(debug_vector_data_o),
        .debug_context_i(debug_context_i),
        .debug_scalar_reg_i(debug_scalar_reg_i),
        .debug_predicate_reg_i(debug_predicate_reg_i),
        .debug_context_valid_o(debug_context_valid_o),
        .debug_pc_o(debug_pc_o),
        .debug_exec_mask_o(debug_exec_mask_o),
        .debug_halted_o(debug_halted_o),
        .debug_scalar_data_o(debug_scalar_data_o),
        .debug_predicate_data_o(debug_predicate_data_o),
        .retire_valid_o(retire_valid_o),
        .retire_wave_o(retire_wave_o),
        .retire_pc_o(retire_pc_o),
        .engine_busy_o(engine_busy_o),
        .faulted_o(faulted_o),
        .valid_mask_o(valid_mask_o),
        .ready_mask_o(ready_mask_o),
        .halted_mask_o(halted_mask_o),
        .rr_cursor_o(rr_cursor_o),
        .cluster_store_observe_enable_i(1'b0),
        .launch_observe_valid_i('0),
        .launch_observe_lane_mask_i('{default: '0}),
        .launch_observe_word_addr_i('{default: '{default: '0}}),
        .ordering_store_valid_i('0),
        .ordering_store_lane_mask_i('{default: '0}),
        .ordering_store_word_addr_i('{default: '{default: '0}}),
        .terminal_store_valid_i('0),
        .terminal_store_lane_mask_i('{default: '0}),
        .terminal_store_word_addr_i('{default: '{default: '0}}),
        .store_terminal_valid_o(store_terminal_valid_unused),
        .store_terminal_fault_o(store_terminal_fault_unused),
        .all_halted_o(all_halted_o)
    );


    always #5 clk = ~clk;


    task automatic clear_loaders;
        begin
            program_we = 1'b0;
            alloc_valid = 1'b0;
            release_valid = 1'b0;
            scalar_we = 1'b0;
            predicate_we = 1'b0;
            vector_we = 1'b0;
        end
    endtask


    task automatic write_program(
        input integer address,
        input logic [63:0] instruction_word
    );
        begin
            if (address < 0 || address >= PROGRAM_WORDS) begin
                $fatal(1, "program address out of range address=%0d", address);
            end
            @(negedge clk);
            clear_loaders();
            program_we = 1'b1;
            program_waddr = PC_W'(address);
            program_wdata = instruction_word;
            @(posedge clk);
            #1;
            @(negedge clk);
            program_we = 1'b0;
        end
    endtask


    task automatic allocate_context(
        input logic [WAVE_ID_W-1:0] wave_id,
        input integer start_pc,
        input logic [WAVE_SIZE-1:0] exec_value
    );
        begin
            if (start_pc < 0 || start_pc >= PROGRAM_WORDS) begin
                $fatal(1, "allocation PC out of range pc=%0d", start_pc);
            end
            @(negedge clk);
            clear_loaders();
            alloc_valid = 1'b1;
            alloc_wave_id = wave_id;
            alloc_pc = PC_W'(start_pc);
            alloc_exec_mask = exec_value;
            alloc_vrf_context_id = wave_id;
            #1;
            if (!alloc_ready) begin
                $fatal(1, "allocation not ready wave=%0d", wave_id);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            alloc_valid = 1'b0;
        end
    endtask


    task automatic write_scalar(
        input logic [WAVE_ID_W-1:0] wave_id,
        input integer reg_id,
        input logic [31:0] value
    );
        begin
            if (reg_id < 0 || reg_id >= SCALAR_REG_COUNT) begin
                $fatal(1, "scalar register out of range reg=%0d", reg_id);
            end
            @(negedge clk);
            clear_loaders();
            scalar_we = 1'b1;
            scalar_wwave = wave_id;
            scalar_wreg = SCALAR_REG_INDEX_W'(reg_id);
            scalar_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            scalar_we = 1'b0;
        end
    endtask


    task automatic write_predicate(
        input logic [WAVE_ID_W-1:0] wave_id,
        input integer reg_id,
        input logic [WAVE_SIZE-1:0] value
    );
        begin
            if (reg_id < 0 || reg_id >= PREDICATE_REG_COUNT) begin
                $fatal(1, "predicate register out of range reg=%0d", reg_id);
            end
            @(negedge clk);
            clear_loaders();
            predicate_we = 1'b1;
            predicate_wwave = wave_id;
            predicate_wreg = PREDICATE_INDEX_W'(reg_id);
            predicate_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            predicate_we = 1'b0;
        end
    endtask


    task automatic write_vector_lane(
        input logic [WAVE_ID_W-1:0] context_id,
        input integer reg_id,
        input integer lane_id,
        input logic [31:0] value
    );
        begin
            if (reg_id < 0 || reg_id >= VECTOR_REG_COUNT) begin
                $fatal(1, "vector register out of range reg=%0d", reg_id);
            end
            if (lane_id < 0 || lane_id >= WAVE_SIZE) begin
                $fatal(1, "vector lane out of range lane=%0d", lane_id);
            end
            @(negedge clk);
            clear_loaders();
            vector_we = 1'b1;
            vector_wcontext = context_id;
            vector_wreg = VECTOR_REG_INDEX_W'(reg_id);
            vector_wlane = $clog2(WAVE_SIZE)'(lane_id);
            vector_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            vector_we = 1'b0;
        end
    endtask


    task automatic expect_vector_lane(
        input logic [WAVE_ID_W-1:0] context_id,
        input integer reg_id,
        input integer lane_id,
        input logic [31:0] expected
    );
        begin
            debug_vector_context_i = context_id;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(reg_id);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane_id);
            #1;
            if (debug_vector_data_o !== expected) begin
                $fatal(
                    1,
                    "vector mismatch ctx=%0d reg=%0d lane=%0d expected=%h actual=%h",
                    context_id,
                    reg_id,
                    lane_id,
                    expected,
                    debug_vector_data_o
                );
            end
        end
    endtask


    task automatic expect_no_memory_traffic;
        integer mem_lane;
        begin
            if (mem_req_valid_o) begin
                for (mem_lane = 0; mem_lane < WAVE_SIZE; mem_lane = mem_lane + 1) begin
                    if (mem_req_lane_mask_o[mem_lane]) begin
                        $display(
                            "unexpected memory lane=%0d addr=%h wdata=%h",
                            mem_lane,
                            mem_req_addr_o[mem_lane],
                            mem_req_wdata_o[mem_lane]
                        );
                    end
                end
                $fatal(
                    1,
                    "compute-only RTL7B test launched memory request write=%0b wave=%0d context=%0d mask=%h",
                    mem_req_write_o,
                    mem_req_wave_o,
                    mem_req_context_o,
                    mem_req_lane_mask_o
                );
            end
            if (memory_outstanding_o) begin
                $fatal(1, "compute-only RTL7B test acquired memory ownership");
            end
            if (memory_tag_error_o) begin
                $fatal(1, "compute-only RTL7B test raised memory tag error");
            end
        end
    endtask


    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        run_enable = 1'b0;

        program_waddr = '0;
        program_wdata = '0;
        alloc_wave_id = '0;
        alloc_pc = '0;
        alloc_exec_mask = '0;
        alloc_vrf_context_id = '0;
        release_wave_id = '0;
        scalar_wwave = '0;
        scalar_wreg = '0;
        scalar_wdata = '0;
        predicate_wwave = '0;
        predicate_wreg = '0;
        predicate_wdata = '0;
        vector_wcontext = '0;
        vector_wreg = '0;
        vector_wlane = '0;
        vector_wdata = '0;
        mem_resp_valid_i = 1'b0;
        mem_resp_wave_i = '0;
        mem_resp_context_i = '0;
        mem_resp_fault_i = 1'b0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            mem_resp_rdata_i[lane] = '0;
        end

        policy_override_valid_i = 1'b0;
        policy_override_wave_i = '0;
        debug_vector_context_i = '0;
        debug_vector_reg_i = '0;
        debug_vector_lane_i = '0;
        debug_context_i = '0;
        debug_scalar_reg_i = '0;
        debug_predicate_reg_i = '0;
        clear_loaders();
        pause_done = 1'b0;
        pause_cursor_snapshot = '0;

        expected_retire_wave[0] = 1'd0;
        expected_retire_wave[1] = 1'd1;
        expected_retire_wave[2] = 1'd0;
        expected_retire_wave[3] = 1'd1;
        expected_retire_wave[4] = 1'd0;
        expected_retire_wave[5] = 1'd1;
        expected_retire_wave[6] = 1'd0;
        expected_retire_wave[7] = 1'd1;

        expected_retire_pc[0] = 4'd0;
        expected_retire_pc[1] = 4'd8;
        expected_retire_pc[2] = 4'd1;
        expected_retire_pc[3] = 4'd9;
        expected_retire_pc[4] = 4'd2;
        expected_retire_pc[5] = 4'd10;
        expected_retire_pc[6] = 4'd3;
        expected_retire_pc[7] = 4'd11;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        expect_no_memory_traffic();

        /*
         * RTL7B uses an identity resident-wave -> VRF-context mapping.
         * Mismatched ownership must be rejected without allocating state.
         */
        alloc_valid = 1'b1;
        alloc_wave_id = 1'd0;
        alloc_pc = 4'd0;
        alloc_exec_mask = 8'hFF;
        alloc_vrf_context_id = 1'd1;
        #1;
        if (alloc_ready) begin
            $fatal(1, "mismatched VRF ownership unexpectedly accepted");
        end
        @(posedge clk);
        #1;
        if (valid_mask_o != 2'b00) begin
            $fatal(1, "rejected VRF ownership still allocated context");
        end
        @(negedge clk);
        alloc_valid = 1'b0;
        $display("RTL7B_VRF_OWNERSHIP_GUARD=PASS");

        /* Two programs at disjoint shared-program-memory locations. */
        write_program(
            0,
            encode_instruction(
                OP_SADD, 4'h0, 6'd3, 6'd1, 6'd2, 6'd0, 4'd0, 24'd0
            )
        );
        write_program(
            1,
            encode_instruction(
                OP_VCMP_LT, 4'h0, 6'd0, 6'd1, 6'd5, 6'd0, 4'd1, 24'd0
            )
        );
        write_program(
            2,
            encode_instruction(
                OP_VADD, 4'h1, 6'd3, 6'd1, 6'd5, 6'd0, 4'd1, 24'd0
            )
        );
        write_program(
            3,
            encode_instruction(
                OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
            )
        );

        write_program(
            8,
            encode_instruction(
                OP_SADD, 4'h0, 6'd3, 6'd1, 6'd2, 6'd0, 4'd0, 24'd0
            )
        );
        write_program(
            9,
            encode_instruction(
                OP_VCMP_LT, 4'h0, 6'd0, 6'd1, 6'd5, 6'd0, 4'd1, 24'd0
            )
        );
        write_program(
            10,
            encode_instruction(
                OP_VADD, 4'h1, 6'd3, 6'd1, 6'd5, 6'd0, 4'd1, 24'd0
            )
        );
        write_program(
            11,
            encode_instruction(
                OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
            )
        );

        allocate_context(1'd0, 0, 8'b0011_1111);
        allocate_context(1'd1, 8, 8'b1111_1100);

        write_scalar(1'd0, 1, 32'd10);
        write_scalar(1'd0, 2, 32'd2);
        write_scalar(1'd1, 1, 32'd100);
        write_scalar(1'd1, 2, 32'd7);

        /* Inactive VCMP lanes preserve these different initial masks. */
        write_predicate(1'd0, 1, 8'b1100_0000);
        write_predicate(1'd1, 1, 8'b0000_0001);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(1'd0, 1, lane, 32'(lane));
            write_vector_lane(1'd0, 5, lane, 32'd4);
            write_vector_lane(1'd0, 3, lane, 32'hA000_0000 + 32'(lane));

            write_vector_lane(1'd1, 1, lane, 32'd10 + 32'(lane));
            write_vector_lane(1'd1, 5, lane, 32'd15);
            write_vector_lane(1'd1, 3, lane, 32'hB000_0000 + 32'(lane));
        end

        if (valid_mask_o != 2'b11 || ready_mask_o != 2'b11) begin
            $fatal(1, "resident wave initialization mismatch");
        end

        $display("RTL7B_TWO_RESIDENT_WAVES=PASS");

        retire_count = 0;
        cycle_count = 0;
        bank_conflict_cycles = 0;
        run_enable = 1'b1;

        /*
         * Pause the first in-flight vector instruction. Architectural
         * ownership, scheduler cursor and retirement must remain frozen.
         */
        fork
            begin : pause_inflight_vector
                wait (engine_busy_o);
                @(negedge clk);
                pause_cursor_snapshot = rr_cursor_o;
                run_enable = 1'b0;

                repeat (4) begin
                    @(posedge clk);
                    #1;
                    if (!engine_busy_o) begin
                        $fatal(1, "pause dropped in-flight vector ownership");
                    end
                    if (retire_valid_o) begin
                        $fatal(1, "instruction retired while run_enable=0");
                    end
                    if (rr_cursor_o !== pause_cursor_snapshot) begin
                        $fatal(1, "scheduler cursor moved during pause");
                    end
                end

                @(negedge clk);
                run_enable = 1'b1;
                pause_done = 1'b1;
            end
        join_none

        while (!all_halted_o && cycle_count < 1000) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
            expect_no_memory_traffic();

            if (dut.operand_bank_conflict_cycle) begin
                bank_conflict_cycles = bank_conflict_cycles + 1;
            end

            if (retire_valid_o) begin
                if (retire_count >= 8) begin
                    $fatal(1, "too many retirements");
                end

                if (
                    retire_wave_o !== expected_retire_wave[retire_count]
                    || retire_pc_o !== expected_retire_pc[retire_count]
                ) begin
                    $fatal(
                        1,
                        "retire sequence mismatch index=%0d expected_wave=%0d actual_wave=%0d expected_pc=%0d actual_pc=%0d",
                        retire_count,
                        expected_retire_wave[retire_count],
                        retire_wave_o,
                        expected_retire_pc[retire_count],
                        retire_pc_o
                    );
                end

                retire_count = retire_count + 1;
            end
        end

        if (!pause_done) begin
            $fatal(1, "in-flight pause verification was not exercised");
        end
        $display("RTL7B_PAUSE_PRESERVES_INFLIGHT=PASS");

        run_enable = 1'b0;
        #1;

        if (!all_halted_o) begin
            $fatal(1, "multi-wave execution timed out cycles=%0d", cycle_count);
        end
        if (halted_mask_o != {RESIDENT_WAVES{1'b1}}) begin
            $fatal(1, "halted mask mismatch expected=%b actual=%b", {RESIDENT_WAVES{1'b1}}, halted_mask_o);
        end
        expect_no_memory_traffic();
        if (retire_count != 8) begin
            $fatal(1, "retirement count mismatch expected=8 actual=%0d", retire_count);
        end
        if (faulted_o) begin
            $fatal(1, "multi-wave core faulted unexpectedly");
        end
        if (engine_busy_o) begin
            $fatal(1, "engine remained busy after all waves halted");
        end
        if (bank_conflict_cycles == 0) begin
            $fatal(1, "same-bank operand serialization was not exercised");
        end

        $display(
            "RTL7B_INTERLEAVED_RETIRE=PASS retirements=%0d cycles=%0d",
            retire_count,
            cycle_count
        );
        $display(
            "RTL7B_CONTEXTED_VRF_CONFLICT=PASS cycles=%0d",
            bank_conflict_cycles
        );

        /* Architectural scalar / PC / EXEC / predicate isolation. */
        debug_context_i = 1'd0;
        debug_scalar_reg_i = 3'd3;
        debug_predicate_reg_i = 2'd1;
        #1;

        if (
            !debug_context_valid_o
            || debug_pc_o != 4'd4
            || debug_exec_mask_o != 8'b0011_1111
            || !debug_halted_o
            || debug_scalar_data_o != 32'd12
            || debug_predicate_data_o != 8'hCF
        ) begin
            $fatal(
                1,
                "wave0 architectural state mismatch pc=%0d exec=%b halt=%0d scalar=%0d pred=%h",
                debug_pc_o,
                debug_exec_mask_o,
                debug_halted_o,
                debug_scalar_data_o,
                debug_predicate_data_o
            );
        end

        debug_context_i = 1'd1;
        #1;

        if (
            !debug_context_valid_o
            || debug_pc_o != 4'd12
            || debug_exec_mask_o != 8'b1111_1100
            || !debug_halted_o
            || debug_scalar_data_o != 32'd107
            || debug_predicate_data_o != 8'h1D
        ) begin
            $fatal(
                1,
                "wave1 architectural state mismatch pc=%0d exec=%b halt=%0d scalar=%0d pred=%h",
                debug_pc_o,
                debug_exec_mask_o,
                debug_halted_o,
                debug_scalar_data_o,
                debug_predicate_data_o
            );
        end

        $display("RTL7B_SCALAR_PC_EXEC_ISOLATION=PASS");
        $display("RTL7B_PREDICATE_ISOLATION=PASS");

        /* Wave 0: only lanes 0..3 pass EXEC & generated P1. */
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (lane < 4) begin
                expect_vector_lane(1'd0, 3, lane, 32'(lane + 4));
            end else begin
                expect_vector_lane(
                    1'd0,
                    3,
                    lane,
                    32'hA000_0000 + 32'(lane)
                );
            end
        end

        /* Wave 1: only lanes 2..4 pass EXEC & generated P1. */
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (lane >= 2 && lane <= 4) begin
                expect_vector_lane(1'd1, 3, lane, 32'd25 + 32'(lane));
            end else begin
                expect_vector_lane(
                    1'd1,
                    3,
                    lane,
                    32'hB000_0000 + 32'(lane)
                );
            end
        end

        $display("RTL7B_VECTOR_CONTEXT_ISOLATION=PASS");
        $display("RTL7B_EXEC_PREDICATION_ISOLATION=PASS");

        if (
            dut.scoreboard_vector_busy[0] != '0
            || dut.scoreboard_vector_busy[1] != '0
            || dut.scoreboard_predicate_busy[0] != '0
            || dut.scoreboard_predicate_busy[1] != '0
        ) begin
            $fatal(1, "wave-qualified scoreboards not empty after halt");
        end

        $display("RTL7B_WAVE_QUALIFIED_SCOREBOARD=PASS");
        $display("RTL7B_LIVE_MULTI_WAVE_CORE_TB=PASS");

        $finish;
    end

endmodule
