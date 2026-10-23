`timescale 1ns/1ps

module a0_wave_core_rtl5b_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;

    localparam integer PROGRAM_WORDS = 16;

    localparam logic [7:0] OP_VADD =
        8'h01;

    localparam logic [7:0] OP_VCMP_LT =
        8'h61;


    logic clk;
    logic rst_n;
    logic run_enable;

    logic program_we;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        program_waddr;

    logic [63:0]
        program_wdata;


    logic vector_we;

    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        vector_wreg;

    logic [$clog2(WAVE_SIZE)-1:0]
        vector_wlane;

    logic [31:0]
        vector_wdata;


    logic scalar_we;

    logic [$clog2(SCALAR_REG_COUNT)-1:0]
        scalar_wreg;

    logic [31:0]
        scalar_wdata;


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
    integer vector_issues;
    integer vector_retirements;

    integer busy_hold_checks;
    integer false_stalls;

    logic issue_check_pending;
    logic retirement_check_pending;

    integer issue_check_pc;
    integer retirement_check_pc;

    integer active_pc;


    a0_wave_core #(
        .WAVE_SIZE(
            WAVE_SIZE
        ),
        .PHYSICAL_LANES(
            PHYSICAL_LANES
        ),
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


    initial begin
        clk = 1'b0;
    end

    always #1 clk = ~clk;

    // RTL5B core scenarios cover dependency/scoreboard behavior only.
    // Any architectural memory request would be a behavioral violation.
    always @(negedge clk) begin : no_memory_traffic_contract
        integer mem_lane;
        if (rst_n && mem_req_valid) begin
            for (mem_lane = 0; mem_lane < WAVE_SIZE; mem_lane = mem_lane + 1) begin
                if (mem_req_lane_mask[mem_lane]) begin
                    $display(
                        "RTL5B unexpected memory lane=%0d addr=%08x wdata=%08x",
                        mem_lane, mem_req_addr[mem_lane], mem_req_wdata[mem_lane]
                    );
                end
            end
            $fatal(
                1,
                "RTL5B unexpected memory request write=%0b lane_mask=%08x",
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


        repeat (3) @(negedge clk);

        rst_n = 1'b1;


        /*
         * Program:
         *
         * PC0: VADD V3,V1,V2
         * PC1: VCMP_LT P2,V1,V2
         * PC2: @P2 VADD V4,V1,V2
         * PC3: HALT
         */
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
         * V1 = 1..32
         * V2 = 17
         *
         * P2 after compare:
         * lanes 0..15 active.
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
                32'd17
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
        end


        @(negedge clk);


        if (
            dut.vector_scoreboard_busy
            != '0
        ) begin

            $fatal(
                1,
                "RTL5B vector scoreboard not empty before run"
            );
        end


        if (
            dut.predicate_scoreboard_busy
            != '0
        ) begin

            $fatal(
                1,
                "RTL5B predicate scoreboard not empty before run"
            );
        end


        cycles = 0;

        vector_issues = 0;
        vector_retirements = 0;

        busy_hold_checks = 0;
        false_stalls = 0;

        issue_check_pending = 1'b0;
        retirement_check_pending = 1'b0;

        issue_check_pc = -1;
        retirement_check_pc = -1;
        active_pc = -1;

        run_enable = 1'b1;


        while (
            !halted
            && cycles < 256
        ) begin

            /*
             * Capture true issue/retirement events before
             * DUT nonblocking assignments update state.
             */
            @(posedge clk);

            issue_check_pending = 1'b0;
            retirement_check_pending = 1'b0;


            /*
             * RTL5C may legitimately block a pending
             * instruction because of a real dependency.
             *
             * The PC2 consumer is predicated by P2, which
             * PC1 VCMP_LT still owns until retirement.
             *
             * Count only hazard-free blocked queries as
             * false stalls.
             */
            if (
                dut.scoreboard_query_valid
                && !dut.scoreboard_issue_allowed
                && !(
                    dut.vector_pending_valid
                    && dut.vector_pending_pc == 2
                    && dut.scoreboard_predicate_raw_hazard
                )
            ) begin

                false_stalls =
                    false_stalls + 1;
            end


            if (
                dut.vector_issue_fire
            ) begin

                vector_issues =
                    vector_issues + 1;

                issue_check_pc =
                    int'(dut.dependency_pc);

                active_pc =
                    int'(dut.dependency_pc);

                issue_check_pending =
                    1'b1;
            end


            if (
                dut.scoreboard_release_valid
            ) begin

                vector_retirements =
                    vector_retirements + 1;

                retirement_check_pc =
                    int'(dut.vector_issue_pc);

                retirement_check_pending =
                    1'b1;
            end


            /*
             * Validate scoreboard state after the DUT's
             * reserve/release NBA updates.
             */
            @(negedge clk);

            cycles = cycles + 1;


            /*
             * A real vector_issue_fire must have reserved
             * its destination by this post-NBA check.
             */
            if (
                issue_check_pending
            ) begin

                case (issue_check_pc)

                    0: begin

                        if (
                            dut.vector_issue_opcode
                            != OP_VADD
                        ) begin

                            $fatal(
                                1,
                                "RTL5B PC0 opcode mismatch"
                            );
                        end


                        if (
                            !dut.vector_scoreboard_busy[3]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B V3 not reserved at VADD issue"
                            );
                        end


                        if (
                            dut.predicate_scoreboard_busy
                            != '0
                        ) begin

                            $fatal(
                                1,
                                "RTL5B unexpected predicate reservation at plain VADD"
                            );
                        end
                    end


                    1: begin

                        if (
                            dut.vector_issue_opcode
                            != OP_VCMP_LT
                        ) begin

                            $fatal(
                                1,
                                "RTL5B PC1 opcode mismatch"
                            );
                        end


                        if (
                            !dut.predicate_scoreboard_busy[2]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B P2 not reserved at VCMP issue"
                            );
                        end


                        if (
                            dut.vector_scoreboard_busy
                            != '0
                        ) begin

                            $fatal(
                                1,
                                "RTL5B VCMP incorrectly reserved vector destination"
                            );
                        end
                    end


                    2: begin

                        if (
                            dut.vector_issue_opcode
                            != OP_VADD
                        ) begin

                            $fatal(
                                1,
                                "RTL5B PC2 opcode mismatch"
                            );
                        end


                        if (
                            !dut.vector_scoreboard_busy[4]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B V4 not reserved at predicated VADD issue"
                            );
                        end


                        /*
                         * P2 is a source dependency here,
                         * never a destination reservation.
                         */
                        if (
                            dut.predicate_scoreboard_busy[2]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B predicate source incorrectly reserved"
                            );
                        end
                    end


                    default: begin

                        $fatal(
                            1,
                            "RTL5B unexpected issued PC=%0d",
                            dut.vector_issue_pc
                        );
                    end

                endcase
            end


            /*
             * Destination ownership must remain busy for
             * the entire in-flight lifetime.
             */
            if (
                dut.vector_waiting
            ) begin

                busy_hold_checks =
                    busy_hold_checks + 1;


                case (active_pc)

                    0: begin

                        if (
                            !dut.vector_scoreboard_busy[3]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B V3 reservation released before retirement"
                            );
                        end
                    end


                    1: begin

                        if (
                            !dut.predicate_scoreboard_busy[2]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B P2 reservation released before retirement"
                            );
                        end
                    end


                    2: begin

                        if (
                            !dut.vector_scoreboard_busy[4]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B V4 reservation released before retirement"
                            );
                        end


                        if (
                            dut.predicate_scoreboard_busy[2]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B P2 source became busy"
                            );
                        end
                    end

                endcase
            end


            /*
             * scoreboard_release_valid is the true
             * architectural vector retirement event.
             *
             * After the completion edge, the retired
             * destination must no longer be owned.
             */
            if (
                retirement_check_pending
            ) begin

                case (retirement_check_pc)

                    0: begin

                        if (
                            dut.vector_scoreboard_busy[3]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B V3 still busy after retirement"
                            );
                        end
                    end


                    1: begin

                        if (
                            dut.predicate_scoreboard_busy[2]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B P2 still busy after retirement"
                            );
                        end
                    end


                    2: begin

                        if (
                            dut.vector_scoreboard_busy[4]
                        ) begin

                            $fatal(
                                1,
                                "RTL5B V4 still busy after retirement"
                            );
                        end
                    end

                endcase
            end


        end


        run_enable = 1'b0;


        if (!halted) begin

            $fatal(
                1,
                "RTL5B timeout before HALT"
            );
        end


        if (faulted) begin

            $fatal(
                1,
                "RTL5B core entered fault state"
            );
        end


        if (
            vector_issues != 3
        ) begin

            $fatal(
                1,
                "RTL5B issue count=%0d expected=3",
                vector_issues
            );
        end


        if (
            vector_retirements != 3
        ) begin

            $fatal(
                1,
                "RTL5B retirement count=%0d expected=3",
                vector_retirements
            );
        end


        if (
            false_stalls != 0
        ) begin

            $fatal(
                1,
                "RTL5B false stalls=%0d",
                false_stalls
            );
        end


        if (
            busy_hold_checks == 0
        ) begin

            $fatal(
                1,
                "RTL5B observed no busy hold cycles"
            );
        end


        if (
            dut.vector_scoreboard_busy
            != '0
        ) begin

            $fatal(
                1,
                "RTL5B vector scoreboard not empty after program"
            );
        end


        if (
            dut.predicate_scoreboard_busy
            != '0
        ) begin

            $fatal(
                1,
                "RTL5B predicate scoreboard not empty after program"
            );
        end


        /*
         * Architectural-result checks.
         */
        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            if (
                dut.vector_regs[3][l]
                != (
                    (l + 1)
                    + 17
                )
            ) begin

                $fatal(
                    1,
                    "RTL5B V3 result mismatch lane=%0d",
                    l
                );
            end


            if (l < 16) begin

                if (
                    dut.vector_regs[4][l]
                    != (
                        (l + 1)
                        + 17
                    )
                ) begin

                    $fatal(
                        1,
                        "RTL5B predicated V4 active lane mismatch lane=%0d",
                        l
                    );
                end

            end else begin

                if (
                    dut.vector_regs[4][l]
                    != 32'hA5A5A5A5
                ) begin

                    $fatal(
                        1,
                        "RTL5B predicated V4 masked lane changed lane=%0d",
                        l
                    );
                end
            end
        end


        if (
            dut.predicate_regs[2]
            != 32'h0000FFFF
        ) begin

            $fatal(
                1,
                "RTL5B P2 result=%08x expected=0000FFFF",
                dut.predicate_regs[2]
            );
        end


        $display(
            "RTL5B_CORE_TB=PASS cycles=%0d pc=%0d",
            cycles,
            pc
        );

        $display(
            "CORE_VECTOR_ISSUES=%0d",
            vector_issues
        );

        $display(
            "CORE_VECTOR_RETIREMENTS=%0d",
            vector_retirements
        );

        $display(
            "VECTOR_DEST_RESERVATION=PASS"
        );

        $display(
            "PREDICATE_DEST_RESERVATION=PASS"
        );

        $display(
            "BUSY_HELD_UNTIL_RETIRE=PASS"
        );

        $display(
            "RETIRE_RELEASE=PASS"
        );

        $display(
            "PREDICATE_SOURCE_NOT_RESERVED=PASS"
        );

        $display(
            "CORE_FALSE_STALLS=%0d",
            false_stalls
        );

        $display(
            "ARCHITECTURAL_RESULT_MATCH=PASS"
        );

        $finish;
    end

endmodule
