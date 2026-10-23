`timescale 1ns/1ps

module a0_multi_wave_core_rtl8c_load_bypass_tb;

    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_SIZE = 4;
    localparam integer PHYSICAL_LANES = 2;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;
    localparam integer GLOBAL_MEMORY_WORDS = 256;
    localparam integer PROGRAM_WORDS = 16;
    localparam integer MSHR_COUNT = 2;
    localparam integer MSHR_LINE_WORDS = 8;
    localparam integer STORE_QUEUE_DEPTH = 2;

    localparam integer WAVE_ID_W = 2;
    localparam integer PC_W = 4;
    localparam integer VECTOR_REG_INDEX_W = 3;
    localparam integer SCALAR_REG_INDEX_W = 3;
    localparam integer PREDICATE_INDEX_W = 2;
    localparam integer MSHR_ENTRY_W = 1;
    localparam integer MSHR_LINE_ADDR_W = 29;
    localparam integer MSHR_OCCUPANCY_W = 2;

    localparam logic [7:0] OP_VLOADX = 8'h54;
    localparam logic [7:0] OP_VSTOREX = 8'h55;
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
    integer rtl8c_store_req_count;
    logic [RESIDENT_WAVES-1:0] tb_allocated_mask;


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
            opcode, flags, dst, src0, src1, src2, pred, imm24
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
        .MSHR_LINE_WORDS(MSHR_LINE_WORDS),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .run_enable(run_enable),
        .program_we(program_we), .program_waddr(program_waddr), .program_wdata(program_wdata),
        .alloc_valid(alloc_valid), .alloc_wave_id(alloc_wave_id), .alloc_ready(alloc_ready),
        .alloc_pc(alloc_pc), .alloc_exec_mask(alloc_exec_mask), .alloc_vrf_context_id(alloc_vrf_context_id),
        .release_valid(release_valid), .release_wave_id(release_wave_id),
        .scalar_we(scalar_we), .scalar_wwave(scalar_wwave), .scalar_wreg(scalar_wreg), .scalar_wdata(scalar_wdata),
        .predicate_we(predicate_we), .predicate_wwave(predicate_wwave), .predicate_wreg(predicate_wreg), .predicate_wdata(predicate_wdata),
        .vector_we(vector_we), .vector_wcontext(vector_wcontext), .vector_wreg(vector_wreg), .vector_wlane(vector_wlane), .vector_wdata(vector_wdata),
        .mem_req_valid_o(mem_req_valid_o), .mem_req_write_o(mem_req_write_o),
        .mem_req_wave_o(mem_req_wave_o), .mem_req_context_o(mem_req_context_o),
        .mem_req_lane_mask_o(mem_req_lane_mask_o), .mem_req_addr_o(mem_req_addr_o), .mem_req_wdata_o(mem_req_wdata_o),
        .mem_resp_valid_i(mem_resp_valid_i), .mem_resp_wave_i(mem_resp_wave_i), .mem_resp_context_i(mem_resp_context_i),
        .mem_resp_fault_i(mem_resp_fault_i), .mem_resp_rdata_i(mem_resp_rdata_i),
        .mshr_mem_req_valid_o(mshr_mem_req_valid_o), .mshr_mem_req_ready_i(mshr_mem_req_ready_i),
        .mshr_mem_req_entry_o(mshr_mem_req_entry_o), .mshr_mem_req_line_addr_o(mshr_mem_req_line_addr_o),
        .mshr_mem_resp_valid_i(mshr_mem_resp_valid_i), .mshr_mem_resp_entry_i(mshr_mem_resp_entry_i),
        .mshr_mem_resp_line_addr_i(mshr_mem_resp_line_addr_i), .mshr_mem_resp_fault_i(mshr_mem_resp_fault_i),
        .mshr_mem_resp_line_data_i(mshr_mem_resp_line_data_i), .mshr_occupancy_o(mshr_occupancy_o),
        .mshr_full_o(mshr_full_o), .mshr_merge_event_o(mshr_merge_event_o),
        .mshr_active_wave_mask_o(mshr_active_wave_mask_o), .mshr_tag_error_o(mshr_tag_error_o),
        .memory_outstanding_o(memory_outstanding_o), .memory_tag_error_o(memory_tag_error_o),
        .policy_override_valid_i(policy_override_valid_i), .policy_override_wave_i(policy_override_wave_i),
        .debug_vector_context_i(debug_vector_context_i), .debug_vector_reg_i(debug_vector_reg_i),
        .debug_vector_lane_i(debug_vector_lane_i), .debug_vector_data_o(debug_vector_data_o),
        .debug_context_i(debug_context_i), .debug_scalar_reg_i(debug_scalar_reg_i),
        .debug_predicate_reg_i(debug_predicate_reg_i), .debug_context_valid_o(debug_context_valid_o),
        .debug_pc_o(debug_pc_o), .debug_exec_mask_o(debug_exec_mask_o), .debug_halted_o(debug_halted_o),
        .debug_scalar_data_o(debug_scalar_data_o), .debug_predicate_data_o(debug_predicate_data_o),
        .retire_valid_o(retire_valid_o), .retire_wave_o(retire_wave_o), .retire_pc_o(retire_pc_o),
        .engine_busy_o(engine_busy_o), .faulted_o(faulted_o), .valid_mask_o(valid_mask_o),
        .ready_mask_o(ready_mask_o), .halted_mask_o(halted_mask_o), .rr_cursor_o(rr_cursor_o),
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

    task automatic write_program(input integer address, input logic [63:0] word);
        begin
            if (address < 0 || address >= PROGRAM_WORDS) begin
                $fatal(1, "program address out of range: %0d", address);
            end
            @(negedge clk); clear_loaders(); program_we = 1'b1;
            program_waddr = PC_W'(address); program_wdata = word;
            @(posedge clk); #1; @(negedge clk); program_we = 1'b0;
        end
    endtask

    task automatic allocate_context(input logic [WAVE_ID_W-1:0] wave, input integer start_pc);
        begin
            if (start_pc < 0 || start_pc >= PROGRAM_WORDS) begin
                $fatal(1, "allocation PC out of range: %0d", start_pc);
            end
            @(negedge clk); clear_loaders(); alloc_valid = 1'b1;
            alloc_wave_id = wave; alloc_pc = PC_W'(start_pc);
            alloc_exec_mask = '1; alloc_vrf_context_id = wave; #1;
            if (!alloc_ready) $fatal(1, "allocation not ready wave=%0d", wave);
            @(posedge clk); #1;
            tb_allocated_mask[wave] = 1'b1;
            @(negedge clk); alloc_valid = 1'b0;
        end
    endtask

    task automatic write_scalar(input logic [WAVE_ID_W-1:0] wave, input integer reg_id, input logic [31:0] value);
        begin
            if (reg_id < 0 || reg_id >= SCALAR_REG_COUNT) begin
                $fatal(1, "scalar register out of range: %0d", reg_id);
            end
            @(negedge clk); clear_loaders(); scalar_we = 1'b1;
            scalar_wwave = wave; scalar_wreg = SCALAR_REG_INDEX_W'(reg_id); scalar_wdata = value;
            @(posedge clk); #1; @(negedge clk); scalar_we = 1'b0;
        end
    endtask

    task automatic write_vector_lane(input logic [WAVE_ID_W-1:0] ctx, input integer reg_id, input integer lane_id, input logic [31:0] value);
        begin
            if (reg_id < 0 || reg_id >= VECTOR_REG_COUNT) begin
                $fatal(1, "vector register out of range: %0d", reg_id);
            end
            if (lane_id < 0 || lane_id >= WAVE_SIZE) begin
                $fatal(1, "vector lane out of range: %0d", lane_id);
            end
            @(negedge clk); clear_loaders(); vector_we = 1'b1;
            vector_wcontext = ctx; vector_wreg = VECTOR_REG_INDEX_W'(reg_id);
            vector_wlane = $clog2(WAVE_SIZE)'(lane_id); vector_wdata = value;
            @(posedge clk); #1; @(negedge clk); vector_we = 1'b0;
        end
    endtask



    /*
     * Count physical stores on the falling edge after registered DUT outputs
     * have settled. Also verify the public request shape and the forwarding
     * dependency that permits a store to overlap an active load.
     */
    always @(negedge clk) begin
        if (!rst_n) begin
            rtl8c_store_req_count <= 0;
        end else begin
            if (mshr_merge_event_o) begin
                $fatal(1, "unexpected MSHR merge in distinct-line bypass scenarios");
            end

            if (mem_req_valid_o) begin
                if (!mem_req_write_o) begin
                    $fatal(1, "physical backend request was not a store");
                end
                if (mem_req_wave_o != mem_req_context_o) begin
                    $fatal(
                        1,
                        "physical store wave/context mismatch wave=%0d context=%0d",
                        mem_req_wave_o, mem_req_context_o
                    );
                end
                if (mem_req_lane_mask_o != {WAVE_SIZE{1'b1}}) begin
                    $fatal(1, "physical store lane mask mismatch: %b", mem_req_lane_mask_o);
                end
                if (integer'(mem_req_addr_o[0]) >= GLOBAL_MEMORY_WORDS) begin
                    $fatal(1, "physical store lane0 address out of range: %0d", mem_req_addr_o[0]);
                end
                for (integer request_lane = 1; request_lane < WAVE_SIZE; request_lane++) begin
                    if (
                        integer'(mem_req_addr_o[request_lane]) >= GLOBAL_MEMORY_WORDS
                        || mem_req_wdata_o[request_lane]
                            != mem_req_wdata_o[0] + 32'(request_lane)
                    ) begin
                        $fatal(
                            1,
                            "physical store lane payload mismatch lane=%0d addr=%0d data=%0d base_data=%0d",
                            request_lane, mem_req_addr_o[request_lane],
                            mem_req_wdata_o[request_lane], mem_req_wdata_o[0]
                        );
                    end
                end
                if (
                    mshr_active_wave_mask_o != '0
                    && !dut.load_mshr_forward_dependency_active
                ) begin
                    $fatal(
                        1,
                        "store overlapped active load without forwarding dependency"
                    );
                end
                rtl8c_store_req_count <= rtl8c_store_req_count + 1;
            end

            if (retire_valid_o) begin
                if (!tb_allocated_mask[retire_wave_o]) begin
                    $fatal(
                        1,
                        "retirement from non-allocated wave=%0d pc=%0d",
                        retire_wave_o, retire_pc_o
                    );
                end
                case (retire_pc_o)
                    4'd0, 4'd1, 4'd4, 4'd5,
                    4'd8, 4'd9, 4'd12, 4'd13: begin end
                    default: $fatal(
                        1,
                        "retirement outside programmed instruction slots wave=%0d pc=%0d",
                        retire_wave_o, retire_pc_o
                    );
                endcase
            end
        end
    end



    integer rtl8c4_miss_count;
    logic [MSHR_ENTRY_W-1:0] rtl8c4_miss_entry_log [0:15];
    logic [MSHR_LINE_ADDR_W-1:0] rtl8c4_miss_line_log [0:15];

    always @(negedge clk) begin
        if (!rst_n) begin
            rtl8c4_miss_count <= 0;
        end else if (mshr_mem_req_valid_o && mshr_mem_req_ready_i) begin
            if (rtl8c4_miss_count >= 16) begin
                $fatal(1, "RTL8C-4 miss log overflow");
            end
            rtl8c4_miss_entry_log[rtl8c4_miss_count] <= mshr_mem_req_entry_o;
            rtl8c4_miss_line_log[rtl8c4_miss_count] <= mshr_mem_req_line_addr_o;
            rtl8c4_miss_count <= rtl8c4_miss_count + 1;
        end
    end

    task automatic rtl8c4_find_entry(
        input integer line_addr,
        output logic [MSHR_ENTRY_W-1:0] entry
    );
        integer scan;
        logic found;
        begin
            entry = '0;
            found = 1'b0;
            for (scan = 0; scan < rtl8c4_miss_count; scan = scan + 1) begin
                if (
                    !found
                    && rtl8c4_miss_line_log[scan]
                        == MSHR_LINE_ADDR_W'(line_addr)
                ) begin
                    entry = rtl8c4_miss_entry_log[scan];
                    found = 1'b1;
                end
            end
            if (!found) begin
                $fatal(1, "RTL8C-4 miss line not found line=%0d", line_addr);
            end
        end
    endtask

    task automatic rtl8c4_respond_line(
        input logic [MSHR_ENTRY_W-1:0] entry,
        input integer line_addr,
        input integer data_base
    );
        integer response_word;
        begin
            if (line_addr < 0 || line_addr >= (1 << MSHR_LINE_ADDR_W)) begin
                $fatal(1, "MSHR response line out of range: %0d", line_addr);
            end
            @(negedge clk);
            mshr_mem_resp_valid_i = 1'b1;
            mshr_mem_resp_entry_i = entry;
            mshr_mem_resp_line_addr_i = MSHR_LINE_ADDR_W'(line_addr);
            mshr_mem_resp_fault_i = 1'b0;
            for (
                response_word = 0;
                response_word < MSHR_LINE_WORDS;
                response_word = response_word + 1
            ) begin
                mshr_mem_resp_line_data_i[response_word] =
                    32'(data_base + response_word);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            mshr_mem_resp_valid_i = 1'b0;
        end
    endtask

    task automatic rtl8c4_respond_store(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [WAVE_ID_W-1:0] context_id
    );
        begin
            @(negedge clk);
            mem_resp_valid_i = 1'b1;
            mem_resp_wave_i = wave;
            mem_resp_context_i = context_id;
            mem_resp_fault_i = 1'b0;
            @(posedge clk);
            #1;
            @(negedge clk);
            mem_resp_valid_i = 1'b0;
        end
    endtask

    task automatic rtl8c4_respond_store_fault(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [WAVE_ID_W-1:0] context_id
    );
        begin
            @(negedge clk);
            mem_resp_valid_i = 1'b1;
            mem_resp_wave_i = wave;
            mem_resp_context_i = context_id;
            mem_resp_fault_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mem_resp_valid_i = 1'b0;
            mem_resp_fault_i = 1'b0;
        end
    endtask


    task automatic rtl8c4_reset_runtime;
        integer reset_lane;
        integer reset_word;
        begin
            run_enable = 1'b0;
            clear_loaders();
            tb_allocated_mask = '0;

            /*
             * Inactive control payloads still need deterministic testbench
             * values even while their corresponding enables remain low.
             */
            release_wave_id = '0;
            predicate_wwave = '0;
            predicate_wreg = '0;
            predicate_wdata = '0;

            policy_override_valid_i = 1'b0;
            policy_override_wave_i = '0;
            mem_resp_valid_i = 1'b0;
            mem_resp_wave_i = '0;
            mem_resp_context_i = '0;
            mem_resp_fault_i = 1'b0;
            mshr_mem_req_ready_i = 1'b1;
            mshr_mem_resp_valid_i = 1'b0;
            mshr_mem_resp_entry_i = '0;
            mshr_mem_resp_line_addr_i = '0;
            mshr_mem_resp_fault_i = 1'b0;
            debug_vector_context_i = '0;
            debug_vector_reg_i = '0;
            debug_vector_lane_i = '0;
            debug_context_i = '0;
            debug_scalar_reg_i = '0;
            debug_predicate_reg_i = '0;

            for (reset_lane = 0; reset_lane < WAVE_SIZE; reset_lane = reset_lane + 1) begin
                mem_resp_rdata_i[reset_lane] = '0;
            end
            for (
                reset_word = 0;
                reset_word < MSHR_LINE_WORDS;
                reset_word = reset_word + 1
            ) begin
                mshr_mem_resp_line_data_i[reset_word] = '0;
            end

            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            if (
                mshr_occupancy_o != '0
                || mshr_full_o
                || mshr_tag_error_o
                || memory_tag_error_o
                || valid_mask_o != '0
                || ready_mask_o != '0
                || halted_mask_o != '0
                || rr_cursor_o != '0
            ) begin
                $fatal(
                    1,
                    "reset ownership/scheduler contract mismatch occ=%0d full=%0d mtag=%0d tag=%0d valid=%b ready=%b halted=%b rr=%0d",
                    mshr_occupancy_o, mshr_full_o, mshr_tag_error_o,
                    memory_tag_error_o, valid_mask_o, ready_mask_o,
                    halted_mask_o, rr_cursor_o
                );
            end
            /*
             * Invalid contexts mask architectural payloads to zero. This does
             * not assume scalar/predicate payload arrays themselves are reset.
             */
            if (
                debug_context_valid_o
                || debug_pc_o != '0
                || debug_exec_mask_o != '0
                || debug_halted_o
                || debug_scalar_data_o != '0
                || debug_predicate_data_o != '0
            ) begin
                $fatal(
                    1,
                    "invalid-context debug mask contract mismatch valid=%0d pc=%0d exec=%b halted=%0d scalar=%0d pred=%b",
                    debug_context_valid_o, debug_pc_o, debug_exec_mask_o,
                    debug_halted_o, debug_scalar_data_o, debug_predicate_data_o
                );
            end
        end
    endtask

    task automatic rtl8c4_wait_all_halted;
        integer timeout;
        begin
            timeout = 0;
            while (!all_halted_o && timeout < 2400) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2400) begin
                $fatal(1, "RTL8C-4 program did not halt");
            end
        end
    endtask


    initial begin
        logic [MSHR_ENTRY_W-1:0] entry_line4;
        logic [MSHR_ENTRY_W-1:0] entry_line10;
        logic [MSHR_ENTRY_W-1:0] entry_line30;
        logic [MSHR_ENTRY_W-1:0] entry_line20;
        logic [MSHR_ENTRY_W-1:0] entry_line16;
        logic [MSHR_ENTRY_W-1:0] entry_line8;
        integer timeout;
        integer paused_miss_count;

        clk = 1'b0;
        rst_n = 1'b0;

        /* Scenario A: queued-store bypass + same-line hold/replay. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(8, encode_instruction(
            OP_VLOADX, 4'h0, 6'd4, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(9, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(12, encode_instruction(
            OP_VLOADX, 4'h0, 6'd5, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(13, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        allocate_context(2'd2, 8);
        allocate_context(2'd3, 12);

        write_scalar(2'd0, 0, 32'd80);
        write_scalar(2'd1, 0, 32'd160);
        write_scalar(2'd2, 0, 32'd160);
        write_scalar(2'd3, 0, 32'd164);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 2, lane, 32'(1000 + lane));
            write_vector_lane(2'd2, 1, lane, 32'(lane));
            write_vector_lane(2'd3, 1, lane, 32'(lane));
        end
        /* wave2 lanes 0/1 hit the queued store; lanes 2/3 remain on line 30. */
        write_vector_lane(2'd2, 1, 2, 32'd80);
        write_vector_lane(2'd2, 1, 3, 32'd81);

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;

        timeout = 0;
        while (!(rtl8c4_miss_count >= 1 && mshr_active_wave_mask_o[0]) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "wave0 older load did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (!(
            dut.store_queue_occupancy == 1
            && dut.store_queue_active_wave_mask_unused == 4'b0010
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "wave1 store did not queue");
        if (rtl8c_store_req_count != 0) $fatal(1, "queued store escaped older load barrier");
        $display("RTL8C5B1_YOUNGER_STORE_BLOCKED_BY_OLDER_LOAD=PASS");

        @(negedge clk);
        policy_override_wave_i = 2'd2;
        timeout = 0;
        while (!(rtl8c4_miss_count >= 2 && mshr_active_wave_mask_o[2]) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "queued partial-forward load failed");
        #1;
        if (
            rtl8c_store_req_count != 0
            || dut.store_queue_occupancy != 1
            || rtl8c4_miss_line_log[1] != MSHR_LINE_ADDR_W'(30)
            || dut.load_mshr_bridge.wave_forward_wait_mask_q[2] != 4'b0011
            || !dut.load_mshr_forward_dependency_active
        ) begin
            $fatal(1, "queued partial-forward launch contract mismatch");
        end
        $display("RTL8C5B1_QUEUED_PARTIAL_FORWARD_NO_MISS=PASS");

        /*
         * The forwarding dependency is now live, but wave0 is an older
         * MSHR-active load whose boundary excludes store seq0. The dependency
         * override must therefore keep the store queued.
         */
        repeat (4) @(posedge clk);
        #1;
        if (
            rtl8c_store_req_count != 0
            || dut.store_queue_occupancy != 1
            || !mshr_active_wave_mask_o[0]
            || !dut.load_mshr_forward_dependency_active
        ) begin
            $fatal(
                1,
                "forward dependency override violated older MSHR boundary"
            );
        end
        $display("RTL8C5B1_DEPENDENCY_OVERRIDE_RESPECTS_OLDER_MSHR=PASS");

        @(negedge clk);
        policy_override_wave_i = 2'd3;
        timeout = 0;
        while (!dut.load_order_wait_valid_q && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "same-line load did not enter order wait");

        #1;
        if (
            engine_busy_o
            || mshr_active_wave_mask_o[3]
            || dut.store_queue_probe_exact_conflict
            || !dut.store_queue_probe_line_conflict
            || !dut.load_store_line_conflict
        ) begin
            $fatal(1, "queued same-line hold contract mismatch");
        end
        $display("RTL8C_SAME_LINE_DIFFERENT_WORD_LOAD_HOLD=PASS");
        $display("RTL8C_LOAD_ORDER_WAIT_ENGINE_RELEASE=PASS");

        @(negedge clk);
        policy_override_valid_i = 1'b0;

        rtl8c4_find_entry(10, entry_line10);
        rtl8c4_find_entry(30, entry_line30);
        rtl8c4_respond_line(entry_line10, 10, 5000);
        rtl8c4_respond_line(entry_line30, 30, 6000);

        timeout = 0;
        while (mshr_active_wave_mask_o[0] && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "older barrier load did not drain");

        #1;
        if (
            !mshr_active_wave_mask_o[2]
            || dut.load_mshr_complete_valid
            || dut.load_mshr_bridge.wave_forward_wait_mask_q[2] != 4'b0011
        ) begin
            $fatal(1, "forwarded load completed before source response");
        end
        $display("RTL8C5B1_PROVISIONAL_WAIT_BEFORE_STORE_RESPONSE=PASS");

        timeout = 0;
        while (rtl8c_store_req_count < 1 && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "queued store never reached backend");
        if (!mshr_active_wave_mask_o[2]) begin
            $fatal(1, "forwarding dependency vanished before store response");
        end
        $display("RTL8C5B1_DEPENDENCY_AGE_SAFE_STORE_DRAIN=PASS");

        #1;
        if (
            !dut.mem_pending_valid_q
            || dut.mem_pending_load_q
            || !dut.store_queue_empty
            || !dut.load_order_wait_valid_q
            || dut.store_queue_probe_line_conflict
            || dut.physical_store_exact_conflict
            || !dut.physical_store_line_conflict
            || !dut.load_store_line_conflict
        ) begin
            $fatal(1, "queue-to-physical conflict continuity failed");
        end
        $display("RTL8C_CONFLICT_SURVIVES_QUEUE_TO_PHYSICAL=PASS");

        /*
         * A correctly tagged physical-store response is captured even while
         * execution is paused. The held load must remain in the order-wait
         * slot and must not replay until run_enable is restored.
         */
        @(negedge clk);
        run_enable = 1'b0;
        paused_miss_count = rtl8c4_miss_count;

        rtl8c4_respond_store(2'd1, 2'd1);

        repeat (3) @(posedge clk);
        #1;

        if (
            !dut.load_order_wait_valid_q
            || dut.load_order_replay_valid
            || dut.load_store_line_conflict
            || !dut.mem_complete_pending_q
            || rtl8c4_miss_count != paused_miss_count
        ) begin
            $fatal(
                1,
                "pause-safe order-wait mismatch wait=%0b replay=%0b conflict=%0b complete=%0b misses=%0d expected=%0d",
                dut.load_order_wait_valid_q,
                dut.load_order_replay_valid,
                dut.load_store_line_conflict,
                dut.mem_complete_pending_q,
                rtl8c4_miss_count,
                paused_miss_count
            );
        end

        $display("RTL8C_PAUSE_PRESERVES_LOAD_ORDER_WAIT=PASS");

        @(negedge clk);
        run_enable = 1'b1;

        timeout = 0;
        while (rtl8c4_miss_count < 3 && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "held load did not replay");
        if (dut.load_order_wait_valid_q || !mshr_active_wave_mask_o[3]) begin
            $fatal(1, "held load replay ownership mismatch");
        end

        rtl8c4_find_entry(20, entry_line20);
        rtl8c4_respond_line(entry_line20, 20, 7000);
        rtl8c4_wait_all_halted();

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            @(negedge clk);
            debug_vector_context_i = 2'd2;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(4);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (lane < 2) begin
                if (debug_vector_data_o != 32'(1000 + lane)) begin
                    $fatal(1, "queued forwarded data mismatch lane=%0d", lane);
                end
            end else begin
                if (debug_vector_data_o != 32'(5998 + lane)) begin
                    $fatal(1, "queued backend data mismatch lane=%0d", lane);
                end
            end

            debug_vector_context_i = 2'd3;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(5);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (debug_vector_data_o != 32'(7004 + lane)) begin
                $fatal(1, "replayed load data mismatch lane=%0d", lane);
            end
        end
        if (faulted_o || memory_outstanding_o) $fatal(1, "scenario A did not drain cleanly");
        $display("RTL8C_HELD_LOAD_REPLAY_AFTER_STORE=PASS");
        $display("RTL8C_LOAD_BYPASS_DATA=PASS");
        $display("RTL8C5B1_FORWARD_SUCCESS_DATA=PASS");

        /* Scenario B: bypass/hold while a store is already physical. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(8, encode_instruction(
            OP_VLOADX, 4'h0, 6'd4, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(9, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        allocate_context(2'd2, 8);
        write_scalar(2'd0, 0, 32'd64);
        write_scalar(2'd1, 0, 32'd128);
        write_scalar(2'd2, 0, 32'd68);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd0, 2, lane, 32'(2000 + lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
            write_vector_lane(2'd2, 1, lane, 32'(lane));
        end

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;

        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical store did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (!(
            rtl8c4_miss_count >= 1
            && mshr_active_wave_mask_o[1]
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical non-conflicting bypass failed");
        $display("RTL8C_PHYSICAL_STORE_NONCONFLICT_LOAD_BYPASS=PASS");

        @(negedge clk);
        policy_override_wave_i = 2'd2;
        timeout = 0;
        while (!dut.load_order_wait_valid_q && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical same-line load did not wait");
        #1;
        if (
            engine_busy_o
            || dut.physical_store_exact_conflict
            || !dut.physical_store_line_conflict
            || !dut.load_store_line_conflict
        ) begin
            $fatal(1, "physical line hold mismatch");
        end
        $display("RTL8C_PHYSICAL_STORE_LINE_CONFLICT_HOLD=PASS");

        @(negedge clk);
        policy_override_valid_i = 1'b0;

        rtl8c4_find_entry(16, entry_line16);
        rtl8c4_respond_line(entry_line16, 16, 8000);
        repeat (4) @(posedge clk);
        if (!dut.mem_pending_valid_q) begin
            $fatal(1, "physical store disappeared before explicit response");
        end

        rtl8c4_respond_store(2'd0, 2'd0);
        timeout = 0;
        while (rtl8c4_miss_count < 2 && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical-conflict load did not replay");

        rtl8c4_find_entry(8, entry_line8);
        rtl8c4_respond_line(entry_line8, 8, 9000);
        rtl8c4_wait_all_halted();
        if (faulted_o || memory_outstanding_o) $fatal(1, "scenario B did not drain cleanly");

        $display("RTL8C_PHYSICAL_STORE_RESPONSE_NO_REPLAY_DEADLOCK=PASS");

        /* Scenario C: queued forwarded data must be discarded on store fault. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VLOADX, 4'h0, 6'd2, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(8, encode_instruction(
            OP_VLOADX, 4'h0, 6'd4, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(9, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        allocate_context(2'd2, 8);
        write_scalar(2'd0, 0, 32'd32);
        write_scalar(2'd1, 0, 32'd64);
        write_scalar(2'd2, 0, 32'd64);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 2, lane, 32'(4000 + lane));
            write_vector_lane(2'd2, 1, lane, 32'(lane));
        end

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;

        timeout = 0;
        while (!(rtl8c4_miss_count >= 1 && mshr_active_wave_mask_o[0])
               && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "fault fallback older load did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (dut.store_queue_occupancy != 1 && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "fault fallback source store did not queue");

        @(negedge clk);
        policy_override_wave_i = 2'd2;
        timeout = 0;
        while (!(
            mshr_active_wave_mask_o[2]
            && dut.load_mshr_bridge.wave_forward_wait_mask_q[2] == 4'b1111
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "all-forward provisional load did not launch");
        if (rtl8c4_miss_count != 1) begin
            $fatal(1, "all-forward provisional load unexpectedly touched backend");
        end
        $display("RTL8C5B1_ALL_FORWARD_PROVISIONAL_NO_MISS=PASS");

        @(negedge clk);
        policy_override_valid_i = 1'b0;
        rtl8c4_find_entry(4, entry_line4);
        rtl8c4_respond_line(entry_line4, 4, 10000);

        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "fault source store did not drain");
        if (!mshr_active_wave_mask_o[2] || rtl8c4_miss_count != 1) begin
            $fatal(1, "provisional load completed before fault response");
        end

        rtl8c4_respond_store_fault(2'd1, 2'd1);

        timeout = 0;
        while (rtl8c4_miss_count < 2 && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "faulted forwarded lanes did not replay");
        if (rtl8c4_miss_line_log[1] != MSHR_LINE_ADDR_W'(8)) begin
            $fatal(1, "fault fallback miss targeted wrong line");
        end
        $display("RTL8C5B1_STORE_FAULT_REPLAYS_FORWARDED_LANES=PASS");

        rtl8c4_find_entry(8, entry_line8);
        rtl8c4_respond_line(entry_line8, 8, 12000);
        rtl8c4_wait_all_halted();

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            @(negedge clk);
            debug_vector_context_i = 2'd2;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(4);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (debug_vector_data_o != 32'(12000 + lane)) begin
                $fatal(1, "fault fallback data mismatch lane=%0d", lane);
            end
        end
        if (!faulted_o || memory_outstanding_o) begin
            $fatal(1, "fault-safe forwarding scenario closure mismatch");
        end
        $display("RTL8C5B1_STORE_FAULT_DISCARDS_PROVISIONAL_DATA=PASS");
        $display("RTL8C5B1_FAULT_SAFE_QUEUED_FORWARDING=PASS");

        /* Scenario D: partial forwarding from an already-physical store. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        write_scalar(2'd0, 0, 32'd64);
        write_scalar(2'd1, 0, 32'd64);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd0, 2, lane, 32'(5000 + lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
        end
        /* lanes 0/1 forward from line8; lanes 2/3 miss on line18. */
        write_vector_lane(2'd1, 1, 2, 32'd80);
        write_vector_lane(2'd1, 1, 3, 32'd81);

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;

        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "5B2 physical source store did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (!(
            mshr_active_wave_mask_o[1]
            && dut.load_mshr_bridge.wave_forward_wait_mask_q[1] == 4'b0011
            && rtl8c4_miss_count >= 1
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical partial-forward load did not launch");
        #1;
        if (
            rtl8c4_miss_count != 1
            || rtl8c4_miss_line_log[0] != MSHR_LINE_ADDR_W'(18)
            || !dut.load_mshr_forward_dependency_active
        ) begin
            $fatal(1, "physical partial-forward miss contract mismatch");
        end
        $display("RTL8C5B2_PHYSICAL_PARTIAL_FORWARD_SINGLE_MISS=PASS");

        rtl8c4_find_entry(18, entry_line8);
        rtl8c4_respond_line(entry_line8, 18, 16000);
        repeat (4) @(posedge clk);
        #1;
        if (
            !mshr_active_wave_mask_o[1]
            || dut.load_mshr_bridge.wave_forward_wait_mask_q[1] != 4'b0011
            || dut.load_mshr_complete_valid
        ) begin
            $fatal(1, "physical provisional load completed before store response");
        end
        $display("RTL8C5B2_PHYSICAL_PROVISIONAL_WAIT_BEFORE_RESPONSE=PASS");

        @(negedge clk);
        policy_override_valid_i = 1'b0;
        rtl8c4_respond_store(2'd0, 2'd0);
        rtl8c4_wait_all_halted();

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            @(negedge clk);
            debug_vector_context_i = 2'd1;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(3);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (lane < 2) begin
                if (debug_vector_data_o != 32'(5000 + lane)) begin
                    $fatal(1, "physical forwarded data mismatch lane=%0d", lane);
                end
            end else begin
                if (debug_vector_data_o != 32'(15998 + lane)) begin
                    $fatal(1, "physical backend data mismatch lane=%0d", lane);
                end
            end
        end
        if (faulted_o || memory_outstanding_o) begin
            $fatal(1, "physical partial-forward scenario did not drain cleanly");
        end
        $display("RTL8C5B2_PHYSICAL_FORWARD_SUCCESS_DATA=PASS");

        /* Scenario E: all-forward physical dependency falls back on store fault. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        write_scalar(2'd0, 0, 32'd64);
        write_scalar(2'd1, 0, 32'd64);
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd0, 2, lane, 32'(6000 + lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
        end

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;
        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical fault source store did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (!(
            mshr_active_wave_mask_o[1]
            && dut.load_mshr_bridge.wave_forward_wait_mask_q[1] == 4'b1111
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "physical all-forward provisional load did not launch");
        if (rtl8c4_miss_count != 0) begin
            $fatal(1, "physical all-forward provisional load unexpectedly touched backend");
        end
        $display("RTL8C5B2_PHYSICAL_ALL_FORWARD_PROVISIONAL_NO_MISS=PASS");

        @(negedge clk);
        policy_override_valid_i = 1'b0;
        rtl8c4_respond_store_fault(2'd0, 2'd0);
        timeout = 0;
        while (rtl8c4_miss_count < 1 && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "physical fault did not re-arm forwarded lanes");
        if (rtl8c4_miss_line_log[0] != MSHR_LINE_ADDR_W'(8)) begin
            $fatal(1, "physical fault fallback miss targeted wrong line");
        end
        $display("RTL8C5B2_PHYSICAL_STORE_FAULT_REPLAYS_FORWARDED_LANES=PASS");

        rtl8c4_find_entry(8, entry_line8);
        rtl8c4_respond_line(entry_line8, 8, 13000);
        rtl8c4_wait_all_halted();
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            @(negedge clk);
            debug_vector_context_i = 2'd1;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(3);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (debug_vector_data_o != 32'(13000 + lane)) begin
                $fatal(1, "physical fault fallback data mismatch lane=%0d", lane);
            end
        end
        if (!faulted_o || memory_outstanding_o) begin
            $fatal(1, "physical fault-safe scenario closure mismatch");
        end
        $display("RTL8C5B2_PHYSICAL_STORE_FAULT_DISCARDS_PROVISIONAL_DATA=PASS");

        /* Scenario F: younger queued source must beat the older physical source. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(8, encode_instruction(
            OP_VLOADX, 4'h0, 6'd4, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(9, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        allocate_context(2'd2, 8);
        write_scalar(2'd0, 0, 32'd64);
        write_scalar(2'd1, 0, 32'd64);
        write_scalar(2'd2, 0, 32'd64);
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd0, 2, lane, 32'(7000 + lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 2, lane, 32'(8000 + lane));
            write_vector_lane(2'd2, 1, lane, 32'(lane));
        end

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;
        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "youngest-source physical store did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (dut.store_queue_occupancy != 1 && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "youngest-source queued store did not enqueue");

        @(negedge clk);
        policy_override_wave_i = 2'd2;
        timeout = 0;
        while (!(
            mshr_active_wave_mask_o[2]
            && dut.load_mshr_bridge.wave_forward_wait_mask_q[2] == 4'b1111
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "youngest queued source load did not launch");
        #1;
        if (
            rtl8c4_miss_count != 0
            || dut.load_mshr_bridge.wave_forward_seq_q[2][0] != 64'd1
            || dut.load_mshr_bridge.wave_forward_seq_q[2][0]
                == dut.mem_owner_store_seq_q
        ) begin
            $fatal(1, "youngest queued source did not beat physical source");
        end
        $display("RTL8C5B2_YOUNGEST_QUEUED_BEATS_PHYSICAL=PASS");

        rtl8c4_respond_store(2'd0, 2'd0);
        repeat (4) @(posedge clk);
        #1;
        if (
            !mshr_active_wave_mask_o[2]
            || dut.load_mshr_bridge.wave_forward_wait_mask_q[2] != 4'b1111
        ) begin
            $fatal(1, "older physical resolve consumed younger queued dependency");
        end
        $display("RTL8C5B2_OLDER_PHYSICAL_RESOLVE_IGNORED=PASS");

        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 2
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
            && dut.mem_owner_wave_q == 2'd1
        ) && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "younger queued source never reached physical backend");

        @(negedge clk);
        policy_override_valid_i = 1'b0;
        rtl8c4_respond_store(2'd1, 2'd1);
        rtl8c4_wait_all_halted();
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            @(negedge clk);
            debug_vector_context_i = 2'd2;
            debug_vector_reg_i = VECTOR_REG_INDEX_W'(4);
            debug_vector_lane_i = $clog2(WAVE_SIZE)'(lane);
            #1;
            if (debug_vector_data_o != 32'(8000 + lane)) begin
                $fatal(1, "youngest queued forwarded data mismatch lane=%0d", lane);
            end
        end
        if (faulted_o || memory_outstanding_o || rtl8c4_miss_count != 0) begin
            $fatal(1, "youngest-source scenario closure mismatch");
        end

        /* Scenario G: response-cycle physical capture is suppressed and replayed. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        write_scalar(2'd0, 0, 32'd64);
        write_scalar(2'd1, 0, 32'd64);
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));
            write_vector_lane(2'd0, 2, lane, 32'(9000 + lane));
            write_vector_lane(2'd1, 1, lane, 32'(lane));
        end

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;
        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "response-race physical store did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (!(
            dut.current_load_order_candidate
            && dut.physical_store_exact_conflict
        ) && timeout < 1200) begin
            @(negedge clk);
            #1;
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "response-race load candidate not reached");

        mem_resp_valid_i = 1'b1;
        mem_resp_wave_i = 2'd0;
        mem_resp_context_i = 2'd0;
        mem_resp_fault_i = 1'b0;
        #1;
        if (
            !dut.store_response_resolve_fire
            || dut.load_store_forward_safe_lane_mask != '0
            || !dut.load_store_unresolved_line_conflict
            || !dut.load_order_hold_fire
        ) begin
            $fatal(1, "response-cycle physical forwarding suppression failed");
        end
        $display("RTL8C5B2_RESPONSE_CYCLE_PHYSICAL_FORWARD_SUPPRESSED=PASS");

        @(posedge clk);
        #1;
        if (
            !dut.load_order_wait_valid_q
            || mshr_active_wave_mask_o[1]
            || dut.load_mshr_bridge.wave_forward_wait_mask_q[1] != '0
        ) begin
            $fatal(1, "response-cycle load captured a stale physical dependency");
        end
        @(negedge clk);
        mem_resp_valid_i = 1'b0;
        policy_override_valid_i = 1'b0;

        timeout = 0;
        while (rtl8c4_miss_count < 1 && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "response-cycle held load did not replay");
        if (rtl8c4_miss_line_log[0] != MSHR_LINE_ADDR_W'(8)) begin
            $fatal(1, "response-cycle replay targeted wrong line");
        end
        rtl8c4_find_entry(8, entry_line8);
        rtl8c4_respond_line(entry_line8, 8, 14000);
        rtl8c4_wait_all_halted();
        if (faulted_o || memory_outstanding_o) begin
            $fatal(1, "response-cycle replay scenario did not drain cleanly");
        end
        $display("RTL8C5B2_RESPONSE_CYCLE_REPLAY_NO_DEADLOCK=PASS");

        /* Scenario H: duplicate physical lanes targeting one word are ambiguous. */
        rtl8c4_reset_runtime();

        write_program(0, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(1, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));
        write_program(4, encode_instruction(
            OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
        ));
        write_program(5, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        allocate_context(2'd0, 0);
        allocate_context(2'd1, 4);
        write_scalar(2'd0, 0, 32'd64);
        write_scalar(2'd1, 0, 32'd64);
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'd0);
            write_vector_lane(2'd0, 2, lane, 32'(10000 + lane));
            write_vector_lane(2'd1, 1, lane, 32'd0);
        end

        @(negedge clk);
        policy_override_valid_i = 1'b1;
        policy_override_wave_i = 2'd0;
        run_enable = 1'b1;
        timeout = 0;
        while (!(
            rtl8c_store_req_count >= 1
            && dut.mem_pending_valid_q
            && !dut.mem_pending_load_q
        ) && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "ambiguous physical store did not launch");

        @(negedge clk);
        policy_override_wave_i = 2'd1;
        timeout = 0;
        while (!dut.load_order_wait_valid_q && timeout < 1200) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1200) $fatal(1, "ambiguous physical load did not hold");
        #1;
        if (
            dut.load_store_source_ambiguous_lane_mask != 4'b1111
            || dut.load_store_forward_safe_lane_mask != '0
            || dut.load_mshr_bridge.wave_forward_wait_mask_q[1] != '0
        ) begin
            $fatal(1, "duplicate physical source ambiguity contract failed");
        end
        $display("RTL8C5B2_DUPLICATE_PHYSICAL_SOURCE_AMBIGUOUS=PASS");

        @(negedge clk);
        policy_override_valid_i = 1'b0;
        rtl8c4_respond_store(2'd0, 2'd0);
        timeout = 0;
        while (rtl8c4_miss_count < 1 && timeout < 1800) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 1800) $fatal(1, "ambiguous physical held load did not replay");
        rtl8c4_find_entry(8, entry_line8);
        rtl8c4_respond_line(entry_line8, 8, 15000);
        rtl8c4_wait_all_halted();
        if (faulted_o || memory_outstanding_o) begin
            $fatal(1, "ambiguous physical scenario did not drain cleanly");
        end

        $display("RTL8C5B2_FAULT_SAFE_PHYSICAL_FORWARDING=PASS");
        $display("RTL8C_SAFE_LOAD_BYPASS_TB=PASS");
        $finish;
    end

endmodule
