`timescale 1ns/1ps

module a0_multi_wave_core_rtl8b_mshr_edges_tb;

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
    integer merge_count;
    integer retire_count;
    logic [MSHR_ENTRY_W-1:0] live_entry;


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
        if (rst_n) begin
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
     * retire_* are registered by the DUT on the rising edge.
     * Sample the stable tuple on the falling edge and keep the
     * retirement counter single-owner.
     */
    always @(negedge clk) begin
        if (!rst_n) begin
            retire_count <= 0;
        end else if (retire_valid_o) begin
            if (!(
                (retire_wave_o == 1'd0 && retire_pc_o == PC_W'(0))
                || (retire_wave_o == 1'd1 && retire_pc_o == PC_W'(4))
            )) begin
                $fatal(
                    1,
                    "unexpected fault-path retirement wave=%0d pc=%0d",
                    retire_wave_o, retire_pc_o
                );
            end
            retire_count <= retire_count + 1;
        end
    end


    /* Capture the accepted physical miss request before the issue-state NBA. */
    always @(negedge clk) begin
        if (rst_n && mshr_mem_req_valid_o && mshr_mem_req_ready_i) begin
            if (mshr_mem_req_line_addr_o != MSHR_LINE_ADDR_W'(10)) begin
                $fatal(1, "unexpected physical miss line=%0d", mshr_mem_req_line_addr_o);
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
        clk = 1'b0; rst_n = 1'b0; run_enable = 1'b0; clear_loaders();
        program_waddr = '0; program_wdata = '0; alloc_wave_id = '0; alloc_pc = '0;
        alloc_exec_mask = '0; alloc_vrf_context_id = '0; release_wave_id = '0;
        scalar_wwave = '0; scalar_wreg = '0; scalar_wdata = '0;
        predicate_wwave = '0; predicate_wreg = '0; predicate_wdata = '0;
        vector_wcontext = '0; vector_wreg = '0; vector_wlane = '0; vector_wdata = '0;
        mem_resp_valid_i = 1'b0; mem_resp_wave_i = '0; mem_resp_context_i = '0; mem_resp_fault_i = 1'b0;
        mshr_mem_req_ready_i = 1'b1; mshr_mem_resp_valid_i = 1'b0;
        mshr_mem_resp_entry_i = '0; mshr_mem_resp_line_addr_i = '0; mshr_mem_resp_fault_i = 1'b0;
        policy_override_valid_i = 1'b0; policy_override_wave_i = '0;
        debug_vector_context_i = '0; debug_vector_reg_i = '0; debug_vector_lane_i = '0;
        debug_context_i = '0; debug_scalar_reg_i = '0; debug_predicate_reg_i = '0;
        miss_count = 0; merge_count = 0; live_entry = '0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) mem_resp_rdata_i[lane] = '0;
        for (word_index = 0; word_index < MSHR_LINE_WORDS; word_index = word_index + 1)
            mshr_mem_resp_line_data_i[word_index] = 32'(5000 + word_index);

        repeat (3) @(posedge clk); @(negedge clk); rst_n = 1'b1;

        write_program(0, encode_instruction(OP_VLOADX,4'h0,6'd3,6'd0,6'd1,6'd0,4'd0,24'd0));
        write_program(1, encode_instruction(OP_HALT,4'h0,6'd0,6'd0,6'd0,6'd0,4'd0,24'd0));
        write_program(4, encode_instruction(OP_VLOADX,4'h0,6'd3,6'd0,6'd1,6'd0,4'd0,24'd0));
        write_program(5, encode_instruction(OP_HALT,4'h0,6'd0,6'd0,6'd0,6'd0,4'd0,24'd0));

        allocate_context(1'd0,0); allocate_context(1'd1,4);
        write_scalar(1'd0,0,32'd80); write_scalar(1'd1,0,32'd80);
        /* Predicate register 1 is not consumed by this program; seed it to
         * make final debug provenance deterministic without changing execution. */
        write_predicate(1'd0, PREDICATE_INDEX_W'(1), 4'hA);
        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector_lane(1'd0,1,lane,32'(lane));
            write_vector_lane(1'd1,1,lane,32'(4 + lane));
            write_vector_lane(1'd0,3,lane,32'd7000);
            write_vector_lane(1'd1,3,lane,32'd7100);
        end

        run_enable = 1'b1;

        begin : wait_merge
            integer timeout; timeout = 0;
            while (!(miss_count == 1 && merge_count == 1 && mshr_active_wave_mask_o == 2'b11) && timeout < 400) begin
                @(posedge clk); timeout = timeout + 1;
            end
            if (timeout >= 400) $fatal(1, "merged live setup timeout");
        end

        if (mshr_occupancy_o != 1 || mshr_full_o || retire_count != 0)
            $fatal(1, "merged ownership mismatch occupancy=%0d full=%0b retire=%0d", mshr_occupancy_o, mshr_full_o, retire_count);

        /* Wrong line tag: must not consume the entry. */
        @(negedge clk);
        mshr_mem_resp_valid_i = 1'b1;
        mshr_mem_resp_entry_i = live_entry;
        mshr_mem_resp_line_addr_i = 29'd11;
        mshr_mem_resp_fault_i = 1'b0;
        #1;
        if (!mshr_tag_error_o || !memory_tag_error_o) $fatal(1, "bad response tag not surfaced before handshake");
        @(posedge clk); #1;
        @(negedge clk); mshr_mem_resp_valid_i = 1'b0;
        repeat (4) @(posedge clk);
        if (mshr_occupancy_o != 1 || mshr_active_wave_mask_o != 2'b11 || retire_count != 0)
            $fatal(1, "bad response consumed live ownership");
        $display("RTL8B_CORE_RESPONSE_TAG_GUARD=PASS");

        /* Correct tag with backend fault: one response must fault both waiters. */
        @(negedge clk);
        mshr_mem_resp_valid_i = 1'b1;
        mshr_mem_resp_entry_i = live_entry;
        mshr_mem_resp_line_addr_i = 29'd10;
        mshr_mem_resp_fault_i = 1'b1;
        @(posedge clk); #1; @(negedge clk); mshr_mem_resp_valid_i = 1'b0;

        begin : wait_fault_halt
            integer timeout; timeout = 0;
            while (!all_halted_o && timeout < 400) begin
                @(posedge clk); timeout = timeout + 1;
            end
            if (!all_halted_o) $fatal(1, "fault fanout did not halt both waves");
        end

        if (halted_mask_o != 2'b11 || retire_count != 2) $fatal(1, "fault retirement mismatch");
        if (memory_outstanding_o || mshr_occupancy_o != 0 || mshr_active_wave_mask_o != 0)
            $fatal(1, "fault path did not drain ownership");
        if (dut.scoreboard_vector_busy[0][3] || dut.scoreboard_vector_busy[1][3])
            $fatal(1, "fault path left scoreboard reservations");
        if (!faulted_o) $fatal(1, "core fault output did not latch");

        debug_context_i = 1'd0;
        debug_scalar_reg_i = SCALAR_REG_INDEX_W'(0);
        debug_predicate_reg_i = PREDICATE_INDEX_W'(1);
        debug_vector_context_i = 1'd0;
        debug_vector_reg_i = VECTOR_REG_INDEX_W'(3);
        debug_vector_lane_i = '0;
        #1;
        if (
            !debug_context_valid_o
            || integer'(debug_pc_o) >= PROGRAM_WORDS
            || debug_exec_mask_o != '1
            || !debug_halted_o
            || debug_scalar_data_o != 32'd80
            || debug_predicate_data_o != 4'hA
            || debug_vector_data_o != 32'd7000
        ) begin
            $fatal(
                1,
                "fault final debug contract mismatch valid=%0b pc=%0d exec=%b halted=%0b scalar=%0d pred=%b v3l0=%0d",
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
                "fault final scheduler contract mismatch busy=%0b valid=%b ready=%b halted=%b rr=%0d",
                engine_busy_o, valid_mask_o, ready_mask_o, halted_mask_o, rr_cursor_o
            );
        end

        $display("RTL8B_CORE_FAULT_FANOUT=PASS");
        $display("RTL8B_FAULT_SCOREBOARD_RELEASE=PASS");
        $display("RTL8B_MSHR_INTEGRATION_EDGE_TB=PASS");
        $finish;
    end

endmodule
