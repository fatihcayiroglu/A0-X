`timescale 1ns/1ps

module a0_production_cu_cluster_frontend_traffic_tb;
    localparam integer CU_COUNT = 1;
    localparam integer RESIDENT_WAVES = 2;
    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 4;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer SCALAR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer PROGRAM_WORDS = 16;
    localparam integer MSHR_COUNT = 2;
    localparam integer MSHR_LINE_WORDS = 8;
    localparam integer WAVE_ID_W = 1;
    localparam integer PC_W = 4;
    localparam integer VECTOR_REG_INDEX_W = 3;
    localparam integer SCALAR_REG_INDEX_W = 3;
    localparam integer PREDICATE_INDEX_W = 2;
    localparam integer MSHR_ENTRY_W = 1;
    localparam integer MSHR_LINE_ADDR_W = 29;
    localparam integer MSHR_OCCUPANCY_W = 2;
    localparam integer GLOBAL_TAG_W = 2;

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

    logic line_req_valid_o;
    logic line_req_ready_i;
    logic [GLOBAL_TAG_W-1:0] line_req_global_tag_o;
    logic [MSHR_LINE_ADDR_W-1:0] line_req_line_addr_o;
    logic line_resp_valid_i;
    logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_i;
    logic [MSHR_LINE_ADDR_W-1:0] line_resp_line_addr_i;
    logic line_resp_fault_i;
    logic [31:0] line_resp_data_i [0:MSHR_LINE_WORDS-1];
    logic line_resp_tag_error_o;
    logic store_observe_valid_o;
    logic [(CU_COUNT * WAVE_SIZE)-1:0] store_observe_lane_mask_o;
    logic [31:0] store_observe_word_addr_o [0:(CU_COUNT * WAVE_SIZE)-1];

    localparam logic [7:0] OP_VLOADX = 8'h54;
    localparam logic [7:0] OP_HALT = 8'hFF;

    integer cu;
    integer lane;
    integer word_index;
    integer traffic_timeout;
    integer traffic_retire_count;
    logic [GLOBAL_TAG_W-1:0] held_global_tag;
    logic [MSHR_LINE_ADDR_W-1:0] held_line_addr;

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

    task automatic clear_cu0_loaders;
        begin
            program_we_i[0] = 1'b0;
            alloc_valid_i[0] = 1'b0;
            release_valid_i[0] = 1'b0;
            scalar_we_i[0] = 1'b0;
            predicate_we_i[0] = 1'b0;
            vector_we_i[0] = 1'b0;
        end
    endtask

    task automatic write_cu0_program(
        input logic [PC_W-1:0] address,
        input logic [63:0] instruction_word
    );
        begin
            @(negedge clk);
            clear_cu0_loaders();
            program_we_i[0] = 1'b1;
            program_waddr_i[0] = address;
            program_wdata_i[0] = instruction_word;
            @(posedge clk);
            #1;
            @(negedge clk);
            program_we_i[0] = 1'b0;
        end
    endtask

    task automatic allocate_cu0_wave0;
        begin
            @(negedge clk);
            clear_cu0_loaders();
            alloc_valid_i[0] = 1'b1;
            alloc_wave_id_i[0] = '0;
            alloc_pc_i[0] = '0;
            alloc_exec_mask_i[0] = {{(WAVE_SIZE-1){1'b0}}, 1'b1};
            alloc_vrf_context_id_i[0] = '0;
            #1;
            if (!alloc_ready_o[0])
                $fatal(1, "P1 traffic allocation not ready");
            @(posedge clk);
            #1;
            @(negedge clk);
            alloc_valid_i[0] = 1'b0;
        end
    endtask

    task automatic write_cu0_scalar0(input logic [31:0] value);
        begin
            @(negedge clk);
            clear_cu0_loaders();
            scalar_we_i[0] = 1'b1;
            scalar_wwave_i[0] = '0;
            scalar_wreg_i[0] = '0;
            scalar_wdata_i[0] = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            scalar_we_i[0] = 1'b0;
        end
    endtask

    task automatic write_cu0_vector_lane0(
        input logic [VECTOR_REG_INDEX_W-1:0] reg_id,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            clear_cu0_loaders();
            vector_we_i[0] = 1'b1;
            vector_wcontext_i[0] = '0;
            vector_wreg_i[0] = reg_id;
            vector_wlane_i[0] = '0;
            vector_wdata_i[0] = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            vector_we_i[0] = 1'b0;
        end
    endtask

    always #5 clk = ~clk;

    a0_production_cu_cluster_frontend #(
        .CU_COUNT(CU_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .SCALAR_PREDICATE_REG_COUNT(4),
        .RECONV_STACK_DEPTH(4),
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
        line_req_ready_i = 1'b1;
        line_resp_valid_i = 1'b0;
        line_resp_global_tag_i = '0;
        line_resp_line_addr_i = '0;
        line_resp_fault_i = 1'b0;

        for (word_index = 0; word_index < MSHR_LINE_WORDS;
             word_index = word_index + 1)
            line_resp_data_i[word_index] = '0;

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

        if (line_req_valid_o
            && $isunknown({line_req_global_tag_o,
                           line_req_line_addr_o}))
            $fatal(1, "cluster line request metadata contains X");

        if (store_observe_valid_o) begin
            for (lane = 0; lane < (CU_COUNT * WAVE_SIZE);
                 lane = lane + 1) begin
                if (store_observe_lane_mask_o[lane]
                    && $isunknown(store_observe_word_addr_o[lane]))
                    $fatal(1, "cluster store observation address contains X");
            end
        end

        if (mem_req_valid_o != '0 || line_req_valid_o
            || store_observe_valid_o || store_observe_lane_mask_o != '0
            || memory_outstanding_o != '0 || mshr_occupancy_o[0] != '0
            || line_resp_tag_error_o || dut.controller_pending_valid != '0
            || dut.shared_client_req_valid != '0)
            $fatal(1, "cluster reset/idle wiring mismatch");
        if ($bits(line_req_global_tag_o) != GLOBAL_TAG_W)
            $fatal(1, "non-power-of-two global tag width mismatch");
        if (dut.peer_ordering_valid[0] != '0)
            $fatal(1, "peer-filtered ordering reset mismatch");

        $display("PROD_SEAM_P1_RESET_IDLE=PASS");

        /*
         * Active P1 traffic proof.  CU0 issues one private-L1 miss while the
         * downstream P0 seam is backpressured.  The new registered holding
         * slot must capture the MSHR request without depending combinationally
         * on downstream ready, hold its payload stable, forward it exactly
         * once when ready rises, and route the line response back to the
         * originating wave.
         */
        line_req_ready_i = 1'b0;
        write_cu0_program(
            0,
            encode_instruction(
                OP_VLOADX, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0
            )
        );
        write_cu0_program(
            1,
            encode_instruction(
                OP_HALT, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0
            )
        );
        allocate_cu0_wave0();
        write_cu0_scalar0(32'd80);
        write_cu0_vector_lane0(1, 32'd0);

        traffic_retire_count = 0;
        run_enable_i[0] = 1'b1;
        /*
         * Stage 1: prove the new frontend decoupler itself captured the miss.
         * The downstream seam is allowed to accept that registered request into
         * its own holding register even while the external line interface is
         * backpressured, so frontend ownership is intentionally transient.
         */
        traffic_timeout = 0;
        while (!dut.line_req_hold_valid_q[0] && traffic_timeout < 400) begin
            @(posedge clk);
            #1;
            if (retire_valid_o[0])
                traffic_retire_count = traffic_retire_count + 1;
            traffic_timeout = traffic_timeout + 1;
        end
        if (!dut.line_req_hold_valid_q[0])
            $fatal(1, "P1 traffic timed out waiting for frontend request hold");
        if (dut.line_req_hold_addr_q[0] != MSHR_LINE_ADDR_W'(10))
            $fatal(
                1,
                "P1 frontend-held request line mismatch expected=10 actual=%0d",
                dut.line_req_hold_addr_q[0]
            );
        if (mshr_occupancy_o[0] != MSHR_OCCUPANCY_W'(1)
            || !mshr_active_wave_mask_o[0][0]
            || !memory_outstanding_o[0])
            $fatal(1, "P1 private MSHR ownership missing at frontend hold");
        $display("PROD_SEAM_P1_FRONTEND_HOLD_CAPTURE=PASS");

        /*
         * Stage 2: the P0 line fabric takes ownership into its own registered
         * hold.  At this point the frontend slot may (and should) drain even
         * though the external line_req_ready_i remains low.
         */
        traffic_timeout = 0;
        while (!line_req_valid_o && traffic_timeout < 40) begin
            @(posedge clk);
            #1;
            if (retire_valid_o[0])
                traffic_retire_count = traffic_retire_count + 1;
            traffic_timeout = traffic_timeout + 1;
        end
        if (!line_req_valid_o)
            $fatal(1, "P1 traffic timed out waiting for P0 seam request hold");
        if (!dut.production_line_seam.line_fabric.hold_valid_q)
            $fatal(1, "P1 public request valid without P0 seam hold owner");
        if (dut.line_req_hold_valid_q[0])
            $fatal(1, "P1 frontend hold did not transfer ownership to P0 seam");
        if (line_req_line_addr_o != MSHR_LINE_ADDR_W'(10))
            $fatal(
                1,
                "P1 seam-held request line mismatch expected=10 actual=%0d",
                line_req_line_addr_o
            );
        if (mshr_occupancy_o[0] != MSHR_OCCUPANCY_W'(1)
            || !mshr_active_wave_mask_o[0][0]
            || !memory_outstanding_o[0])
            $fatal(1, "P1 private MSHR ownership missing while seam stalled");

        held_global_tag = line_req_global_tag_o;
        held_line_addr = line_req_line_addr_o;
        $display("PROD_SEAM_P1_REQUEST_CAPTURED_WHILE_BACKPRESSURED=PASS");

        repeat (4) begin
            @(posedge clk);
            #1;
            if (!line_req_valid_o
                || line_req_global_tag_o !== held_global_tag
                || line_req_line_addr_o !== held_line_addr
                || !dut.production_line_seam.line_fabric.hold_valid_q)
                $fatal(1, "P1 seam-held request payload changed under backpressure");
        end
        $display("PROD_SEAM_P1_REQUEST_PAYLOAD_STABLE=PASS");

        @(negedge clk);
        line_req_ready_i = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        line_req_ready_i = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (dut.line_req_hold_valid_q[0] || line_req_valid_o)
            $fatal(1, "P1 held request did not drain after downstream handshake");
        $display("PROD_SEAM_P1_REQUEST_FORWARD_HANDSHAKE=PASS");

        @(negedge clk);
        line_resp_valid_i = 1'b1;
        line_resp_global_tag_i = held_global_tag;
        line_resp_line_addr_i = held_line_addr;
        line_resp_fault_i = 1'b0;
        for (word_index = 0; word_index < MSHR_LINE_WORDS;
             word_index = word_index + 1)
            line_resp_data_i[word_index] = 32'(1000 + word_index);
        @(posedge clk);
        #1;
        @(negedge clk);
        line_resp_valid_i = 1'b0;

        traffic_timeout = 0;
        while (!all_halted_o[0] && traffic_timeout < 600) begin
            @(posedge clk);
            #1;
            if (retire_valid_o[0])
                traffic_retire_count = traffic_retire_count + 1;
            traffic_timeout = traffic_timeout + 1;
        end
        if (!all_halted_o[0])
            $fatal(1, "P1 load response did not return wave to HALT");
        if (traffic_retire_count < 2)
            $fatal(1, "P1 load+halt retirement chain incomplete count=%0d", traffic_retire_count);
        if (mshr_occupancy_o[0] != '0 || mshr_active_wave_mask_o[0] != '0
            || memory_outstanding_o[0] || mshr_full_o[0]
            || mshr_tag_error_o[0] || memory_tag_error_o[0]
            || line_resp_tag_error_o || faulted_o[0])
            $fatal(1, "P1 active traffic did not fully drain cleanly");

        debug_vector_context_i[0] = '0;
        debug_vector_reg_i[0] = VECTOR_REG_INDEX_W'(3);
        debug_vector_lane_i[0] = '0;
        #1;
        if (debug_vector_data_o[0] !== 32'd1000)
            $fatal(1, "P1 load refill data mismatch expected=1000 actual=%0d", debug_vector_data_o[0]);

        $display("PROD_SEAM_P1_LOAD_RESPONSE_ROUNDTRIP=PASS");
        $display("PROD_SEAM_P1_MSHR_FINAL_DRAIN=PASS");
        $display("PROD_SEAM_P1_FRONTEND_TRAFFIC_TB=PASS");
        $finish;
    end
endmodule
