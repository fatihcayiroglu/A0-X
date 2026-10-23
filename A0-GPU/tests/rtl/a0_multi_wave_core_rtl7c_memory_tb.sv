`timescale 1ns/1ps

module a0_multi_wave_core_rtl7c_memory_tb;

    localparam integer RESIDENT_WAVES = 2;
    localparam integer WAVE_SIZE = 8;
    localparam integer PHYSICAL_LANES = 4;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;
    localparam integer GLOBAL_MEMORY_WORDS = 512;
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
    localparam logic [7:0] OP_VLOADX  = 8'h54;
    localparam logic [7:0] OP_VSTOREX = 8'h55;
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

    integer lane;
    integer cycles;
    integer retire_count;
    integer request_count;
    integer pre_load_response_wave1_retires;
    integer pre_store_response_wave0_halts;

    logic saw_load_complete_retire;
    logic saw_store_complete_retire;
    logic saw_wave0_vadd_retire;
    logic saw_wave0_halt_retire;
    logic saw_wave1_vadd_retire;
    logic saw_wave1_sadd_retire;
    logic saw_wave1_halt_retire;


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
            request_count <= request_count + 1;
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
        input integer start_pc
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
            alloc_exec_mask = '1;
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
                    "vector mismatch ctx=%0d reg=%0d lane=%0d expected=%0d actual=%0d",
                    context_id,
                    reg_id,
                    lane_id,
                    expected,
                    debug_vector_data_o
                );
            end
        end
    endtask


    task automatic drive_load_response(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [WAVE_ID_W-1:0] context_id
    );
        begin
            @(negedge clk);
            mem_resp_wave_i = wave_id;
            mem_resp_context_i = context_id;
            mem_resp_fault_i = 1'b0;

            for (
                lane = 0;
                lane < WAVE_SIZE;
                lane = lane + 1
            ) begin
                mem_resp_rdata_i[lane] = 32'(1000 + lane);
            end

            mem_resp_valid_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mem_resp_valid_i = 1'b0;
        end
    endtask


    task automatic drive_store_response(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [WAVE_ID_W-1:0] context_id
    );
        begin
            @(negedge clk);
            mem_resp_wave_i = wave_id;
            mem_resp_context_i = context_id;
            mem_resp_fault_i = 1'b0;
            mem_resp_valid_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mem_resp_valid_i = 1'b0;
        end
    endtask


    task automatic sample_retirement;
        begin
            if (retire_valid_o) begin
                retire_count = retire_count + 1;

                if (
                    retire_wave_o == 1'd1
                    && retire_pc_o == 4'd8
                ) begin
                    saw_wave1_vadd_retire = 1'b1;
                    pre_load_response_wave1_retires =
                        pre_load_response_wave1_retires + 1;
                end

                if (
                    retire_wave_o == 1'd1
                    && retire_pc_o == 4'd9
                ) begin
                    saw_wave1_sadd_retire = 1'b1;
                    pre_load_response_wave1_retires =
                        pre_load_response_wave1_retires + 1;
                end

                if (
                    retire_wave_o == 1'd0
                    && retire_pc_o == 4'd0
                ) begin
                    saw_load_complete_retire = 1'b1;
                end

                if (
                    retire_wave_o == 1'd0
                    && retire_pc_o == 4'd1
                ) begin
                    saw_wave0_vadd_retire = 1'b1;
                end

                if (
                    retire_wave_o == 1'd0
                    && retire_pc_o == 4'd2
                ) begin
                    saw_wave0_halt_retire = 1'b1;
                    pre_store_response_wave0_halts =
                        pre_store_response_wave0_halts + 1;
                end

                if (
                    retire_wave_o == 1'd1
                    && retire_pc_o == 4'd10
                ) begin
                    saw_store_complete_retire = 1'b1;
                end

                if (
                    retire_wave_o == 1'd1
                    && retire_pc_o == 4'd11
                ) begin
                    saw_wave1_halt_retire = 1'b1;
                end
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

        clear_loaders();

        cycles = 0;
        retire_count = 0;
        request_count = 0;
        pre_load_response_wave1_retires = 0;
        pre_store_response_wave0_halts = 0;

        saw_load_complete_retire = 1'b0;
        saw_store_complete_retire = 1'b0;
        saw_wave0_vadd_retire = 1'b0;
        saw_wave0_halt_retire = 1'b0;
        saw_wave1_vadd_retire = 1'b0;
        saw_wave1_sadd_retire = 1'b0;
        saw_wave1_halt_retire = 1'b0;

        for (
            lane = 0;
            lane < WAVE_SIZE;
            lane = lane + 1
        ) begin
            mem_resp_rdata_i[lane] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        /*
         * Wave 0: load -> dependent add -> halt.
         * Wave 1: independent vector/scalar work -> store -> halt.
         */
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
                OP_VADD,
                4'h0,
                6'd4,
                6'd3,
                6'd2,
                6'd0,
                4'd0,
                24'd0
            )
        );
        write_program(
            2,
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

        write_program(
            8,
            encode_instruction(
                OP_VADD,
                4'h0,
                6'd6,
                6'd1,
                6'd5,
                6'd0,
                4'd0,
                24'd0
            )
        );
        write_program(
            9,
            encode_instruction(
                OP_SADD,
                4'h0,
                6'd3,
                6'd1,
                6'd2,
                6'd0,
                4'd0,
                24'd0
            )
        );
        write_program(
            10,
            encode_instruction(
                OP_VSTOREX,
                4'h1,
                6'd0,
                6'd0,
                6'd1,
                6'd2,
                4'd1,
                24'd0
            )
        );
        write_program(
            11,
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

        allocate_context(1'd0, 0);
        allocate_context(1'd1, 8);

        write_scalar(1'd0, 0, 32'd100);
        write_scalar(1'd1, 0, 32'd200);
        write_scalar(1'd1, 1, 32'd9);
        write_scalar(1'd1, 2, 32'd4);

        write_predicate(1'd0, 1, 8'b0011_1111);
        write_predicate(1'd1, 1, 8'b1111_1100);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(1'd0, 1, lane, 32'(lane));
            write_vector_lane(1'd0, 2, lane, 32'(10 + lane));
            write_vector_lane(1'd0, 3, lane, 32'(300 + lane));

            write_vector_lane(1'd1, 1, lane, 32'(lane));
            write_vector_lane(1'd1, 2, lane, 32'(5000 + lane));
            write_vector_lane(1'd1, 5, lane, 32'(100 + lane));
        end

        run_enable = 1'b1;

        /*
         * First backend request must be the predicated wave-0 load.
         */
        cycles = 0;
        while (!mem_req_valid_o && cycles < 300) begin
            @(posedge clk);
            #1;
            sample_retirement();
            cycles = cycles + 1;
        end

        if (!mem_req_valid_o) begin
            $fatal(1, "timed out waiting for VLOADX request");
        end

        if (
            mem_req_write_o
            || mem_req_wave_o != 1'd0
            || mem_req_context_o != 1'd0
            || mem_req_lane_mask_o != 8'b0011_1111
        ) begin
            $fatal(1, "wave-0 load request tag/mask mismatch");
        end

        for (lane = 0; lane < 6; lane = lane + 1) begin
            if (mem_req_addr_o[lane] != 32'(100 + lane)) begin
                $fatal(
                    1,
                    "wave-0 load address mismatch lane=%0d",
                    lane
                );
            end
        end

        if (!memory_outstanding_o) begin
            $fatal(1, "memory ownership not visible after load launch");
        end

        if (
            dut.scoreboard_vector_busy[0][3] !== 1'b1
            || dut.scoreboard_vector_busy[1][3] !== 1'b0
        ) begin
            $fatal(1, "wave-qualified load scoreboard ownership mismatch");
        end

        $display("RTL7C_WAVE_TAGGED_LOAD_REQUEST=PASS");
        $display("RTL7C_LOAD_SCOREBOARD_HOLD=PASS");

        /*
         * Do not answer the load yet. Wave 1 must continue making progress.
         */
        cycles = 0;
        while (
            !(saw_wave1_vadd_retire && saw_wave1_sadd_retire)
            && cycles < 300
        ) begin
            @(posedge clk);
            #1;
            sample_retirement();
            cycles = cycles + 1;
        end

        if (!(saw_wave1_vadd_retire && saw_wave1_sadd_retire)) begin
            $fatal(1, "wave 1 failed to retire while wave 0 waited on memory");
        end

        if (pre_load_response_wave1_retires < 2) begin
            $fatal(1, "insufficient latency hiding before load response");
        end

        debug_context_i = 1'd0;
        #1;
        if (
            debug_pc_o != 4'd1
            || ready_mask_o[0] !== 1'b0
        ) begin
            $fatal(1, "wave 0 did not yield with advanced PC + memory wait");
        end

        $display("RTL7C_LOAD_LATENCY_HIDING=PASS");
        $display("RTL7C_PER_WAVE_MEMORY_WAIT=PASS");

        /*
         * Send one deliberately wrong response tag. It must be rejected
         * without consuming the outstanding request.
         */
        @(negedge clk);
        mem_resp_wave_i = 1'd1;
        mem_resp_context_i = 1'd1;
        mem_resp_fault_i = 1'b0;
        mem_resp_valid_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_resp_valid_i = 1'b0;
        #1;

        if (
            !memory_tag_error_o
            || !memory_outstanding_o
        ) begin
            $fatal(1, "wrong response tag was not rejected");
        end

        $display("RTL7C_RESPONSE_TAG_GUARD=PASS");

        /*
         * Pause while the load is outstanding, then deliver the correct
         * response during the pause. Ownership/refill state must survive.
         */
        run_enable = 1'b0;
        repeat (2) @(posedge clk);

        if (!memory_outstanding_o) begin
            $fatal(1, "pause lost outstanding memory ownership");
        end

        drive_load_response(1'd0, 1'd0);

        repeat (2) @(posedge clk);
        if (!memory_outstanding_o) begin
            $fatal(1, "paused response/refill ownership disappeared");
        end

        $display("RTL7C_PAUSE_PRESERVES_MEMORY_OWNER=PASS");

        run_enable = 1'b1;

        /*
         * Load completion is architectural only after context-VRF refill.
         */
        cycles = 0;
        while (!saw_load_complete_retire && cycles < 300) begin
            @(posedge clk);
            #1;
            sample_retirement();
            cycles = cycles + 1;
        end

        if (!saw_load_complete_retire) begin
            $fatal(1, "load did not retire after refill");
        end

        if (dut.scoreboard_vector_busy[0][3] !== 1'b0) begin
            $fatal(1, "load destination scoreboard was not released");
        end

        $display("RTL7C_CONTEXTED_LOAD_REFILL=PASS");
        $display("RTL7C_LOAD_SCOREBOARD_RELEASE=PASS");

        /*
         * Wave 0's dependent VADD must see the refilled V3 values. After that
         * wave 1 is allowed to launch its store because the backend is free.
         */
        cycles = 0;
        while (
            !(saw_wave0_vadd_retire && mem_req_valid_o)
            && cycles < 400
        ) begin
            @(posedge clk);
            #1;
            sample_retirement();
            cycles = cycles + 1;
        end

        if (!saw_wave0_vadd_retire) begin
            $fatal(1, "dependent wave-0 VADD never retired");
        end

        if (!mem_req_valid_o) begin
            /*
             * The request pulse may have occurred one or more cycles after
             * VADD retirement. Continue looking without losing retirement
             * bookkeeping.
             */
            cycles = 0;
            while (!mem_req_valid_o && cycles < 200) begin
                @(posedge clk);
                #1;
                sample_retirement();
                cycles = cycles + 1;
            end
        end

        if (!mem_req_valid_o) begin
            $fatal(1, "timed out waiting for VSTOREX request");
        end

        if (
            !mem_req_write_o
            || mem_req_wave_o != 1'd1
            || mem_req_context_o != 1'd1
            || mem_req_lane_mask_o != 8'b1111_1100
        ) begin
            $fatal(1, "wave-1 store request tag/mask mismatch");
        end

        for (lane = 2; lane < WAVE_SIZE; lane = lane + 1) begin
            if (
                mem_req_addr_o[lane] != 32'(200 + lane)
                || mem_req_wdata_o[lane] != 32'(5000 + lane)
            ) begin
                $fatal(
                    1,
                    "wave-1 store payload mismatch lane=%0d",
                    lane
                );
            end
        end

        $display("RTL7C_WAVE_TAGGED_STORE_REQUEST=PASS");
        $display("RTL7C_CONTEXTED_STORE_DATA=PASS");

        /*
         * Hold store response. Wave 0's HALT must still retire while wave 1
         * is memory_waiting.
         */
        cycles = 0;
        while (!saw_wave0_halt_retire && cycles < 200) begin
            @(posedge clk);
            #1;
            sample_retirement();
            cycles = cycles + 1;
        end

        if (!saw_wave0_halt_retire) begin
            $fatal(1, "wave 0 failed to retire HALT while store waited");
        end

        if (pre_store_response_wave0_halts < 1) begin
            $fatal(1, "store latency hiding was not observed");
        end

        $display("RTL7C_STORE_LATENCY_HIDING=PASS");

        drive_store_response(1'd1, 1'd1);

        cycles = 0;
        while (
            !(saw_store_complete_retire && saw_wave1_halt_retire)
            && cycles < 300
        ) begin
            @(posedge clk);
            #1;
            sample_retirement();
            cycles = cycles + 1;
        end

        if (
            !saw_store_complete_retire
            || !saw_wave1_halt_retire
        ) begin
            $fatal(1, "store completion / wave-1 HALT missing");
        end

        if (!all_halted_o) begin
            $fatal(1, "both resident waves did not halt");
        end

        if (faulted_o) begin
            $fatal(1, "unexpected architectural fault in RTL7C memory test");
        end

        if (request_count != 2) begin
            $fatal(1, "unexpected memory request count=%0d", request_count);
        end

        /*
         * Verify load lane mask semantics and dependent ALU consumption.
         */
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (lane < 6) begin
                expect_vector_lane(
                    1'd0,
                    3,
                    lane,
                    32'(1000 + lane)
                );
                expect_vector_lane(
                    1'd0,
                    4,
                    lane,
                    32'(1010 + (2 * lane))
                );
            end else begin
                expect_vector_lane(
                    1'd0,
                    3,
                    lane,
                    32'(300 + lane)
                );
                expect_vector_lane(
                    1'd0,
                    4,
                    lane,
                    32'(310 + (2 * lane))
                );
            end

            expect_vector_lane(
                1'd1,
                6,
                lane,
                32'(100 + (2 * lane))
            );
        end

        debug_context_i = 1'd1;
        debug_scalar_reg_i = SCALAR_REG_INDEX_W'(3);
        debug_predicate_reg_i = PREDICATE_INDEX_W'(1);
        #1;

        if (
            !debug_context_valid_o
            || debug_pc_o != 4'd12
            || debug_exec_mask_o != '1
            || !debug_halted_o
            || debug_scalar_data_o != 32'd13
            || debug_predicate_data_o != 8'b1111_1100
        ) begin
            $fatal(
                1,
                "wave-1 final architectural state mismatch valid=%0b pc=%0d exec=%b halt=%0b scalar=%0d pred=%b",
                debug_context_valid_o,
                debug_pc_o,
                debug_exec_mask_o,
                debug_halted_o,
                debug_scalar_data_o,
                debug_predicate_data_o
            );
        end
        if (
            engine_busy_o
            || valid_mask_o != 2'b11
            || ready_mask_o != 2'b00
            || halted_mask_o != 2'b11
            || integer'(rr_cursor_o) >= RESIDENT_WAVES
        ) begin
            $fatal(
                1,
                "final scheduler state mismatch busy=%0b valid=%b ready=%b halted=%b rr=%0d",
                engine_busy_o, valid_mask_o, ready_mask_o, halted_mask_o, rr_cursor_o
            );
        end

        $display("RTL7C_MEMORY_CONTEXT_ISOLATION=PASS");
        $display("RTL7C_DEPENDENT_LOAD_USE=PASS");
        $display("RTL7C_SINGLE_OUTSTANDING_CONTRACT=PASS");
        $display(
            "RTL7C_LIVE_MEMORY_TB=PASS retirements=%0d requests=%0d",
            retire_count,
            request_count
        );

        $finish;
    end

endmodule
