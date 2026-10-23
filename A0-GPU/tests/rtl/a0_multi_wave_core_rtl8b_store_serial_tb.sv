`timescale 1ns/1ps

module a0_multi_wave_core_rtl8b_store_serial_tb;

    localparam integer RESIDENT_WAVES = 2;
    localparam integer WAVE_SIZE = 4;
    localparam integer PHYSICAL_LANES = 2;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 4;
    localparam integer RECONV_STACK_DEPTH = 4;
    localparam integer GLOBAL_MEMORY_WORDS = 256;
    localparam integer PROGRAM_WORDS = 8;
    localparam integer MSHR_COUNT = 2;
    localparam integer MSHR_LINE_WORDS = 8;

    localparam integer WAVE_ID_W = 1;
    localparam integer PC_W = 3;
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
    integer word_index;
    integer miss_count;
    integer retire_count;
    integer store_request_count;
    logic [MSHR_ENTRY_W-1:0] live_entry;
    logic store_seen;


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
        .MSHR_LINE_WORDS(MSHR_LINE_WORDS)
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

    always @(posedge clk) begin
        if (rst_n && mshr_merge_event_o) begin
            $fatal(1, "store-serialization test unexpectedly merged an MSHR");
        end
    end

    /*
     * mem_req_* and retire_* are registered DUT outputs updated on the
     * rising edge. Sample them on the falling edge and keep the sticky
     * counters/flags single-owner.
     */
    always @(negedge clk) begin
        if (!rst_n) begin
            retire_count <= 0;
            store_request_count <= 0;
            store_seen <= 1'b0;
        end else begin
            if (mem_req_valid_o) begin
                store_request_count <= store_request_count + 1;
                store_seen <= 1'b1;
                if (!mem_req_write_o) begin
                    $fatal(1, "legacy RTL8B request was not a store");
                end
                if (
                    mshr_occupancy_o != 0
                    || mshr_active_wave_mask_o != 0
                ) begin
                    $fatal(1, "store launched before load MSHRs drained");
                end
            end
            if (retire_valid_o) begin
                if (!(
                    (retire_wave_o == 1'd0 && (retire_pc_o == PC_W'(0) || retire_pc_o == PC_W'(1)))
                    || (retire_wave_o == 1'd1 && (retire_pc_o == PC_W'(4) || retire_pc_o == PC_W'(5)))
                )) begin
                    $fatal(1, "unexpected retirement wave=%0d pc=%0d", retire_wave_o, retire_pc_o);
                end
                retire_count <= retire_count + 1;
            end
        end
    end


    /* Capture the accepted physical miss request before the issue-state NBA. */
    always @(negedge clk) begin
        if (rst_n && mshr_mem_req_valid_o && mshr_mem_req_ready_i) begin
            if (mshr_mem_req_line_addr_o != MSHR_LINE_ADDR_W'(10)) begin
                $fatal(1, "unexpected load miss line=%0d", mshr_mem_req_line_addr_o);
            end
            miss_count <= miss_count + 1;
            live_entry <= mshr_mem_req_entry_o;
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

    task automatic allocate_context(input logic wave, input integer start_pc);
        begin
            if (start_pc < 0 || start_pc >= PROGRAM_WORDS) begin
                $fatal(1, "allocation PC out of range: %0d", start_pc);
            end
            @(negedge clk); clear_loaders(); alloc_valid = 1'b1;
            alloc_wave_id = wave; alloc_pc = PC_W'(start_pc);
            alloc_exec_mask = '1; alloc_vrf_context_id = wave; #1;
            if (!alloc_ready) $fatal(1, "allocation not ready wave=%0d", wave);
            @(posedge clk); #1; @(negedge clk); alloc_valid = 1'b0;
        end
    endtask

    task automatic write_scalar(input logic wave, input integer reg_id, input logic [31:0] value);
        begin
            if (reg_id < 0 || reg_id >= SCALAR_REG_COUNT) begin
                $fatal(1, "scalar register out of range: %0d", reg_id);
            end
            @(negedge clk); clear_loaders(); scalar_we = 1'b1;
            scalar_wwave = wave; scalar_wreg = SCALAR_REG_INDEX_W'(reg_id); scalar_wdata = value;
            @(posedge clk); #1; @(negedge clk); scalar_we = 1'b0;
        end
    endtask

    task automatic write_predicate(
        input logic wave,
        input logic [PREDICATE_INDEX_W-1:0] reg_id,
        input logic [WAVE_SIZE-1:0] value
    );
        begin
            @(negedge clk); clear_loaders(); predicate_we = 1'b1;
            predicate_wwave = wave; predicate_wreg = reg_id; predicate_wdata = value;
            @(posedge clk); #1; @(negedge clk); predicate_we = 1'b0;
        end
    endtask

    task automatic write_vector_lane(input logic ctx, input integer reg_id, input integer lane_id, input logic [31:0] value);
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
        mshr_mem_req_ready_i = 1'b1;
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
        live_entry = '0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            mem_resp_rdata_i[lane] = '0;
        end
        for (
            word_index = 0;
            word_index < MSHR_LINE_WORDS;
            word_index = word_index + 1
        ) begin
            mshr_mem_resp_line_data_i[word_index] = 32'(6000 + word_index);
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        /* Wave0 owns a non-blocking load. Wave1's store must wait behind it. */
        write_program(
            0,
            encode_instruction(
                OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
            )
        );
        write_program(
            1,
            encode_instruction(
                OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
            )
        );
        write_program(
            4,
            encode_instruction(
                OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
            )
        );
        write_program(
            5,
            encode_instruction(
                OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
            )
        );

        allocate_context(1'd0, 0);
        allocate_context(1'd1, 4);
        write_scalar(1'd0, 0, 32'd80);   // line 10
        write_scalar(1'd1, 0, 32'd240);  // store words 240..243
        /* Predicate register 1 is unused by the program and is seeded only
         * to give the final debug-port contract deterministic provenance. */
        write_predicate(1'd1, PREDICATE_INDEX_W'(1), 4'hA);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(1'd0, 1, lane, 32'(lane));
            write_vector_lane(1'd1, 1, lane, 32'(lane));
            write_vector_lane(1'd1, 2, lane, 32'(900 + lane));
        end

        run_enable = 1'b1;

        begin : wait_load_miss
            integer timeout;
            timeout = 0;
            while (
                !(miss_count == 1 && mshr_active_wave_mask_o == 2'b01)
                && timeout < 400
            ) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 400) begin
                $fatal(1, "load miss did not become outstanding");
            end
        end

        repeat (25) @(posedge clk);
        if (store_seen || store_request_count != 0) begin
            $fatal(1, "store escaped ordering barrier while load was live");
        end
        if (mshr_occupancy_o != 1 || mshr_full_o || mshr_active_wave_mask_o != 2'b01) begin
            $fatal(1, "load ownership changed before response occupancy=%0d full=%0b active=%b", mshr_occupancy_o, mshr_full_o, mshr_active_wave_mask_o);
        end
        $display("RTL8B_STORE_BLOCKED_BEHIND_LOAD_MSHR=PASS");

        /* Complete the load. Store may launch only after the bridge fully drains. */
        @(negedge clk);
        mshr_mem_resp_valid_i = 1'b1;
        mshr_mem_resp_entry_i = live_entry;
        mshr_mem_resp_line_addr_i = 29'd10;
        mshr_mem_resp_fault_i = 1'b0;
        #1;
        if (mshr_tag_error_o) begin
            $fatal(1, "correct load response rejected before handshake");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        mshr_mem_resp_valid_i = 1'b0;

        begin : wait_store_request
            integer timeout;
            timeout = 0;
            while (!store_seen && timeout < 500) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!store_seen) begin
                $fatal(1, "store did not launch after load MSHR drain");
            end
        end

        if (store_request_count != 1) begin
            $fatal(1, "unexpected store request count=%0d", store_request_count);
        end
        if (
            mem_req_wave_o != 1'd1
            || mem_req_context_o != 1'd1
            || mem_req_lane_mask_o != 4'hF
        ) begin
            $fatal(1, "store ownership metadata mismatch");
        end
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (mem_req_addr_o[lane] != 32'(240 + lane)) begin
                $fatal(1, "store address mismatch lane=%0d", lane);
            end
            if (mem_req_wdata_o[lane] != 32'(900 + lane)) begin
                $fatal(1, "store data mismatch lane=%0d", lane);
            end
        end
        $display("RTL8B_STORE_LAUNCH_AFTER_MSHR_DRAIN=PASS");
        $display("RTL8B_STORE_CONTEXT_DATA=PASS");

        /* Complete the legacy store transaction. */
        @(negedge clk);
        mem_resp_valid_i = 1'b1;
        mem_resp_wave_i = 1'd1;
        mem_resp_context_i = 1'd1;
        mem_resp_fault_i = 1'b0;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_resp_valid_i = 1'b0;

        begin : wait_halts
            integer timeout;
            timeout = 0;
            while (!all_halted_o && timeout < 500) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!all_halted_o) begin
                $fatal(1, "store-serialization program did not halt");
            end
        end

        if (
            memory_outstanding_o
            || mshr_occupancy_o != 0
            || mshr_active_wave_mask_o != 0
        ) begin
            $fatal(1, "memory ownership not drained at end");
        end
        if (faulted_o || memory_tag_error_o || mshr_tag_error_o) begin
            $fatal(1, "unexpected fault/tag error in store serialization test");
        end
        if (retire_count != 4) begin
            $fatal(1, "expected 4 retirements got=%0d", retire_count);
        end

        debug_context_i = 1'd1;
        debug_scalar_reg_i = SCALAR_REG_INDEX_W'(0);
        debug_predicate_reg_i = PREDICATE_INDEX_W'(1);
        debug_vector_context_i = 1'd1;
        debug_vector_reg_i = VECTOR_REG_INDEX_W'(2);
        debug_vector_lane_i = '0;
        #1;
        if (
            !debug_context_valid_o
            || integer'(debug_pc_o) >= PROGRAM_WORDS
            || debug_exec_mask_o != '1
            || !debug_halted_o
            || debug_scalar_data_o != 32'd240
            || debug_predicate_data_o != 4'hA
            || debug_vector_data_o != 32'd900
        ) begin
            $fatal(
                1,
                "store final debug contract mismatch valid=%0b pc=%0d exec=%b halted=%0b scalar=%0d pred=%b v2l0=%0d",
                debug_context_valid_o, debug_pc_o, debug_exec_mask_o, debug_halted_o,
                debug_scalar_data_o, debug_predicate_data_o, debug_vector_data_o
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
                "store final scheduler contract mismatch busy=%0b valid=%b ready=%b halted=%b rr=%0d",
                engine_busy_o, valid_mask_o, ready_mask_o, halted_mask_o, rr_cursor_o
            );
        end

        $display("RTL8B_STORE_SERIALIZATION_TB=PASS");
        $finish;
    end

endmodule
