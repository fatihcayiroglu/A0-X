`timescale 1ns/1ps

module a0_dependency_classifier_tb;

    localparam logic [7:0] OP_VADD     = 8'h01;
    localparam logic [7:0] OP_VMUL     = 8'h03;
    localparam logic [7:0] OP_VXOR     = 8'h06;

    localparam logic [7:0] OP_VLOADX   = 8'h54;
    localparam logic [7:0] OP_VSTOREX  = 8'h55;

    localparam logic [7:0] OP_VCMP_LT  = 8'h61;

    localparam logic [7:0] OP_SPLIT    = 8'h72;


    logic clk;
    logic rst_n;

    logic instruction_valid;

    logic [7:0] opcode;
    logic [3:0] flags;

    logic [5:0] dst_index;
    logic [5:0] src0_index;
    logic [5:0] src1_index;
    logic [5:0] src2_index;

    logic [3:0] pred_index;


    logic tracked_instruction;

    logic vector_src0_enable;
    logic [5:0] vector_src0;

    logic vector_src1_enable;
    logic [5:0] vector_src1;

    logic vector_src2_enable;
    logic [5:0] vector_src2;

    logic vector_dst_enable;
    logic [5:0] vector_dst;

    logic predicate_src_enable;
    logic [3:0] predicate_src;

    logic predicate_dst_enable;
    logic [3:0] predicate_dst;


    logic reserve_valid;
    logic reserve_vector_dst_enable;
    logic [5:0] reserve_vector_dst;

    logic reserve_predicate_dst_enable;
    logic [3:0] reserve_predicate_dst;

    logic release_valid;
    logic release_vector_dst_enable;
    logic [5:0] release_vector_dst;

    logic release_predicate_dst_enable;
    logic [3:0] release_predicate_dst;


    logic vector_raw_hazard;
    logic vector_waw_hazard;

    logic predicate_raw_hazard;
    logic predicate_waw_hazard;

    logic any_hazard;
    logic issue_allowed;

    logic [63:0] vector_busy;
    logic [15:0] predicate_busy;


    a0_dependency_classifier classifier (
        .instruction_valid(
            instruction_valid
        ),

        .opcode(opcode),
        .flags(flags),

        .dst_index(dst_index),
        .src0_index(src0_index),
        .src1_index(src1_index),
        .src2_index(src2_index),

        .pred_index(pred_index),

        .tracked_instruction(
            tracked_instruction
        ),

        .vector_src0_enable(
            vector_src0_enable
        ),
        .vector_src0(
            vector_src0
        ),

        .vector_src1_enable(
            vector_src1_enable
        ),
        .vector_src1(
            vector_src1
        ),

        .vector_src2_enable(
            vector_src2_enable
        ),
        .vector_src2(
            vector_src2
        ),

        .vector_dst_enable(
            vector_dst_enable
        ),
        .vector_dst(
            vector_dst
        ),

        .predicate_src_enable(
            predicate_src_enable
        ),
        .predicate_src(
            predicate_src
        ),

        .predicate_dst_enable(
            predicate_dst_enable
        ),
        .predicate_dst(
            predicate_dst
        )
    );


    a0_scoreboard #(
        .VECTOR_REG_COUNT(64),
        .PREDICATE_REG_COUNT(16)
    ) scoreboard (
        .clk(clk),
        .rst_n(rst_n),

        .query_valid(
            tracked_instruction
        ),

        .query_vector_src0_enable(
            vector_src0_enable
        ),
        .query_vector_src0(
            vector_src0
        ),

        .query_vector_src1_enable(
            vector_src1_enable
        ),
        .query_vector_src1(
            vector_src1
        ),

        .query_vector_src2_enable(
            vector_src2_enable
        ),
        .query_vector_src2(
            vector_src2
        ),

        .query_vector_dst_enable(
            vector_dst_enable
        ),
        .query_vector_dst(
            vector_dst
        ),

        .query_predicate_src_enable(
            predicate_src_enable
        ),
        .query_predicate_src(
            predicate_src
        ),

        .query_predicate_dst_enable(
            predicate_dst_enable
        ),
        .query_predicate_dst(
            predicate_dst
        ),

        .reserve_valid(
            reserve_valid
        ),

        .reserve_vector_dst_enable(
            reserve_vector_dst_enable
        ),
        .reserve_vector_dst(
            reserve_vector_dst
        ),

        .reserve_predicate_dst_enable(
            reserve_predicate_dst_enable
        ),
        .reserve_predicate_dst(
            reserve_predicate_dst
        ),

        .release_valid(
            release_valid
        ),

        .release_vector_dst_enable(
            release_vector_dst_enable
        ),
        .release_vector_dst(
            release_vector_dst
        ),

        .release_predicate_dst_enable(
            release_predicate_dst_enable
        ),
        .release_predicate_dst(
            release_predicate_dst
        ),

        .vector_raw_hazard(
            vector_raw_hazard
        ),

        .vector_waw_hazard(
            vector_waw_hazard
        ),

        .predicate_raw_hazard(
            predicate_raw_hazard
        ),

        .predicate_waw_hazard(
            predicate_waw_hazard
        ),

        .any_hazard(
            any_hazard
        ),

        .issue_allowed(
            issue_allowed
        ),

        .vector_busy(
            vector_busy
        ),

        .predicate_busy(
            predicate_busy
        )
    );


    initial begin
        clk = 1'b0;
    end

    always #1 clk = ~clk;


    task automatic clear_state_controls;
        begin

            reserve_valid = 1'b0;

            reserve_vector_dst_enable = 1'b0;
            reserve_vector_dst = '0;

            reserve_predicate_dst_enable = 1'b0;
            reserve_predicate_dst = '0;

            release_valid = 1'b0;

            release_vector_dst_enable = 1'b0;
            release_vector_dst = '0;

            release_predicate_dst_enable = 1'b0;
            release_predicate_dst = '0;
        end
    endtask


    task automatic drive_instruction(
        input logic [7:0] op,
        input logic [3:0] instruction_flags,
        input logic [5:0] dst,
        input logic [5:0] src0,
        input logic [5:0] src1,
        input logic [5:0] src2,
        input logic [3:0] pred
    );
        begin

            @(negedge clk);

            instruction_valid = 1'b1;

            opcode = op;
            flags = instruction_flags;

            dst_index = dst;
            src0_index = src0;
            src1_index = src1;
            src2_index = src2;

            pred_index = pred;

            @(negedge clk);
        end
    endtask


    task automatic reserve_v(
        input logic [5:0] index
    );
        begin

            @(negedge clk);

            reserve_valid = 1'b1;
            reserve_vector_dst_enable = 1'b1;
            reserve_vector_dst = index;

            @(negedge clk);

            reserve_valid = 1'b0;
            reserve_vector_dst_enable = 1'b0;
        end
    endtask


    task automatic release_v(
        input logic [5:0] index
    );
        begin

            @(negedge clk);

            release_valid = 1'b1;
            release_vector_dst_enable = 1'b1;
            release_vector_dst = index;

            @(negedge clk);

            release_valid = 1'b0;
            release_vector_dst_enable = 1'b0;
        end
    endtask


    task automatic reserve_p(
        input logic [3:0] index
    );
        begin

            @(negedge clk);

            reserve_valid = 1'b1;
            reserve_predicate_dst_enable = 1'b1;
            reserve_predicate_dst = index;

            @(negedge clk);

            reserve_valid = 1'b0;
            reserve_predicate_dst_enable = 1'b0;
        end
    endtask


    task automatic release_p(
        input logic [3:0] index
    );
        begin

            @(negedge clk);

            release_valid = 1'b1;
            release_predicate_dst_enable = 1'b1;
            release_predicate_dst = index;

            @(negedge clk);

            release_valid = 1'b0;
            release_predicate_dst_enable = 1'b0;
        end
    endtask


    initial begin

        rst_n = 1'b0;

        instruction_valid = 1'b0;

        opcode = '0;
        flags = '0;

        dst_index = '0;
        src0_index = '0;
        src1_index = '0;
        src2_index = '0;
        pred_index = '0;

        clear_state_controls();


        repeat (3) @(negedge clk);

        rst_n = 1'b1;


        /*
         * Plain VADD:
         * reads V1,V2 and writes V3.
         */
        drive_instruction(
            OP_VADD,
            4'b0000,
            3,
            1,
            2,
            0,
            4
        );

        if (
            !tracked_instruction
            || !vector_src0_enable
            || vector_src0 != 1
            || !vector_src1_enable
            || vector_src1 != 2
            || vector_src2_enable
            || !vector_dst_enable
            || vector_dst != 3
            || predicate_src_enable
            || predicate_dst_enable
        ) begin

            $fatal(
                1,
                "RTL5B plain VADD classification failed"
            );
        end


        /*
         * Predicated VADD additionally reads P4.
         */
        drive_instruction(
            OP_VADD,
            4'b0001,
            3,
            1,
            2,
            0,
            4
        );

        if (
            !predicate_src_enable
            || predicate_src != 4
        ) begin

            $fatal(
                1,
                "RTL5B predicated VADD classification failed"
            );
        end


        /*
         * VCMP reads two vectors and writes P2.
         *
         * flags[0] must NOT turn P2 into a source.
         */
        drive_instruction(
            OP_VCMP_LT,
            4'b0001,
            0,
            7,
            8,
            0,
            2
        );

        if (
            !tracked_instruction
            || !vector_src0_enable
            || vector_src0 != 7
            || !vector_src1_enable
            || vector_src1 != 8
            || vector_dst_enable
            || predicate_src_enable
            || !predicate_dst_enable
            || predicate_dst != 2
        ) begin

            $fatal(
                1,
                "RTL5B VCMP classification failed"
            );
        end


        /*
         * VLOADX:
         * scalar src0 is outside Phase 2.
         * Reads vector src1 and optional predicate.
         * Writes vector dst.
         */
        drive_instruction(
            OP_VLOADX,
            4'b0001,
            12,
            6,
            9,
            0,
            3
        );

        if (
            vector_src0_enable
            || !vector_src1_enable
            || vector_src1 != 9
            || vector_src2_enable
            || !vector_dst_enable
            || vector_dst != 12
            || !predicate_src_enable
            || predicate_src != 3
            || predicate_dst_enable
        ) begin

            $fatal(
                1,
                "RTL5B VLOADX classification failed"
            );
        end


        /*
         * VSTOREX:
         * reads vector offset V9 and data V10.
         */
        drive_instruction(
            OP_VSTOREX,
            4'b0001,
            0,
            6,
            9,
            10,
            3
        );

        if (
            vector_src0_enable
            || !vector_src1_enable
            || vector_src1 != 9
            || !vector_src2_enable
            || vector_src2 != 10
            || vector_dst_enable
            || !predicate_src_enable
            || predicate_src != 3
        ) begin

            $fatal(
                1,
                "RTL5B VSTOREX classification failed"
            );
        end


        /*
         * SPLIT consumes a vector predicate.
         */
        drive_instruction(
            OP_SPLIT,
            4'b0000,
            0,
            0,
            0,
            0,
            5
        );

        if (
            !tracked_instruction
            || vector_src0_enable
            || vector_src1_enable
            || vector_src2_enable
            || vector_dst_enable
            || !predicate_src_enable
            || predicate_src != 5
            || predicate_dst_enable
        ) begin

            $fatal(
                1,
                "RTL5B SPLIT classification failed"
            );
        end


        /*
         * Integrated vector RAW:
         *
         * Reserve V3, then decode:
         * VMUL V4,V3,V5
         */
        reserve_v(3);

        if (vector_busy != (64'b1 << 3)) begin
            $fatal(1, "RTL5B vector busy mask mismatch after reserve: %016x", vector_busy);
        end

        drive_instruction(
            OP_VMUL,
            4'b0000,
            4,
            3,
            5,
            0,
            0
        );

        if (
            !vector_raw_hazard
            || vector_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B classifier scoreboard RAW failed"
            );
        end


        /*
         * Integrated WAW:
         *
         * VXOR V3,V4,V5
         */
        drive_instruction(
            OP_VXOR,
            4'b0000,
            3,
            4,
            5,
            0,
            0
        );

        if (
            vector_raw_hazard
            || !vector_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B classifier scoreboard WAW failed"
            );
        end


        release_v(3);

        if (vector_busy != '0) begin
            $fatal(1, "RTL5B vector busy mask not cleared after release: %016x", vector_busy);
        end


        /*
         * Independent instruction must issue.
         */
        drive_instruction(
            OP_VXOR,
            4'b0000,
            6,
            4,
            5,
            0,
            0
        );

        if (
            any_hazard
            || !issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B classifier false vector hazard"
            );
        end


        /*
         * Predicate producer is busy.
         */
        reserve_p(2);

        if (predicate_busy != (16'b1 << 2)) begin
            $fatal(1, "RTL5B predicate busy mask mismatch after reserve: %04x", predicate_busy);
        end


        /*
         * Predicated ALU reads P2 => predicate RAW.
         */
        drive_instruction(
            OP_VADD,
            4'b0001,
            3,
            1,
            2,
            0,
            2
        );

        if (
            !predicate_raw_hazard
            || predicate_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B classifier predicate RAW failed"
            );
        end


        /*
         * VCMP writes P2 => predicate WAW.
         */
        drive_instruction(
            OP_VCMP_LT,
            4'b0000,
            0,
            1,
            2,
            0,
            2
        );

        if (
            predicate_raw_hazard
            || !predicate_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B classifier predicate WAW failed"
            );
        end


        release_p(2);

        if (predicate_busy != '0) begin
            $fatal(1, "RTL5B predicate busy mask not cleared after release: %04x", predicate_busy);
        end


        /*
         * Unknown/untracked opcode does not enter the
         * scoreboard query and is not issue_allowed by
         * the scoreboard interface.
         */
        drive_instruction(
            8'hEE,
            4'b0000,
            0,
            0,
            0,
            0,
            0
        );

        if (
            tracked_instruction
            || any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B untracked opcode behavior failed"
            );
        end


        $display(
            "RTL5B_CLASSIFIER_TB=PASS"
        );

        $display(
            "ALU_DEPENDENCY_CLASS=PASS"
        );

        $display(
            "PREDICATED_ALU_CLASS=PASS"
        );

        $display(
            "COMPARE_PREDICATE_DEST=PASS"
        );

        $display(
            "VLOADX_DEPENDENCY_CLASS=PASS"
        );

        $display(
            "VSTOREX_DEPENDENCY_CLASS=PASS"
        );

        $display(
            "SPLIT_PREDICATE_SOURCE=PASS"
        );

        $display(
            "CLASSIFIER_SCOREBOARD_RAW=PASS"
        );

        $display(
            "CLASSIFIER_SCOREBOARD_WAW=PASS"
        );

        $display(
            "CLASSIFIER_SCOREBOARD_PRED_RAW=PASS"
        );

        $display(
            "CLASSIFIER_SCOREBOARD_PRED_WAW=PASS"
        );

        $display(
            "UNTRACKED_OPCODE_BLOCKED=PASS"
        );

        $finish;
    end

endmodule
