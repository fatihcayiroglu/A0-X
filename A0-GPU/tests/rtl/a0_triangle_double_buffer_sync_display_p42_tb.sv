`timescale 1ns/1ps
// P42 HDL integration testbench. Must execute on a real HDL simulator
// to count as RTL PASS; parser/lint alone is NOT a behavioral PASS.
module a0_triangle_double_buffer_sync_display_p42_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic clear_valid = 0, clear_ready, clear_done;
    logic [23:0] clear_color = 0;
    logic tri_valid = 0, tri_ready, tri_done;
    logic signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
    logic [23:0] tri_color = 0;
    logic render_initialized, render_busy;
    logic swap_valid = 0, swap_ready, swap_pending, swap_done;
    logic display_bank, render_bank, display_initialized;
    logic scan_enable = 0;
    logic pixel_valid, pixel_ready=0;
    logic [15:0] pixel_x, pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame, end_of_line, end_of_frame, frame_done;

    a0_triangle_double_buffer_sync_display_p42 #(
        .FRAME_WIDTH(4), .FRAME_HEIGHT(3)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .clear_valid(clear_valid), .clear_ready(clear_ready),
        .clear_color(clear_color), .clear_done(clear_done),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
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
        bit finished;
        begin
            @(negedge clk);
            if (!clear_ready) $fatal(1, "P42 clear not ready");
            clear_color=rgb;
            clear_valid=1;
            @(negedge clk);
            clear_valid=0;
            finished=0;
            for (int i=0; i<25 && !finished; i++) begin
                @(negedge clk);
                if (clear_done) finished=1;
            end
            if (!finished || !render_initialized || render_busy)
                $fatal(1, "P42 clear did not complete");
        end
    endtask

    task automatic request_swap;
        begin
            @(negedge clk);
            if (!swap_ready) $fatal(1, "P42 not ready for swap");
            swap_valid=1;
            @(negedge clk);
            swap_valid=0;
            if (!swap_pending) $fatal(1, "P42 lost accepted swap");
        end
    endtask

    initial begin : main
        int old_count, new_count, cycles;
        bit swapped;
        logic [58:0] stalled;
        rst_n=0;
        repeat (3) @(negedge clk);
        rst_n=1;
        if (display_initialized || pixel_valid || swap_ready)
            $fatal(1, "P42 reset should start with undefined frame");

        clear_back(24'h010203);
        request_swap();
        @(negedge clk);
        if (!swap_done || !display_initialized || display_bank != 1)
            $fatal(1, "P42 first front swap failed");
        scan_enable=1;
        pixel_ready=0;
        cycles=0;
        while (!pixel_valid && cycles < 15) begin
            @(negedge clk);
            cycles++;
        end
        if (!pixel_valid || pixel_color != 24'h010203 || pixel_x != 0 || pixel_y != 0)
            $fatal(1, "P42 synchronous first pixel mismatch");
        stalled={pixel_x,pixel_y,pixel_color,start_of_frame,end_of_line,end_of_frame};
        repeat(7) begin
            @(negedge clk);
            if (!pixel_valid ||
                {pixel_x,pixel_y,pixel_color,start_of_frame,end_of_line,end_of_frame} !== stalled)
                $fatal(1, "P42 stalled output changed");
        end

        clear_back(24'hAABBCC);
        request_swap();
        if (!swap_pending) $fatal(1, "P42 pending swap unexpectedly cancelled");
        old_count=0;
        new_count=0;
        swapped=0;
        for (int t=0; t<150 && (new_count==0); t++) begin
            @(negedge clk);
            if (t==0) pixel_ready=1;
            if (swap_done) swapped=1;
            if (pixel_valid && pixel_ready) begin
                if (!swapped) begin
                    if (pixel_color !== 24'h010203 ||
                        pixel_x !== 16'(old_count % 4) ||
                        pixel_y !== 16'(old_count / 4))
                        $fatal(1, "P42 old bank corrupted at pixel %0d",old_count);
                    if ((old_count==11) != (end_of_frame==1'b1))
                        $fatal(1, "P42 old frame EOF incorrect");
                    old_count++;
                end else begin
                    if (pixel_x != 0 || pixel_y != 0 || pixel_color !== 24'hAABBCC ||
                        !start_of_frame)
                        $fatal(1, "P42 new bank did not restart at (0,0)");
                    new_count++;
                end
            end
        end
        if (!swapped || old_count != 12 || new_count != 1)
            $fatal(1, "P42 swap/scanout incomplete old=%0d new=%0d swapped=%0d",
                   old_count,new_count,swapped);
        $display("P42_HDL_PASS: registered read, stalls, front/back isolation, EOF swap");
        $finish;
    end
endmodule
