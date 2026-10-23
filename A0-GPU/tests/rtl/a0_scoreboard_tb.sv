`timescale 1ns/1ps

module a0_scoreboard_tb;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer PREDICATE_REG_COUNT = 16;

    logic clk;
    logic rst_n;

    logic query_valid;

    logic query_vector_src0_enable;
    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_src0;

    logic query_vector_src1_enable;
    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_src1;

    logic query_vector_src2_enable;
    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_src2;

    logic query_vector_dst_enable;
    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        query_vector_dst;

    logic query_predicate_src_enable;
    logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        query_predicate_src;

    logic query_predicate_dst_enable;
    logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        query_predicate_dst;

    logic reserve_valid;

    logic reserve_vector_dst_enable;
    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        reserve_vector_dst;

    logic reserve_predicate_dst_enable;
    logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        reserve_predicate_dst;

    logic release_valid;

    logic release_vector_dst_enable;
    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        release_vector_dst;

    logic release_predicate_dst_enable;
    logic [$clog2(PREDICATE_REG_COUNT)-1:0]
        release_predicate_dst;

    logic vector_raw_hazard;
    logic vector_waw_hazard;

    logic predicate_raw_hazard;
    logic predicate_waw_hazard;

    logic any_hazard;
    logic issue_allowed;

    logic [VECTOR_REG_COUNT-1:0]
        vector_busy;

    logic [PREDICATE_REG_COUNT-1:0]
        predicate_busy;


    a0_scoreboard #(
        .VECTOR_REG_COUNT(
            VECTOR_REG_COUNT
        ),
        .PREDICATE_REG_COUNT(
            PREDICATE_REG_COUNT
        )
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .query_valid(query_valid),

        .query_vector_src0_enable(
            query_vector_src0_enable
        ),
        .query_vector_src0(
            query_vector_src0
        ),

        .query_vector_src1_enable(
            query_vector_src1_enable
        ),
        .query_vector_src1(
            query_vector_src1
        ),

        .query_vector_src2_enable(
            query_vector_src2_enable
        ),
        .query_vector_src2(
            query_vector_src2
        ),

        .query_vector_dst_enable(
            query_vector_dst_enable
        ),
        .query_vector_dst(
            query_vector_dst
        ),

        .query_predicate_src_enable(
            query_predicate_src_enable
        ),
        .query_predicate_src(
            query_predicate_src
        ),

        .query_predicate_dst_enable(
            query_predicate_dst_enable
        ),
        .query_predicate_dst(
            query_predicate_dst
        ),

        .reserve_valid(reserve_valid),

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

        .release_valid(release_valid),

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

        .any_hazard(any_hazard),
        .issue_allowed(issue_allowed),

        .vector_busy(vector_busy),
        .predicate_busy(predicate_busy)
    );


    initial begin
        clk = 1'b0;
    end

    always #1 clk = ~clk;


    task automatic clear_query;
        begin

            query_valid = 1'b0;

            query_vector_src0_enable = 1'b0;
            query_vector_src0 = '0;

            query_vector_src1_enable = 1'b0;
            query_vector_src1 = '0;

            query_vector_src2_enable = 1'b0;
            query_vector_src2 = '0;

            query_vector_dst_enable = 1'b0;
            query_vector_dst = '0;

            query_predicate_src_enable = 1'b0;
            query_predicate_src = '0;

            query_predicate_dst_enable = 1'b0;
            query_predicate_dst = '0;
        end
    endtask


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


    task automatic reserve_vector(
        input integer register_index
    );
        begin
            if ((register_index < 0) || (register_index >= VECTOR_REG_COUNT)) begin
                $fatal(1, "reserve_vector register_index out of range: %0d", register_index);
            end

            @(negedge clk);

            reserve_valid = 1'b1;
            reserve_vector_dst_enable = 1'b1;
            reserve_vector_dst = register_index[$clog2(VECTOR_REG_COUNT)-1:0];

            @(negedge clk);

            reserve_valid = 1'b0;
            reserve_vector_dst_enable = 1'b0;
        end
    endtask


    task automatic release_vector(
        input integer register_index
    );
        begin
            if ((register_index < 0) || (register_index >= VECTOR_REG_COUNT)) begin
                $fatal(1, "release_vector register_index out of range: %0d", register_index);
            end

            @(negedge clk);

            release_valid = 1'b1;
            release_vector_dst_enable = 1'b1;
            release_vector_dst = register_index[$clog2(VECTOR_REG_COUNT)-1:0];

            @(negedge clk);

            release_valid = 1'b0;
            release_vector_dst_enable = 1'b0;
        end
    endtask


    task automatic reserve_predicate(
        input integer predicate_index
    );
        begin
            if ((predicate_index < 0) || (predicate_index >= PREDICATE_REG_COUNT)) begin
                $fatal(1, "reserve_predicate predicate_index out of range: %0d", predicate_index);
            end

            @(negedge clk);

            reserve_valid = 1'b1;
            reserve_predicate_dst_enable = 1'b1;
            reserve_predicate_dst = predicate_index[$clog2(PREDICATE_REG_COUNT)-1:0];

            @(negedge clk);

            reserve_valid = 1'b0;
            reserve_predicate_dst_enable = 1'b0;
        end
    endtask


    task automatic release_predicate(
        input integer predicate_index
    );
        begin
            if ((predicate_index < 0) || (predicate_index >= PREDICATE_REG_COUNT)) begin
                $fatal(1, "release_predicate predicate_index out of range: %0d", predicate_index);
            end

            @(negedge clk);

            release_valid = 1'b1;
            release_predicate_dst_enable = 1'b1;
            release_predicate_dst = predicate_index[$clog2(PREDICATE_REG_COUNT)-1:0];

            @(negedge clk);

            release_valid = 1'b0;
            release_predicate_dst_enable = 1'b0;
        end
    endtask


    initial begin

        rst_n = 1'b0;

        clear_query();
        clear_state_controls();


        repeat (3) @(negedge clk);

        rst_n = 1'b1;

        @(negedge clk);


        if (
            vector_busy != '0
            || predicate_busy != '0
        ) begin

            $fatal(
                1,
                "RTL5B reset did not clear scoreboard"
            );
        end


        /*
         * Reserve V3 as an in-flight destination.
         */
        reserve_vector(3);

        if (!vector_busy[3]) begin

            $fatal(
                1,
                "RTL5B V3 reservation missing"
            );
        end


        /*
         * RAW:
         *
         * VMUL V4, V3, V5
         *
         * V3 is busy, therefore issue must be blocked.
         */
        @(negedge clk);

        clear_query();

        query_valid = 1'b1;

        query_vector_src0_enable = 1'b1;
        query_vector_src0 = 3;

        query_vector_src1_enable = 1'b1;
        query_vector_src1 = 5;

        query_vector_dst_enable = 1'b1;
        query_vector_dst = 4;

        @(negedge clk);

        if (
            !vector_raw_hazard
            || vector_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B vector RAW classification failed"
            );
        end


        /*
         * WAW:
         *
         * VXOR V3, V4, V5
         *
         * Destination V3 is already busy.
         */
        clear_query();

        query_valid = 1'b1;

        query_vector_src0_enable = 1'b1;
        query_vector_src0 = 4;

        query_vector_src1_enable = 1'b1;
        query_vector_src1 = 5;

        query_vector_dst_enable = 1'b1;
        query_vector_dst = 3;

        @(negedge clk);

        if (
            vector_raw_hazard
            || !vector_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B vector WAW classification failed"
            );
        end


        /*
         * Independent vector instruction.
         *
         * V6 = V4 xor V5 has no dependency on busy V3.
         */
        clear_query();

        query_valid = 1'b1;

        query_vector_src0_enable = 1'b1;
        query_vector_src0 = 4;

        query_vector_src1_enable = 1'b1;
        query_vector_src1 = 5;

        query_vector_dst_enable = 1'b1;
        query_vector_dst = 6;

        @(negedge clk);

        if (
            vector_raw_hazard
            || vector_waw_hazard
            || predicate_raw_hazard
            || predicate_waw_hazard
            || any_hazard
            || !issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B false vector hazard"
            );
        end


        /*
         * src2 must participate in RAW checking.
         */
        clear_query();

        query_valid = 1'b1;

        query_vector_src2_enable = 1'b1;
        query_vector_src2 = 3;

        @(negedge clk);

        if (
            !vector_raw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B src2 RAW classification failed"
            );
        end


        /*
         * Release V3 and ensure the dependency disappears.
         */
        clear_query();

        release_vector(3);

        if (vector_busy[3]) begin

            $fatal(
                1,
                "RTL5B V3 release failed"
            );
        end


        clear_query();

        query_valid = 1'b1;

        query_vector_src0_enable = 1'b1;
        query_vector_src0 = 3;

        query_vector_dst_enable = 1'b1;
        query_vector_dst = 4;

        @(negedge clk);

        if (
            any_hazard
            || !issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B released V3 still hazards"
            );
        end


        /*
         * Predicate RAW/WAW.
         */
        clear_query();

        reserve_predicate(2);

        if (!predicate_busy[2]) begin

            $fatal(
                1,
                "RTL5B P2 reservation missing"
            );
        end


        clear_query();

        query_valid = 1'b1;
        query_predicate_src_enable = 1'b1;
        query_predicate_src = 2;

        @(negedge clk);

        if (
            !predicate_raw_hazard
            || predicate_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B predicate RAW classification failed"
            );
        end


        clear_query();

        query_valid = 1'b1;
        query_predicate_dst_enable = 1'b1;
        query_predicate_dst = 2;

        @(negedge clk);

        if (
            predicate_raw_hazard
            || !predicate_waw_hazard
            || !any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B predicate WAW classification failed"
            );
        end


        clear_query();

        release_predicate(2);

        if (predicate_busy[2]) begin

            $fatal(
                1,
                "RTL5B P2 release failed"
            );
        end


        /*
         * Simultaneous release + reserve on the same vector
         * destination leaves the new owner busy.
         */
        reserve_vector(7);

        @(negedge clk);

        release_valid = 1'b1;
        release_vector_dst_enable = 1'b1;
        release_vector_dst = 7;

        reserve_valid = 1'b1;
        reserve_vector_dst_enable = 1'b1;
        reserve_vector_dst = 7;

        @(negedge clk);

        clear_state_controls();

        if (!vector_busy[7]) begin

            $fatal(
                1,
                "RTL5B release+reserve ownership failed"
            );
        end


        release_vector(7);

        if (vector_busy[7]) begin

            $fatal(
                1,
                "RTL5B final V7 release failed"
            );
        end


        /*
         * Invalid query is not an issuable instruction.
         */
        clear_query();

        @(negedge clk);

        if (
            any_hazard
            || issue_allowed
        ) begin

            $fatal(
                1,
                "RTL5B invalid-query behavior failed"
            );
        end


        $display(
            "RTL5B_SCOREBOARD_TB=PASS"
        );

        $display(
            "VECTOR_RAW_HAZARD=PASS"
        );

        $display(
            "VECTOR_WAW_HAZARD=PASS"
        );

        $display(
            "VECTOR_SRC2_RAW_HAZARD=PASS"
        );

        $display(
            "VECTOR_NO_FALSE_HAZARD=PASS"
        );

        $display(
            "PREDICATE_RAW_HAZARD=PASS"
        );

        $display(
            "PREDICATE_WAW_HAZARD=PASS"
        );

        $display(
            "RESERVATION_RELEASE=PASS"
        );

        $display(
            "RELEASE_RESERVE_SAME_CYCLE=PASS"
        );

        $display(
            "INVALID_QUERY_BLOCKED=PASS"
        );

        $finish;
    end

endmodule
