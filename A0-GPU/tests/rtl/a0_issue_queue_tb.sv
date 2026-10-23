module a0_issue_queue_tb;

    localparam logic [7:0] OP_VADD    = 8'h01;
    localparam logic [7:0] OP_VLOADX  = 8'h54;
    localparam logic [7:0] OP_VSTOREX = 8'h55;
    localparam logic [7:0] OP_VCMP_LT = 8'h61;

    logic clk;
    logic rst;

    logic        dispatch_valid;
    logic [31:0] dispatch_pc;
    logic [7:0]  dispatch_opcode;
    logic [3:0]  dispatch_flags;
    logic [5:0]  dispatch_dst;
    logic [5:0]  dispatch_src0;
    logic [5:0]  dispatch_src1;
    logic [5:0]  dispatch_src2;
    logic [3:0]  dispatch_pred;

    logic dispatch_vector_src0_enable;
    logic dispatch_vector_src1_enable;
    logic dispatch_vector_src2_enable;
    logic dispatch_vector_dst_enable;
    logic dispatch_predicate_src_enable;
    logic dispatch_predicate_dst_enable;

    logic dispatch_ready;

    logic        issue_valid;
    logic [31:0] issue_pc;
    logic [7:0]  issue_opcode;
    logic [3:0]  issue_flags;
    logic [5:0]  issue_dst;
    logic [5:0]  issue_src0;
    logic [5:0]  issue_src1;
    logic [5:0]  issue_src2;
    logic [3:0]  issue_pred;

    logic issue_vector_src0_enable;
    logic issue_vector_src1_enable;
    logic issue_vector_src2_enable;
    logic issue_vector_dst_enable;
    logic issue_predicate_src_enable;
    logic issue_predicate_dst_enable;

    logic issue_ready;

    logic [63:0] busy_vector_regs;
    logic [15:0] busy_predicate_regs;

    integer i;

    a0_issue_queue #(
        .DEPTH(8)
    ) dut (
        .clk(clk),
        .rst(rst),

        .dispatch_valid(dispatch_valid),
        .dispatch_pc(dispatch_pc),
        .dispatch_opcode(dispatch_opcode),
        .dispatch_flags(dispatch_flags),
        .dispatch_dst(dispatch_dst),
        .dispatch_src0(dispatch_src0),
        .dispatch_src1(dispatch_src1),
        .dispatch_src2(dispatch_src2),
        .dispatch_pred(dispatch_pred),
        .dispatch_vector_src0_enable(dispatch_vector_src0_enable),
        .dispatch_vector_src1_enable(dispatch_vector_src1_enable),
        .dispatch_vector_src2_enable(dispatch_vector_src2_enable),
        .dispatch_vector_dst_enable(dispatch_vector_dst_enable),
        .dispatch_predicate_src_enable(dispatch_predicate_src_enable),
        .dispatch_predicate_dst_enable(dispatch_predicate_dst_enable),
        .dispatch_ready(dispatch_ready),

        .issue_valid(issue_valid),
        .issue_pc(issue_pc),
        .issue_opcode(issue_opcode),
        .issue_flags(issue_flags),
        .issue_dst(issue_dst),
        .issue_src0(issue_src0),
        .issue_src1(issue_src1),
        .issue_src2(issue_src2),
        .issue_pred(issue_pred),
        .issue_vector_src0_enable(issue_vector_src0_enable),
        .issue_vector_src1_enable(issue_vector_src1_enable),
        .issue_vector_src2_enable(issue_vector_src2_enable),
        .issue_vector_dst_enable(issue_vector_dst_enable),
        .issue_predicate_src_enable(issue_predicate_src_enable),
        .issue_predicate_dst_enable(issue_predicate_dst_enable),
        .issue_ready(issue_ready),

        .busy_vector_regs(busy_vector_regs),
        .busy_predicate_regs(busy_predicate_regs)
    );

    always #5 clk = ~clk;

    task automatic clear_dispatch;
        begin
            dispatch_valid = 1'b0;
            dispatch_pc = 32'b0;
            dispatch_opcode = 8'b0;
            dispatch_flags = 4'b0;
            dispatch_dst = 6'b0;
            dispatch_src0 = 6'b0;
            dispatch_src1 = 6'b0;
            dispatch_src2 = 6'b0;
            dispatch_pred = 4'b0;
            dispatch_vector_src0_enable = 1'b0;
            dispatch_vector_src1_enable = 1'b0;
            dispatch_vector_src2_enable = 1'b0;
            dispatch_vector_dst_enable = 1'b0;
            dispatch_predicate_src_enable = 1'b0;
            dispatch_predicate_dst_enable = 1'b0;
        end
    endtask

    task automatic reset_dut;
        begin
            clear_dispatch();
            busy_vector_regs = '0;
            busy_predicate_regs = '0;
            issue_ready = 1'b0;
            rst = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            #1;
        end
    endtask

    task automatic enqueue(
        input logic [31:0] pc,
        input logic [7:0] opcode,
        input logic [3:0] flags,
        input logic [5:0] dst,
        input logic [5:0] src0,
        input logic [5:0] src1,
        input logic [5:0] src2,
        input logic [3:0] pred,
        input logic vsrc0_en,
        input logic vsrc1_en,
        input logic vsrc2_en,
        input logic vdst_en,
        input logic psrc_en,
        input logic pdst_en
    );
        begin
            @(negedge clk);
            if (!dispatch_ready) begin
                $fatal(1, "enqueue called while dispatch_ready=0 pc=%08x", pc);
            end

            dispatch_valid = 1'b1;
            dispatch_pc = pc;
            dispatch_opcode = opcode;
            dispatch_flags = flags;
            dispatch_dst = dst;
            dispatch_src0 = src0;
            dispatch_src1 = src1;
            dispatch_src2 = src2;
            dispatch_pred = pred;
            dispatch_vector_src0_enable = vsrc0_en;
            dispatch_vector_src1_enable = vsrc1_en;
            dispatch_vector_src2_enable = vsrc2_en;
            dispatch_vector_dst_enable = vdst_en;
            dispatch_predicate_src_enable = psrc_en;
            dispatch_predicate_dst_enable = pdst_en;

            @(posedge clk);
            #1;
            clear_dispatch();
        end
    endtask

    task automatic consume_one;
        begin
            if (!issue_valid) begin
                $fatal(1, "consume_one called while issue_valid=0");
            end
            issue_ready = 1'b1;
            @(posedge clk);
            #1;
            issue_ready = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        clear_dispatch();
        issue_ready = 1'b0;
        busy_vector_regs = '0;
        busy_predicate_regs = '0;

        /* ---------------------------------------------------------- */
        /* Current interface and metadata preservation.                */
        /* ---------------------------------------------------------- */
        reset_dut();

        enqueue(
            32'h0000_0100, OP_VSTOREX, 4'h1,
            6'd17, 6'd5, 6'd21, 6'd22, 4'd7,
            1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0
        );

        if (!issue_valid) $fatal(1, "metadata test did not produce issue_valid");
        if (issue_pc != 32'h0000_0100) $fatal(1, "metadata pc mismatch");
        if (issue_opcode != OP_VSTOREX) $fatal(1, "metadata opcode mismatch");
        if (issue_flags != 4'h1) $fatal(1, "metadata flags mismatch");
        if (issue_dst != 6'd17) $fatal(1, "metadata dst mismatch");
        if (issue_src0 != 6'd5) $fatal(1, "metadata src0 mismatch");
        if (issue_src1 != 6'd21) $fatal(1, "metadata src1 mismatch");
        if (issue_src2 != 6'd22) $fatal(1, "metadata src2 mismatch");
        if (issue_pred != 4'd7) $fatal(1, "metadata pred mismatch");
        if (issue_vector_src0_enable != 1'b0) $fatal(1, "metadata vsrc0 enable mismatch");
        if (issue_vector_src1_enable != 1'b1) $fatal(1, "metadata vsrc1 enable mismatch");
        if (issue_vector_src2_enable != 1'b1) $fatal(1, "metadata vsrc2 enable mismatch");
        if (issue_vector_dst_enable != 1'b0) $fatal(1, "metadata vdst enable mismatch");
        if (issue_predicate_src_enable != 1'b1) $fatal(1, "metadata psrc enable mismatch");
        if (issue_predicate_dst_enable != 1'b0) $fatal(1, "metadata pdst enable mismatch");
        $display("ISSUE_QUEUE_METADATA=PASS");
        consume_one();

        /* ---------------------------------------------------------- */
        /* Q-1: unused src2 must not create a false V0 dependency.    */
        /* ---------------------------------------------------------- */
        reset_dut();
        busy_vector_regs[0] = 1'b1;
        enqueue(
            32'h0000_0200, OP_VADD, 4'h0,
            6'd8, 6'd1, 6'd2, 6'd0, 4'd0,
            1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0
        );
        if (!issue_valid || issue_pc != 32'h0000_0200) begin
            $fatal(1, "Q1 false src2 dependency was not eliminated");
        end
        $display("ISSUE_QUEUE_Q1_UNUSED_SRC2=PASS");
        consume_one();

        /* ---------------------------------------------------------- */
        /* Q-2: scalar src0 must not alias the vector busy bitmap.     */
        /* ---------------------------------------------------------- */
        reset_dut();
        busy_vector_regs[5] = 1'b1;
        enqueue(
            32'h0000_0300, OP_VLOADX, 4'h0,
            6'd9, 6'd5, 6'd7, 6'd0, 4'd0,
            1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0
        );
        if (!issue_valid || issue_pc != 32'h0000_0300) begin
            $fatal(1, "Q2 scalar src0 aliased V5");
        end
        $display("ISSUE_QUEUE_Q2_SCALAR_ALIAS=PASS");
        consume_one();

        /* ---------------------------------------------------------- */
        /* Q-3: busy destination must block WAW.                       */
        /* ---------------------------------------------------------- */
        reset_dut();
        busy_vector_regs[12] = 1'b1;
        enqueue(
            32'h0000_0400, OP_VADD, 4'h0,
            6'd12, 6'd1, 6'd2, 6'd0, 4'd0,
            1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0
        );
        if (issue_valid) $fatal(1, "Q3 vector WAW did not block");
        busy_vector_regs[12] = 1'b0;
        #1;
        if (!issue_valid || issue_pc != 32'h0000_0400) begin
            $fatal(1, "Q3 vector WAW did not release");
        end
        $display("ISSUE_QUEUE_Q3_VECTOR_WAW=PASS");
        consume_one();

        /* ---------------------------------------------------------- */
        /* Q-4a: predicated consumer must wait for predicate RAW.      */
        /* ---------------------------------------------------------- */
        reset_dut();
        busy_predicate_regs[3] = 1'b1;
        enqueue(
            32'h0000_0500, OP_VADD, 4'h1,
            6'd10, 6'd1, 6'd2, 6'd0, 4'd3,
            1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0
        );
        if (issue_valid) $fatal(1, "Q4 predicate RAW did not block");
        busy_predicate_regs[3] = 1'b0;
        #1;
        if (!issue_valid || issue_pc != 32'h0000_0500) begin
            $fatal(1, "Q4 predicate RAW did not release");
        end
        $display("ISSUE_QUEUE_Q4_PREDICATE_RAW=PASS");
        consume_one();

        /* Q-4b: compare destination must also obey predicate WAW. */
        reset_dut();
        busy_predicate_regs[4] = 1'b1;
        enqueue(
            32'h0000_0580, OP_VCMP_LT, 4'h0,
            6'd0, 6'd1, 6'd2, 6'd0, 4'd4,
            1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1
        );
        if (issue_valid) $fatal(1, "predicate WAW did not block");
        busy_predicate_regs[4] = 1'b0;
        #1;
        if (!issue_valid || issue_pc != 32'h0000_0580) begin
            $fatal(1, "predicate WAW did not release");
        end
        $display("ISSUE_QUEUE_PREDICATE_WAW=PASS");
        consume_one();

        /* ---------------------------------------------------------- */
        /* Oldest-ready selection: younger ready may bypass blocked.  */
        /* ---------------------------------------------------------- */
        reset_dut();
        busy_vector_regs[3] = 1'b1;
        enqueue(
            32'h0000_0600, OP_VADD, 4'h0,
            6'd20, 6'd3, 6'd2, 6'd0, 4'd0,
            1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0
        );
        if (issue_valid) $fatal(1, "blocked older entry unexpectedly ready");

        enqueue(
            32'h0000_0610, OP_VADD, 4'h0,
            6'd21, 6'd1, 6'd2, 6'd0, 4'd0,
            1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0
        );
        if (!issue_valid || issue_pc != 32'h0000_0610) begin
            $fatal(1, "younger ready entry was not selected");
        end
        $display("ISSUE_QUEUE_READY_BYPASS=PASS");

        busy_vector_regs[3] = 1'b0;
        #1;
        if (!issue_valid || issue_pc != 32'h0000_0600) begin
            $fatal(1, "older entry did not regain priority after release");
        end
        $display("ISSUE_QUEUE_OLDEST_READY=PASS");
        consume_one();
        if (!issue_valid || issue_pc != 32'h0000_0610) begin
            $fatal(1, "younger entry missing after older issue");
        end
        consume_one();

        /* ---------------------------------------------------------- */
        /* Full backpressure + same-cycle issue/dispatch refill.       */
        /* ---------------------------------------------------------- */
        reset_dut();
        issue_ready = 1'b0;

        for (i = 0; i < 8; i = i + 1) begin
            enqueue(
                32'h0000_0800 + i,
                OP_VADD, 4'h0,
                6'd0, 6'd0, 6'd0, 6'd0, 4'd0,
                1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0
            );
        end

        if (dispatch_ready) $fatal(1, "full queue did not backpressure");
        if (!issue_valid || issue_pc != 32'h0000_0800) begin
            $fatal(1, "full queue oldest issue mismatch");
        end
        $display("ISSUE_QUEUE_FULL_BACKPRESSURE=PASS");

        /* Full queue is allowed to refill the slot issuing this cycle. */
        issue_ready = 1'b1;
        #1;
        if (!dispatch_ready) begin
            $fatal(1, "full queue did not expose same-cycle refill readiness");
        end

        @(negedge clk);
        dispatch_valid = 1'b1;
        dispatch_pc = 32'h0000_0900;
        dispatch_opcode = OP_VADD;
        dispatch_flags = 4'h0;
        dispatch_dst = 6'd0;
        dispatch_src0 = 6'd0;
        dispatch_src1 = 6'd0;
        dispatch_src2 = 6'd0;
        dispatch_pred = 4'd0;
        dispatch_vector_src0_enable = 1'b0;
        dispatch_vector_src1_enable = 1'b0;
        dispatch_vector_src2_enable = 1'b0;
        dispatch_vector_dst_enable = 1'b0;
        dispatch_predicate_src_enable = 1'b0;
        dispatch_predicate_dst_enable = 1'b0;

        @(posedge clk);
        #1;
        clear_dispatch();
        issue_ready = 1'b0;
        #1;

        if (dispatch_ready) $fatal(1, "queue lost full occupancy after refill");
        if (!issue_valid || issue_pc != 32'h0000_0801) begin
            $fatal(1, "age order corrupted by same-cycle refill");
        end
        $display("ISSUE_QUEUE_SAME_CYCLE_REFILL=PASS");

        $display("RTL5E_ISSUE_QUEUE_TB=PASS");
        $finish;
    end

endmodule
