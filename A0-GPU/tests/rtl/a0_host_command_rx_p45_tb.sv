`timescale 1ns/1ps
// P45 simulation-only testbench. This file exists but no HDL simulator was
// available in the authoring environment; it is NOT a passing RTL receipt.
module a0_host_command_rx_p45_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n=1'b0, in_valid=1'b0, in_ready;
    logic [7:0] in_byte=8'd0;
    logic cmd_valid, cmd_ready=1'b0;
    logic [1:0] cmd_opcode;
    logic [15:0] cmd_tag;
    logic [23:0] cmd_color;
    logic signed [15:0] cmd_x0,cmd_y0,cmd_x1,cmd_y1,cmd_x2,cmd_y2;
    logic [31:0] invalid_frame_count;
    a0_host_command_rx_p45 dut(.*);
    localparam logic [255:0] GOOD_CLEAR = 256'ha62691b2000000000000000000000000000000000013579b1234000143473041;
    localparam logic [255:0] GOOD_TRIANGLE = 256'hb1c10785000000000049ff9cffff000a7fff800000ab674529ab010143473041;
    localparam logic [255:0] GOOD_PRESENT = 256'h7cb3370c0000000000000000000000000000000000000000abcd020143473041;
    localparam logic [255:0] BAD_CRC = 256'ha62691b2000000000000005500000000000000000013579b1234000143473041;
    localparam logic [255:0] BAD_RESERVED = 256'hc40f50690000000100000000000000000000000000000000abcd020143473041;

    task automatic send_byte(input logic [7:0] value);
        @(negedge clk);
        while (!in_ready) @(negedge clk);
        in_valid = 1'b1;
        in_byte = value;
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
    endtask
    task automatic send_frame(input logic [255:0] frame);
        for (int i=0;i<32;i++) send_byte(frame[i*8+:8]);
    endtask
    task automatic must_hold(input logic [1:0] op, input logic [15:0] tag,
                             input logic [23:0] color);
        if (!cmd_valid || cmd_opcode !== op || cmd_tag !== tag || cmd_color !== color)
            $fatal(1,"P45 decoded command mismatch: valid=%b op=%d tag=%h color=%h",
                   cmd_valid,cmd_opcode,cmd_tag,cmd_color);
        repeat(8) begin
            if (!cmd_valid || in_ready || cmd_opcode !== op || cmd_tag !== tag || cmd_color !== color)
                $fatal(1,"P45 held command / backpressure invariant broken");
            @(posedge clk);
            @(negedge clk);
        end
    endtask
    task automatic take_command;
        if (!cmd_valid) $fatal(1,"P45 expected pending command");
        cmd_ready=1'b1;
        @(posedge clk);
        @(negedge clk);
        cmd_ready=1'b0;
        if (cmd_valid || !in_ready) $fatal(1,"P45 command not consumed");
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1'b1;
        send_frame(GOOD_CLEAR);
        must_hold(2'd0,16'h1234,24'h13579b);
        take_command();
        send_frame(BAD_CRC);
        if (cmd_valid || invalid_frame_count != 1) $fatal(1,"corrupted CRC dispatched");
        send_frame(BAD_RESERVED);
        if (cmd_valid || invalid_frame_count != 2) $fatal(1,"noncanonical packet dispatched");
        send_frame(GOOD_TRIANGLE);
        must_hold(2'd1,16'h29ab,24'hab6745);
        if (cmd_x0 !== -16'sd32768 || cmd_y0 !== 16'sd32767 ||
            cmd_x1 !== 16'sd10 || cmd_y1 !== -16'sd1 ||
            cmd_x2 !== -16'sd100 || cmd_y2 !== 16'sd73)
            $fatal(1,"P45 vertex / signedness extraction mismatch");
        take_command();
        // Fake magic inside broken frame, followed by a complete good frame:
        send_byte(8'h41);send_byte(8'h30);send_byte(8'h47);send_byte(8'h43);
        repeat(9) send_byte(8'h3f);
        send_frame(GOOD_PRESENT);
        must_hold(2'd2,16'habcd,24'd0);
        if (invalid_frame_count != 3) $fatal(1,"resync invalid frame count mismatch");
        take_command();
        send_frame(GOOD_CLEAR);
        if (!cmd_valid) $fatal(1,"expected valid before reset");
        rst_n=1'b0;
        @(posedge clk);
        @(negedge clk);
        if (cmd_valid || in_ready || invalid_frame_count != 0)
            $fatal(1,"reset failed to cancel pending command / counters");
        rst_n=1'b1;
        send_frame(GOOD_CLEAR);
        must_hold(2'd0,16'h1234,24'h13579b);
        take_command();
        $display("P45 RTL RX TB PASS");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"P45 TB watchdog timeout");
    end
endmodule
