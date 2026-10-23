`timescale 1ns/1ps
// P46 actual RTL behavioral testbench. Test only becomes evidence when run
// under Icarus/Verilator: its existence alone is NOT evidence of passing RTL.
module a0_host_result_tx_p46_tb;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0;
    logic result_valid=0, result_ready;
    logic [15:0] result_tag=0;
    logic result_error=0;
    logic [31:0] result_cycles=0;
    logic out_valid, out_ready=0;
    logic [7:0] out_byte;
    logic [127:0] wire_frame;

    a0_host_result_tx_p46 dut(.*);
    localparam logic [127:0] EXPECT_OK = 128'h3b4d201990abcdef1234000152473041;
    localparam logic [127:0] EXPECT_ERR = 128'h427d444cffffffffffff010152473041;
    localparam logic [127:0] EXPECT_ZERO = 128'h1411035b000000000000000152473041;

    task automatic enqueue(input logic [15:0] tag,
                           input logic error_flag, input logic [31:0] cycles);
        @(negedge clk);
        while (!result_ready) @(negedge clk);
        result_valid = 1'b1;
        result_tag = tag;
        result_error = error_flag;
        result_cycles = cycles;
        @(negedge clk);
        result_valid = 1'b0;
    endtask

    task automatic take_frame(output logic [127:0] frame);
        frame='0;
        for (int i=0;i<16;i++) begin
            @(negedge clk);
            while (!out_valid) @(negedge clk);
            // Check stable payload under output stalls; source payload is
            // intentionally changed after enqueue in the main test.
            if ((i%3)==0) begin
                begin
                    logic [7:0] held_byte;
                    held_byte=out_byte;
                    for (int k=0;k<4;k++) begin
                        if (!out_valid || out_byte !== held_byte)
                            $fatal(1,"P46 output unexpectedly changed on stall");
                        @(negedge clk);
                    end
                end
            end
            if (!out_valid || result_ready)
                $fatal(1,"P46 output/ready mutual exclusion failed");
            frame[i*8+:8] = out_byte;
            out_ready = 1'b1;
            @(negedge clk);
            out_ready = 1'b0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        enqueue(16'h1234,0,32'h90abcdef);
        result_tag=16'hbeef; result_cycles=0; result_error=1;
        take_frame(wire_frame);
        if (wire_frame !== EXPECT_OK) $fatal(1,"P46 OK exact P44 frame mismatch %h",wire_frame);
        enqueue(16'hffff,1,32'hffffffff);
        take_frame(wire_frame);
        if (wire_frame !== EXPECT_ERR) $fatal(1,"P46 ERROR exact P44 frame mismatch %h",wire_frame);
        enqueue(0,0,0);
        take_frame(wire_frame);
        if (wire_frame !== EXPECT_ZERO) $fatal(1,"P46 zero exact P44 frame mismatch %h",wire_frame);
        enqueue(16'hbabe,0,32'hffffffff);
        repeat(3) begin
            @(negedge clk);
            if (!out_valid) $fatal(1,"P46 premature completion while stalled");
            out_ready=1;
        end
        @(negedge clk);
        out_ready=0;
        rst_n=0;
        @(posedge clk);
        @(negedge clk);
        if (out_valid || result_ready) $fatal(1,"P46 reset did not cancel response");
        rst_n=1;
        @(negedge clk);
        if (!result_ready || out_valid) $fatal(1,"P46 reset restart failed");
        $display("P46 RTL TX TB PASS");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"P46 TX TB watchdog timeout");
    end
endmodule
