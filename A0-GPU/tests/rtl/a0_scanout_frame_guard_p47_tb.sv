`timescale 1ns/1ps
// P47 RTL test. Requires an ACTUAL Icarus/Verilator run to count as evidence.
module a0_scanout_frame_guard_p47_tb;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0, stream_active=0, pixel_valid=0, pixel_ready=0;
    logic [15:0] pixel_x=0, pixel_y=0;
    logic [23:0] pixel_color=0;
    logic start_of_frame=0, end_of_line=0, end_of_frame=0;
    logic frame_valid, frame_error;
    logic [31:0] frame_crc32, good_frame_count, bad_frame_count, aborted_frame_count;
    a0_scanout_frame_guard_p47 #(.FRAME_WIDTH(2), .FRAME_HEIGHT(2)) dut(.*);
    localparam logic [31:0] GOLDEN = 32'h5cfccabe; // Check with Python zlib before running.

    task automatic send_pixel(input logic [15:0] x, y,
                              input logic [23:0] rgb,
                              input logic sof, eol, eof,
                              input int stalls);
        @(negedge clk);
        stream_active=1;
        pixel_x=x; pixel_y=y; pixel_color=rgb;
        start_of_frame=sof; end_of_line=eol; end_of_frame=eof;
        pixel_valid=1; pixel_ready=0;
        repeat(stalls) begin
            @(negedge clk);
            if (frame_valid) $fatal(1,"P47 advanced on pixel stall");
        end
        pixel_ready=1;
        @(negedge clk);
        pixel_ready=0;
        pixel_valid=0;
    endtask

    task automatic send_frame(input logic wrong_second);
        send_pixel(0,0,24'h112233,1,0,0,4);
        send_pixel(wrong_second ? 16'd7 : 16'd1,0,24'h445566,0,1,0,0);
        send_pixel(0,1,24'h778899,0,0,0,2);
        send_pixel(1,1,24'habcdef,0,1,1,2);
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1; stream_active=1;
        send_frame(0);
        if (!frame_valid || frame_error || good_frame_count != 1 ||
            bad_frame_count != 0 || frame_crc32 !== GOLDEN)
            $fatal(1,"P47 good frame mismatch got crc=%h",frame_crc32);
        send_frame(1);
        if (!frame_valid || !frame_error || bad_frame_count != 1 ||
            good_frame_count != 1 || frame_crc32 !== GOLDEN)
            $fatal(1,"P47 bad coordinate not detected");
        send_pixel(0,0,24'h112233,1,0,1,0);
        if (!frame_valid || !frame_error || bad_frame_count != 2)
            $fatal(1,"P47 early EOF not detected");
        send_pixel(0,0,24'h112233,1,0,0,0);
        @(negedge clk); stream_active=0;
        @(negedge clk);
        if (aborted_frame_count != 1 || frame_valid)
            $fatal(1,"P47 incomplete frame abort not detected");
        @(negedge clk); rst_n=0;
        @(negedge clk);
        if (good_frame_count != 0 || bad_frame_count != 0 ||
            aborted_frame_count != 0 || frame_valid)
            $fatal(1,"P47 reset not clean");
        $display("P47 GUARD RTL TB PASS");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"P47 GUARD watchdog timeout");
    end
endmodule
