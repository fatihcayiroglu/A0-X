`timescale 1ns/1ps

module a0_wave_core_rtl5c_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;

    localparam integer PROGRAM_WORDS = 16;


    logic clk;
    logic rst_n;
    logic run_enable;

    logic program_we;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        program_waddr;

    logic [63:0] program_wdata;


    logic vector_we;

    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        vector_wreg;

    logic [$clog2(WAVE_SIZE)-1:0]
        vector_wlane;

    logic [31:0] vector_wdata;


    logic scalar_we;

    logic [$clog2(SCALAR_REG_COUNT)-1:0]
        scalar_wreg;

    logic [31:0] scalar_wdata;


    logic mem_req_valid;
    logic mem_req_write;

    logic [WAVE_SIZE-1:0]
        mem_req_lane_mask;

    logic [31:0]
        mem_req_addr [0:WAVE_SIZE-1];

    logic [31:0]
        mem_req_wdata [0:WAVE_SIZE-1];

    logic mem_resp_valid;
    logic mem_resp_fault;

    logic [31:0]
        mem_resp_rdata [0:WAVE_SIZE-1];


    logic halted;
    logic faulted;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        pc;


    logic [63:0]
        program_init [0:PROGRAM_WORDS-1];


    integer i;
    integer l;

    integer cycles;

    integer issue_count;
    integer retirement_count;

    integer pending_capture_count;
    integer independent_handoff_count;

    integer raw_hazard_cycles;
    integer raw_retire_block_count;

    logic expect_raw_issue_next_cycle;
    integer raw_extra_bubble_cycles;
    integer pending_metadata_checks;


    a0_wave_core #(
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .PROGRAM_WORDS(PROGRAM_WORDS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_enable(run_enable),

        .program_we(program_we),
        .program_waddr(program_waddr),
        .program_wdata(program_wdata),

        .vector_we(vector_we),
        .vector_wreg(vector_wreg),
        .vector_wlane(vector_wlane),
        .vector_wdata(vector_wdata),

        .scalar_we(scalar_we),
        .scalar_wreg(scalar_wreg),
        .scalar_wdata(scalar_wdata),

        .mem_req_valid(mem_req_valid),
        .mem_req_write(mem_req_write),
        .mem_req_lane_mask(mem_req_lane_mask),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),

        .mem_resp_valid(mem_resp_valid),
        .mem_resp_fault(mem_resp_fault),
        .mem_resp_rdata(mem_resp_rdata),

        .halted(halted),
        .faulted(faulted),
        .pc(pc)
    );


    initial clk = 1'b0;
    always #1 clk = ~clk;

    // RTL5C exercises vector issue/pending/scoreboard handoff only.
    // Any architectural memory request is a behavioral violation.
    always @(negedge clk) begin : no_memory_traffic_contract
        integer mem_lane;
        if (rst_n && mem_req_valid) begin
            for (mem_lane = 0; mem_lane < WAVE_SIZE; mem_lane = mem_lane + 1) begin
                if (mem_req_lane_mask[mem_lane]) begin
                    $display(
                        "RTL5C unexpected memory lane=%0d addr=%08x wdata=%08x",
                        mem_lane, mem_req_addr[mem_lane], mem_req_wdata[mem_lane]
                    );
                end
            end
            $fatal(
                1,
                "RTL5C unexpected memory request write=%0b lane_mask=%08x",
                mem_req_write, mem_req_lane_mask
            );
        end
    end


    task automatic write_program(
        input integer address,
        input logic [63:0] value
    );
        begin
            if ((address < 0) || (address >= PROGRAM_WORDS)) begin
                $fatal(1, "write_program address out of range: %0d", address);
            end

            @(negedge clk);

            program_we = 1'b1;
            program_waddr = address[$clog2(PROGRAM_WORDS)-1:0];
            program_wdata = value;

            @(negedge clk);

            program_we = 1'b0;
        end
    endtask


    task automatic write_vector(
        input integer reg_index,
        input integer lane_index,
        input logic [31:0] value
    );
        begin
            if ((reg_index < 0) || (reg_index >= VECTOR_REG_COUNT)) begin
                $fatal(1, "write_vector reg_index out of range: %0d", reg_index);
            end
            if ((lane_index < 0) || (lane_index >= WAVE_SIZE)) begin
                $fatal(1, "write_vector lane_index out of range: %0d", lane_index);
            end

            @(negedge clk);

            vector_we = 1'b1;
            vector_wreg = reg_index[$clog2(VECTOR_REG_COUNT)-1:0];
            vector_wlane = lane_index[$clog2(WAVE_SIZE)-1:0];
            vector_wdata = value;

            @(negedge clk);

            vector_we = 1'b0;
        end
    endtask


    /*
     * Event observation happens on the architectural
     * consumption edge, before DUT nonblocking updates.
     */
    always @(posedge clk) begin

        if (
            rst_n
            && run_enable
        ) begin

            cycles <= cycles + 1;


            if (dut.vector_issue_fire) begin

                issue_count <=
                    issue_count + 1;


                if (
                    dut.pending_handoff_fire
                ) begin

                    independent_handoff_count <=
                        independent_handoff_count + 1;
                end


                /*
                 * RAW post-release issue is checked by the
                 * explicit next-cycle protocol below.
                 */
            end


            /*
             * A RAW-blocked retirement must become an
             * issuable pending instruction exactly on the
             * next enabled cycle.
             */
            if (
                expect_raw_issue_next_cycle
            ) begin

                if (
                    !dut.pending_vector_issue_fire
                    || !dut.vector_pending_valid
                    || dut.vector_pending_pc != 2
                    || dut.scoreboard_vector_raw_hazard
                    || dut.vector_scoreboard_busy[4]
                ) begin

                    $fatal(
                        1,
                        "RTL5C RAW did not issue exactly one cycle after release"
                    );
                end


                raw_extra_bubble_cycles <=
                    raw_extra_bubble_cycles + 1;

                expect_raw_issue_next_cycle <=
                    1'b0;
            end


            if (
                dut.scoreboard_release_valid
            ) begin

                retirement_count <=
                    retirement_count + 1;
            end


            if (
                dut.vector_pending_valid
                && dut.vector_pending_pc == 2
                && dut.scoreboard_vector_raw_hazard
            ) begin

                raw_hazard_cycles <=
                    raw_hazard_cycles + 1;


                /*
                 * Pending PC2 must remain the expected
                 * dependent VADD V7,V4,V1.
                 */
                if (
                    dut.vector_pending_dst_index != 7
                    || dut.vector_pending_src0_index != 4
                    || dut.vector_pending_src1_index != 1
                ) begin

                    $fatal(
                        1,
                        "RTL5C pending RAW metadata changed"
                    );
                end

                pending_metadata_checks <=
                    pending_metadata_checks + 1;
            end


            /*
             * PC1 producer retirement while PC2 still
             * observes RAW on V4.
             */
            if (
                dut.vector_seq_done
                && dut.vector_pending_valid
                && dut.vector_pending_pc == 2
                && dut.scoreboard_vector_raw_hazard
            ) begin

                if (
                    dut.pending_handoff_fire
                ) begin

                    $fatal(
                        1,
                        "RTL5C RAW incorrectly handed off"
                    );
                end

                raw_retire_block_count <=
                    raw_retire_block_count + 1;


                if (
                    expect_raw_issue_next_cycle
                    && !dut.pending_vector_issue_fire
                ) begin

                    $fatal(
                        1,
                        "RTL5C duplicate RAW retirement block"
                    );
                end


                expect_raw_issue_next_cycle <=
                    1'b1;
            end
        end
    end


    initial begin

        rst_n = 1'b0;
        run_enable = 1'b0;

        program_we = 1'b0;
        program_waddr = '0;
        program_wdata = '0;

        vector_we = 1'b0;
        vector_wreg = '0;
        vector_wlane = '0;
        vector_wdata = '0;

        scalar_we = 1'b0;
        scalar_wreg = '0;
        scalar_wdata = '0;

        mem_resp_valid = 1'b0;
        mem_resp_fault = 1'b0;


        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            mem_resp_rdata[l] = 32'b0;
        end


        $readmemh(
            "program.hex",
            program_init
        );


        cycles = 0;

        issue_count = 0;
        retirement_count = 0;

        pending_capture_count = 0;
        independent_handoff_count = 0;

        raw_hazard_cycles = 0;
        raw_retire_block_count = 0;

        expect_raw_issue_next_cycle = 1'b0;
        raw_extra_bubble_cycles = 0;
        pending_metadata_checks = 0;


        repeat (3) @(negedge clk);

        rst_n = 1'b1;


        for (
            i = 0;
            i < PROGRAM_WORDS;
            i = i + 1
        ) begin

            write_program(
                i,
                program_init[i]
            );
        end


        /*
         * V1 = lane + 1
         * V2 = 10
         * V5 = lane + 100
         * V6 = 0x55
         */
        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            write_vector(
                1,
                l,
                l + 1
            );

            write_vector(
                2,
                l,
                32'd10
            );

            write_vector(
                5,
                l,
                l + 100
            );

            write_vector(
                6,
                l,
                32'h00000055
            );

            write_vector(
                3,
                l,
                32'hDEADBEEF
            );

            write_vector(
                4,
                l,
                32'hA5A5A5A5
            );

            write_vector(
                7,
                l,
                32'hCCCCCCCC
            );
        end


        @(negedge clk);

        run_enable = 1'b1;


        /*
         * PC0 issue must immediately capture independent
         * PC1 into the pending queue.
         */
        while (
            !(
                dut.vector_waiting
                && dut.vector_issue_pc == 0
                && dut.vector_pending_valid
            )
            && cycles < 256
        ) begin

            @(negedge clk);
        end


        if (
            !dut.vector_pending_valid
            || dut.vector_pending_pc != 1
        ) begin

            $fatal(
                1,
                "RTL5C PC1 pending capture missing"
            );
        end


        if (
            dut.vector_pending_dst_index != 4
            || dut.vector_pending_src0_index != 5
            || dut.vector_pending_src1_index != 6
        ) begin

            $fatal(
                1,
                "RTL5C PC1 pending metadata mismatch"
            );
        end


        pending_capture_count =
            pending_capture_count + 1;


        /*
         * Run through HALT.
         */
        while (
            !halted
            && cycles < 512
        ) begin

            @(negedge clk);
        end


        run_enable = 1'b0;


        if (!halted) begin

            $fatal(
                1,
                "RTL5C timeout before HALT"
            );
        end


        if (faulted) begin

            $fatal(
                1,
                "RTL5C core faulted"
            );
        end


        if (issue_count != 3) begin

            $fatal(
                1,
                "RTL5C issue_count=%0d expected=3",
                issue_count
            );
        end


        if (retirement_count != 3) begin

            $fatal(
                1,
                "RTL5C retirements=%0d expected=3",
                retirement_count
            );
        end


        if (
            independent_handoff_count != 1
        ) begin

            $fatal(
                1,
                "RTL5C independent handoff count=%0d",
                independent_handoff_count
            );
        end


        if (
            raw_hazard_cycles < 1
        ) begin

            $fatal(
                1,
                "RTL5C live RAW hazard not observed"
            );
        end


        if (
            raw_retire_block_count != 1
        ) begin

            $fatal(
                1,
                "RTL5C RAW retirement block count=%0d",
                raw_retire_block_count
            );
        end


        if (
            expect_raw_issue_next_cycle
        ) begin

            $fatal(
                1,
                "RTL5C RAW next-cycle issue still pending"
            );
        end


        if (
            raw_extra_bubble_cycles != 1
        ) begin

            $fatal(
                1,
                "RTL5C RAW extra bubble count=%0d expected=1",
                raw_extra_bubble_cycles
            );
        end


        if (
            pending_metadata_checks < 1
        ) begin

            $fatal(
                1,
                "RTL5C pending metadata not exercised"
            );
        end


        /*
         * Architectural result checks.
         */
        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            if (
                dut.vector_regs[3][l]
                != (l + 1 + 10)
            ) begin

                $fatal(
                    1,
                    "RTL5C V3 mismatch lane=%0d",
                    l
                );
            end


            if (
                dut.vector_regs[4][l]
                != (
                    (l + 100)
                    ^ 32'h00000055
                )
            ) begin

                $fatal(
                    1,
                    "RTL5C V4 mismatch lane=%0d",
                    l
                );
            end


            if (
                dut.vector_regs[7][l]
                != (
                    (
                        (l + 100)
                        ^ 32'h00000055
                    )
                    + (l + 1)
                )
            ) begin

                $fatal(
                    1,
                    "RTL5C V7 mismatch lane=%0d",
                    l
                );
            end
        end


        $display(
            "RTL5C_TB=PASS cycles=%0d pc=%0d",
            cycles,
            pc
        );

        $display(
            "PENDING_CAPTURE=PASS"
        );

        $display(
            "PENDING_METADATA_STABLE=PASS"
        );

        $display(
            "INDEPENDENT_PENDING_READY=PASS"
        );

        $display(
            "INDEPENDENT_RETIRE_HANDOFF=PASS"
        );

        $display(
            "RAW_PENDING_HAZARD=PASS"
        );

        $display(
            "RAW_RETIRE_HANDOFF_BLOCKED=PASS"
        );

        $display(
            "RAW_ISSUE_AFTER_RELEASE=PASS"
        );

        $display(
            "RAW_EXTRA_BUBBLE_CYCLES=%0d",
            raw_extra_bubble_cycles
        );

        $display(
            "ARCHITECTURAL_RESULT_MATCH=PASS"
        );

        $finish;
    end

endmodule
