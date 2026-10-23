`timescale 1ns/1ps

module a0_multi_wave_core_rtl7c_memory_edges_tb;

    localparam integer RESIDENT_WAVES = 1;
    localparam integer WAVE_SIZE = 4;
    localparam integer PHYSICAL_LANES = 2;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;
    localparam integer GLOBAL_MEMORY_WORDS = 32;
    localparam integer PROGRAM_WORDS = 8;

    localparam integer WAVE_ID_W = 1;
    localparam integer PC_W = 3;
    localparam integer VECTOR_REG_INDEX_W = 3;
    localparam integer SCALAR_REG_INDEX_W = 3;
    localparam integer PREDICATE_INDEX_W = 2;
    localparam integer MSHR_LINE_WORDS = 8;
    localparam integer MSHR_ENTRY_W = 1;
    localparam integer MSHR_LINE_ADDR_W = 29;
    localparam integer MSHR_OCCUPANCY_W = 2;

    localparam logic [7:0] OP_VLOADX = 8'h54;
    localparam logic [7:0] OP_HALT = 8'hFF;

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

    integer lane;
    integer cycles;
    integer request_pulses;


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
        .SCALAR_PREDICATE_REG_COUNT(
            SCALAR_PREDICATE_REG_COUNT
        ),
        .RECONV_STACK_DEPTH(RECONV_STACK_DEPTH),
        .GLOBAL_MEMORY_WORDS(GLOBAL_MEMORY_WORDS),
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

    always @(posedge clk) begin
        if (rst_n && mem_req_valid_o) begin
            request_pulses <= request_pulses + 1;
        end
    end


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


    task automatic apply_reset;
        begin
            run_enable = 1'b0;
            mem_resp_valid_i = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            request_pulses = 0;
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


    task automatic allocate_context;
        begin
            @(negedge clk);
            clear_loaders();
            alloc_valid = 1'b1;
            alloc_wave_id = '0;
            alloc_pc = '0;
            alloc_exec_mask = '1;
            alloc_vrf_context_id = '0;
            #1;
            if (!alloc_ready) begin
                $fatal(1, "single context allocation not ready");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            alloc_valid = 1'b0;
        end
    endtask


    task automatic write_scalar0(input logic [31:0] value);
        begin
            @(negedge clk);
            clear_loaders();
            scalar_we = 1'b1;
            scalar_wwave = '0;
            scalar_wreg = '0;
            scalar_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            scalar_we = 1'b0;
        end
    endtask


    task automatic write_pred1(input logic [WAVE_SIZE-1:0] value);
        begin
            @(negedge clk);
            clear_loaders();
            predicate_we = 1'b1;
            predicate_wwave = '0;
            predicate_wreg = PREDICATE_INDEX_W'(1);
            predicate_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            predicate_we = 1'b0;
        end
    endtask


    task automatic write_offset_lane(
        input integer lane_id,
        input logic [31:0] value
    );
        begin
            if (lane_id < 0 || lane_id >= WAVE_SIZE) begin
                $fatal(1, "write_offset_lane lane out of range lane=%0d", lane_id);
            end
            @(negedge clk);
            clear_loaders();
            vector_we = 1'b1;
            vector_wcontext = '0;
            vector_wreg = VECTOR_REG_INDEX_W'(1);
            vector_wlane = $clog2(WAVE_SIZE)'(lane_id);
            vector_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            vector_we = 1'b0;
        end
    endtask


    task automatic write_dst_lane(
        input integer lane_id,
        input logic [31:0] value
    );
        begin
            if (lane_id < 0 || lane_id >= WAVE_SIZE) begin
                $fatal(1, "write_dst_lane lane out of range lane=%0d", lane_id);
            end
            @(negedge clk);
            clear_loaders();
            vector_we = 1'b1;
            vector_wcontext = '0;
            vector_wreg = VECTOR_REG_INDEX_W'(3);
            vector_wlane = $clog2(WAVE_SIZE)'(lane_id);
            vector_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            vector_we = 1'b0;
        end
    endtask


    task automatic wait_retire_pc0;
        begin
            cycles = 0;
            while (
                !(retire_valid_o && retire_pc_o == '0)
                && cycles < 200
            ) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            if (!(retire_valid_o && retire_pc_o == '0)) begin
                $fatal(1, "timed out waiting for pc0 retirement");
            end
            if (retire_wave_o != '0) begin
                $fatal(1, "pc0 retired on unexpected wave=%0d", retire_wave_o);
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

        policy_override_valid_i = 1'b0;
        policy_override_wave_i = '0;
        debug_vector_context_i = '0;
        debug_vector_reg_i = '0;
        debug_vector_lane_i = '0;
        debug_context_i = '0;
        debug_scalar_reg_i = '0;
        debug_predicate_reg_i = '0;

        request_pulses = 0;
        clear_loaders();

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            mem_resp_rdata_i[lane] = 32'(9000 + lane);
        end

        /*
         * Scenario 1: predicated all-masked VLOADX is an architectural no-op.
         * It retires and releases the destination without backend access.
         */
        apply_reset();

        write_program(
            0,
            encode_instruction(
                OP_VLOADX,
                4'h1,
                6'd3,
                6'd0,
                6'd1,
                6'd0,
                4'd1,
                24'd0
            )
        );
        write_program(
            1,
            encode_instruction(
                OP_HALT,
                4'h0,
                6'd0,
                6'd0,
                6'd0,
                6'd0,
                4'd0,
                24'd0
            )
        );

        allocate_context();
        write_scalar0(32'd4);
        write_pred1('0);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_offset_lane(lane, 32'(lane));
            write_dst_lane(lane, 32'(700 + lane));
        end

        run_enable = 1'b1;
        wait_retire_pc0();

        if (
            request_pulses != 0
            || memory_outstanding_o
            || memory_tag_error_o
            || faulted_o
            || dut.scoreboard_vector_busy[0][3] !== 1'b0
        ) begin
            $fatal(1, "all-masked memory no-op contract failed");
        end
        debug_vector_context_i = '0;
        debug_vector_reg_i = VECTOR_REG_INDEX_W'(3);
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (debug_vector_data_o != 32'(700 + lane)) begin
                $fatal(1, "all-masked load modified destination lane=%0d", lane);
            end
        end

        $display("RTL7C_ALL_MASKED_MEMORY_NOOP=PASS");

        /*
         * Scenario 2: any active out-of-range lane prevents the request
         * entirely and faults/halt the wave (fail-before-access).
         */
        apply_reset();

        write_program(
            0,
            encode_instruction(
                OP_VLOADX,
                4'h0,
                6'd3,
                6'd0,
                6'd1,
                6'd0,
                4'd0,
                24'd0
            )
        );

        allocate_context();
        write_scalar0(32'(GLOBAL_MEMORY_WORDS - 2));

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_offset_lane(lane, 32'(lane));
        end

        run_enable = 1'b1;
        wait_retire_pc0();
        #1;

        if (
            request_pulses != 0
            || memory_outstanding_o
            || !faulted_o
            || halted_mask_o[0] !== 1'b1
            || dut.scoreboard_vector_busy[0][3] !== 1'b0
        ) begin
            $fatal(1, "fail-before-access address fault contract failed");
        end

        $display("RTL7C_ADDRESS_FAULT_NO_ACCESS=PASS");

        /*
         * Scenario 3: a correctly tagged backend fault completes the memory
         * instruction, releases its scoreboard reservation and halts the wave.
         */
        apply_reset();

        write_program(
            0,
            encode_instruction(
                OP_VLOADX,
                4'h0,
                6'd3,
                6'd0,
                6'd1,
                6'd0,
                4'd0,
                24'd0
            )
        );

        allocate_context();
        write_scalar0(32'd8);
        write_pred1(4'b1010);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_offset_lane(lane, 32'(lane));
        end

        run_enable = 1'b1;

        cycles = 0;
        while (!mem_req_valid_o && cycles < 200) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (
            !mem_req_valid_o
            || mem_req_write_o
            || mem_req_wave_o != '0
            || mem_req_context_o != '0
            || mem_req_lane_mask_o != '1
            || !memory_outstanding_o
        ) begin
            $fatal(1, "backend-fault scenario request metadata mismatch");
        end
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (
                mem_req_addr_o[lane] != 32'(8 + lane)
                || mem_req_wdata_o[lane] != '0
            ) begin
                $fatal(1, "backend-fault load payload mismatch lane=%0d", lane);
            end
        end

        @(negedge clk);
        mem_resp_wave_i = '0;
        mem_resp_context_i = '0;
        mem_resp_fault_i = 1'b1;
        mem_resp_valid_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_resp_valid_i = 1'b0;
        mem_resp_fault_i = 1'b0;

        wait_retire_pc0();
        #1;

        if (
            !faulted_o
            || memory_outstanding_o
            || memory_tag_error_o
            || request_pulses != 1
            || dut.scoreboard_vector_busy[0][3] !== 1'b0
        ) begin
            $fatal(1, "backend fault completion contract failed");
        end

        debug_context_i = '0;
        debug_scalar_reg_i = '0;
        debug_predicate_reg_i = PREDICATE_INDEX_W'(1);
        #1;
        if (
            !debug_context_valid_o
            || integer'(debug_pc_o) >= PROGRAM_WORDS
            || debug_exec_mask_o != '1
            || !debug_halted_o
            || debug_scalar_data_o != 32'd8
            || debug_predicate_data_o != 4'b1010
        ) begin
            $fatal(
                1,
                "backend fault debug contract mismatch valid=%0b pc=%0d exec=%b halted=%0b scalar=%0d pred=%b",
                debug_context_valid_o, debug_pc_o, debug_exec_mask_o,
                debug_halted_o, debug_scalar_data_o, debug_predicate_data_o
            );
        end
        if (
            engine_busy_o
            || valid_mask_o != 1'b1
            || ready_mask_o != 1'b0
            || halted_mask_o != 1'b1
            || rr_cursor_o != '0
            || !all_halted_o
        ) begin
            $fatal(
                1,
                "backend fault scheduler contract mismatch busy=%0b valid=%b ready=%b halted=%b rr=%0d all_halted=%0b",
                engine_busy_o, valid_mask_o, ready_mask_o, halted_mask_o,
                rr_cursor_o, all_halted_o
            );
        end

        $display("RTL7C_BACKEND_FAULT_COMPLETION=PASS");
        $display("RTL7C_MEMORY_EDGE_TB=PASS");

        $finish;
    end

endmodule
