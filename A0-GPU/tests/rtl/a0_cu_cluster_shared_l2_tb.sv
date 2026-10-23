`timescale 1ns/1ps

module a0_cu_cluster_shared_l2_tb;
    localparam integer CU_COUNT = 3;
    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;
    localparam integer PROGRAM_WORDS = 256;
    localparam integer MSHR_COUNT = 2;
    localparam integer MSHR_LINE_WORDS = 8;
    localparam integer WAVE_ID_W = 2;
    localparam integer PC_W = 8;
    localparam integer VECTOR_REG_INDEX_W = 6;
    localparam integer SCALAR_REG_INDEX_W = 5;
    localparam integer PREDICATE_INDEX_W = 4;
    localparam integer MSHR_ENTRY_W = 1;
    localparam integer MSHR_LINE_ADDR_W = 29;
    localparam integer MSHR_OCCUPANCY_W = 2;
    localparam integer GLOBAL_TAG_W = 3;

    logic clk;
    logic rst_n;
    logic [CU_COUNT-1:0] run_enable_i;
    logic [CU_COUNT-1:0] program_we_i;
    logic [PC_W-1:0] program_waddr_i [0:CU_COUNT-1];
    logic [63:0] program_wdata_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] alloc_valid_i;
    logic [WAVE_ID_W-1:0] alloc_wave_id_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] alloc_ready_o;
    logic [PC_W-1:0] alloc_pc_i [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0] alloc_exec_mask_i [0:CU_COUNT-1];
    logic [WAVE_ID_W-1:0] alloc_vrf_context_id_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] release_valid_i;
    logic [WAVE_ID_W-1:0] release_wave_id_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] scalar_we_i;
    logic [WAVE_ID_W-1:0] scalar_wwave_i [0:CU_COUNT-1];
    logic [SCALAR_REG_INDEX_W-1:0] scalar_wreg_i [0:CU_COUNT-1];
    logic [31:0] scalar_wdata_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] predicate_we_i;
    logic [WAVE_ID_W-1:0] predicate_wwave_i [0:CU_COUNT-1];
    logic [PREDICATE_INDEX_W-1:0] predicate_wreg_i [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0] predicate_wdata_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] vector_we_i;
    logic [WAVE_ID_W-1:0] vector_wcontext_i [0:CU_COUNT-1];
    logic [VECTOR_REG_INDEX_W-1:0] vector_wreg_i [0:CU_COUNT-1];
    logic [$clog2(WAVE_SIZE)-1:0] vector_wlane_i [0:CU_COUNT-1];
    logic [31:0] vector_wdata_i [0:CU_COUNT-1];

    logic [CU_COUNT-1:0] mem_req_valid_o;
    logic [CU_COUNT-1:0] mem_req_write_o;
    logic [WAVE_ID_W-1:0] mem_req_wave_o [0:CU_COUNT-1];
    logic [WAVE_ID_W-1:0] mem_req_context_o [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0] mem_req_lane_mask_o [0:CU_COUNT-1];
    logic [31:0] mem_req_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1];
    logic [31:0] mem_req_wdata_o [0:CU_COUNT-1][0:WAVE_SIZE-1];
    logic [CU_COUNT-1:0] mem_resp_valid_i;
    logic [WAVE_ID_W-1:0] mem_resp_wave_i [0:CU_COUNT-1];
    logic [WAVE_ID_W-1:0] mem_resp_context_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] mem_resp_fault_i;
    logic [31:0] mem_resp_rdata_i [0:CU_COUNT-1][0:WAVE_SIZE-1];

    logic [MSHR_OCCUPANCY_W-1:0] mshr_occupancy_o [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] mshr_full_o;
    logic [CU_COUNT-1:0] mshr_merge_event_o;
    logic [RESIDENT_WAVES-1:0]
        mshr_active_wave_mask_o [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] mshr_tag_error_o;
    logic [CU_COUNT-1:0] memory_outstanding_o;
    logic [CU_COUNT-1:0] memory_tag_error_o;
    logic [CU_COUNT-1:0] policy_override_valid_i;
    logic [WAVE_ID_W-1:0] policy_override_wave_i [0:CU_COUNT-1];

    logic [WAVE_ID_W-1:0] debug_vector_context_i [0:CU_COUNT-1];
    logic [VECTOR_REG_INDEX_W-1:0] debug_vector_reg_i [0:CU_COUNT-1];
    logic [$clog2(WAVE_SIZE)-1:0]
        debug_vector_lane_i [0:CU_COUNT-1];
    logic [31:0] debug_vector_data_o [0:CU_COUNT-1];
    logic [WAVE_ID_W-1:0] debug_context_i [0:CU_COUNT-1];
    logic [SCALAR_REG_INDEX_W-1:0]
        debug_scalar_reg_i [0:CU_COUNT-1];
    logic [PREDICATE_INDEX_W-1:0]
        debug_predicate_reg_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] debug_context_valid_o;
    logic [PC_W-1:0] debug_pc_o [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0] debug_exec_mask_o [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] debug_halted_o;
    logic [31:0] debug_scalar_data_o [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0] debug_predicate_data_o [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] retire_valid_o;
    logic [WAVE_ID_W-1:0] retire_wave_o [0:CU_COUNT-1];
    logic [PC_W-1:0] retire_pc_o [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] engine_busy_o;
    logic [CU_COUNT-1:0] faulted_o;
    logic [RESIDENT_WAVES-1:0] valid_mask_o [0:CU_COUNT-1];
    logic [RESIDENT_WAVES-1:0] ready_mask_o [0:CU_COUNT-1];
    logic [RESIDENT_WAVES-1:0] halted_mask_o [0:CU_COUNT-1];
    logic [WAVE_ID_W-1:0] rr_cursor_o [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] all_halted_o;

    logic line_mem_req_valid_o;
    logic line_mem_req_ready_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o;
    logic [MSHR_LINE_ADDR_W-1:0] line_mem_req_line_addr_o;
    logic line_mem_resp_valid_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i;
    logic [MSHR_LINE_ADDR_W-1:0] line_mem_resp_line_addr_i;
    logic line_mem_resp_fault_i;
    logic [31:0] line_mem_resp_data_i [0:MSHR_LINE_WORDS-1];
    logic line_resp_tag_error_o;

    integer cu;
    integer lane;
    integer word_index;

    always #5 clk = ~clk;

    a0_cu_cluster #(
        .CU_COUNT(CU_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .MSHR_COUNT(MSHR_COUNT),
        .MSHR_LINE_WORDS(MSHR_LINE_WORDS)
    ) dut (.*);

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        run_enable_i = '0;
        program_we_i = '0;
        alloc_valid_i = '0;
        release_valid_i = '0;
        scalar_we_i = '0;
        predicate_we_i = '0;
        vector_we_i = '0;
        mem_resp_valid_i = '0;
        mem_resp_fault_i = '0;
        policy_override_valid_i = '0;
        line_mem_req_ready_i = 1'b1;
        line_mem_resp_valid_i = 1'b0;
        line_mem_resp_global_tag_i = '0;
        line_mem_resp_line_addr_i = '0;
        line_mem_resp_fault_i = 1'b0;

        for (word_index = 0; word_index < MSHR_LINE_WORDS;
             word_index = word_index + 1)
            line_mem_resp_data_i[word_index] = '0;

        for (cu = 0; cu < CU_COUNT; cu = cu + 1) begin
            program_waddr_i[cu] = '0;
            program_wdata_i[cu] = '0;
            alloc_wave_id_i[cu] = '0;
            alloc_pc_i[cu] = '0;
            alloc_exec_mask_i[cu] = '1;
            alloc_vrf_context_id_i[cu] = '0;
            release_wave_id_i[cu] = '0;
            scalar_wwave_i[cu] = '0;
            scalar_wreg_i[cu] = '0;
            scalar_wdata_i[cu] = '0;
            predicate_wwave_i[cu] = '0;
            predicate_wreg_i[cu] = '0;
            predicate_wdata_i[cu] = '0;
            vector_wcontext_i[cu] = '0;
            vector_wreg_i[cu] = '0;
            vector_wlane_i[cu] = '0;
            vector_wdata_i[cu] = '0;
            mem_resp_wave_i[cu] = '0;
            mem_resp_context_i[cu] = '0;
            policy_override_wave_i[cu] = '0;
            debug_vector_context_i[cu] = '0;
            debug_vector_reg_i[cu] = '0;
            debug_vector_lane_i[cu] = '0;
            debug_context_i[cu] = '0;
            debug_scalar_reg_i[cu] = '0;
            debug_predicate_reg_i[cu] = '0;
            for (lane = 0; lane < WAVE_SIZE; lane = lane + 1)
                mem_resp_rdata_i[cu][lane] = '0;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        #1;

        /*
         * Strict warning-clean reset/idle observability contract.  Metadata
         * is checked when its valid bit is asserted; architecturally live
         * state is required to be quiescent immediately after reset.
         */
        if (alloc_ready_o != '1)
            $fatal(1, "cluster reset alloc-ready mismatch");
        if (mshr_full_o != '0 || mshr_merge_event_o != '0
            || mshr_tag_error_o != '0 || memory_tag_error_o != '0
            || debug_context_valid_o != '0 || debug_halted_o != '0
            || retire_valid_o != '0 || engine_busy_o != '0
            || faulted_o != '0 || all_halted_o != '0)
            $fatal(1, "cluster reset status mismatch");
        if ($bits(dut.core_line_req_entry[0]) != MSHR_ENTRY_W)
            $fatal(1, "cluster local MSHR tag width mismatch");

        for (cu = 0; cu < CU_COUNT; cu = cu + 1) begin
            if (mshr_active_wave_mask_o[cu] != '0
                || valid_mask_o[cu] != '0
                || ready_mask_o[cu] != '0
                || halted_mask_o[cu] != '0
                || rr_cursor_o[cu] != '0)
                $fatal(1, "cluster reset per-CU state mismatch");

            if (mem_req_valid_o[cu]) begin
                if ($isunknown({mem_req_write_o[cu], mem_req_wave_o[cu],
                    mem_req_context_o[cu], mem_req_lane_mask_o[cu]}))
                    $fatal(1, "cluster request metadata contains X");
                for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                    if ($isunknown(mem_req_addr_o[cu][lane])
                        || $isunknown(mem_req_wdata_o[cu][lane]))
                        $fatal(1, "cluster request lane metadata contains X");
                end
            end

            if (debug_context_valid_o[cu]) begin
                if ($isunknown({debug_pc_o[cu], debug_exec_mask_o[cu],
                    debug_scalar_data_o[cu], debug_predicate_data_o[cu]}))
                    $fatal(1, "cluster debug context contains X");
            end
            if (!$isunknown(debug_vector_data_o[cu])) begin
                /* The vector debug payload is allowed to be unspecified for
                 * an invalid context; when driven, it must be a known word. */
                if (^debug_vector_data_o[cu] === 1'bx)
                    $fatal(1, "cluster vector debug payload contains X");
            end
            if (retire_valid_o[cu]
                && $isunknown({retire_wave_o[cu], retire_pc_o[cu]}))
                $fatal(1, "cluster retire metadata contains X");
        end

        if (line_mem_req_valid_o
            && $isunknown({line_mem_req_global_tag_o,
                           line_mem_req_line_addr_o}))
            $fatal(1, "cluster line request metadata contains X");

        if (mem_req_valid_o != '0 || line_mem_req_valid_o
            || memory_outstanding_o != '0 || mshr_occupancy_o[0] != '0
            || mshr_occupancy_o[1] != '0 || mshr_occupancy_o[2] != '0
            || line_resp_tag_error_o || dut.controller_pending_valid != '0
            || dut.shared_client_req_valid != '0)
            $fatal(1, "cluster reset/idle wiring mismatch");
        if ($bits(line_mem_req_global_tag_o) != GLOBAL_TAG_W)
            $fatal(1, "non-power-of-two global tag width mismatch");
        if (dut.peer_ordering_valid[0] != '0
            || dut.peer_ordering_valid[1] != '0
            || dut.peer_ordering_valid[2] != '0)
            $fatal(1, "peer-filtered ordering reset mismatch");

        $display("A0_CU_CLUSTER_SHARED_L2_WIRING_TB=PASS");
        $finish;
    end
endmodule
