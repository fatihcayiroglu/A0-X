module a0_wave_core_rtl4b_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;
    localparam integer PROGRAM_WORDS = 256;

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

    logic [$clog2(PROGRAM_WORDS)-1:0] pc;

    logic [63:0] program_init
        [0:PROGRAM_WORDS-1];

    logic [31:0] vector_init
        [0:(VECTOR_REG_COUNT * WAVE_SIZE)-1];

    logic [31:0] scalar_init
        [0:SCALAR_REG_COUNT-1];

    integer i;
    integer r;
    integer l;
    integer p;

    integer cycles;

    integer vector_launches;
    integer physical_beats;
    integer vector_retirements;

    integer pc_hold_violations;
    integer retirement_pc_violations;

    logic retirement_check_pending;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        vector_instruction_pc;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        retired_instruction_pc;

    integer vector_file;
    integer scalar_file;
    integer predicate_file;

    a0_wave_core #(
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(
            PREDICATE_REG_COUNT
        ),
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

    initial begin
        clk = 1'b0;
    end

    always #1 clk = ~clk;

    task automatic write_program(
        input integer address,
        input logic [63:0] value
    );
        begin
            if ((address < 0) || (address > 255)) begin
                $fatal(1, "write_program address out of range: %0d", address);
            end

            @(negedge clk);

            program_we = 1'b1;
            program_waddr = address[7:0];
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
            if ((reg_index < 0) || (reg_index > 63)) begin
                $fatal(1, "write_vector reg_index out of range: %0d", reg_index);
            end
            if ((lane_index < 0) || (lane_index > 31)) begin
                $fatal(1, "write_vector lane_index out of range: %0d", lane_index);
            end

            @(negedge clk);

            vector_we = 1'b1;
            vector_wreg = reg_index[5:0];
            vector_wlane = lane_index[4:0];
            vector_wdata = value;

            @(negedge clk);

            vector_we = 1'b0;
        end
    endtask

    task automatic write_scalar(
        input integer reg_index,
        input logic [31:0] value
    );
        begin
            if ((reg_index < 0) || (reg_index > 31)) begin
                $fatal(1, "write_scalar reg_index out of range: %0d", reg_index);
            end

            @(negedge clk);

            scalar_we = 1'b1;
            scalar_wreg = reg_index[4:0];
            scalar_wdata = value;

            @(negedge clk);

            scalar_we = 1'b0;
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
            mem_resp_rdata[l] = 32'b0;
        end

        $readmemh(
            "program.hex",
            program_init
        );

        $readmemh(
            "vregs_init.hex",
            vector_init
        );

        $readmemh(
            "sregs_init.hex",
            scalar_init
        );

        repeat (3) @(negedge clk);

        rst_n = 1'b1;

        /*
         * Program memory configuration.
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
         * Initial vector architectural state.
         */
        for (
            r = 0;
            r < VECTOR_REG_COUNT;
            r = r + 1
        ) begin
            for (
                l = 0;
                l < WAVE_SIZE;
                l = l + 1
            ) begin
                write_vector(
                    r,
                    l,
                    vector_init[
                        r * WAVE_SIZE + l
                    ]
                );
            end
        end

        /*
         * Initial scalar architectural state.
         */
        for (
            r = 0;
            r < SCALAR_REG_COUNT;
            r = r + 1
        ) begin
            write_scalar(
                r,
                scalar_init[r]
            );
        end

        @(negedge clk);

        run_enable = 1'b1;
        cycles = 0;

        vector_launches = 0;
        physical_beats = 0;
        vector_retirements = 0;

        pc_hold_violations = 0;
        retirement_pc_violations = 0;

        retirement_check_pending = 1'b0;

        vector_instruction_pc = '0;
        retired_instruction_pc = '0;

        while (
            !halted
            && cycles < 512
        ) begin

            /*
             * A0-RTL5C compatibility observer.
             *
             * Issue and retirement are architectural
             * events now; vector_waiting may remain high
             * across a zero-bubble retirement handoff.
             */
            @(posedge clk);

            retirement_check_pending =
                1'b0;


            if (
                dut.vector_issue_fire
            ) begin

                vector_launches =
                    vector_launches + 1;

                /*
                 * dependency_pc is the candidate that
                 * actually owns this issue event.
                 */
                vector_instruction_pc =
                    dut.dependency_pc;
            end


            if (
                dut.scoreboard_release_valid
            ) begin

                vector_retirements =
                    vector_retirements + 1;

                retired_instruction_pc =
                    dut.vector_issue_pc;

                retirement_check_pending =
                    1'b1;
            end


            /*
             * Observe post-NBA architectural state.
             */
            @(negedge clk);

            cycles = cycles + 1;


            /*
             * Architectural PC must remain fixed at the
             * current execution owner's PC.
             *
             * On same-cycle handoff vector_instruction_pc
             * has already changed to the new owner.
             */
            if (
                dut.vector_waiting
                && pc != vector_instruction_pc
            ) begin

                pc_hold_violations =
                    pc_hold_violations + 1;
            end


            /*
             * Count every architecturally executed physical SIMD beat.
             *
             * A0-RTL6B may hold vector_seq_beat_valid high for multiple
             * cycles while the operand collector serializes bank
             * conflicts or waits for RF response.  Visibility is no
             * longer equivalent to execution. vector_execute_beat_fire
             * is the single-cycle handshake that consumes one complete
             * operand set and advances the lane sequencer.
             */
            if (
                dut.vector_execute_beat_fire
            ) begin

                physical_beats =
                    physical_beats + 1;
            end


            /*
             * Every retirement advances architectural PC
             * exactly once to retired_pc + 1.
             *
             * This remains true for a same-edge handoff:
             * the new sequential owner is retired_pc + 1.
             */
            if (
                retirement_check_pending
                && pc
                    != (
                        retired_instruction_pc
                        + 1'b1
                    )
            ) begin

                retirement_pc_violations =
                    retirement_pc_violations
                    + 1;
            end
        end

        run_enable = 1'b0;

        if (!halted) begin
            $fatal(
                1,
                "RTL0 timeout before HALT"
            );
        end

        if (faulted) begin
            $fatal(
                1,
                "RTL0 entered faulted state"
            );
        end

        vector_file = $fopen(
            "rtl_vregs.hex",
            "w"
        );

        scalar_file = $fopen(
            "rtl_sregs.hex",
            "w"
        );

        predicate_file = $fopen(
            "rtl_preds.hex",
            "w"
        );

        if (
            vector_file == 0
            || scalar_file == 0
            || predicate_file == 0
        ) begin
            $fatal(
                1,
                "Could not create RTL0 result files"
            );
        end

        for (
            r = 0;
            r < VECTOR_REG_COUNT;
            r = r + 1
        ) begin
            for (
                l = 0;
                l < WAVE_SIZE;
                l = l + 1
            ) begin
                $fdisplay(
                    vector_file,
                    "%08x",
                    dut.vector_regs[r][l]
                );
            end
        end

        for (
            r = 0;
            r < SCALAR_REG_COUNT;
            r = r + 1
        ) begin
            $fdisplay(
                scalar_file,
                "%08x",
                dut.scalar_regs[r]
            );
        end

        for (
            p = 0;
            p < PREDICATE_REG_COUNT;
            p = p + 1
        ) begin
            $fdisplay(
                predicate_file,
                "%08x",
                dut.predicate_regs[p]
            );
        end

        $fclose(vector_file);
        $fclose(scalar_file);
        $fclose(predicate_file);

        if (vector_launches == 0) begin
            $fatal(
                1,
                "RTL4B observed zero vector launches"
            );
        end


        if (
            physical_beats
            != (
                vector_launches
                * (
                    WAVE_SIZE
                    / PHYSICAL_LANES
                )
            )
        ) begin

            $fatal(
                1,
                "RTL4B beat mismatch launches=%0d beats=%0d",
                vector_launches,
                physical_beats
            );
        end


        if (
            vector_retirements
            != vector_launches
        ) begin

            $fatal(
                1,
                "RTL4B retirement mismatch launches=%0d retires=%0d",
                vector_launches,
                vector_retirements
            );
        end


        if (
            pc_hold_violations != 0
        ) begin

            $fatal(
                1,
                "RTL4B PC hold violations=%0d",
                pc_hold_violations
            );
        end


        if (
            retirement_pc_violations != 0
        ) begin

            $fatal(
                1,
                "RTL4B retirement PC violations=%0d",
                retirement_pc_violations
            );
        end


        $display(
            "RTL4B_TB=PASS cycles=%0d pc=%0d",
            cycles,
            pc
        );

        $display(
            "PHYSICAL_LANES=%0d",
            PHYSICAL_LANES
        );

        $display(
            "VECTOR_INSTRUCTIONS=%0d",
            vector_launches
        );

        $display(
            "PHYSICAL_BEATS=%0d",
            physical_beats
        );

        $display(
            "VECTOR_RETIREMENTS=%0d",
            vector_retirements
        );

        $display(
            "VECTOR_PC_HOLD=PASS"
        );

        $display(
            "VECTOR_RETIREMENT_MATCH=PASS"
        );

        $display(
            "PHYSICAL_BEAT_RATIO=PASS"
        );

        $finish;
    end

endmodule
