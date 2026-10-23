`timescale 1ns/1ps
// P40 actual RTL behavioral gate; compile alongside P38/P39/P40 modules.
module a0_triangle_display_p40_tb;
    logic clk;
    initial clk=1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic clear_valid = 0, clear_ready, clear_done;
    logic [23:0] clear_color = '0;
    logic tri_valid = 0, tri_ready, tri_done;
    logic signed [15:0] x0 = 0, y0 = 0, x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    logic [23:0] tri_color = '0;
    logic initialized, busy;
    logic scan_enable = 0;
    logic pixel_valid, pixel_ready = 0;
    logic [15:0] pixel_x, pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame, end_of_line, end_of_frame, frame_done;

    a0_triangle_display_p40 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(3)) dut (
        .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),.clear_ready(clear_ready),
        .clear_color(clear_color),.clear_done(clear_done),
        .tri_valid(tri_valid),.tri_ready(tri_ready),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
        .tri_color(tri_color),.tri_done(tri_done),.initialized(initialized),.busy(busy),
        .scan_enable(scan_enable),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_color(pixel_color),
        .start_of_frame(start_of_frame),.end_of_line(end_of_line),
        .end_of_frame(end_of_frame),.frame_done(frame_done)
    );

    task automatic do_clear(input logic [23:0] color);
        bit complete;
        begin
            @(negedge clk);
            if (!clear_ready) $fatal(1,"clear not ready");
            clear_valid = 1'b1;
            clear_color = color;
            @(negedge clk);
            clear_valid = 1'b0;
            complete = 0;
            for (int t=0; t<20 && !complete; t++) begin
                @(posedge clk); #1;
                if (clear_done) complete=1;
            end
            if (!complete || !initialized) $fatal(1,"clear did not complete");
        end
    endtask

    task automatic do_tri;
        bit complete;
        begin
            @(negedge clk);
            if (!tri_ready) $fatal(1,"tri not ready");
            x0=0; y0=0; x1=3; y1=0; x2=0; y2=3;
            tri_color=24'hE04020;
            tri_valid=1'b1;
            @(negedge clk);
            tri_valid=1'b0;
            complete=0;
            for (int t=0; t<30 && !complete; t++) begin
                @(posedge clk); #1;
                if (tri_done) complete=1;
            end
            if (!complete) $fatal(1,"tri never completed");
        end
    endtask

    initial begin : test
        int accepted;
        int cycles;
        int x, y;
        bit handshake, eof_pre;
        logic [23:0] expected;
        logic [58:0] hold_record;
        bit hold_valid;
        repeat (2) @(negedge clk);
        scan_enable=1'b1;
        #1;
        if (pixel_valid) $fatal(1,"uninitialized stream valid");
        rst_n=1'b1;
        do_clear(24'h102030);
        scan_enable=1'b0;
        repeat (2) @(negedge clk);
        do_tri();
        if (!initialized || busy) $fatal(1,"framebuffer not idle after triangle");
        @(negedge clk); scan_enable=1'b1;
        accepted=0;
        cycles=0;
        hold_valid=0;
        while (accepted<24 && cycles<160) begin
            @(negedge clk);
            pixel_ready=((cycles % 5) != 0 && (cycles % 9) != 0);
            #1;
            if (hold_valid) begin
                if (!pixel_valid || {pixel_x,pixel_y,pixel_color,start_of_frame,end_of_line,end_of_frame} !== hold_record)
                    $fatal(1,"stall changed output at cycle %0d",cycles);
            end
            handshake = pixel_valid && pixel_ready;
            eof_pre = end_of_frame;
            if (handshake) begin
                x = accepted % 4;
                y = (accepted % 12)/4;
                expected = x+y < 2 ? 24'hE04020 : 24'h102030;
                if (pixel_x !== 16'(x) || pixel_y !== 16'(y) || pixel_color !== expected)
                    $fatal(1,"stream beat %0d mismatch: xy=%0d,%0d rgb=%h exp=%h",accepted,pixel_x,pixel_y,pixel_color,expected);
                if (start_of_frame !== (accepted%12==0) ||
                    end_of_line !== (x==3) || end_of_frame !== (accepted%12==11))
                    $fatal(1,"stream markers bad at %0d",accepted);
                accepted++;
            end
            hold_valid = pixel_valid && !pixel_ready;
            if (hold_valid)
                hold_record={pixel_x,pixel_y,pixel_color,start_of_frame,end_of_line,end_of_frame};
            @(posedge clk); #1;
            if (frame_done !== (handshake && eof_pre))
                $fatal(1,"frame_done pulse wrong at cycle %0d",cycles);
            cycles++;
        end
        if (accepted!=24) $fatal(1,"stream loss/timeout: %0d accepted",accepted);
        pixel_ready=1'b0;
        @(negedge clk); scan_enable=1'b0;
        #1;
        if (pixel_valid) $fatal(1,"disable did not suppress valid");
        @(negedge clk); scan_enable=1'b1;
        repeat (2) @(negedge clk);
        #1;
        if (!pixel_valid || !start_of_frame || pixel_x!=0 || pixel_y!=0)
            $fatal(1,"re-enable did not restart frame from origin");
        $display("P40_RTL_DISPLAY_PASS integrated triangle/readout/backpressure/markers/abort");
        $finish;
    end
    initial begin #100000; $fatal(1,"P40 simulation timeout"); end
endmodule
