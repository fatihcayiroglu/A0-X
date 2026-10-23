`timescale 1ns/1ps

module a0_multi_wave_core_rtl9c1_l1_tb;

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

    localparam logic [7:0] OP_VLOADX  = 8'h54;
    localparam logic [7:0] OP_VSTOREX = 8'h55;
    localparam logic [7:0] OP_HALT    = 8'hFF;

    localparam logic [MSHR_LINE_ADDR_W-1:0]
        LINE_A = 29'd10;

    localparam logic [MSHR_LINE_ADDR_W-1:0]
        LINE_B = 29'd20;

    localparam logic [31:0]
        LINE_B_BASE_WORD = 32'(LINE_B) << 3;

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
    logic [31:0]
        mshr_mem_resp_line_data_i [0:MSHR_LINE_WORDS-1];

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

    integer backend_miss_count;
    integer legacy_store_count;
    integer legacy_read_count;

    logic [WAVE_ID_W-1:0] last_store_wave;
    logic [WAVE_ID_W-1:0] last_store_context;
    logic [WAVE_SIZE-1:0] last_store_lane_mask;
    logic [31:0] last_store_addr [0:WAVE_SIZE-1];
    logic [31:0] last_store_wdata [0:WAVE_SIZE-1];


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
        .mshr_mem_resp_line_addr_i(
            mshr_mem_resp_line_addr_i
        ),
        .mshr_mem_resp_fault_i(mshr_mem_resp_fault_i),
        .mshr_mem_resp_line_data_i(
            mshr_mem_resp_line_data_i
        ),

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


    /*
     * The MSHR backend request is an explicit ready/valid
     * handshake accepted on the rising edge.
     */
    always @(posedge clk) begin
        if (
            rst_n
            && mshr_mem_req_valid_o
            && mshr_mem_req_ready_i
        ) begin
            backend_miss_count <=
                backend_miss_count + 1;
        end
    end


    /*
     * mem_req_* are registered DUT outputs updated on the
     * rising edge. Match the proven RTL8B store harness and
     * sample the physical legacy request pulse on negedge.
     *
     * Use a block-local loop variable so this observer cannot
     * race with scenario/task code that uses the global lane
     * iterator.
     */
    /*
     * Physical legacy traffic accounting only.
     *
     * Payload capture deliberately does NOT occur here.
     * wait_store_request captures and validates the store
     * request in its own procedural thread.
     */
    always @(negedge clk) begin : legacy_request_observer
        if (rst_n && mem_req_valid_o) begin
            if (mem_req_write_o) begin
                legacy_store_count <=
                    legacy_store_count + 1;
            end else begin
                legacy_read_count <=
                    legacy_read_count + 1;
            end
        end
    end


    /*
     * Retirement is a public architectural event.  Consume the
     * complete identity rather than leaving wave/PC observability
     * dangling in this integration test.
     */
    always @(negedge clk) begin : retirement_contract
        if (rst_n && retire_valid_o) begin
            if (integer'(retire_wave_o) >= RESIDENT_WAVES) begin
                $fatal(
                    1,
                    "RTL9C1 retirement wave out of range wave=%0d pc=%0d",
                    retire_wave_o,
                    retire_pc_o
                );
            end

            if (
                dut.program_mem[retire_pc_o][63:56] != OP_VLOADX
                && dut.program_mem[retire_pc_o][63:56] != OP_VSTOREX
                && dut.program_mem[retire_pc_o][63:56] != OP_HALT
            ) begin
                $fatal(
                    1,
                    "RTL9C1 retirement PC does not reference a loaded test opcode wave=%0d pc=%0d opcode=%0h",
                    retire_wave_o,
                    retire_pc_o,
                    dut.program_mem[retire_pc_o][63:56]
                );
            end
        end
    end


    /*
     * Cross-check public aggregate/status outputs that are part of
     * the production core contract.  This test never intentionally
     * merges two live MSHR waiters; all same-line reuse is an L1 hit
     * or happens after the prior owner drained.
     */
    always @(negedge clk) begin : public_status_contract
        if (rst_n) begin
            if (
                mshr_full_o
                !== (mshr_occupancy_o == MSHR_OCCUPANCY_W'(MSHR_COUNT))
            ) begin
                $fatal(
                    1,
                    "RTL9C1 MSHR full/occupancy mismatch full=%0b occupancy=%0d",
                    mshr_full_o,
                    mshr_occupancy_o
                );
            end

            if (mshr_merge_event_o) begin
                $fatal(
                    1,
                    "RTL9C1 unexpected MSHR merge event in L1 integration matrix"
                );
            end

            if (integer'(rr_cursor_o) >= RESIDENT_WAVES) begin
                $fatal(
                    1,
                    "RTL9C1 scheduler RR cursor out of range cursor=%0d",
                    rr_cursor_o
                );
            end

            if (
                all_halted_o
                !== (
                    valid_mask_o != '0
                    && (halted_mask_o & valid_mask_o) == valid_mask_o
                )
            ) begin
                $fatal(
                    1,
                    "RTL9C1 all-halted aggregate mismatch all=%0b valid=%b halted=%b",
                    all_halted_o,
                    valid_mask_o,
                    halted_mask_o
                );
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
                $fatal(
                    1,
                    "RTL9C1 program address out of range address=%0d words=%0d",
                    address,
                    PROGRAM_WORDS
                );
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
            @(negedge clk);

            clear_loaders();

            alloc_valid = 1'b1;
            alloc_wave_id = wave_id;
            alloc_pc = PC_W'(start_pc);
            alloc_exec_mask = 8'h0F;
            alloc_vrf_context_id = wave_id;

            #1;

            if (!alloc_ready) begin
                $fatal(
                    1,
                    "RTL9C1 allocation not ready wave=%0d pc=%0d",
                    wave_id,
                    start_pc
                );
            end

            @(posedge clk);
            #1;

            @(negedge clk);
            alloc_valid = 1'b0;
        end
    endtask


    task automatic release_context(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        begin
            @(negedge clk);

            run_enable = 1'b0;
            clear_loaders();

            release_valid = 1'b1;
            release_wave_id = wave_id;

            @(posedge clk);
            #1;

            @(negedge clk);
            release_valid = 1'b0;

            #1;

            if (valid_mask_o[wave_id]) begin
                $fatal(
                    1,
                    "RTL9C1 release failed wave=%0d valid=%b",
                    wave_id,
                    valid_mask_o
                );
            end

            /* Invalid contexts must mask every public debug payload. */
            debug_context_i = wave_id;
            debug_scalar_reg_i = '0;
            debug_predicate_reg_i = '0;
            #1;

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
                    "RTL9C1 released-context debug masking failed wave=%0d valid=%0b pc=%0d exec=%b halted=%0b scalar=%0h predicate=%b",
                    wave_id,
                    debug_context_valid_o,
                    debug_pc_o,
                    debug_exec_mask_o,
                    debug_halted_o,
                    debug_scalar_data_o,
                    debug_predicate_data_o
                );
            end
        end
    endtask


    task automatic write_scalar(
        input logic [WAVE_ID_W-1:0] wave_id,
        input integer reg_id,
        input logic [31:0] value
    );
        begin
            if (reg_id < 0 || reg_id >= SCALAR_REG_COUNT) begin
                $fatal(
                    1,
                    "RTL9C1 scalar register out of range reg=%0d count=%0d",
                    reg_id,
                    SCALAR_REG_COUNT
                );
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


    task automatic write_vector_lane(
        input logic [WAVE_ID_W-1:0] context_id,
        input integer reg_id,
        input integer lane_id,
        input logic [31:0] value
    );
        begin
            if (reg_id < 0 || reg_id >= VECTOR_REG_COUNT) begin
                $fatal(
                    1,
                    "RTL9C1 vector register out of range reg=%0d count=%0d",
                    reg_id,
                    VECTOR_REG_COUNT
                );
            end

            if (lane_id < 0 || lane_id >= WAVE_SIZE) begin
                $fatal(
                    1,
                    "RTL9C1 vector lane out of range lane=%0d wave_size=%0d",
                    lane_id,
                    WAVE_SIZE
                );
            end

            @(negedge clk);

            clear_loaders();

            vector_we = 1'b1;
            vector_wcontext = context_id;
            vector_wreg =
                VECTOR_REG_INDEX_W'(reg_id);
            vector_wlane =
                $clog2(WAVE_SIZE)'(lane_id);
            vector_wdata = value;

            @(posedge clk);
            #1;

            @(negedge clk);
            vector_we = 1'b0;
        end
    endtask


    task automatic setup_load_operands(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [31:0] base_word,
        input logic [31:0] dst_sentinel
    );
        begin
            write_scalar(
                wave_id,
                0,
                base_word
            );

            for (
                lane = 0;
                lane < WAVE_SIZE;
                lane = lane + 1
            ) begin
                write_vector_lane(
                    wave_id,
                    1,
                    lane,
                    32'(lane)
                );

                write_vector_lane(
                    wave_id,
                    3,
                    lane,
                    dst_sentinel + lane
                );
            end
        end
    endtask


    task automatic setup_store_operands(
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [31:0] base_word,
        input logic [31:0] data_base
    );
        begin
            write_scalar(
                wave_id,
                0,
                base_word
            );

            for (
                lane = 0;
                lane < WAVE_SIZE;
                lane = lane + 1
            ) begin
                write_vector_lane(
                    wave_id,
                    1,
                    lane,
                    32'(lane)
                );

                write_vector_lane(
                    wave_id,
                    2,
                    lane,
                    data_base + lane
                );
            end
        end
    endtask


    task automatic expect_vector_lane(
        input logic [WAVE_ID_W-1:0] context_id,
        input integer reg_id,
        input integer lane_id,
        input logic [31:0] expected
    );
        begin
            debug_vector_context_i =
                context_id;

            debug_vector_reg_i =
                VECTOR_REG_INDEX_W'(reg_id);

            debug_vector_lane_i =
                $clog2(WAVE_SIZE)'(lane_id);

            #1;

            if (
                debug_vector_data_o
                !== expected
            ) begin
                $fatal(
                    1,
                    "RTL9C1 vector mismatch ctx=%0d reg=%0d lane=%0d expected=%0h actual=%0h",
                    context_id,
                    reg_id,
                    lane_id,
                    expected,
                    debug_vector_data_o
                );
            end
        end
    endtask


    task automatic wait_wave_halted(
        input logic [WAVE_ID_W-1:0] wave_id
    );
        integer timeout;

        begin
            timeout = 0;

            while (
                !halted_mask_o[wave_id]
                && timeout < 800
            ) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (!halted_mask_o[wave_id]) begin
                $fatal(
                    1,
                    "RTL9C1 wave halt timeout wave=%0d pc=%0d ready=%b valid=%b memout=%0b mshr_occ=%0d",
                    wave_id,
                    dut.context_pc_by_wave[wave_id],
                    ready_mask_o,
                    valid_mask_o,
                    memory_outstanding_o,
                    mshr_occupancy_o
                );
            end

            @(negedge clk);
            #1;
        end
    endtask


    task automatic accept_backend_miss(
        input logic [MSHR_LINE_ADDR_W-1:0]
            expected_line,
        output logic [MSHR_ENTRY_W-1:0]
            accepted_entry
    );
        integer timeout;
        integer count_before;

        logic [MSHR_ENTRY_W-1:0]
            observed_entry;

        logic [MSHR_LINE_ADDR_W-1:0]
            observed_line;

        logic [MSHR_ENTRY_W-1:0]
            accepted_edge_entry;

        logic [MSHR_LINE_ADDR_W-1:0]
            accepted_edge_line;

        begin
            count_before = backend_miss_count;

            mshr_mem_req_ready_i = 1'b0;
            timeout = 0;

            while (
                !mshr_mem_req_valid_o
                && timeout < 300
            ) begin
                @(negedge clk);
                timeout = timeout + 1;
            end

            if (!mshr_mem_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9C1 backend miss timeout expected_line=%0d occupancy=%0d active=%b",
                    expected_line,
                    mshr_occupancy_o,
                    mshr_active_wave_mask_o
                );
            end

            observed_entry =
                mshr_mem_req_entry_o;

            observed_line =
                mshr_mem_req_line_addr_o;

            if (observed_line != expected_line) begin
                $fatal(
                    1,
                    "RTL9C1 backend miss line mismatch expected=%0d actual=%0d entry=%0d",
                    expected_line,
                    observed_line,
                    observed_entry
                );
            end

            mshr_mem_req_ready_i = 1'b1;

            /*
             * RTL9C-1 V2:
             * allow the L1/backend ready path to settle before
             * the accepting rising edge.
             *
             * The V1 diagnostic proved that entry/line remain
             * stable across this interval.
             */
            #1;

            /*
             * Capture the accepted ready/valid payload directly
             * in this task at the accepting rising edge.
             *
             * The V2 diagnostic proved that entry and line were
             * stable before ready, after settle and at this edge.
             */
            @(posedge clk);

            accepted_edge_entry =
                mshr_mem_req_entry_o;

            accepted_edge_line =
                mshr_mem_req_line_addr_o;

            #1;

            if (
                backend_miss_count
                != count_before + 1
            ) begin
                $fatal(
                    1,
                    "RTL9C1 backend handshake count mismatch before=%0d after=%0d",
                    count_before,
                    backend_miss_count
                );
            end

            if (
                accepted_edge_entry != observed_entry
                || accepted_edge_line != observed_line
                || accepted_edge_line != expected_line
            ) begin
                $fatal(
                    1,
                    "RTL9C1 accepted miss payload changed pre_entry=%0d pre_line=%0d edge_entry=%0d edge_line=%0d expected_line=%0d",
                    observed_entry,
                    observed_line,
                    accepted_edge_entry,
                    accepted_edge_line,
                    expected_line
                );
            end

            accepted_entry =
                observed_entry;

            @(negedge clk);
            mshr_mem_req_ready_i = 1'b0;
        end
    endtask


    task automatic send_line_response(
        input logic [MSHR_ENTRY_W-1:0] entry,
        input logic [MSHR_LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] data_base
    );
        begin
            @(negedge clk);

            mshr_mem_resp_valid_i = 1'b1;
            mshr_mem_resp_entry_i = entry;
            mshr_mem_resp_line_addr_i =
                line_addr;
            mshr_mem_resp_fault_i = 1'b0;

            for (
                word_index = 0;
                word_index < MSHR_LINE_WORDS;
                word_index = word_index + 1
            ) begin
                mshr_mem_resp_line_data_i[
                    word_index
                ] = data_base + word_index;
            end

            #1;

            if (mshr_tag_error_o) begin
                $fatal(
                    1,
                    "RTL9C1 correct line response rejected entry=%0d line=%0d",
                    entry,
                    line_addr
                );
            end

            @(posedge clk);
            #1;

            @(negedge clk);
            mshr_mem_resp_valid_i = 1'b0;
        end
    endtask


    /*
     * Faulted backend response for the core-level L1 proof.
     *
     * A faulted refill must still traverse:
     *
     * external backend
     *   -> L1 response path
     *   -> memory service boundary
     *   -> MSHR bridge
     *   -> core load completion
     *
     * but it must never install the returned line into L1.
     */
    task automatic send_faulted_line_response(
        input logic [MSHR_ENTRY_W-1:0] entry,
        input logic [MSHR_LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);

            mshr_mem_resp_valid_i =
                1'b1;

            mshr_mem_resp_entry_i =
                entry;

            mshr_mem_resp_line_addr_i =
                line_addr;

            mshr_mem_resp_fault_i =
                1'b1;

            for (
                word_index = 0;
                word_index < MSHR_LINE_WORDS;
                word_index = word_index + 1
            ) begin
                mshr_mem_resp_line_data_i[
                    word_index
                ] =
                    32'hF300_0000
                    + 32'(word_index);
            end

            #1;

            if (mshr_tag_error_o) begin
                $fatal(
                    1,
                    "RTL9C1 correctly tagged faulted response rejected entry=%0d line=%0d",
                    entry,
                    line_addr
                );
            end

            @(posedge clk);
            #1;

            @(negedge clk);

            mshr_mem_resp_valid_i =
                1'b0;

            mshr_mem_resp_fault_i =
                1'b0;
        end
    endtask


    task automatic wait_store_request(
        input integer count_before,
        input logic [31:0] expected_base_word,
        input logic [31:0] expected_data_base
    );
        integer timeout;
        integer capture_lane;
        logic captured;

        begin
            timeout = 0;
            captured = 1'b0;

            /*
             * Capture the physical registered request directly
             * in this task. The previous diagnostic proved that
             * mem_req_* carries the correct wave/context/mask/
             * address/data throughout the store pulse.
             */
            while (
                !captured
                && timeout < 500
            ) begin
                @(negedge clk);
                #1;

                if (
                    rst_n
                    && mem_req_valid_o
                    && mem_req_write_o
                ) begin
                    last_store_wave =
                        mem_req_wave_o;

                    last_store_context =
                        mem_req_context_o;

                    last_store_lane_mask =
                        mem_req_lane_mask_o;

                    for (
                        capture_lane = 0;
                        capture_lane < WAVE_SIZE;
                        capture_lane = capture_lane + 1
                    ) begin
                        last_store_addr[capture_lane] =
                            mem_req_addr_o[capture_lane];

                        last_store_wdata[capture_lane] =
                            mem_req_wdata_o[capture_lane];
                    end

                    captured = 1'b1;
                end

                timeout = timeout + 1;
            end

            if (!captured) begin
                $fatal(
                    1,
                    "RTL9C1 physical store request timeout before=%0d after=%0d",
                    count_before,
                    legacy_store_count
                );
            end

            /*
             * The counter observer sampled the same physical
             * pulse at the preceding negedge. Check it only on
             * the following edge, never in the same event slot.
             */
            @(posedge clk);
            #1;

            if (
                legacy_store_count
                != count_before + 1
            ) begin
                $fatal(
                    1,
                    "RTL9C1 store launch count mismatch before=%0d after=%0d",
                    count_before,
                    legacy_store_count
                );
            end

            if (
                last_store_lane_mask
                != 8'h0F
            ) begin
                $fatal(
                    1,
                    "RTL9C1 store lane mask mismatch mask=%b",
                    last_store_lane_mask
                );
            end

            for (
                capture_lane = 0;
                capture_lane < PHYSICAL_LANES;
                capture_lane = capture_lane + 1
            ) begin
                if (
                    last_store_addr[capture_lane]
                    != expected_base_word + capture_lane
                ) begin
                    $fatal(
                        1,
                        "RTL9C1 store address mismatch lane=%0d expected=%0d actual=%0d",
                        capture_lane,
                        expected_base_word + capture_lane,
                        last_store_addr[capture_lane]
                    );
                end

                if (
                    last_store_wdata[capture_lane]
                    != expected_data_base + capture_lane
                ) begin
                    $fatal(
                        1,
                        "RTL9C1 store data mismatch lane=%0d expected=%h actual=%h",
                        capture_lane,
                        expected_data_base + capture_lane,
                        last_store_wdata[capture_lane]
                    );
                end
            end
        end
    endtask


    task automatic send_store_response;
        begin
            @(negedge clk);

            mem_resp_valid_i = 1'b1;
            mem_resp_wave_i = last_store_wave;
            mem_resp_context_i =
                last_store_context;
            mem_resp_fault_i = 1'b0;

            @(posedge clk);
            #1;

            @(negedge clk);
            mem_resp_valid_i = 1'b0;
        end
    endtask


    initial begin
        logic [MSHR_ENTRY_W-1:0]
            entry_a_first;

        logic [MSHR_ENTRY_W-1:0]
            entry_a_after_store;

        integer misses_before;
        integer stores_before;

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

        backend_miss_count = 0;
        legacy_store_count = 0;
        legacy_read_count = 0;
        last_store_wave = '0;
        last_store_context = '0;
        last_store_lane_mask = '0;

        for (
            lane = 0;
            lane < WAVE_SIZE;
            lane = lane + 1
        ) begin
            mem_resp_rdata_i[lane] = '0;
            last_store_addr[lane] = '0;
            last_store_wdata[lane] = '0;
        end

        for (
            word_index = 0;
            word_index < MSHR_LINE_WORDS;
            word_index = word_index + 1
        ) begin
            mshr_mem_resp_line_data_i[
                word_index
            ] = '0;
        end

        repeat (3) @(posedge clk);

        @(negedge clk);
        rst_n = 1'b1;

        /*
         * Programs:
         *
         * 0 : cold load line A
         * 2 : second same-line load
         * 4 : store line A
         * 6 : load line A after invalidation
         * 8 : store unrelated line B
         * 10: load A after unrelated store
         * 12: wave0 cached load A
         * 14: wave1 cached load A
         */
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

        write_program(
            2,
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

        write_program(
            3,
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
            4,
            encode_instruction(
                OP_VSTOREX,
                4'h0,
                6'd0,
                6'd0,
                6'd1,
                6'd2,
                4'd0,
                24'd0
            )
        );

        write_program(
            5,
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
            6,
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

        write_program(
            7,
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
                OP_VSTOREX,
                4'h0,
                6'd0,
                6'd0,
                6'd1,
                6'd2,
                4'd0,
                24'd0
            )
        );

        write_program(
            9,
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
            10,
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

        write_program(
            12,
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

        write_program(
            13,
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
            14,
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

        write_program(
            15,
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

        /*
         * Scenario 1:
         * cold core load -> physical line miss -> refill.
         */
        allocate_context(2'd0, 0);

        setup_load_operands(
            2'd0,
            32'd80,
            32'hDEAD_1000
        );

        run_enable = 1'b1;

        accept_backend_miss(
            LINE_A,
            entry_a_first
        );

        if (legacy_read_count != 0) begin
            $fatal(
                1,
                "RTL9C1 VLOADX escaped onto legacy read path count=%0d",
                legacy_read_count
            );
        end

        $display(
            "RTL9C1_COLD_LOAD_MISS_REACHES_BACKEND=PASS"
        );

        $display(
            "RTL9C1_NO_LEGACY_READ_REQUEST=PASS"
        );

        send_line_response(
            entry_a_first,
            LINE_A,
            32'd1000
        );

        wait_wave_halted(2'd0);

        for (
            lane = 0;
            lane < PHYSICAL_LANES;
            lane = lane + 1
        ) begin
            expect_vector_lane(
                2'd0,
                3,
                lane,
                32'(1000 + lane)
            );
        end

        $display(
            "RTL9C1_REFILL_COMPLETES_LOAD=PASS"
        );

        $display(
            "RTL9C1_REFILL_DATA_REACHES_WAVE=PASS"
        );

        release_context(2'd0);

        /*
         * Scenario 2:
         * same line through a different wave must hit L1.
         */
        allocate_context(2'd1, 2);

        setup_load_operands(
            2'd1,
            32'd80,
            32'hDEAD_2000
        );

        misses_before = backend_miss_count;

        mshr_mem_req_ready_i = 1'b1;
        run_enable = 1'b1;

        wait_wave_halted(2'd1);

        if (
            backend_miss_count
            != misses_before
        ) begin
            $fatal(
                1,
                "RTL9C1 same-line hit leaked backend request before=%0d after=%0d",
                misses_before,
                backend_miss_count
            );
        end

        for (
            lane = 0;
            lane < PHYSICAL_LANES;
            lane = lane + 1
        ) begin
            expect_vector_lane(
                2'd1,
                3,
                lane,
                32'(1000 + lane)
            );
        end

        $display(
            "RTL9C1_SECOND_SAME_LINE_LOAD_ACCEPTED=PASS"
        );

        $display(
            "RTL9C1_SECOND_SAME_LINE_LOAD_HITS_L1=PASS"
        );

        $display(
            "RTL9C1_HIT_SUPPRESSES_BACKEND_REQUEST=PASS"
        );

        $display(
            "RTL9C1_HIT_DATA_REACHES_WAVE=PASS"
        );

        release_context(2'd1);

        /*
         * Scenario 3:
         * physical legacy store to cached line A invalidates it.
         */
        allocate_context(2'd2, 4);

        setup_store_operands(
            2'd2,
            32'd80,
            32'hA100_0000
        );

        stores_before = legacy_store_count;

        run_enable = 1'b1;

        wait_store_request(
            stores_before,
            32'd80,
            32'hA100_0000
        );

        $display(
            "RTL9C1_STORE_TO_CACHED_LINE_LAUNCHES_LEGACY=PASS"
        );

        send_store_response();

        wait_wave_halted(2'd2);

        release_context(2'd2);

        /*
         * Scenario 4:
         * load A after store must miss again.
         */
        allocate_context(2'd0, 6);

        setup_load_operands(
            2'd0,
            32'd80,
            32'hDEAD_3000
        );

        misses_before = backend_miss_count;

        run_enable = 1'b1;

        accept_backend_miss(
            LINE_A,
            entry_a_after_store
        );

        if (
            backend_miss_count
            != misses_before + 1
        ) begin
            $fatal(
                1,
                "RTL9C1 expected miss after same-line store"
            );
        end

        $display(
            "RTL9C1_STORE_TO_CACHED_LINE_INVALIDATES=PASS"
        );

        $display(
            "RTL9C1_LOAD_AFTER_STORE_MISSES_AGAIN=PASS"
        );

        send_line_response(
            entry_a_after_store,
            LINE_A,
            32'd2000
        );

        wait_wave_halted(2'd0);

        for (
            lane = 0;
            lane < PHYSICAL_LANES;
            lane = lane + 1
        ) begin
            expect_vector_lane(
                2'd0,
                3,
                lane,
                32'(2000 + lane)
            );
        end

        release_context(2'd0);

        /*
         * Scenario 5:
         * store to unrelated line B must preserve cached A.
         */
        allocate_context(2'd1, 8);

        setup_store_operands(
            2'd1,
            LINE_B_BASE_WORD,
            32'hB100_0000
        );

        stores_before = legacy_store_count;

        run_enable = 1'b1;

        wait_store_request(
            stores_before,
            LINE_B_BASE_WORD,
            32'hB100_0000
        );

        send_store_response();

        wait_wave_halted(2'd1);

        release_context(2'd1);

        allocate_context(2'd2, 10);

        setup_load_operands(
            2'd2,
            32'd80,
            32'hDEAD_4000
        );

        misses_before = backend_miss_count;

        mshr_mem_req_ready_i = 1'b1;
        run_enable = 1'b1;

        wait_wave_halted(2'd2);

        if (
            backend_miss_count
            != misses_before
        ) begin
            $fatal(
                1,
                "RTL9C1 unrelated store destroyed cached line A"
            );
        end

        for (
            lane = 0;
            lane < PHYSICAL_LANES;
            lane = lane + 1
        ) begin
            expect_vector_lane(
                2'd2,
                3,
                lane,
                32'(2000 + lane)
            );
        end

        $display(
            "RTL9C1_STORE_OTHER_LINE_PRESERVES_CACHED_LINE=PASS"
        );

        release_context(2'd2);

        /*
         * Scenario 6:
         * two independent waves consume already-cached line A.
         */
        allocate_context(2'd0, 12);
        setup_load_operands(
            2'd0,
            32'd80,
            32'hDEAD_5000
        );

        allocate_context(2'd1, 14);
        setup_load_operands(
            2'd1,
            32'd80,
            32'hDEAD_6000
        );

        misses_before = backend_miss_count;

        mshr_mem_req_ready_i = 1'b1;
        run_enable = 1'b1;

        begin : wait_two_cached_waves
            integer timeout;

            timeout = 0;

            while (
                !(
                    halted_mask_o[0]
                    && halted_mask_o[1]
                )
                && timeout < 800
            ) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (
                !halted_mask_o[0]
                || !halted_mask_o[1]
            ) begin
                $fatal(
                    1,
                    "RTL9C1 two-wave cached-hit timeout halted=%b",
                    halted_mask_o
                );
            end
        end

        @(negedge clk);
        #1;

        if (engine_busy_o || !all_halted_o) begin
            $fatal(
                1,
                "RTL9C1 cached waves did not reach quiescent all-halted state busy=%0b all_halted=%0b halted=%b",
                engine_busy_o,
                all_halted_o,
                halted_mask_o
            );
        end

        if (
            backend_miss_count
            != misses_before
        ) begin
            $fatal(
                1,
                "RTL9C1 multi-wave cached hit leaked backend request"
            );
        end

        for (
            lane = 0;
            lane < PHYSICAL_LANES;
            lane = lane + 1
        ) begin
            expect_vector_lane(
                2'd0,
                3,
                lane,
                32'(2000 + lane)
            );

            expect_vector_lane(
                2'd1,
                3,
                lane,
                32'(2000 + lane)
            );
        end

        $display(
            "RTL9C1_MULTI_WAVE_SAME_LINE_HIT=PASS"
        );

        run_enable = 1'b0;

        /*
         * Final architectural / physical drain.
         */
        if (legacy_read_count != 0) begin
            $fatal(
                1,
                "RTL9C1 unexpected legacy read count=%0d",
                legacy_read_count
            );
        end

        if (
            memory_outstanding_o
            || mshr_occupancy_o != 0
            || mshr_active_wave_mask_o != 0
        ) begin
            $fatal(
                1,
                "RTL9C1 final memory drain failed outstanding=%0b occupancy=%0d active=%b",
                memory_outstanding_o,
                mshr_occupancy_o,
                mshr_active_wave_mask_o
            );
        end

        if (
            faulted_o
            || memory_tag_error_o
            || mshr_tag_error_o
        ) begin
            $fatal(
                1,
                "RTL9C1 unexpected fault/tag error fault=%0b memtag=%0b mshrtag=%0b",
                faulted_o,
                memory_tag_error_o,
                mshr_tag_error_o
            );
        end

        if (backend_miss_count != 2) begin
            $fatal(
                1,
                "RTL9C1 expected exactly two backend misses got=%0d",
                backend_miss_count
            );
        end

        if (legacy_store_count != 2) begin
            $fatal(
                1,
                "RTL9C1 expected exactly two legacy stores got=%0d",
                legacy_store_count
            );
        end

        $display(
            "RTL9C1_FINAL_MSHR_DRAIN=PASS"
        );


        /*
         * ====================================================
         * Scenario 7 — core-level faulted refill proof.
         * ====================================================
         *
         * Use a new line:
         *
         *   word base 240 -> line 30
         *
         * The reset below only isolates this scenario from the
         * already-PASS base matrix.
         *
         * CRITICAL:
         *
         * There is NO reset between the faulted response and
         * wave1's retry of line 30.
         *
         * Therefore a second external miss for line 30 proves
         * the faulted refill was not installed in L1.
         */
        begin : rtl9c1_faulted_refill_edge
            logic [MSHR_ENTRY_W-1:0]
                fault_entry;

            logic [MSHR_ENTRY_W-1:0]
                retry_entry;

            logic fault_forward_seen;

            integer timeout;
            integer fault_lane;
            integer legacy_reads_before;

            /*
             * Isolate the fault scenario from all earlier cache
             * contents and wave state.
             */
            @(negedge clk);

            run_enable =
                1'b0;

            clear_loaders();

            mshr_mem_req_ready_i =
                1'b0;

            mshr_mem_resp_valid_i =
                1'b0;

            mshr_mem_resp_fault_i =
                1'b0;

            mem_resp_valid_i =
                1'b0;

            mem_resp_fault_i =
                1'b0;

            rst_n =
                1'b0;

            repeat (3) @(posedge clk);

            @(negedge clk);

            rst_n =
                1'b1;

            /*
             * wave0:
             *
             *   VLOADX V3, S0 + V1
             *   HALT
             *
             * wave1:
             *
             *   VLOADX V4, S0 + V1
             *   HALT
             */
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

            write_program(
                4,
                encode_instruction(
                    OP_VLOADX,
                    4'h0,
                    6'd4,
                    6'd0,
                    6'd1,
                    6'd0,
                    4'd0,
                    24'd0
                )
            );

            write_program(
                5,
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

            /*
             * First owner: wave0 / context0.
             */
            allocate_context(
                2'd0,
                0
            );

            write_scalar(
                2'd0,
                0,
                32'd240
            );

            for (
                fault_lane = 0;
                fault_lane < WAVE_SIZE;
                fault_lane = fault_lane + 1
            ) begin
                write_vector_lane(
                    2'd0,
                    1,
                    fault_lane,
                    32'(fault_lane)
                );
            end

            legacy_reads_before =
                legacy_read_count;

            run_enable =
                1'b1;

            /*
             * Cold line30 must reach the real external line
             * backend.
             */
            accept_backend_miss(
                29'd30,
                fault_entry
            );

            $display(
                "RTL9C1_FAULTED_LOAD_MISS_REACHES_BACKEND=PASS"
            );

            /*
             * Drive the faulted refill while independently
             * watching the actual core-side MSHR completion
             * ready/valid handshake.
             *
             * Sampling both the active edge and #1 settled
             * state avoids a testbench scheduling assumption.
             */
            fault_forward_seen =
                1'b0;

            fork : rtl9c1_fault_forwarding_proof
                begin : drive_fault_response
                    send_faulted_line_response(
                        fault_entry,
                        29'd30
                    );
                end

                begin : watch_fault_completion
                    integer fault_watch_timeout;

                    fault_watch_timeout =
                        0;

                    while (
                        !fault_forward_seen
                        && fault_watch_timeout < 500
                    ) begin
                        @(posedge clk);

                        if (
                            dut.load_mshr_complete_valid
                            && dut.load_mshr_complete_ready
                            && dut.load_mshr_complete_fault
                        ) begin
                            fault_forward_seen =
                                1'b1;
                        end

                        #1;

                        if (
                            dut.load_mshr_complete_valid
                            && dut.load_mshr_complete_ready
                            && dut.load_mshr_complete_fault
                        ) begin
                            fault_forward_seen =
                                1'b1;
                        end

                        fault_watch_timeout =
                            fault_watch_timeout + 1;
                    end

                    if (!fault_forward_seen) begin
                        $fatal(
                            1,
                            "RTL9C1 faulted refill did not reach core MSHR completion handshake"
                        );
                    end
                end
            join

            /*
             * The fault completion must fully release the
             * physical MSHR ownership before the retry.
             */
            timeout =
                0;

            while (
                (
                    memory_outstanding_o
                    || mshr_occupancy_o != 0
                    || mshr_active_wave_mask_o != 0
                )
                && timeout < 800
            ) begin
                @(posedge clk);
                timeout =
                    timeout + 1;
            end

            if (timeout >= 800) begin
                $fatal(
                    1,
                    "RTL9C1 faulted completion did not drain memory ownership outstanding=%b occupancy=%0d active=%b",
                    memory_outstanding_o,
                    mshr_occupancy_o,
                    mshr_active_wave_mask_o
                );
            end

            if (
                mshr_tag_error_o
                || memory_tag_error_o
            ) begin
                $fatal(
                    1,
                    "RTL9C1 faulted response produced a tag error mshr=%b memory=%b",
                    mshr_tag_error_o,
                    memory_tag_error_o
                );
            end

            $display(
                "RTL9C1_FAULTED_REFILL_FORWARDED_TO_CORE=PASS"
            );

            /*
             * Pause before introducing the independent retry
             * wave.
             *
             * NO RESET occurs here.
             */
            @(negedge clk);

            run_enable =
                1'b0;

            /*
             * Second owner: wave1 / context1, same line30.
             */
            allocate_context(
                2'd1,
                4
            );

            write_scalar(
                2'd1,
                0,
                32'd240
            );

            for (
                fault_lane = 0;
                fault_lane < WAVE_SIZE;
                fault_lane = fault_lane + 1
            ) begin
                write_vector_lane(
                    2'd1,
                    1,
                    fault_lane,
                    32'(fault_lane)
                );
            end

            run_enable =
                1'b1;

            /*
             * This is the decisive not-cached proof.
             *
             * If the faulted refill had installed line30 in L1,
             * this task would never observe an external backend
             * miss and would time out.
             */
            accept_backend_miss(
                29'd30,
                retry_entry
            );

            $display(
                "RTL9C1_FAULTED_REFILL_NOT_CACHED=PASS"
            );

            $display(
                "RTL9C1_FAULT_RETRY_SAME_LINE_MISSES_AGAIN=PASS"
            );

            /*
             * Complete the retry successfully.
             */
            send_line_response(
                retry_entry,
                29'd30,
                32'd5000
            );

            timeout =
                0;

            while (
                (
                    !halted_mask_o[1]
                    || memory_outstanding_o
                    || mshr_occupancy_o != 0
                    || mshr_active_wave_mask_o != 0
                )
                && timeout < 1000
            ) begin
                @(posedge clk);
                timeout =
                    timeout + 1;
            end

            if (timeout >= 1000) begin
                $fatal(
                    1,
                    "RTL9C1 successful fault retry did not finish halted=%b outstanding=%b occupancy=%0d active=%b",
                    halted_mask_o[1],
                    memory_outstanding_o,
                    mshr_occupancy_o,
                    mshr_active_wave_mask_o
                );
            end

            /*
             * Active mask is 8'h0F, therefore lanes 0..3 must
             * receive the successful refill data.
             */
            for (
                fault_lane = 0;
                fault_lane < PHYSICAL_LANES;
                fault_lane = fault_lane + 1
            ) begin
                expect_vector_lane(
                    2'd1,
                    4,
                    fault_lane,
                    32'(5000 + fault_lane)
                );
            end

            if (
                legacy_read_count
                != legacy_reads_before
            ) begin
                $fatal(
                    1,
                    "RTL9C1 fault scenario incorrectly used legacy load path before=%0d after=%0d",
                    legacy_reads_before,
                    legacy_read_count
                );
            end

            if (
                mshr_tag_error_o
                || memory_tag_error_o
            ) begin
                $fatal(
                    1,
                    "RTL9C1 retry produced tag error mshr=%b memory=%b",
                    mshr_tag_error_o,
                    memory_tag_error_o
                );
            end

            $display(
                "RTL9C1_FAULT_RETRY_SUCCESS_DATA_REACHES_WAVE=PASS"
            );
        end

        $display(
            "RTL9C1_CORE_L1_END_TO_END_TB=PASS"
        );

        $finish;
    end

endmodule
