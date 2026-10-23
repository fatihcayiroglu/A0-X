`timescale 1ns/1ps

module a0_wave_core_rtl5c_hazards_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;

    localparam integer PROGRAM_WORDS = 16;

    localparam logic [7:0] OP_VADD    = 8'h01;
    localparam logic [7:0] OP_VXOR    = 8'h06;

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

    integer independent_handoff_count;


    integer waw_hazard_cycles;
    integer waw_retire_block_count;
    integer waw_extra_bubble_cycles;

    logic expect_waw_issue_next_cycle;


    integer predicate_raw_hazard_cycles;
    integer predicate_raw_retire_block_count;
    integer predicate_raw_extra_bubble_cycles;

    logic expect_predicate_raw_issue_next_cycle;


    integer waw_metadata_checks;
    integer predicate_metadata_checks;


    a0_wave_core #(
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),

        .VECTOR_REG_COUNT(
            VECTOR_REG_COUNT
        ),

        .SCALAR_REG_COUNT(
            SCALAR_REG_COUNT
        ),

        .PREDICATE_REG_COUNT(
            PREDICATE_REG_COUNT
        ),

        .PROGRAM_WORDS(
            PROGRAM_WORDS
        )
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

        .mem_req_lane_mask(
            mem_req_lane_mask
        ),

        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),

        .mem_resp_valid(mem_resp_valid),
        .mem_resp_fault(mem_resp_fault),

        .mem_resp_rdata(
            mem_resp_rdata
        ),

        .halted(halted),
        .faulted(faulted),
        .pc(pc)
    );


    initial clk = 1'b0;

    always #1 clk = ~clk;

    // RTL5C Phase2 exercises vector hazard/scoreboard behavior only.
    // Any architectural memory request is a behavioral violation.
    always @(negedge clk) begin : no_memory_traffic_contract
        integer mem_lane;
        if (rst_n && mem_req_valid) begin
            for (
                mem_lane = 0;
                mem_lane < WAVE_SIZE;
                mem_lane = mem_lane + 1
            ) begin
                if (mem_req_lane_mask[mem_lane]) begin
                    $display(
                        "RTL5C Phase2 unexpected memory lane=%0d addr=%08x wdata=%08x",
                        mem_lane,
                        mem_req_addr[mem_lane],
                        mem_req_wdata[mem_lane]
                    );
                end
            end
            $fatal(
                1,
                "RTL5C Phase2 unexpected memory request write=%0b lane_mask=%08x",
                mem_req_write,
                mem_req_lane_mask
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

            program_waddr =
                address[
                    $clog2(PROGRAM_WORDS)-1:0
                ];

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

            vector_wreg =
                reg_index[
                    $clog2(VECTOR_REG_COUNT)-1:0
                ];

            vector_wlane =
                lane_index[
                    $clog2(WAVE_SIZE)-1:0
                ];

            vector_wdata = value;


            @(negedge clk);

            vector_we = 1'b0;
        end
    endtask


    /*
     * Observe DUT state before its NBA updates on each
     * architectural clock edge.
     */
    always @(posedge clk) begin

        if (
            rst_n
            && run_enable
        ) begin

            cycles <=
                cycles + 1;


            if (
                dut.vector_issue_fire
            ) begin

                issue_count <=
                    issue_count + 1;


                if (
                    dut.pending_handoff_fire
                ) begin

                    independent_handoff_count <=
                        independent_handoff_count + 1;
                end
            end


            if (
                dut.scoreboard_release_valid
            ) begin

                retirement_count <=
                    retirement_count + 1;
            end


            /*
             * ------------------------------------------------
             * WAW next-cycle protocol.
             * ------------------------------------------------
             */
            if (
                expect_waw_issue_next_cycle
            ) begin

                if (
                    !dut.pending_vector_issue_fire
                    || !dut.vector_pending_valid
                    || dut.vector_pending_pc != 4
                    || dut.scoreboard_vector_waw_hazard
                    || dut.vector_scoreboard_busy[8]
                ) begin

                    $fatal(
                        1,
                        "RTL5C WAW did not issue exactly one cycle after release"
                    );
                end


                waw_extra_bubble_cycles <=
                    waw_extra_bubble_cycles + 1;

                expect_waw_issue_next_cycle <=
                    1'b0;
            end


            /*
             * PC4 is VXOR V8,V5,V6 while PC3 still owns V8.
             */
            if (
                dut.vector_pending_valid
                && dut.vector_pending_pc == 4
                && dut.scoreboard_vector_waw_hazard
            ) begin

                if (
                    dut.vector_pending_opcode
                        != OP_VXOR
                    || dut.vector_pending_dst_index
                        != 8
                    || dut.vector_pending_src0_index
                        != 5
                    || dut.vector_pending_src1_index
                        != 6
                ) begin

                    $fatal(
                        1,
                        "RTL5C WAW pending metadata changed"
                    );
                end


                waw_hazard_cycles <=
                    waw_hazard_cycles + 1;

                waw_metadata_checks <=
                    waw_metadata_checks + 1;
            end


            /*
             * PC3 producer retirement must not hand PC4
             * directly into execution because both write V8.
             */
            if (
                dut.vector_seq_done
                && dut.vector_issue_pc == 3
                && dut.vector_pending_valid
                && dut.vector_pending_pc == 4
            ) begin

                if (
                    !dut.scoreboard_vector_waw_hazard
                    || !dut.vector_scoreboard_busy[8]
                ) begin

                    $fatal(
                        1,
                        "RTL5C WAW missing at producer retirement"
                    );
                end


                if (
                    dut.pending_handoff_fire
                ) begin

                    $fatal(
                        1,
                        "RTL5C WAW incorrectly handed off"
                    );
                end


                waw_retire_block_count <=
                    waw_retire_block_count + 1;


                if (
                    expect_waw_issue_next_cycle
                    && !dut.pending_vector_issue_fire
                ) begin

                    $fatal(
                        1,
                        "RTL5C duplicate WAW retirement block"
                    );
                end


                expect_waw_issue_next_cycle <=
                    1'b1;
            end


            /*
             * ------------------------------------------------
             * Predicate RAW next-cycle protocol.
             * ------------------------------------------------
             */
            if (
                expect_predicate_raw_issue_next_cycle
            ) begin

                if (
                    !dut.pending_vector_issue_fire
                    || !dut.vector_pending_valid
                    || dut.vector_pending_pc != 6
                    || dut.scoreboard_predicate_raw_hazard
                    || dut.predicate_scoreboard_busy[3]
                ) begin

                    $fatal(
                        1,
                        "RTL5C predicate RAW did not issue exactly one cycle after release"
                    );
                end


                predicate_raw_extra_bubble_cycles <=
                    predicate_raw_extra_bubble_cycles
                    + 1;

                expect_predicate_raw_issue_next_cycle <=
                    1'b0;
            end


            /*
             * PC5 writes P3.
             *
             * PC6 is @P3 VADD V9,V1,V2, therefore P3 is
             * a true predicate source dependency.
             */
            if (
                dut.vector_pending_valid
                && dut.vector_pending_pc == 6
                && dut.scoreboard_predicate_raw_hazard
            ) begin

                if (
                    dut.vector_pending_opcode
                        != OP_VADD
                    || !dut.vector_pending_flags[0]
                    || dut.vector_pending_pred_index
                        != 3
                    || dut.vector_pending_dst_index
                        != 9
                ) begin

                    $fatal(
                        1,
                        "RTL5C predicate RAW pending metadata changed"
                    );
                end


                predicate_raw_hazard_cycles <=
                    predicate_raw_hazard_cycles
                    + 1;

                predicate_metadata_checks <=
                    predicate_metadata_checks
                    + 1;
            end


            /*
             * PC5 VCMP_LT retires while P3 is still busy.
             * PC6 must therefore miss same-cycle handoff.
             */
            if (
                dut.vector_seq_done
                && dut.vector_issue_pc == 5
                && dut.vector_pending_valid
                && dut.vector_pending_pc == 6
            ) begin

                if (
                    !dut.scoreboard_predicate_raw_hazard
                    || !dut.predicate_scoreboard_busy[3]
                ) begin

                    $fatal(
                        1,
                        "RTL5C predicate RAW missing at producer retirement"
                    );
                end


                if (
                    dut.pending_handoff_fire
                ) begin

                    $fatal(
                        1,
                        "RTL5C predicate RAW incorrectly handed off"
                    );
                end


                predicate_raw_retire_block_count <=
                    predicate_raw_retire_block_count
                    + 1;


                if (
                    expect_predicate_raw_issue_next_cycle
                    && !dut.pending_vector_issue_fire
                ) begin

                    $fatal(
                        1,
                        "RTL5C duplicate predicate RAW retirement block"
                    );
                end


                expect_predicate_raw_issue_next_cycle <=
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

            mem_resp_rdata[l] =
                32'b0;
        end


        $readmemh(
            "program.hex",
            program_init
        );


        cycles = 0;

        issue_count = 0;
        retirement_count = 0;

        independent_handoff_count = 0;


        waw_hazard_cycles = 0;
        waw_retire_block_count = 0;
        waw_extra_bubble_cycles = 0;

        expect_waw_issue_next_cycle =
            1'b0;


        predicate_raw_hazard_cycles = 0;

        predicate_raw_retire_block_count =
            0;

        predicate_raw_extra_bubble_cycles =
            0;

        expect_predicate_raw_issue_next_cycle =
            1'b0;


        waw_metadata_checks = 0;
        predicate_metadata_checks = 0;


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
         * Input state:
         *
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

            write_vector(
                8,
                l,
                32'h11111111
            );

            write_vector(
                9,
                l,
                32'h12345678
            );
        end


        @(negedge clk);

        run_enable = 1'b1;


        while (
            !halted
            && cycles < 1024
        ) begin

            @(negedge clk);
        end


        run_enable = 1'b0;


        if (!halted) begin

            $fatal(
                1,
                "RTL5C Phase2 timeout before HALT"
            );
        end


        if (faulted) begin

            $fatal(
                1,
                "RTL5C Phase2 core faulted"
            );
        end


        /*
         * Seven sequenced vector instructions.
         */
        if (
            issue_count != 7
        ) begin

            $fatal(
                1,
                "RTL5C Phase2 issues=%0d expected=7",
                issue_count
            );
        end


        if (
            retirement_count != 7
        ) begin

            $fatal(
                1,
                "RTL5C Phase2 retirements=%0d expected=7",
                retirement_count
            );
        end


        /*
         * Zero-bubble handoffs:
         *
         * PC0 -> PC1
         * PC2 -> PC3
         * PC4 -> PC5
         */
        if (
            independent_handoff_count != 3
        ) begin

            $fatal(
                1,
                "RTL5C Phase2 independent handoffs=%0d expected=3",
                independent_handoff_count
            );
        end


        /*
         * Vector WAW proof.
         */
        if (
            waw_hazard_cycles < 1
        ) begin

            $fatal(
                1,
                "RTL5C live WAW hazard not observed"
            );
        end


        if (
            waw_metadata_checks < 1
        ) begin

            $fatal(
                1,
                "RTL5C WAW metadata not exercised"
            );
        end


        if (
            waw_retire_block_count != 1
        ) begin

            $fatal(
                1,
                "RTL5C WAW retire blocks=%0d expected=1",
                waw_retire_block_count
            );
        end


        if (
            expect_waw_issue_next_cycle
        ) begin

            $fatal(
                1,
                "RTL5C WAW next-cycle issue still pending"
            );
        end


        if (
            waw_extra_bubble_cycles != 1
        ) begin

            $fatal(
                1,
                "RTL5C WAW bubbles=%0d expected=1",
                waw_extra_bubble_cycles
            );
        end


        /*
         * Predicate RAW proof.
         */
        if (
            predicate_raw_hazard_cycles < 1
        ) begin

            $fatal(
                1,
                "RTL5C live predicate RAW hazard not observed"
            );
        end


        if (
            predicate_metadata_checks < 1
        ) begin

            $fatal(
                1,
                "RTL5C predicate metadata not exercised"
            );
        end


        if (
            predicate_raw_retire_block_count
                != 1
        ) begin

            $fatal(
                1,
                "RTL5C predicate RAW retire blocks=%0d expected=1",
                predicate_raw_retire_block_count
            );
        end


        if (
            expect_predicate_raw_issue_next_cycle
        ) begin

            $fatal(
                1,
                "RTL5C predicate RAW next-cycle issue still pending"
            );
        end


        if (
            predicate_raw_extra_bubble_cycles
                != 1
        ) begin

            $fatal(
                1,
                "RTL5C predicate RAW bubbles=%0d expected=1",
                predicate_raw_extra_bubble_cycles
            );
        end


        /*
         * Architectural results.
         */
        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            /*
             * PC0
             */
            if (
                dut.vector_regs[3][l]
                    != (l + 11)
            ) begin

                $fatal(
                    1,
                    "RTL5C Phase2 V3 mismatch lane=%0d",
                    l
                );
            end


            /*
             * PC1
             */
            if (
                dut.vector_regs[4][l]
                    != (
                        (l + 100)
                        ^ 32'h00000055
                    )
            ) begin

                $fatal(
                    1,
                    "RTL5C Phase2 V4 mismatch lane=%0d",
                    l
                );
            end


            /*
             * PC2 RAW consumer.
             */
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
                    "RTL5C Phase2 V7 mismatch lane=%0d",
                    l
                );
            end


            /*
             * PC4 is the younger WAW writer and therefore
             * defines final V8.
             */
            if (
                dut.vector_regs[8][l]
                    != (
                        (l + 100)
                        ^ 32'h00000055
                    )
            ) begin

                $fatal(
                    1,
                    "RTL5C Phase2 V8 mismatch lane=%0d",
                    l
                );
            end


            /*
             * PC5:
             *
             * P3 = (V1 < V2)
             *    = (lane + 1 < 10)
             */
            if (
                dut.predicate_regs[3][l]
                    != (l < 9)
            ) begin

                $fatal(
                    1,
                    "RTL5C Phase2 P3 mismatch lane=%0d",
                    l
                );
            end


            /*
             * PC6 executes only where P3 is true.
             */
            if (l < 9) begin

                if (
                    dut.vector_regs[9][l]
                        != (l + 11)
                ) begin

                    $fatal(
                        1,
                        "RTL5C Phase2 predicated V9 active mismatch lane=%0d",
                        l
                    );
                end

            end else begin

                if (
                    dut.vector_regs[9][l]
                        != 32'h12345678
                ) begin

                    $fatal(
                        1,
                        "RTL5C Phase2 predicated V9 inactive mismatch lane=%0d",
                        l
                    );
                end
            end
        end


        if (
            dut.vector_scoreboard_busy != '0
        ) begin

            $fatal(
                1,
                "RTL5C Phase2 vector scoreboard not empty"
            );
        end


        if (
            dut.predicate_scoreboard_busy != '0
        ) begin

            $fatal(
                1,
                "RTL5C Phase2 predicate scoreboard not empty"
            );
        end


        $display(
            "RTL5C_PHASE2_TB=PASS cycles=%0d pc=%0d",
            cycles,
            pc
        );

        $display(
            "VECTOR_ISSUES=%0d",
            issue_count
        );

        $display(
            "VECTOR_RETIREMENTS=%0d",
            retirement_count
        );

        $display(
            "INDEPENDENT_HANDOFFS=%0d",
            independent_handoff_count
        );


        $display(
            "VECTOR_WAW_PENDING_HAZARD=PASS"
        );

        $display(
            "VECTOR_WAW_HANDOFF_BLOCKED=PASS"
        );

        $display(
            "VECTOR_WAW_ISSUE_AFTER_RELEASE=PASS"
        );

        $display(
            "WAW_EXTRA_BUBBLE_CYCLES=%0d",
            waw_extra_bubble_cycles
        );


        $display(
            "PREDICATE_RAW_PENDING_HAZARD=PASS"
        );

        $display(
            "PREDICATE_RAW_HANDOFF_BLOCKED=PASS"
        );

        $display(
            "PREDICATE_RAW_ISSUE_AFTER_RELEASE=PASS"
        );

        $display(
            "PREDICATE_RAW_EXTRA_BUBBLE_CYCLES=%0d",
            predicate_raw_extra_bubble_cycles
        );


        $display(
            "PHASE2_ARCHITECTURAL_RESULT_MATCH=PASS"
        );

        $display(
            "PHASE2_SCOREBOARDS_EMPTY=PASS"
        );


        $finish;
    end

endmodule
