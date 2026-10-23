`timescale 1ns/1ps

module a0_multi_wave_core_rtl8b_mshr_tb;

    localparam integer RESIDENT_WAVES = 3;
    localparam integer WAVE_SIZE = 8;
    localparam integer PHYSICAL_LANES = 4;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;
    localparam integer GLOBAL_MEMORY_WORDS = 512;
    localparam integer PROGRAM_WORDS = 16;
    localparam integer MSHR_COUNT = 2;
    localparam integer MSHR_LINE_WORDS = 8;

    localparam integer WAVE_ID_W = 2;
    localparam integer PC_W = 4;
    localparam integer VECTOR_REG_INDEX_W = 3;
    localparam integer SCALAR_REG_INDEX_W = 3;
    localparam integer PREDICATE_INDEX_W = 2;
    localparam integer MSHR_ENTRY_W = 1;
    localparam integer MSHR_LINE_ADDR_W = 29;
    localparam integer MSHR_OCCUPANCY_W = 2;

    localparam logic [7:0] OP_VADD   = 8'h01;
    localparam logic [7:0] OP_VLOADX = 8'h54;
    localparam logic [7:0] OP_HALT   = 8'hFF;

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

    logic mshr_mem_req_valid_o;
    logic mshr_mem_req_ready_i;
    logic [MSHR_ENTRY_W-1:0] mshr_mem_req_entry_o;
    logic [MSHR_LINE_ADDR_W-1:0] mshr_mem_req_line_addr_o;

    logic mshr_mem_resp_valid_i;
    logic [MSHR_ENTRY_W-1:0] mshr_mem_resp_entry_i;
    logic [MSHR_LINE_ADDR_W-1:0] mshr_mem_resp_line_addr_i;
    logic mshr_mem_resp_fault_i;
    logic [31:0] mshr_mem_resp_line_data_i [0:MSHR_LINE_WORDS-1];

    logic [MSHR_OCCUPANCY_W-1:0] mshr_occupancy_o;
    logic mshr_full_o;
    logic mshr_merge_event_o;
    logic [RESIDENT_WAVES-1:0] mshr_active_wave_mask_o;
    logic mshr_tag_error_o;

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
    integer word_index;
    integer miss_count;
    integer merge_count;
    integer retire_count;
    integer cycle_count;

    logic [MSHR_ENTRY_W-1:0] entry_line10;
    logic [MSHR_ENTRY_W-1:0] entry_line20;
    logic saw_wave1_load_retire;
    logic saw_wave1_add_retire;
    logic saw_wave1_halt_retire;
    logic saw_wave0_load_retire;
    logic saw_wave2_load_retire;


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
        .GLOBAL_MEMORY_WORDS(GLOBAL_MEMORY_WORDS),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .ENABLE_LOAD_MSHR(1),
        .MSHR_COUNT(MSHR_COUNT),
        .MSHR_LINE_WORDS(MSHR_LINE_WORDS)
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

        .mshr_mem_req_valid_o(mshr_mem_req_valid_o),
        .mshr_mem_req_ready_i(mshr_mem_req_ready_i),
        .mshr_mem_req_entry_o(mshr_mem_req_entry_o),
        .mshr_mem_req_line_addr_o(mshr_mem_req_line_addr_o),
        .mshr_mem_resp_valid_i(mshr_mem_resp_valid_i),
        .mshr_mem_resp_entry_i(mshr_mem_resp_entry_i),
        .mshr_mem_resp_line_addr_i(mshr_mem_resp_line_addr_i),
        .mshr_mem_resp_fault_i(mshr_mem_resp_fault_i),
        .mshr_mem_resp_line_data_i(mshr_mem_resp_line_data_i),
        .mshr_occupancy_o(mshr_occupancy_o),
        .mshr_full_o(mshr_full_o),
        .mshr_merge_event_o(mshr_merge_event_o),
        .mshr_active_wave_mask_o(mshr_active_wave_mask_o),
        .mshr_tag_error_o(mshr_tag_error_o),

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
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if (mem_req_valid_o) begin
                for (int req_lane = 0; req_lane < WAVE_SIZE; req_lane++) begin
                    $display(
                        "unexpected legacy request lane=%0d addr=%0d data=%0d",
                        req_lane, mem_req_addr_o[req_lane], mem_req_wdata_o[req_lane]
                    );
                end
                $fatal(
                    1,
                    "VLOADX incorrectly used legacy request path write=%0b wave=%0d context=%0d lanes=%b",
                    mem_req_write_o, mem_req_wave_o, mem_req_context_o, mem_req_lane_mask_o
                );
            end
            if (mshr_merge_event_o) begin
                merge_count <= merge_count + 1;
            end
        end
    end

    /*
     * retire_* are registered outputs updated with nonblocking assignments on
     * the rising edge. Sample them on the falling edge so the emitted
     * {valid,wave,pc} tuple is stable and cannot be observed one event late.
     */
    always @(negedge clk) begin
        if (!rst_n) begin
            saw_wave1_load_retire <= 1'b0;
            saw_wave1_add_retire <= 1'b0;
            saw_wave1_halt_retire <= 1'b0;
            saw_wave0_load_retire <= 1'b0;
            saw_wave2_load_retire <= 1'b0;
        end else if (retire_valid_o) begin
            retire_count <= retire_count + 1;
            $display(
                "RTL8B_RETIRE_TRACE count=%0d wave=%0d pc=%0d halted=%b ready=%b",
                retire_count,
                retire_wave_o,
                retire_pc_o,
                halted_mask_o,
                ready_mask_o
            );
            if (retire_wave_o == 2'd1 && retire_pc_o == 4'd4) begin
                saw_wave1_load_retire <= 1'b1;
            end
            if (retire_wave_o == 2'd1 && retire_pc_o == 4'd5) begin
                saw_wave1_add_retire <= 1'b1;
            end
            if (retire_wave_o == 2'd1 && retire_pc_o == 4'd6) begin
                saw_wave1_halt_retire <= 1'b1;
            end
            if (retire_wave_o == 2'd0 && retire_pc_o == 4'd0) begin
                saw_wave0_load_retire <= 1'b1;
            end
            if (retire_wave_o == 2'd2 && retire_pc_o == 4'd8) begin
                saw_wave2_load_retire <= 1'b1;
            end
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
                $fatal(1, "program address out of range: %0d", address);
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
                $fatal(1, "allocation PC out of range: %0d", start_pc);
            end
            @(negedge clk);
            clear_loaders();
            alloc_valid = 1'b1;
            alloc_wave_id = wave_id;
            alloc_pc = PC_W'(start_pc);
            alloc_exec_mask = 8'h0F;
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
                $fatal(1, "scalar register out of range: %0d", reg_id);
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
        input logic [PREDICATE_INDEX_W-1:0] reg_id,
        input logic [WAVE_SIZE-1:0] value
    );
        begin
            @(negedge clk);
            clear_loaders();
            predicate_we = 1'b1;
            predicate_wwave = wave_id;
            predicate_wreg = reg_id;
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
                $fatal(1, "vector register out of range: %0d", reg_id);
            end
            if (lane_id < 0 || lane_id >= WAVE_SIZE) begin
                $fatal(1, "vector lane out of range: %0d", lane_id);
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


    /*
     * Keep the physical miss backend stalled while the three logical loads
     * allocate/merge. Then accept exactly one downstream miss per ready pulse
     * and capture its {entry,line} tag before the accepting posedge.
     */
    task automatic accept_mshr_miss;
        integer timeout;
        logic [MSHR_ENTRY_W-1:0] captured_entry;
        logic [MSHR_LINE_ADDR_W-1:0] captured_line;
        begin
            mshr_mem_req_ready_i = 1'b0;
            timeout = 0;

            while (!mshr_mem_req_valid_o && timeout < 128) begin
                @(negedge clk);
                timeout = timeout + 1;
            end

            if (!mshr_mem_req_valid_o) begin
                $fatal(
                    1,
                    "physical miss request timeout miss=%0d occupancy=%0d full=%0b active=%b",
                    miss_count,
                    mshr_occupancy_o,
                    mshr_full_o,
                    mshr_active_wave_mask_o
                );
            end

            captured_entry = mshr_mem_req_entry_o;
            captured_line = mshr_mem_req_line_addr_o;

            case (integer'(captured_line))
                10: entry_line10 = captured_entry;
                20: entry_line20 = captured_entry;
                default: begin
                    $fatal(
                        1,
                        "unexpected deterministic live MSHR line=%0d entry=%0d",
                        captured_line,
                        captured_entry
                    );
                end
            endcase

            /* Exactly one accepting posedge for this physical miss. */
            mshr_mem_req_ready_i = 1'b1;
            @(posedge clk);
            #1;
            miss_count = miss_count + 1;

            @(negedge clk);
            mshr_mem_req_ready_i = 1'b0;
        end
    endtask


    task automatic send_mshr_response(
        input logic [MSHR_ENTRY_W-1:0] entry,
        input logic [MSHR_LINE_ADDR_W-1:0] line_addr,
        input integer data_base
    );
        begin
            @(negedge clk);
            mshr_mem_resp_valid_i = 1'b1;
            mshr_mem_resp_entry_i = entry;
            mshr_mem_resp_line_addr_i = line_addr;
            mshr_mem_resp_fault_i = 1'b0;
            for (
                word_index = 0;
                word_index < MSHR_LINE_WORDS;
                word_index = word_index + 1
            ) begin
                mshr_mem_resp_line_data_i[word_index] = data_base + word_index;
            end
            #1;
            if (mshr_tag_error_o) begin
                $fatal(1, "correct MSHR response rejected before handshake line=%0d", line_addr);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            mshr_mem_resp_valid_i = 1'b0;
        end
    endtask


    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        run_enable = 1'b0;
        clear_loaders();

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

        mshr_mem_req_ready_i = 1'b0;
        mshr_mem_resp_valid_i = 1'b0;
        mshr_mem_resp_entry_i = '0;
        mshr_mem_resp_line_addr_i = '0;
        mshr_mem_resp_fault_i = 1'b0;

        policy_override_valid_i = 1'b0;
        policy_override_wave_i = '0;
        debug_vector_context_i = '0;
        debug_vector_reg_i = '0;
        debug_vector_lane_i = '0;
        debug_context_i = '0;
        debug_scalar_reg_i = '0;
        debug_predicate_reg_i = '0;

        miss_count = 0;
        merge_count = 0;
        retire_count = 0;
        cycle_count = 0;
        entry_line10 = '0;
        entry_line20 = '0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            mem_resp_rdata_i[lane] = '0;
        end
        for (
            word_index = 0;
            word_index < MSHR_LINE_WORDS;
            word_index = word_index + 1
        ) begin
            mshr_mem_resp_line_data_i[word_index] = '0;
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        /* Each wave: VLOADX V3 -> VADD V4,V3,V2 -> HALT. */
        write_program(0, encode_instruction(OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0));
        write_program(1, encode_instruction(OP_VADD,   4'h0, 6'd4, 6'd3, 6'd2, 6'd0, 4'd0, 24'd0));
        write_program(2, encode_instruction(OP_HALT,   4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0));

        write_program(4, encode_instruction(OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0));
        write_program(5, encode_instruction(OP_VADD,   4'h0, 6'd4, 6'd3, 6'd2, 6'd0, 4'd0, 24'd0));
        write_program(6, encode_instruction(OP_HALT,   4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0));

        write_program(8, encode_instruction(OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0));
        write_program(9, encode_instruction(OP_VADD,   4'h0, 6'd4, 6'd3, 6'd2, 6'd0, 4'd0, 24'd0));
        write_program(10, encode_instruction(OP_HALT,  4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        allocate_context(2'd2, 8);

        write_scalar(2'd0, 0, 32'd80);   // line 10
        write_scalar(2'd1, 0, 32'd160);  // line 20
        write_scalar(2'd2, 0, 32'd80);   // line 10 again
        /* Predicate register 1 is unused by the program; seed it only so the
         * final debug-port contract has deterministic payload provenance. */
        write_predicate(2'd0, PREDICATE_INDEX_W'(1), 8'hA5);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
            write_vector_lane(2'd2, 1, lane, 32'(4 + lane));

            write_vector_lane(2'd0, 2, lane, 32'd10);
            write_vector_lane(2'd1, 2, lane, 32'd20);
            write_vector_lane(2'd2, 2, lane, 32'd30);

            write_vector_lane(2'd0, 3, lane, 32'd3000);
            write_vector_lane(2'd1, 3, lane, 32'd3100);
            write_vector_lane(2'd2, 3, lane, 32'd3200);
            write_vector_lane(2'd0, 4, lane, 32'd4000);
            write_vector_lane(2'd1, 4, lane, 32'd4100);
            write_vector_lane(2'd2, 4, lane, 32'd4200);
        end

        run_enable = 1'b1;

        /*
         * Hold the backend closed until all three logical loads are resident:
         * line10 + line20 consume the two physical MSHRs and wave2 merges into
         * line10 while the table is full.
         */
        begin : wait_three_loads
            integer timeout;
            timeout = 0;
            while (
                !(mshr_occupancy_o == MSHR_OCCUPANCY_W'(MSHR_COUNT)
                  && mshr_full_o
                  && mshr_active_wave_mask_o == 3'b111
                  && merge_count >= 1)
                && timeout < 800
            ) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 800) begin
                $fatal(
                    1,
                    "three-load MSHR setup timeout miss=%0d occupancy=%0d full=%0b active=%b merge=%0d",
                    miss_count,
                    mshr_occupancy_o,
                    mshr_full_o,
                    mshr_active_wave_mask_o,
                    merge_count
                );
            end
        end

        /*
         * The backend has accepted nothing yet, so the two physical entries
         * must still be live and full. Now accept exactly two physical misses
         * one at a time and capture their stable downstream tags.
         */
        @(negedge clk);
        if (mshr_occupancy_o != MSHR_OCCUPANCY_W'(MSHR_COUNT) || !mshr_full_o) begin
            $fatal(
                1,
                "MSHR_COUNT=2 state mismatch occupancy=%0d full=%0b miss=%0d active=%b merge=%0d",
                mshr_occupancy_o,
                mshr_full_o,
                miss_count,
                mshr_active_wave_mask_o,
                merge_count
            );
        end
        if (miss_count != 0) begin
            $fatal(1, "backend accepted a miss while ready was held low miss=%0d", miss_count);
        end

        accept_mshr_miss();
        accept_mshr_miss();

        if (miss_count != 2) begin
            $fatal(1, "expected exactly two physical misses miss=%0d", miss_count);
        end
        if (entry_line10 == entry_line20) begin
            $fatal(
                1,
                "two unique live misses captured the same entry line10=%0d line20=%0d",
                entry_line10,
                entry_line20
            );
        end
        if (mshr_mem_req_valid_o) begin
            $fatal(
                1,
                "unexpected third physical miss line=%0d entry=%0d",
                mshr_mem_req_line_addr_o,
                mshr_mem_req_entry_o
            );
        end
        if (ready_mask_o != 0) begin
            $fatal(1, "memory-waiting waves remained scheduler-ready");
        end
        if (
            dut.scoreboard_vector_busy[0][3] !== 1'b1
            || dut.scoreboard_vector_busy[1][3] !== 1'b1
            || dut.scoreboard_vector_busy[2][3] !== 1'b1
        ) begin
            $fatal(1, "load destination scoreboard did not remain reserved");
        end

        $display("RTL8B_TWO_MSHR_THREE_LOADS=PASS");
        $display("RTL8B_SAME_LINE_MERGE=PASS");
        $display("RTL8B_LOAD_SCOREBOARD_HOLD=PASS");

        /*
         * Return wave1's unique line while run_enable=0. The line response may
         * be buffered, but architectural refill/retirement must wait for resume.
         */
        run_enable = 1'b0;
        send_mshr_response(entry_line20, 29'd20, 2000);
        repeat (8) @(posedge clk);

        if (retire_count != 0 || mshr_active_wave_mask_o != 3'b111) begin
            $fatal(1, "pause consumed architectural load completion");
        end
        $display("RTL8B_PAUSE_BUFFERS_MSHR_RESPONSE=PASS");

        run_enable = 1'b1;

        /* Wave1 must fully finish before line10 is returned. */
        begin : wait_wave1_finish
            integer timeout;
            timeout = 0;
            while (!saw_wave1_halt_retire && timeout < 500) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!saw_wave1_halt_retire) begin
                $fatal(
                    1,
                    "wave1 did not finish before line10 response pc1=%0d halted=%0b memwait=%0b sb_v3=%0b retire=%0d",
                    dut.context_pc_by_wave[1],
                    halted_mask_o[1],
                    dut.memory_waiting_mask[1],
                    dut.scoreboard_vector_busy[1][3],
                    retire_count
                );
            end
        end

        if (!saw_wave1_load_retire || !saw_wave1_add_retire) begin
            $fatal(1, "wave1 retirement chain incomplete");
        end
        if (saw_wave0_load_retire || saw_wave2_load_retire) begin
            $fatal(1, "line10 owners retired before their response");
        end
        if (mshr_active_wave_mask_o != 3'b101) begin
            $fatal(1, "wave1 load ownership did not clear independently");
        end
        if (
            dut.scoreboard_vector_busy[1][3] !== 1'b0
            || dut.scoreboard_vector_busy[0][3] !== 1'b1
            || dut.scoreboard_vector_busy[2][3] !== 1'b1
        ) begin
            $fatal(1, "out-of-order scoreboard release mismatch");
        end

        for (lane = 0; lane < 4; lane = lane + 1) begin
            expect_vector_lane(2'd1, 3, lane, 32'(2000 + lane));
            expect_vector_lane(2'd1, 4, lane, 32'(2020 + lane));
        end
        for (lane = 4; lane < WAVE_SIZE; lane = lane + 1) begin
            expect_vector_lane(2'd1, 3, lane, 32'd3100);
            expect_vector_lane(2'd1, 4, lane, 32'd4100);
        end

        $display("RTL8B_OUT_OF_ORDER_WAVE_COMPLETION=PASS");
        $display("RTL8B_MEMORY_LATENCY_HIDING=PASS");

        /* One line response fans out to wave0 and wave2 waiters. */
        send_mshr_response(entry_line10, 29'd10, 1000);

        begin : wait_all_halted
            integer timeout;
            timeout = 0;
            while (!all_halted_o && timeout < 800) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!all_halted_o) begin
                $fatal(1, "all waves did not halt after merged response");
            end
        end

        if (miss_count != 2 || merge_count != 1) begin
            $fatal(
                1,
                "unexpected physical traffic miss=%0d merge=%0d",
                miss_count,
                merge_count
            );
        end
        if (retire_count != 9) begin
            $fatal(1, "expected 9 architectural retirements got=%0d", retire_count);
        end
        if (
            memory_outstanding_o
            || mshr_occupancy_o != 0
            || mshr_active_wave_mask_o != 0
        ) begin
            $fatal(1, "MSHR/load ownership did not fully drain");
        end
        if (faulted_o || memory_tag_error_o || mshr_tag_error_o) begin
            $fatal(1, "fault/tag error asserted on correct live flow");
        end

        for (lane = 0; lane < 4; lane = lane + 1) begin
            expect_vector_lane(2'd0, 3, lane, 32'(1000 + lane));
            expect_vector_lane(2'd0, 4, lane, 32'(1010 + lane));
            expect_vector_lane(2'd2, 3, lane, 32'(1004 + lane));
            expect_vector_lane(2'd2, 4, lane, 32'(1034 + lane));
        end
        for (lane = 4; lane < WAVE_SIZE; lane = lane + 1) begin
            expect_vector_lane(2'd0, 3, lane, 32'd3000);
            expect_vector_lane(2'd0, 4, lane, 32'd4000);
            expect_vector_lane(2'd2, 3, lane, 32'd3200);
            expect_vector_lane(2'd2, 4, lane, 32'd4200);
        end

        if (
            dut.scoreboard_vector_busy[0][3] !== 1'b0
            || dut.scoreboard_vector_busy[1][3] !== 1'b0
            || dut.scoreboard_vector_busy[2][3] !== 1'b0
        ) begin
            $fatal(1, "load scoreboards not empty at final drain");
        end

        debug_context_i = 2'd0;
        debug_scalar_reg_i = SCALAR_REG_INDEX_W'(0);
        debug_predicate_reg_i = PREDICATE_INDEX_W'(1);
        #1;
        if (
            !debug_context_valid_o
            || debug_pc_o != PC_W'(3)
            || debug_exec_mask_o != 8'h0F
            || !debug_halted_o
            || debug_scalar_data_o != 32'd80
            || debug_predicate_data_o != 8'hA5
        ) begin
            $fatal(
                1,
                "final debug contract mismatch valid=%0b pc=%0d exec=%b halted=%0b scalar=%0d pred=%b",
                debug_context_valid_o, debug_pc_o, debug_exec_mask_o,
                debug_halted_o, debug_scalar_data_o, debug_predicate_data_o
            );
        end
        if (
            engine_busy_o
            || valid_mask_o != 3'b111
            || ready_mask_o != 3'b000
            || halted_mask_o != 3'b111
            || integer'(rr_cursor_o) >= RESIDENT_WAVES
        ) begin
            $fatal(
                1,
                "final scheduler contract mismatch busy=%0b valid=%b ready=%b halted=%b rr=%0d",
                engine_busy_o, valid_mask_o, ready_mask_o, halted_mask_o, rr_cursor_o
            );
        end

        $display("RTL8B_MERGED_RESPONSE_FANOUT=PASS");
        $display("RTL8B_CONTEXT_QUALIFIED_REFILL=PASS");
        $display("RTL8B_DEPENDENT_LOAD_USE=PASS");
        $display("RTL8B_FINAL_SCOREBOARD_DRAIN=PASS");
        $display(
            "RTL8B_LIVE_MSHR_CORE_TB=PASS misses=%0d merges=%0d retirements=%0d cycles=%0d",
            miss_count,
            merge_count,
            retire_count,
            cycle_count
        );
        $finish;
    end

endmodule
