`timescale 1ns/1ps

module a0_multi_wave_core_rtl8c_multi_store_tb;

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
    integer word_index;
    integer miss_count;
    logic [MSHR_ENTRY_W-1:0] live_entry;
    logic [MSHR_LINE_ADDR_W-1:0] live_line_addr;

    integer rtl8c_store_req_count;
    integer rtl8c_store_req_wave_log [0:7];
    integer rtl8c_store_req_context_log [0:7];
    integer rtl8c_store_req_addr0_log [0:7];
    integer rtl8c_store_req_data0_log [0:7];

    integer rtl8c_retire_count;
    integer rtl8c_retire_wave_log [0:15];
    integer rtl8c_retire_pc_log [0:15];

    integer rtl8c_scan_i;
    integer rtl8c_store_retire_sequence;


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

    /* Capture the accepted physical miss request before the issue-state NBA. */
    always @(negedge clk) begin
        if (rst_n) begin
            if (mshr_merge_event_o) begin
                $fatal(1, "unexpected MSHR merge in single-load scenario");
            end
            if (mshr_mem_req_valid_o && mshr_mem_req_ready_i) begin
                miss_count <= miss_count + 1;
                live_entry <= mshr_mem_req_entry_o;
                live_line_addr <= mshr_mem_req_line_addr_o;
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
            @(posedge clk); #1; @(negedge clk); alloc_valid = 1'b0;
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

    task automatic write_predicate(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [PREDICATE_INDEX_W-1:0] reg_id,
        input logic [WAVE_SIZE-1:0] value
    );
        begin
            @(negedge clk); clear_loaders(); predicate_we = 1'b1;
            predicate_wwave = wave; predicate_wreg = reg_id;
            predicate_wdata = value;
            @(posedge clk); #1; @(negedge clk); predicate_we = 1'b0;
        end
    endtask


    /*
     * RTL8C-3 observation log. Keep sticky counters single-owner and sample
     * registered DUT outputs on the falling edge, after NBA updates.
     */
    always @(negedge clk) begin
        if (!rst_n) begin
            rtl8c_store_req_count <= 0;
            rtl8c_retire_count <= 0;
        end else begin
            if (mem_req_valid_o && mem_req_write_o) begin
                if (mem_req_lane_mask_o != {WAVE_SIZE{1'b1}}) begin
                    $fatal(1, "physical store lane mask mismatch: %b", mem_req_lane_mask_o);
                end
                if (
                    mshr_occupancy_o != '0
                    || mshr_active_wave_mask_o != '0
                ) begin
                    $fatal(1, "store launched before load MSHRs drained");
                end
                if (rtl8c_store_req_count >= 8) begin
                    $fatal(1, "RTL8C store request log overflow");
                end
                rtl8c_store_req_wave_log[rtl8c_store_req_count] <=
                    integer'(mem_req_wave_o);
                rtl8c_store_req_context_log[rtl8c_store_req_count] <=
                    integer'(mem_req_context_o);
                rtl8c_store_req_addr0_log[rtl8c_store_req_count] <=
                    integer'(mem_req_addr_o[0]);
                rtl8c_store_req_data0_log[rtl8c_store_req_count] <=
                    integer'(mem_req_wdata_o[0]);
                rtl8c_store_req_count <= rtl8c_store_req_count + 1;
            end

            if (retire_valid_o) begin
                if (rtl8c_retire_count >= 16) begin
                    $fatal(1, "RTL8C retirement log overflow");
                end
                rtl8c_retire_wave_log[rtl8c_retire_count] <=
                    integer'(retire_wave_o);
                rtl8c_retire_pc_log[rtl8c_retire_count] <=
                    integer'(retire_pc_o);
                rtl8c_retire_count <= rtl8c_retire_count + 1;
            end
        end
    end


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
        live_line_addr = '0;

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

        /*
         * Wave0 owns the older live VLOADX. While that load prevents physical
         * store drain, wave1 and wave2 fill the two-entry store queue.
         * Wave3 remains blocked by queue capacity.
         */
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
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
        ));
        write_program(9, encode_instruction(
            OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
        ));

        write_program(12, encode_instruction(
            OP_VSTOREX, 4'h0, 6'd0, 6'd0, 6'd1, 6'd2, 4'd0, 24'd0
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
        write_scalar(2'd2, 0, 32'd180);
        write_scalar(2'd3, 0, 32'd200);

        write_predicate(2'd0, 2'd1, 4'b1001);
        write_predicate(2'd1, 2'd1, 4'b1010);
        write_predicate(2'd2, 2'd1, 4'b1100);
        write_predicate(2'd3, 2'd1, 4'b0110);

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(2'd0, 1, lane, 32'(lane));

            write_vector_lane(2'd1, 1, lane, 32'(lane));
            write_vector_lane(2'd1, 2, lane, 32'(1000 + lane));

            write_vector_lane(2'd2, 1, lane, 32'(lane));
            write_vector_lane(2'd2, 2, lane, 32'(2000 + lane));

            write_vector_lane(2'd3, 1, lane, 32'(lane));
            write_vector_lane(2'd3, 2, lane, 32'(3000 + lane));
        end

        run_enable = 1'b1;

        begin : wait_load_and_queue_full
            integer timeout;
            timeout = 0;
            while (
                !(
                    miss_count == 1
                    && mshr_active_wave_mask_o[0]
                    && dut.store_queue_full
                    && dut.store_queue_occupancy == 2'd2
                )
                && timeout < 1200
            ) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 1200) begin
                $fatal(1, "load + full store queue state not reached");
            end
        end

        #1;
        if (live_line_addr != 29'd10 || mshr_full_o) begin
            $fatal(
                1,
                "live MSHR contract mismatch line=%0d full=%0d",
                live_line_addr,
                mshr_full_o
            );
        end
        if (rtl8c_store_req_count != 0) begin
            $fatal(1, "physical store escaped older load barrier");
        end
        if (dut.store_queue_active_wave_mask_unused != 4'b0110) begin
            $fatal(1, "unexpected queued waves before drain");
        end
        $display("RTL8C_MULTI_STORE_QUEUE_CONCURRENCY=PASS");
        $display("RTL8C_STORE_QUEUE_FULL_BACKPRESSURE_CORE=PASS");

        @(negedge clk);
        run_enable = 1'b0;
        repeat (8) @(posedge clk);
        #1;
        if (
            dut.store_queue_occupancy != 2'd2
            || dut.store_queue_active_wave_mask_unused != 4'b0110
            || rtl8c_store_req_count != 0
        ) begin
            $fatal(1, "pause changed queued store ownership");
        end

        @(negedge clk);
        mshr_mem_resp_valid_i = 1'b1;
        mshr_mem_resp_entry_i = live_entry;
        mshr_mem_resp_line_addr_i = live_line_addr;
        mshr_mem_resp_fault_i = 1'b0;
        #1;
        if (mshr_tag_error_o) begin
            $fatal(1, "correct paused load response rejected");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        mshr_mem_resp_valid_i = 1'b0;

        repeat (5) @(posedge clk);
        #1;
        if (
            dut.store_queue_occupancy != 2'd2
            || dut.store_queue_active_wave_mask_unused != 4'b0110
            || rtl8c_store_req_count != 0
        ) begin
            $fatal(1, "paused response caused store drain");
        end
        $display("RTL8C_PAUSE_PRESERVES_STORE_QUEUE=PASS");

        @(negedge clk);
        run_enable = 1'b1;

        begin : wait_first_store
            integer timeout;
            timeout = 0;
            while (rtl8c_store_req_count < 1 && timeout < 1200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 1200) begin
                $fatal(1, "first store request never launched");
            end
        end

        if (
            rtl8c_store_req_wave_log[0] != 1
            || rtl8c_store_req_context_log[0] != 1
            || rtl8c_store_req_addr0_log[0] != 160
            || rtl8c_store_req_data0_log[0] != 1000
        ) begin
            $fatal(1, "first store metadata/data mismatch");
        end

        begin : wait_three_pending_stores
            integer timeout;
            timeout = 0;
            while (
                !(
                    dut.mem_pending_valid_q
                    && !dut.mem_pending_load_q
                    && dut.store_queue_occupancy == 2'd2
                    && dut.store_queue_active_wave_mask_unused == 4'b1100
                )
                && timeout < 1200
            ) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 1200) begin
                $fatal(1, "1 physical + 2 queued store state not reached");
            end
        end

        if (
            dut.store_seq_next_q != 64'd3
            || dut.mem_owner_store_seq_q != 64'd0
        ) begin
            $fatal(
                1,
                "RTL8C-5A first physical sequence mismatch next=%0d physical=%0d",
                dut.store_seq_next_q,
                dut.mem_owner_store_seq_q
            );
        end

        $display("RTL8C5_STORE_SEQUENCE_MONOTONIC_CORE=PASS");

        repeat (8) @(posedge clk);
        if (rtl8c_store_req_count != 1) begin
            $fatal(1, "second store launched before first response");
        end
        $display("RTL8C_THREE_PENDING_STORES=PASS");
        $display("RTL8C_SINGLE_PHYSICAL_STORE_OUTSTANDING=PASS");

        /*
         * Queue insertion and physical request launch are not architectural
         * store retirement. No VSTOREX PC may have retired before the first
         * correctly tagged backend response.
         */
        for (
            rtl8c_scan_i = 0;
            rtl8c_scan_i < rtl8c_retire_count;
            rtl8c_scan_i = rtl8c_scan_i + 1
        ) begin
            if (
                rtl8c_retire_pc_log[rtl8c_scan_i] == 4
                || rtl8c_retire_pc_log[rtl8c_scan_i] == 8
                || rtl8c_retire_pc_log[rtl8c_scan_i] == 12
            ) begin
                $fatal(
                    1,
                    "store retired before backend response wave=%0d pc=%0d",
                    rtl8c_retire_wave_log[rtl8c_scan_i],
                    rtl8c_retire_pc_log[rtl8c_scan_i]
                );
            end
        end
        $display("RTL8C_NO_STORE_RETIRE_BEFORE_RESPONSE=PASS");

        @(negedge clk);
        mem_resp_valid_i = 1'b1;
        mem_resp_wave_i = 2'd2;
        mem_resp_context_i = 2'd2;
        mem_resp_fault_i = 1'b0;
        @(posedge clk);
        #1;
        if (!memory_tag_error_o) begin
            $fatal(1, "wrong store response tag did not raise error");
        end
        if (!dut.mem_pending_valid_q) begin
            $fatal(1, "wrong tag consumed outstanding store");
        end
        @(negedge clk);
        mem_resp_valid_i = 1'b0;
        $display("RTL8C_STORE_RESPONSE_TAG_GUARD=PASS");

        /*
         * A response to an already-launched physical store must be captured
         * while paused, but architectural retirement and the next FIFO drain
         * must remain blocked until run_enable returns.
         */
        @(negedge clk);
        run_enable = 1'b0;
        repeat (4) @(posedge clk);

        @(negedge clk);
        mem_resp_valid_i = 1'b1;
        mem_resp_wave_i = 2'd1;
        mem_resp_context_i = 2'd1;
        mem_resp_fault_i = 1'b0;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_resp_valid_i = 1'b0;

        repeat (4) @(posedge clk);
        #1;

        if (
            dut.mem_pending_valid_q
            || !dut.mem_complete_pending_q
        ) begin
            $fatal(
                1,
                "paused physical response was not buffered for completion"
            );
        end

        if (
            dut.store_queue_occupancy != 2'd2
            || dut.store_queue_active_wave_mask_unused != 4'b1100
            || rtl8c_store_req_count != 1
        ) begin
            $fatal(
                1,
                "paused physical response changed FIFO ownership"
            );
        end

        for (
            rtl8c_scan_i = 0;
            rtl8c_scan_i < rtl8c_retire_count;
            rtl8c_scan_i = rtl8c_scan_i + 1
        ) begin
            if (rtl8c_retire_pc_log[rtl8c_scan_i] == 4) begin
                $fatal(
                    1,
                    "physical store retired while run_enable was low"
                );
            end
        end

        $display(
            "RTL8C_PHYSICAL_STORE_RESPONSE_BUFFERED_DURING_PAUSE=PASS"
        );

        @(negedge clk);
        run_enable = 1'b1;

        begin : wait_second_store
            integer timeout;
            timeout = 0;
            while (rtl8c_store_req_count < 2 && timeout < 1200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 1200) begin
                $fatal(1, "second store request never launched");
            end
        end

        if (
            rtl8c_store_req_wave_log[1] != 2
            || rtl8c_store_req_context_log[1] != 2
            || rtl8c_store_req_addr0_log[1] != 180
            || rtl8c_store_req_data0_log[1] != 2000
        ) begin
            $fatal(1, "second FIFO store mismatch");
        end
        if (
            dut.store_seq_next_q != 64'd3
            || dut.mem_owner_store_seq_q != 64'd1
        ) begin
            $fatal(
                1,
                "RTL8C-5A second physical sequence mismatch next=%0d physical=%0d",
                dut.store_seq_next_q,
                dut.mem_owner_store_seq_q
            );
        end

        $display("RTL8C_STORE_FIFO_SECOND=PASS");

        @(negedge clk);
        mem_resp_valid_i = 1'b1;
        mem_resp_wave_i = 2'd2;
        mem_resp_context_i = 2'd2;
        mem_resp_fault_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_resp_valid_i = 1'b0;

        begin : wait_third_store
            integer timeout;
            timeout = 0;
            while (rtl8c_store_req_count < 3 && timeout < 1200) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 1200) begin
                $fatal(1, "third store request never launched");
            end
        end

        if (
            rtl8c_store_req_wave_log[2] != 3
            || rtl8c_store_req_context_log[2] != 3
            || rtl8c_store_req_addr0_log[2] != 200
            || rtl8c_store_req_data0_log[2] != 3000
        ) begin
            $fatal(1, "third FIFO store mismatch");
        end
        if (
            dut.store_seq_next_q != 64'd3
            || dut.mem_owner_store_seq_q != 64'd2
        ) begin
            $fatal(
                1,
                "RTL8C-5A third physical sequence mismatch next=%0d physical=%0d",
                dut.store_seq_next_q,
                dut.mem_owner_store_seq_q
            );
        end

        $display("RTL8C5_PHYSICAL_STORE_SEQUENCE_PRESERVED=PASS");
        $display("RTL8C_STORE_FAULT_CONTINUES_FIFO=PASS");

        @(negedge clk);
        mem_resp_valid_i = 1'b1;
        mem_resp_wave_i = 2'd3;
        mem_resp_context_i = 2'd3;
        mem_resp_fault_i = 1'b0;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_resp_valid_i = 1'b0;

        begin : wait_all_halted
            integer timeout;
            timeout = 0;
            while (!all_halted_o && timeout < 1600) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 1600) begin
                $fatal(1, "RTL8C multi-store program did not halt");
            end
        end

        rtl8c_store_retire_sequence = 0;
        for (
            rtl8c_scan_i = 0;
            rtl8c_scan_i < rtl8c_retire_count;
            rtl8c_scan_i = rtl8c_scan_i + 1
        ) begin
            if (
                rtl8c_retire_pc_log[rtl8c_scan_i] == 4
                || rtl8c_retire_pc_log[rtl8c_scan_i] == 8
                || rtl8c_retire_pc_log[rtl8c_scan_i] == 12
            ) begin
                case (rtl8c_store_retire_sequence)
                    0: if (
                        rtl8c_retire_wave_log[rtl8c_scan_i] != 1
                        || rtl8c_retire_pc_log[rtl8c_scan_i] != 4
                    ) $fatal(1, "first store retirement PC/order mismatch");
                    1: if (
                        rtl8c_retire_wave_log[rtl8c_scan_i] != 2
                        || rtl8c_retire_pc_log[rtl8c_scan_i] != 8
                    ) $fatal(1, "second store retirement PC/order mismatch");
                    2: if (
                        rtl8c_retire_wave_log[rtl8c_scan_i] != 3
                        || rtl8c_retire_pc_log[rtl8c_scan_i] != 12
                    ) $fatal(1, "third store retirement PC/order mismatch");
                    default: $fatal(1, "unexpected extra store retirement");
                endcase
                rtl8c_store_retire_sequence =
                    rtl8c_store_retire_sequence + 1;
            end
        end

        if (rtl8c_store_retire_sequence != 3) begin
            $fatal(1, "expected three store retirements");
        end
        $display("RTL8C_STORE_RETIRE_PC_FIFO=PASS");

        if (rtl8c_store_req_count != 3) begin
            $fatal(1, "expected exactly 3 physical stores");
        end

        if (
            memory_outstanding_o
            || dut.mem_pending_valid_q
            || !dut.store_queue_empty
            || dut.store_queue_occupancy != '0
            || mshr_occupancy_o != '0
            || mshr_active_wave_mask_o != '0
        ) begin
            $fatal(1, "final memory/store ownership did not drain");
        end
        $display("RTL8C_STORE_QUEUE_FINAL_DRAIN_CORE=PASS");

        if (!memory_tag_error_o) begin
            $fatal(1, "intentional tag error was not sticky");
        end
        if (!faulted_o) begin
            $fatal(1, "intentional backend store fault was not reported");
        end
        if (rtl8c_retire_count != 7) begin
            $fatal(1, "expected 7 architectural retirements");
        end

        /*
         * Observe the public architectural/debug surface after completion.
         * Predicate payload is checked only after this test explicitly wrote
         * register 1; reset is not assumed to initialise predicate payload.
         */
        debug_context_i = 2'd3;
        debug_scalar_reg_i = 3'd0;
        debug_predicate_reg_i = 2'd1;
        debug_vector_context_i = 2'd3;
        debug_vector_reg_i = 3'd2;
        debug_vector_lane_i = 2'd0;
        #1;
        if (
            !debug_context_valid_o
            || debug_pc_o != 4'd14
            || debug_exec_mask_o != 4'b1111
            || !debug_halted_o
            || debug_scalar_data_o != 32'd200
            || debug_predicate_data_o != 4'b0110
            || debug_vector_data_o != 32'd3000
        ) begin
            $fatal(
                1,
                "final debug contract mismatch valid=%0d pc=%0d exec=%b halt=%0d scalar=%0d pred=%b vector=%0d",
                debug_context_valid_o, debug_pc_o, debug_exec_mask_o,
                debug_halted_o, debug_scalar_data_o,
                debug_predicate_data_o, debug_vector_data_o
            );
        end
        if (
            engine_busy_o
            || valid_mask_o != 4'b1111
            || ready_mask_o != 4'b0000
            || halted_mask_o != 4'b1111
            || integer'(rr_cursor_o) >= RESIDENT_WAVES
        ) begin
            $fatal(
                1,
                "final scheduler contract mismatch busy=%0d valid=%b ready=%b halted=%b rr=%0d",
                engine_busy_o, valid_mask_o, ready_mask_o, halted_mask_o, rr_cursor_o
            );
        end

        $display("RTL8C_MULTI_STORE_INTEGRATION_TB=PASS");
        $finish;
    end

endmodule
