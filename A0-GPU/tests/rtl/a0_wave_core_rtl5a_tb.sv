`timescale 1ns/1ps

module a0_wave_core_rtl5a_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;

    localparam integer PROGRAM_WORDS = 16;

    localparam logic [7:0] OP_VADD = 8'h01;
    localparam logic [7:0] OP_VXOR = 8'h06;

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

    logic [63:0]
        mutation_init [0:0];

    integer i;
    integer l;
    integer cycles;

    integer target_retirements;
    integer pc_hold_violations;

    integer vector_file;

    logic previous_vector_waiting;

    logic [7:0]
        captured_opcode;

    logic [3:0]
        captured_flags;

    logic [5:0]
        captured_dst;

    logic [5:0]
        captured_src0;

    logic [5:0]
        captured_src1;

    logic [3:0]
        captured_pred;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        captured_pc;

    logic [$clog2(WAVE_SIZE)-1:0]
        paused_beat_index;


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

    // RTL5A exercises only vector sequencing/ALU instructions.  Any
    // architectural memory request is therefore a contract violation;
    // include the complete request payload in the diagnostic so every
    // output is observably checked rather than warning-suppressed.
    always @(negedge clk) begin : no_memory_traffic_contract
        integer mem_lane;
        if (rst_n && mem_req_valid) begin
            for (mem_lane = 0; mem_lane < WAVE_SIZE; mem_lane = mem_lane + 1) begin
                if (mem_req_lane_mask[mem_lane]) begin
                    $display(
                        "RTL5A unexpected memory lane=%0d addr=%08x wdata=%08x",
                        mem_lane,
                        mem_req_addr[mem_lane],
                        mem_req_wdata[mem_lane]
                    );
                end
            end
            $fatal(
                1,
                "RTL5A unexpected memory request write=%0b lane_mask=%08x",
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
            mem_resp_rdata[l] = 32'b0;
        end


        $readmemh(
            "program.hex",
            program_init
        );

        $readmemh(
            "mutation.hex",
            mutation_init
        );


        repeat (3) @(negedge clk);

        rst_n = 1'b1;


        /*
         * Program:
         *
         * PC0: VCMP_LT P1, V1, V2
         * PC1: @P1 VADD V3, V1, V2
         * PC2: HALT
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
         * Therefore:
         *
         * P1 = lanes 0..15 active because
         *      values 1..16 are < 17.
         *
         * V3 starts with a sentinel value.
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
        end


        @(negedge clk);

        run_enable = 1'b1;
        cycles = 0;


        /*
         * Ignore the first vector instruction
         * (VCMP_LT at PC0).
         *
         * Stop when the target predicated VADD
         * at PC1 has been issued.
         */
        while (
            !(
                dut.vector_waiting
                && dut.vector_issue_pc == 1
            )
            && cycles < 128
        ) begin

            @(negedge clk);

            cycles = cycles + 1;
        end


        if (
            !dut.vector_waiting
            || dut.vector_issue_pc != 1
        ) begin

            $fatal(
                1,
                "RTL5A target vector issue not observed"
            );
        end


        /*
         * Capture the issued instruction identity.
         */
        captured_opcode =
            dut.vector_issue_opcode;

        captured_flags =
            dut.vector_issue_flags;

        captured_dst =
            dut.vector_issue_dst_index;

        captured_src0 =
            dut.vector_issue_src0_index;

        captured_src1 =
            dut.vector_issue_src1_index;

        captured_pred =
            dut.vector_issue_pred_index;

        captured_pc =
            dut.vector_issue_pc;


        if (
            captured_opcode != OP_VADD
        ) begin

            $fatal(
                1,
                "RTL5A expected latched VADD opcode=%02x",
                captured_opcode
            );
        end


        if (
            captured_dst != 6'd3
            || captured_src0 != 6'd1
            || captured_src1 != 6'd2
        ) begin

            $fatal(
                1,
                "RTL5A latched register metadata mismatch"
            );
        end


        if (
            !captured_flags[0]
            || captured_pred != 4'd1
        ) begin

            $fatal(
                1,
                "RTL5A predication metadata mismatch flags=%x pred=%0d",
                captured_flags,
                captured_pred
            );
        end


        /*
         * Pause immediately after issue.
         *
         * The lane sequencer uses run_enable as
         * advance_enable, so no physical progress
         * may occur while paused.
         */
        run_enable = 1'b0;

        paused_beat_index =
            dut.vector_seq_beat_index;


        repeat (3) begin

            @(negedge clk);

            if (
                !dut.vector_waiting
            ) begin

                $fatal(
                    1,
                    "RTL5A vector ownership lost while paused"
                );
            end

            if (
                dut.vector_seq_beat_index
                != paused_beat_index
            ) begin

                $fatal(
                    1,
                    "RTL5A sequencer advanced while paused"
                );
            end

            if (
                pc != captured_pc
            ) begin

                $fatal(
                    1,
                    "RTL5A PC changed while paused"
                );
            end
        end


        /*
         * No destination lane may have executed
         * before resume.
         */
        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            if (
                dut.vector_regs[3][l]
                != 32'hDEADBEEF
            ) begin

                $fatal(
                    1,
                    "RTL5A early vector write lane=%0d value=%08x",
                    l,
                    dut.vector_regs[3][l]
                );
            end
        end


        /*
         * While paused, overwrite PC1 through the
         * architectural program-write interface.
         *
         * The live decoder must now see VXOR,
         * while the in-flight vector state must
         * continue to own the original VADD.
         */
        write_program(
            1,
            mutation_init[0]
        );


        if (
            dut.opcode != OP_VXOR
        ) begin

            $fatal(
                1,
                "RTL5A live decoder did not observe VXOR opcode=%02x",
                dut.opcode
            );
        end


        if (
            dut.vector_issue_opcode
            != captured_opcode
            || dut.vector_issue_flags
            != captured_flags
            || dut.vector_issue_dst_index
            != captured_dst
            || dut.vector_issue_src0_index
            != captured_src0
            || dut.vector_issue_src1_index
            != captured_src1
            || dut.vector_issue_pred_index
            != captured_pred
            || dut.vector_issue_pc
            != captured_pc
        ) begin

            $fatal(
                1,
                "RTL5A issue latch changed after program mutation"
            );
        end


        if (
            dut.vector_issue_opcode
            == dut.opcode
        ) begin

            $fatal(
                1,
                "RTL5A live decode did not diverge from latch"
            );
        end


        if (
            dut.vector_seq_beat_index
            != paused_beat_index
        ) begin

            $fatal(
                1,
                "RTL5A sequencer moved during mutation"
            );
        end


        /*
         * Resume and require exactly one retirement
         * of the already-issued architectural VADD.
         */
        target_retirements = 0;
        pc_hold_violations = 0;

        previous_vector_waiting =
            dut.vector_waiting;

        run_enable = 1'b1;


        while (
            !halted
            && cycles < 256
        ) begin

            @(negedge clk);

            cycles = cycles + 1;


            if (
                dut.vector_waiting
                && pc != captured_pc
            ) begin

                pc_hold_violations =
                    pc_hold_violations + 1;
            end


            if (
                !dut.vector_waiting
                && previous_vector_waiting
            ) begin

                target_retirements =
                    target_retirements + 1;

                if (
                    pc
                    != (
                        captured_pc
                        + 1'b1
                    )
                ) begin

                    $fatal(
                        1,
                        "RTL5A retirement PC mismatch pc=%0d expected=%0d",
                        pc,
                        captured_pc + 1'b1
                    );
                end
            end


            previous_vector_waiting =
                dut.vector_waiting;
        end


        run_enable = 1'b0;


        if (!halted) begin

            $fatal(
                1,
                "RTL5A timeout before HALT"
            );
        end


        if (faulted) begin

            $fatal(
                1,
                "RTL5A entered faulted state"
            );
        end


        if (
            target_retirements != 1
        ) begin

            $fatal(
                1,
                "RTL5A target retirements=%0d expected=1",
                target_retirements
            );
        end


        if (
            pc_hold_violations != 0
        ) begin

            $fatal(
                1,
                "RTL5A PC hold violations=%0d",
                pc_hold_violations
            );
        end


        vector_file = $fopen(
            "rtl_v3.hex",
            "w"
        );

        if (
            vector_file == 0
        ) begin

            $fatal(
                1,
                "RTL5A could not create rtl_v3.hex"
            );
        end


        for (
            l = 0;
            l < WAVE_SIZE;
            l = l + 1
        ) begin

            $fdisplay(
                vector_file,
                "%08x",
                dut.vector_regs[3][l]
            );
        end

        $fclose(vector_file);


        $display(
            "RTL5A_TB=PASS cycles=%0d pc=%0d",
            cycles,
            pc
        );

        $display(
            "PHYSICAL_LANES=%0d",
            PHYSICAL_LANES
        );

        $display(
            "ISSUED_OPCODE_LATCHED=PASS"
        );

        $display(
            "ISSUED_METADATA_LATCHED=PASS"
        );

        $display(
            "PROGRAM_MEMORY_MUTATION=PASS"
        );

        $display(
            "LIVE_DECODE_INDEPENDENCE=PASS"
        );

        $display(
            "PAUSE_STATE_STABLE=PASS"
        );

        $display(
            "NO_EARLY_VECTOR_WRITE=PASS"
        );

        $display(
            "VECTOR_PC_HOLD=PASS"
        );

        $display(
            "SINGLE_RETIREMENT=PASS"
        );

        $finish;
    end

endmodule
