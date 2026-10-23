`timescale 1ns/1ps
// P41 executable HDL integration gate (not a substitute for FPGA qualification).
module a0_triangle_double_buffer_display_p41_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic clear_valid = 0, clear_ready, clear_done;
    logic [23:0] clear_color = 0;
    logic tri_valid = 0, tri_ready, tri_done;
    logic signed [15:0] x0 = 0, y0 = 0, x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    logic [23:0] tri_color = 0;
    logic render_initialized, render_busy;
    logic swap_valid = 0, swap_ready, swap_pending, swap_done;
    logic display_bank, render_bank, display_initialized;
    logic scan_enable = 0;
    logic pixel_valid, pixel_ready = 0;
    logic [15:0] pixel_x, pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame, end_of_line, end_of_frame, frame_done;

    a0_triangle_double_buffer_display_p41 #(.FRAME_WIDTH(4), .FRAME_HEIGHT(3)) dut (
        .clk(clk), .rst_n(rst_n),
        .clear_valid(clear_valid), .clear_ready(clear_ready),
        .clear_color(clear_color), .clear_done(clear_done),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .tri_color(tri_color), .tri_done(tri_done),
        .render_initialized(render_initialized), .render_busy(render_busy),
        .swap_valid(swap_valid), .swap_ready(swap_ready),
        .swap_pending(swap_pending), .swap_done(swap_done),
        .display_bank(display_bank), .render_bank(render_bank),
        .display_initialized(display_initialized),
        .scan_enable(scan_enable), .pixel_valid(pixel_valid),
        .pixel_ready(pixel_ready), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .pixel_color(pixel_color), .start_of_frame(start_of_frame),
        .end_of_line(end_of_line), .end_of_frame(end_of_frame),
        .frame_done(frame_done)
    );

    task automatic clear_back(input logic [23:0] rgb);
        bit completed;
        begin
            @(negedge clk);
            if (!clear_ready) $fatal(1, "P41 clear not ready");
            clear_valid = 1'b1;
            clear_color = rgb;
            @(negedge clk);
            clear_valid = 1'b0;
            completed = 0;
            for (int t=0; t<25 && !completed; t++) begin
                @(posedge clk); #1;
                if (clear_done) completed=1;
            end
            if (!completed || !render_initialized || render_busy)
                $fatal(1, "P41 failed to initialize hidden framebuffer");
        end
    endtask

    task automatic draw_back;
        bit completed;
        begin
            @(negedge clk);
            if (!tri_ready) $fatal(1,"P41 render not ready");
            x0=0; y0=0; x1=3; y1=0; x2=0; y2=3;
            tri_color=24'hAA5500;
            tri_valid=1'b1;
            @(negedge clk);
            tri_valid=1'b0;
            completed=0;
            for (int t=0; t<35 && !completed; t++) begin
                @(posedge clk); #1;
                if (tri_done) completed=1;
            end
            if (!completed) $fatal(1,"P41 back triangle timeout");
        end
    endtask

    task automatic request_swap;
        begin
            @(negedge clk);
            pixel_ready=0;
            if (!swap_ready) $fatal(1,"P41 swap not ready");
            swap_valid=1;
            @(negedge clk);
            swap_valid=0;
            #1;
            if (!swap_pending) $fatal(1,"P41 swap request lost");
        end
    endtask

    initial begin : main
        int old_beats;
        int new_beats;
        int ticks;
        bit handshake;
        bit finished;
        bit now_swapped;
        logic [58:0] stalled;
        bit was_stalled;
        logic [23:0] expected;
        repeat (3) @(negedge clk);
        rst_n=1;
        if (display_initialized) $fatal(1,"front initialized after reset");

        // First front is uninitialized. Swap a clear back while scan disabled.
        clear_back(24'h112233);
        request_swap();
        @(posedge clk); #1;
        if (!swap_done || display_bank!==1'b1 || !display_initialized)
            $fatal(1,"initial swap failed");

        // While the original front is being read, prepare the other bank.
        // Hold ready low until the second swap is accepted so no beat is lost.
        @(negedge clk); scan_enable=1; pixel_ready=0;
        clear_back(24'h445566);
        draw_back();
        request_swap();
        if (!swap_pending || swap_ready || clear_ready || tri_ready)
            $fatal(1,"pending swap did not freeze back bank");
        old_beats=0;
        new_beats=0;
        ticks=0;
        was_stalled=0;
        now_swapped=0;
        finished=0;
        while (ticks<200 && !finished) begin
            @(negedge clk);
            pixel_ready = ((ticks % 5)!=0) && ((ticks % 11)!=0);
            #1;
            if (was_stalled && !now_swapped) begin
                if (!pixel_valid ||
                    {pixel_x,pixel_y,pixel_color,start_of_frame,end_of_line,end_of_frame} !== stalled)
                    $fatal(1,"P41 stalled stream changed");
            end
            handshake=pixel_valid && pixel_ready;
            if (handshake) begin
                if (!now_swapped) begin
                    if (old_beats>=12 || pixel_color!==24'h112233 ||
                        pixel_x!==16'(old_beats%4) || pixel_y!==16'(old_beats/4) ||
                        start_of_frame !== (old_beats==0) ||
                        end_of_line !== (old_beats%4==3) ||
                        end_of_frame !== (old_beats==11))
                        $fatal(1,"P41 old front tear/corruption at beat %0d",old_beats);
                    old_beats++;
                end else begin
                    expected = (int'(pixel_x)+int'(pixel_y)<2) ? 24'hAA5500 : 24'h445566;
                    if (pixel_color!==expected ||
                        pixel_x!==16'(new_beats%4) || pixel_y!==16'(new_beats/4) ||
                        start_of_frame !== (new_beats==0))
                        $fatal(1,"P41 new front mismatch at beat %0d",new_beats);
                    new_beats++;
                    if (new_beats==12) finished=1;
                end
            end
            was_stalled = pixel_valid && !pixel_ready;
            if (was_stalled)
                stalled={pixel_x,pixel_y,pixel_color,start_of_frame,end_of_line,end_of_frame};
            @(posedge clk); #1;
            if (swap_done) begin
                if (now_swapped || old_beats != 12 || display_bank!==1'b0)
                    $fatal(1,"P41 swap committed before complete old frame");
                now_swapped=1;
                was_stalled=0;
            end
            ticks++;
        end
        if (!finished || !now_swapped || old_beats!=12 || new_beats!=12)
            $fatal(1,"P41 display stream stalled: old=%0d new=%0d",old_beats,new_beats);

        // Another prepared frame may swap during disabled scan immediately.
        @(negedge clk); scan_enable=0; pixel_ready=0;
        clear_back(24'h778899);
        request_swap();
        @(posedge clk); #1;
        if (!swap_done || display_bank!==1'b1)
            $fatal(1,"P41 disabled-scan commit failed");
        @(negedge clk); scan_enable=1;
        @(posedge clk); #1;
        if (!pixel_valid || !start_of_frame || pixel_color!==24'h778899)
            $fatal(1,"P41 new frame was not restarted at origin");

        $display("P41_RTL_DOUBLE_BUFFER_PASS ownership/swap/backpressure/triangle/two-frames");
        $finish;
    end
    initial begin #150000; $fatal(1,"P41 RTL testbench timeout"); end
endmodule
