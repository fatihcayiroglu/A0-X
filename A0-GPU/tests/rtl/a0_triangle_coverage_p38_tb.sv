`timescale 1ns/1ps
// P38 stand-alone simulation contract; requires a SystemVerilog tool.
module a0_triangle_coverage_p38_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic tri_valid = 1'b0;
    logic tri_ready;
    logic signed [15:0] x0, y0, x1, y1, x2, y2;
    logic pixel_valid, pixel_ready = 1'b1;
    logic [15:0] pixel_x, pixel_y;
    logic done;

    a0_triangle_coverage_p38 #(.FRAME_WIDTH(8), .FRAME_HEIGHT(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .done(done)
    );

    task automatic run_case(
        input logic signed [15:0] ta_x, ta_y, tb_x, tb_y, tc_x, tc_y,
        input logic [63:0] expected,
        input logic degenerate
    );
        logic [63:0] seen;
        logic pre_valid, pre_ready;
        logic [15:0] pre_x, pre_y;
        logic stalled;
        logic [15:0] stalled_x, stalled_y;
        logic complete;
        int position;
        begin
            seen = '0;
            complete = 1'b0;
            stalled = 1'b0;
            @(negedge clk);
            if (!tri_ready) $fatal(1, "triangle was not ready");
            tri_valid = 1'b1;
            x0 = ta_x; y0 = ta_y;
            x1 = tb_x; y1 = tb_y;
            x2 = tc_x; y2 = tc_y;
            @(posedge clk);
            #1;
            if (degenerate) begin
                if (!done || !tri_ready || pixel_valid) begin
                    $fatal(1, "degenerate triangle did not finish immediately");
                end
                complete = 1'b1;
            end else if (tri_ready) begin
                $fatal(1, "non-degenerate triangle not accepted");
            end
            @(negedge clk);
            tri_valid = 1'b0;
            if (!degenerate) begin
                for (int cycle = 0; cycle < 180; cycle++) begin
                    // Advance-ready stalls exercise output identity stability.
                    pixel_ready = ((cycle % 5) != 0);
                    #1;
                    if (stalled && (!pixel_valid || pixel_x !== stalled_x ||
                                    pixel_y !== stalled_y)) begin
                        $fatal(1, "pixel changed under backpressure");
                    end
                    pre_valid = pixel_valid;
                    pre_ready = pixel_ready;
                    pre_x = pixel_x;
                    pre_y = pixel_y;
                    stalled = pre_valid && !pre_ready;
                    stalled_x = pre_x;
                    stalled_y = pre_y;
                    @(posedge clk);
                    if (pre_valid && pre_ready) begin
                        if (pre_x >= 8 || pre_y >= 8) $fatal(1, "pixel out of frame");
                        position = (int'(pre_y) * 8) + int'(pre_x);
                        if (seen[position]) $fatal(1, "duplicate pixel");
                        if (!expected[position]) $fatal(1, "unexpected pixel");
                        seen[position] = 1'b1;
                    end
                    #1;
                    if (done) begin
                        complete = 1'b1;
                        break;
                    end
                    @(negedge clk);
                end
            end
            if (!complete || seen !== expected || !tri_ready) begin
                $fatal(1, "triangle incomplete/incorrect: seen=%h expected=%h", seen, expected);
            end
        end
    endtask

    initial begin
        x0='0; y0='0; x1='0; y1='0; x2='0; y2='0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        // Known mask: (1,1), (2,1), (3,1), (1,2), (2,2), (1,3).
        run_case(1,1, 5,1, 1,5, 64'h0000_0000_0206_0E00, 1'b0);
        // Identical coverage under opposite input winding.
        run_case(1,1, 1,5, 5,1, 64'h0000_0000_0206_0E00, 1'b0);
        // Triangle enclosing all pixel centers in an 8x8 framebuffer.
        run_case(-10,-10, 30,-10, -10,30, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0);
        // Collinear vertices produce no samples but a completion pulse.
        run_case(1,1, 2,2, 3,3, 64'h0, 1'b1);
        $display("P38_RTL_TRIANGLE_COVERAGE_PASS cases=4");
        $finish;
    end
endmodule
