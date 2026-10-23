`timescale 1ns/1ps

module a0_operand_collector_tb;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer BANK_COUNT = 4;
    localparam integer DATA_W = PHYSICAL_LANES * 32;

    logic clk;
    logic rst_n;

    logic req_valid;
    logic req_ready;
    logic req_src0_enable;
    logic req_src1_enable;
    logic req_src2_enable;
    logic [5:0] req_src0;
    logic [5:0] req_src1;
    logic [5:0] req_src2;
    logic [1:0] req_beat;

    logic result_valid;
    logic result_ready;
    logic [DATA_W-1:0] result_src0_data;
    logic [DATA_W-1:0] result_src1_data;
    logic [DATA_W-1:0] result_src2_data;
    logic collector_busy;
    logic bank_conflict_cycle;

    logic [2:0] rf_read_valid;
    logic [5:0] rf_read_reg [0:2];
    logic [1:0] rf_read_beat [0:2];
    logic [2:0] rf_read_ready;
    logic [2:0] rf_read_bank_conflict;
    logic [2:0] rf_read_resp_valid;
    logic [DATA_W-1:0] rf_read_resp_data [0:2];

    logic write_valid;
    logic [5:0] write_reg;
    logic [1:0] write_beat;
    logic [PHYSICAL_LANES-1:0] write_lane_mask;
    logic [DATA_W-1:0] write_data;
    logic write_ready;


    a0_operand_collector #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES)
    ) collector (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_src0_enable(req_src0_enable),
        .req_src1_enable(req_src1_enable),
        .req_src2_enable(req_src2_enable),
        .req_src0(req_src0),
        .req_src1(req_src1),
        .req_src2(req_src2),
        .req_beat(req_beat),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_src0_data(result_src0_data),
        .result_src1_data(result_src1_data),
        .result_src2_data(result_src2_data),
        .busy(collector_busy),
        .bank_conflict_cycle(bank_conflict_cycle),
        .rf_read_valid(rf_read_valid),
        .rf_read_reg(rf_read_reg),
        .rf_read_beat(rf_read_beat),
        .rf_read_ready(rf_read_ready),
        .rf_read_bank_conflict(rf_read_bank_conflict),
        .rf_read_resp_valid(rf_read_resp_valid),
        .rf_read_resp_data(rf_read_resp_data)
    );


    a0_regfile_banked #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(BANK_COUNT),
        .READ_PORTS(3)
    ) regfile (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid(rf_read_valid),
        .read_reg(rf_read_reg),
        .read_beat(rf_read_beat),
        .read_ready(rf_read_ready),
        .read_bank_conflict(rf_read_bank_conflict),
        .read_resp_valid(rf_read_resp_valid),
        .read_resp_data(rf_read_resp_data),
        .write_valid(write_valid),
        .write_reg(write_reg),
        .write_beat(write_beat),
        .write_lane_mask(write_lane_mask),
        .write_data(write_data),
        .write_ready(write_ready)
    );


    always #5 clk = ~clk;


    function automatic logic [DATA_W-1:0] make_beat(
        input logic [31:0] base
    );
        integer l;
        begin
            make_beat = '0;
            for (l = 0; l < PHYSICAL_LANES; l = l + 1) begin
                make_beat[l*32 +: 32] = base + l;
            end
        end
    endfunction


    task automatic clear_request;
        begin
            req_valid = 1'b0;
            req_src0_enable = 1'b0;
            req_src1_enable = 1'b0;
            req_src2_enable = 1'b0;
            req_src0 = '0;
            req_src1 = '0;
            req_src2 = '0;
            req_beat = '0;
        end
    endtask


    task automatic clear_write;
        begin
            write_valid = 1'b0;
            write_reg = '0;
            write_beat = '0;
            write_lane_mask = '0;
            write_data = '0;
        end
    endtask


    task automatic write_one(
        input logic [5:0] reg_index,
        input logic [1:0] beat_index,
        input logic [DATA_W-1:0] value
    );
        begin
            @(negedge clk);
            write_valid = 1'b1;
            write_reg = reg_index;
            write_beat = beat_index;
            write_lane_mask = '1;
            write_data = value;
            #1;
            if (!write_ready) begin
                $fatal(1, "collector TB init write rejected");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_write();
        end
    endtask


    task automatic send_request(
        input logic en0,
        input logic en1,
        input logic en2,
        input logic [5:0] src0,
        input logic [5:0] src1,
        input logic [5:0] src2,
        input logic [1:0] beat
    );
        logic accepted;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_src0_enable = en0;
            req_src1_enable = en1;
            req_src2_enable = en2;
            req_src0 = src0;
            req_src1 = src1;
            req_src2 = src2;
            req_beat = beat;

            accepted = 1'b0;
            while (!accepted) begin
                #1;
                accepted = req_ready;
                @(posedge clk);
                #1;
                if (!accepted) begin
                    @(negedge clk);
                end
            end

            @(negedge clk);
            clear_request();
        end
    endtask


    task automatic wait_result_expect(
        input logic [DATA_W-1:0] expected0,
        input logic [DATA_W-1:0] expected1,
        input logic [DATA_W-1:0] expected2,
        output logic saw_conflict
    );
        integer guard;
        begin
            result_ready = 1'b1;
            saw_conflict = 1'b0;
            guard = 0;

            while (!result_valid) begin
                @(negedge clk);
                #1;
                if (bank_conflict_cycle) begin
                    saw_conflict = 1'b1;
                end
                guard = guard + 1;
                if (guard > 32) begin
                    $fatal(1, "collector timeout waiting for result");
                end
            end

            if (result_src0_data !== expected0) begin
                $fatal(1, "collector src0 mismatch");
            end
            if (result_src1_data !== expected1) begin
                $fatal(1, "collector src1 mismatch");
            end
            if (result_src2_data !== expected2) begin
                $fatal(1, "collector src2 mismatch");
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            result_ready = 1'b0;
        end
    endtask


    initial begin
        logic [DATA_W-1:0] a;
        logic [DATA_W-1:0] b;
        logic [DATA_W-1:0] c;
        logic [DATA_W-1:0] d;
        logic [DATA_W-1:0] held0;
        logic [DATA_W-1:0] held1;
        logic [DATA_W-1:0] held2;
        logic saw_conflict;
        integer hold_cycle;
        integer guard;

        clk = 1'b0;
        rst_n = 1'b0;
        result_ready = 1'b0;
        clear_request();
        clear_write();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (collector_busy || result_valid || !req_ready) begin
            $fatal(1, "collector reset state invalid");
        end
        $display("RTL6_COLLECTOR_RESET=PASS");

        a = make_beat(32'h1100_0000);
        b = make_beat(32'h1200_0000);
        c = make_beat(32'h1300_0000);
        d = make_beat(32'h1400_0000);

        write_one(6'd1, 2'd0, a);
        write_one(6'd2, 2'd0, b);
        write_one(6'd3, 2'd0, c);

        send_request(1'b1, 1'b1, 1'b1, 6'd1, 6'd2, 6'd3, 2'd0);
        wait_result_expect(a, b, c, saw_conflict);
        if (saw_conflict) begin
            $fatal(1, "different-bank collector request reported conflict");
        end
        $display("RTL6_COLLECTOR_3SRC_NO_CONFLICT=PASS");

        write_one(6'd0, 2'd0, a);
        write_one(6'd4, 2'd0, b);
        write_one(6'd8, 2'd0, c);

        send_request(1'b1, 1'b1, 1'b1, 6'd0, 6'd4, 6'd8, 2'd0);
        wait_result_expect(a, b, c, saw_conflict);
        if (!saw_conflict) begin
            $fatal(1, "same-bank collector request never exposed conflict");
        end
        $display("RTL6_COLLECTOR_SAME_BANK_SERIALIZE=PASS");

        send_request(1'b1, 1'b0, 1'b1, 6'd1, 6'd55, 6'd3, 2'd0);
        wait_result_expect(a, '0, c, saw_conflict);
        $display("RTL6_COLLECTOR_DISABLED_SOURCE_ZERO=PASS");

        write_one(6'd5, 2'd1, d);
        send_request(1'b1, 1'b0, 1'b0, 6'd5, 6'd0, 6'd0, 2'd1);

        result_ready = 1'b0;
        guard = 0;
        while (!result_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 16) begin
                $fatal(1, "collector timeout entering backpressure state");
            end
        end

        held0 = result_src0_data;
        held1 = result_src1_data;
        held2 = result_src2_data;

        for (hold_cycle = 0; hold_cycle < 3; hold_cycle = hold_cycle + 1) begin
            @(posedge clk);
            #1;
            if (!result_valid) begin
                $fatal(1, "collector dropped result under backpressure");
            end
            if (
                result_src0_data !== held0
                || result_src1_data !== held1
                || result_src2_data !== held2
            ) begin
                $fatal(1, "collector result changed under backpressure");
            end
            if (req_ready) begin
                $fatal(1, "collector accepted replacement while result blocked");
            end
        end

        @(negedge clk);
        result_ready = 1'b1;
        #1;
        if (result_src0_data !== d) begin
            $fatal(1, "backpressured result payload mismatch");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        result_ready = 1'b0;
        $display("RTL6_COLLECTOR_BACKPRESSURE_STABLE=PASS");

        /*
         * Zero-bubble result-consume / replacement-request handoff.
         */
        send_request(1'b1, 1'b0, 1'b0, 6'd1, 6'd0, 6'd0, 2'd0);
        result_ready = 1'b0;
        guard = 0;
        while (!result_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 16) begin
                $fatal(1, "collector timeout before handoff");
            end
        end

        @(negedge clk);
        req_valid = 1'b1;
        req_src0_enable = 1'b1;
        req_src1_enable = 1'b0;
        req_src2_enable = 1'b0;
        req_src0 = 6'd2;
        req_src1 = '0;
        req_src2 = '0;
        req_beat = 2'd0;
        result_ready = 1'b1;
        #1;
        if (!req_ready) begin
            $fatal(1, "collector zero-bubble replacement was not ready");
        end
        if (!result_valid || result_src0_data !== a) begin
            $fatal(1, "collector old result invalid during handoff");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_request();
        result_ready = 1'b1;

        guard = 0;
        while (!result_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 16) begin
                $fatal(1, "collector timeout after zero-bubble handoff");
            end
        end
        if (result_src0_data !== b) begin
            $fatal(1, "replacement request result mismatch");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        result_ready = 1'b0;
        $display("RTL6_COLLECTOR_ZERO_BUBBLE_HANDOFF=PASS");

        $display("RTL6_OPERAND_COLLECTOR_TB=PASS");
        $finish;
    end

endmodule
