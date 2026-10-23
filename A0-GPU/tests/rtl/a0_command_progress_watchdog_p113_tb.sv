`timescale 1ns/1ps
module a0_command_progress_watchdog_p113_tb;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0,cmd_valid=0,cmd_ready=0;
    logic [1:0] cmd_opcode=0;
    logic [15:0] cmd_tag=0,completion_tag=0;
    logic completion_valid=0,completion_ready=0,completion_error=0;
    logic pixel_valid=0,pixel_ready=0;
    logic fault_sticky,pending;
    logic [15:0] active_tag,last_fault_tag;
    logic [31:0] timeout_count,tag_mismatch_count,protocol_fault_count;
    logic [31:0] completed_count,present_pixel_count;
    a0_command_progress_watchdog_p113 #(.MAX_WAIT_CYCLES(4)) dut(.*);

    task automatic tick;
        @(posedge clk);#1;
    endtask
    task automatic inputs_idle;
        cmd_valid=0;cmd_ready=0;
        completion_valid=0;completion_ready=0;completion_error=0;
        pixel_valid=0;pixel_ready=0;
    endtask
    task automatic reset_monitor;
        @(negedge clk);rst_n=0;inputs_idle();
        tick();
        @(negedge clk);rst_n=1;
    endtask
    task automatic accept(input logic [1:0] op,input logic [15:0] tag_value);
        @(negedge clk);inputs_idle();
        cmd_valid=1;cmd_ready=1;cmd_opcode=op;cmd_tag=tag_value;
        tick();
        if(!pending || active_tag!==tag_value)$fatal(1,"accept failed");
        @(negedge clk);inputs_idle();
    endtask
    task automatic complete(input logic [15:0] tag_value);
        @(negedge clk);inputs_idle();
        completion_valid=1;completion_ready=1;completion_tag=tag_value;
        tick();
        @(negedge clk);inputs_idle();
    endtask
    initial begin
        reset_monitor();
        accept(2'b10,16'h2222);
        for(integer k=0;k<100;k=k+1) begin
            // Every pixel acceptance resets the PRESENT progress timeout.
            pixel_valid=1;pixel_ready=1;
            tick();
            if(fault_sticky || !pending || present_pixel_count!==(k+1))
                $fatal(1,"valid PRESENT pixel progress failed %0d",k);
            @(negedge clk);
        end
        pixel_valid=1;pixel_ready=0;
        for(integer k=0;k<80;k=k+1) begin
            tick();
            if(fault_sticky || present_pixel_count!==100)
                $fatal(1,"PRESENT sink stall false timeout %0d",k);
            @(negedge clk);
        end
        complete(16'h2222);
        if(pending || completed_count!==1 || fault_sticky)
            $fatal(1,"PRESENT completion failure");

        // Pixels must NOT refresh the timeout for TRIANGLE.
        reset_monitor();accept(2'b01,16'h0011);
        pixel_valid=1;pixel_ready=1;
        for(integer k=0;k<4;k=k+1) begin
            tick();@(negedge clk);
        end
        if(!fault_sticky || timeout_count!==1 || last_fault_tag!==16'h0011)
            $fatal(1,"TRIANGLE timeout suppressed by pixel traffic");

        // PRESENT without any valid pixel must time out (not indefinitely pause).
        reset_monitor();accept(2'b10,16'h0033);
        for(integer k=0;k<4;k=k+1) begin
            tick();@(negedge clk);
        end
        if(!fault_sticky || timeout_count!==1)
            $fatal(1,"PRESENT zero-progress timeout failed");

        reset_monitor();accept(2'b10,16'h0044);
        pixel_valid=1;pixel_ready=1;
        tick();@(negedge clk);
        if(present_pixel_count!==1)$fatal(1,"pixel counted twice");
        complete(16'h0045);
        if(!fault_sticky || tag_mismatch_count!==1 || last_fault_tag!==16'h0045)
            $fatal(1,"mismatched response tag not detected");

        reset_monitor();accept(2'b10,16'h0055);
        completion_valid=1;completion_ready=0;completion_tag=16'h0055;
        tick();@(negedge clk);
        for(integer k=0;k<20;k=k+1) begin
            tick();@(negedge clk);
        end
        if(fault_sticky || !pending)$fatal(1,"held completion false fault");
        completion_ready=1;tick();@(negedge clk);
        if(completed_count!==1 || pending)$fatal(1,"held completion handshake failure");

        $display("P113_REAL_RTL_PROGRESS_WATCHDOG_PASS");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"P113 RTL testbench timed out");
    end
endmodule
