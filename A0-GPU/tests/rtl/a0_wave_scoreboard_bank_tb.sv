`timescale 1ns/1ps

module a0_wave_scoreboard_bank_tb;

    localparam integer RESIDENT_WAVES = 2;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer PREDICATE_REG_COUNT = 4;
    localparam integer WAVE_ID_W = 1;

    logic clk;
    logic rst_n;

    logic query_valid;
    logic [WAVE_ID_W-1:0] query_wave;
    logic query_vector_src0_enable;
    logic [2:0] query_vector_src0;
    logic query_vector_src1_enable;
    logic [2:0] query_vector_src1;
    logic query_vector_src2_enable;
    logic [2:0] query_vector_src2;
    logic query_vector_dst_enable;
    logic [2:0] query_vector_dst;
    logic query_predicate_src_enable;
    logic [1:0] query_predicate_src;
    logic query_predicate_dst_enable;
    logic [1:0] query_predicate_dst;

    logic reserve_valid;
    logic [WAVE_ID_W-1:0] reserve_wave;
    logic reserve_vector_dst_enable;
    logic [2:0] reserve_vector_dst;
    logic reserve_predicate_dst_enable;
    logic [1:0] reserve_predicate_dst;

    logic release_valid;
    logic [WAVE_ID_W-1:0] release_wave;
    logic release_vector_dst_enable;
    logic [2:0] release_vector_dst;
    logic release_predicate_dst_enable;
    logic [1:0] release_predicate_dst;

    logic clear_valid;
    logic [WAVE_ID_W-1:0] clear_wave;

    logic vector_raw_hazard;
    logic vector_waw_hazard;
    logic predicate_raw_hazard;
    logic predicate_waw_hazard;
    logic any_hazard;
    logic issue_allowed;

    logic [VECTOR_REG_COUNT-1:0]
        vector_busy_by_wave [0:RESIDENT_WAVES-1];
    logic [PREDICATE_REG_COUNT-1:0]
        predicate_busy_by_wave [0:RESIDENT_WAVES-1];


    a0_wave_scoreboard_bank #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .query_valid(query_valid),
        .query_wave(query_wave),
        .query_vector_src0_enable(query_vector_src0_enable),
        .query_vector_src0(query_vector_src0),
        .query_vector_src1_enable(query_vector_src1_enable),
        .query_vector_src1(query_vector_src1),
        .query_vector_src2_enable(query_vector_src2_enable),
        .query_vector_src2(query_vector_src2),
        .query_vector_dst_enable(query_vector_dst_enable),
        .query_vector_dst(query_vector_dst),
        .query_predicate_src_enable(query_predicate_src_enable),
        .query_predicate_src(query_predicate_src),
        .query_predicate_dst_enable(query_predicate_dst_enable),
        .query_predicate_dst(query_predicate_dst),
        .reserve_valid(reserve_valid),
        .reserve_wave(reserve_wave),
        .reserve_vector_dst_enable(reserve_vector_dst_enable),
        .reserve_vector_dst(reserve_vector_dst),
        .reserve_predicate_dst_enable(reserve_predicate_dst_enable),
        .reserve_predicate_dst(reserve_predicate_dst),
        .release_valid(release_valid),
        .release_wave(release_wave),
        .release_vector_dst_enable(release_vector_dst_enable),
        .release_vector_dst(release_vector_dst),
        .release_predicate_dst_enable(release_predicate_dst_enable),
        .release_predicate_dst(release_predicate_dst),
        .clear_valid(clear_valid),
        .clear_wave(clear_wave),
        .vector_raw_hazard(vector_raw_hazard),
        .vector_waw_hazard(vector_waw_hazard),
        .predicate_raw_hazard(predicate_raw_hazard),
        .predicate_waw_hazard(predicate_waw_hazard),
        .any_hazard(any_hazard),
        .issue_allowed(issue_allowed),
        .vector_busy_by_wave(vector_busy_by_wave),
        .predicate_busy_by_wave(predicate_busy_by_wave)
    );


    always #5 clk = ~clk;


    task automatic clear_events;
        begin
            query_valid = 1'b0;
            query_vector_src0_enable = 1'b0;
            query_vector_src1_enable = 1'b0;
            query_vector_src2_enable = 1'b0;
            query_vector_dst_enable = 1'b0;
            query_predicate_src_enable = 1'b0;
            query_predicate_dst_enable = 1'b0;
            reserve_valid = 1'b0;
            reserve_vector_dst_enable = 1'b0;
            reserve_predicate_dst_enable = 1'b0;
            release_valid = 1'b0;
            release_vector_dst_enable = 1'b0;
            release_predicate_dst_enable = 1'b0;
            clear_valid = 1'b0;
        end
    endtask


    task automatic reserve_vector(
        input logic wave,
        input logic [2:0] reg_id
    );
        begin
            @(negedge clk);
            clear_events();
            reserve_valid = 1'b1;
            reserve_wave = wave;
            reserve_vector_dst_enable = 1'b1;
            reserve_vector_dst = reg_id;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_events();
        end
    endtask


    task automatic reserve_predicate(
        input logic wave,
        input logic [1:0] reg_id
    );
        begin
            @(negedge clk);
            clear_events();
            reserve_valid = 1'b1;
            reserve_wave = wave;
            reserve_predicate_dst_enable = 1'b1;
            reserve_predicate_dst = reg_id;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_events();
        end
    endtask


    task automatic release_vector(
        input logic wave,
        input logic [2:0] reg_id
    );
        begin
            @(negedge clk);
            clear_events();
            release_valid = 1'b1;
            release_wave = wave;
            release_vector_dst_enable = 1'b1;
            release_vector_dst = reg_id;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_events();
        end
    endtask


    task automatic release_predicate(
        input logic wave,
        input logic [1:0] reg_id
    );
        begin
            @(negedge clk);
            clear_events();
            release_valid = 1'b1;
            release_wave = wave;
            release_predicate_dst_enable = 1'b1;
            release_predicate_dst = reg_id;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_events();
        end
    endtask


    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        query_wave = '0;
        query_vector_src0 = '0;
        query_vector_src1 = '0;
        query_vector_src2 = '0;
        query_vector_dst = '0;
        query_predicate_src = '0;
        query_predicate_dst = '0;
        reserve_wave = '0;
        reserve_vector_dst = '0;
        reserve_predicate_dst = '0;
        release_wave = '0;
        release_vector_dst = '0;
        release_predicate_dst = '0;
        clear_wave = '0;
        clear_events();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (
            vector_busy_by_wave[0] != '0
            || vector_busy_by_wave[1] != '0
            || predicate_busy_by_wave[0] != '0
            || predicate_busy_by_wave[1] != '0
        ) begin
            $fatal(1, "scoreboard bank reset mismatch");
        end

        $display("RTL7B_SCOREBOARD_RESET=PASS");

        reserve_vector(1'd0, 3'd3);

        if (
            !vector_busy_by_wave[0][3]
            || vector_busy_by_wave[1][3]
        ) begin
            $fatal(1, "wave0 vector reservation leaked to wave1");
        end

        query_valid = 1'b1;
        query_wave = 1'd0;
        query_vector_src0_enable = 1'b1;
        query_vector_src0 = 3'd3;
        #1;
        if (!vector_raw_hazard || issue_allowed) begin
            $fatal(1, "wave0 did not observe own V3 RAW hazard");
        end

        query_wave = 1'd1;
        #1;
        if (vector_raw_hazard || any_hazard || !issue_allowed) begin
            $fatal(1, "wave1 incorrectly observed wave0 V3 hazard");
        end

        query_wave = 1'd0;
        query_vector_src0_enable = 1'b0;
        query_vector_dst_enable = 1'b1;
        query_vector_dst = 3'd3;
        #1;
        if (!vector_waw_hazard || !any_hazard || issue_allowed) begin
            $fatal(1, "wave0 did not observe own V3 WAW hazard");
        end
        query_wave = 1'd1;
        #1;
        if (vector_waw_hazard || any_hazard || !issue_allowed) begin
            $fatal(1, "wave1 incorrectly observed wave0 V3 WAW hazard");
        end

        clear_events();
        $display("RTL7B_SCOREBOARD_VECTOR_ISOLATION=PASS");

        reserve_vector(1'd1, 3'd3);
        release_vector(1'd0, 3'd3);

        if (
            vector_busy_by_wave[0][3]
            || !vector_busy_by_wave[1][3]
        ) begin
            $fatal(1, "wave0 release corrupted wave1 V3 reservation");
        end

        $display("RTL7B_SCOREBOARD_RELEASE_ISOLATION=PASS");

        reserve_predicate(1'd0, 2'd1);

        query_valid = 1'b1;
        query_wave = 1'd0;
        query_predicate_src_enable = 1'b1;
        query_predicate_src = 2'd1;
        #1;
        if (!predicate_raw_hazard || issue_allowed) begin
            $fatal(1, "wave0 did not observe own P1 RAW hazard");
        end

        query_wave = 1'd1;
        #1;
        if (predicate_raw_hazard || any_hazard || !issue_allowed) begin
            $fatal(1, "wave1 incorrectly observed wave0 P1 hazard");
        end

        query_wave = 1'd0;
        query_predicate_src_enable = 1'b0;
        query_predicate_dst_enable = 1'b1;
        query_predicate_dst = 2'd1;
        #1;
        if (!predicate_waw_hazard || !any_hazard || issue_allowed) begin
            $fatal(1, "wave0 did not observe own P1 WAW hazard");
        end
        query_wave = 1'd1;
        #1;
        if (predicate_waw_hazard || any_hazard || !issue_allowed) begin
            $fatal(1, "wave1 incorrectly observed wave0 P1 WAW hazard");
        end

        clear_events();
        reserve_predicate(1'd1, 2'd1);
        release_predicate(1'd0, 2'd1);

        if (
            predicate_busy_by_wave[0][1]
            || !predicate_busy_by_wave[1][1]
        ) begin
            $fatal(1, "wave0 P1 release corrupted wave1 reservation");
        end

        $display("RTL7B_SCOREBOARD_PREDICATE_ISOLATION=PASS");

        /* Context teardown clears only the selected wave scoreboard. */
        @(negedge clk);
        clear_events();
        clear_valid = 1'b1;
        clear_wave = 1'd0;
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_events();

        if (
            vector_busy_by_wave[0] != '0
            || predicate_busy_by_wave[0] != '0
            || !vector_busy_by_wave[1][3]
            || !predicate_busy_by_wave[1][1]
        ) begin
            $fatal(1, "context clear leaked across wave scoreboards");
        end

        $display("RTL7B_SCOREBOARD_CONTEXT_CLEAR=PASS");

        release_vector(1'd1, 3'd3);
        release_predicate(1'd1, 2'd1);

        if (
            vector_busy_by_wave[0] != '0
            || vector_busy_by_wave[1] != '0
            || predicate_busy_by_wave[0] != '0
            || predicate_busy_by_wave[1] != '0
        ) begin
            $fatal(1, "scoreboard bank did not drain");
        end

        $display("RTL7B_WAVE_SCOREBOARD_BANK_TB=PASS");
        $finish;
    end

endmodule
