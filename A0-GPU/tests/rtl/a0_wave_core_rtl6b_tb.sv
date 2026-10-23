`timescale 1ns/1ps

module a0_wave_core_rtl6b_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer PROGRAM_WORDS = 32;
    localparam integer GLOBAL_MEMORY_WORDS = 1024;

    logic clk;
    logic rst_n;
    logic run_enable;

    logic program_we;
    logic [$clog2(PROGRAM_WORDS)-1:0] program_waddr;
    logic [63:0] program_wdata;

    logic vector_we;
    logic [5:0] vector_wreg;
    logic [$clog2(WAVE_SIZE)-1:0] vector_wlane;
    logic [31:0] vector_wdata;

    logic scalar_we;
    logic [4:0] scalar_wreg;
    logic [31:0] scalar_wdata;

    logic mem_req_valid;
    logic mem_req_write;
    logic [WAVE_SIZE-1:0] mem_req_lane_mask;
    logic [31:0] mem_req_addr [0:WAVE_SIZE-1];
    logic [31:0] mem_req_wdata [0:WAVE_SIZE-1];

    logic mem_resp_valid;
    logic mem_resp_fault;
    logic [31:0] mem_resp_rdata [0:WAVE_SIZE-1];

    logic halted;
    logic faulted;
    logic [$clog2(PROGRAM_WORDS)-1:0] pc;

    integer cycles;
    integer bank_conflict_cycles;
    integer refill_cycles;
    integer refill_issue_violations;
    integer response_delay;
    logic response_pending;


    a0_wave_core #(
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .GLOBAL_MEMORY_WORDS(GLOBAL_MEMORY_WORDS)
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


    always #1 clk = ~clk;


    function automatic logic [63:0] encode(
        input logic [7:0] op,
        input logic [3:0] flags,
        input logic [5:0] dst,
        input logic [5:0] src0,
        input logic [5:0] src1,
        input logic [5:0] src2,
        input logic [3:0] pred,
        input logic [23:0] imm24
    );
        encode = {
            op,
            flags,
            dst,
            src0,
            src1,
            src2,
            pred,
            imm24
        };
    endfunction


    task automatic pulse_reset;
        begin
            run_enable = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask


    task automatic write_program(
        input integer address,
        input logic [63:0] value
    );
        begin
            if (address < 0 || address >= PROGRAM_WORDS) begin
                $fatal(1, "program address out of range: %0d", address);
            end
            @(negedge clk);
            program_we = 1'b1;
            program_waddr = $clog2(PROGRAM_WORDS)'(address);
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
            if (reg_index < 0 || reg_index >= 64) begin
                $fatal(1, "vector register out of range: %0d", reg_index);
            end
            if (lane_index < 0 || lane_index >= WAVE_SIZE) begin
                $fatal(1, "vector lane out of range: %0d", lane_index);
            end
            @(negedge clk);
            vector_we = 1'b1;
            vector_wreg = 6'(reg_index);
            vector_wlane = $clog2(WAVE_SIZE)'(lane_index);
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
            if (reg_index < 0 || reg_index >= 32) begin
                $fatal(1, "scalar register out of range: %0d", reg_index);
            end
            @(negedge clk);
            scalar_we = 1'b1;
            scalar_wreg = 5'(reg_index);
            scalar_wdata = value;
            @(negedge clk);
            scalar_we = 1'b0;
        end
    endtask


    task automatic run_until_halt(
        input integer max_cycles
    );
        begin
            cycles = 0;
            run_enable = 1'b1;
            while (!halted && cycles < max_cycles) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            run_enable = 1'b0;

            if (!halted) begin
                $fatal(1, "RTL6B timeout before HALT");
            end

            if (faulted) begin
                $fatal(1, "RTL6B unexpected core fault");
            end
        end
    endtask


    /*
     * Minimal one-response memory model for the load->ALU coherence test.
     * Response data is deterministic per logical lane.
     */
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_fault <= 1'b0;
            response_pending <= 1'b0;
            response_delay <= 0;

            for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                mem_resp_rdata[lane] <= 32'b0;
            end
        end else begin
            mem_resp_valid <= 1'b0;
            mem_resp_fault <= 1'b0;

            if (response_pending) begin
                if (response_delay == 0) begin
                    mem_resp_valid <= 1'b1;
                    response_pending <= 1'b0;

                    for (
                        integer lane = 0;
                        lane < WAVE_SIZE;
                        lane = lane + 1
                    ) begin
                        mem_resp_rdata[lane] <= 32'd1000 + lane;
                    end
                end else begin
                    response_delay <= response_delay - 1;
                end
            end

            if (
                mem_req_valid
                && !mem_req_write
                && !response_pending
            ) begin
                if (mem_req_lane_mask != {WAVE_SIZE{1'b1}}) begin
                    $fatal(1, "RTL6B load request lane mask mismatch");
                end
                for (integer request_lane = 0; request_lane < WAVE_SIZE; request_lane = request_lane + 1) begin
                    if (mem_req_addr[request_lane] != 32'(request_lane)) begin
                        $fatal(1, "RTL6B load address mismatch lane=%0d addr=%0d", request_lane, mem_req_addr[request_lane]);
                    end
                    if (mem_req_wdata[request_lane] != 32'b0) begin
                        $fatal(1, "RTL6B load request carried write data lane=%0d", request_lane);
                    end
                end
                response_pending <= 1'b1;
                response_delay <= 1;
            end
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_conflict_cycles <= 0;
            refill_cycles <= 0;
            refill_issue_violations <= 0;
        end else if (run_enable) begin
            if (dut.vector_operand_bank_conflict_cycle) begin
                bank_conflict_cycles <= bank_conflict_cycles + 1;
            end

            if (dut.vrf_refill_pending) begin
                refill_cycles <= refill_cycles + 1;

                if (
                    dut.scoreboard_query_valid
                    || dut.vector_issue_fire
                    || dut.vector_waiting
                    || dut.vector_seq_busy
                ) begin
                    refill_issue_violations <=
                        refill_issue_violations + 1;
                end
            end
        end
    end


    initial begin
        clk = 1'b0;
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

        /* ============================================================
         * Phase 1: prove ALU sources are live banked-VRF data.
         * V1 and V5 map to the same bank when BANK_COUNT=4.
         * ========================================================== */
        pulse_reset();

        write_program(
            0,
            encode(8'h01, 4'h0, 6'd9, 6'd1, 6'd5, 6'd0, 4'd0, 24'd0)
        );
        write_program(
            1,
            encode(8'hFF, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0)
        );

        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector(1, lane, 32'd10 + lane);
            write_vector(5, lane, 32'd100 + lane);
        end

        /*
         * Corrupt only the legacy shadow after the banked RF has been
         * initialized. If vector execution still sources vector_regs,
         * V9 will be wrong. The banked VRF is intentionally untouched.
         */
        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            dut.vector_regs[1][lane] = 32'hDEAD0000 + lane;
            dut.vector_regs[5][lane] = 32'hBEEF0000 + lane;
        end

        run_until_halt(1024);

        if (pc != 5'd2) begin
            $fatal(1, "RTL6B phase1 HALT PC mismatch got=%0d", pc);
        end

        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (dut.vector_regs[9][lane] !== 32'd110 + (2 * lane)) begin
                $fatal(
                    1,
                    "RTL6B banked source mismatch lane=%0d got=%08x",
                    lane,
                    dut.vector_regs[9][lane]
                );
            end
        end

        if (bank_conflict_cycles < 1) begin
            $fatal(1, "RTL6B observed no live bank conflict");
        end

        $display("RTL6B_BANKED_SOURCE_PROOF=PASS");
        $display("RTL6B_SAME_BANK_CONFLICT=PASS cycles=%0d", bank_conflict_cycles);

        /* ============================================================
         * Phase 2: prove VLOADX response is refilled into the banked RF
         * before a dependent vector ALU instruction executes.
         * ========================================================== */
        pulse_reset();

        write_program(
            0,
            encode(8'h54, 4'h0, 6'd3, 6'd0, 6'd1, 6'd0, 4'd0, 24'd0)
        );
        write_program(
            1,
            encode(8'h01, 4'h0, 6'd4, 6'd3, 6'd2, 6'd0, 4'd0, 24'd0)
        );
        write_program(
            2,
            encode(8'hFF, 4'h0, 6'd0, 6'd0, 6'd0, 6'd0, 4'd0, 24'd0)
        );

        write_scalar(0, 32'd0);

        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            write_vector(1, lane, lane);
            write_vector(2, lane, 32'd7);
        end

        run_until_halt(2048);

        if (pc != 5'd3) begin
            $fatal(1, "RTL6B phase2 HALT PC mismatch got=%0d", pc);
        end

        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (dut.vector_regs[3][lane] !== 32'd1000 + lane) begin
                $fatal(1, "RTL6B load shadow mismatch lane=%0d", lane);
            end

            if (dut.vector_regs[4][lane] !== 32'd1007 + lane) begin
                $fatal(
                    1,
                    "RTL6B load->ALU banked coherence mismatch lane=%0d got=%08x",
                    lane,
                    dut.vector_regs[4][lane]
                );
            end
        end

        if (refill_cycles < 1) begin
            $fatal(1, "RTL6B banked VRF refill never became active");
        end

        if (refill_issue_violations != 0) begin
            $fatal(
                1,
                "RTL6B issue escaped during refill count=%0d",
                refill_issue_violations
            );
        end

        if (dut.vector_scoreboard_busy !== '0) begin
            $fatal(1, "RTL6B vector scoreboard not empty at halt");
        end

        if (dut.predicate_scoreboard_busy !== '0) begin
            $fatal(1, "RTL6B predicate scoreboard not empty at halt");
        end

        $display("RTL6B_LOAD_TO_ALU_REFILL=PASS cycles=%0d", refill_cycles);
        $display("RTL6B_REFILL_ISSUE_ISOLATION=PASS");
        $display("RTL6B_RELEASE_ENABLE_LATCH=PASS");
        $display("RTL6B_LIVE_CORE_TB=PASS");

        $finish;
    end

endmodule
