`timescale 1ns/1ps
module a0_scanout_liveness_guard_p114_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n,scan_active,pixel_valid,pixel_ready;
    logic [15:0] pixel_x,pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame,end_of_line,end_of_frame,frame_done;
    wire fault_sticky,pending;
    wire [31:0] timeout_count,protocol_fault_count,completed_frames,accepted_pixels,stalled_cycles;
    wire [15:0] last_fault_x,last_fault_y;
    a0_scanout_liveness_guard_p114 #(
        .FRAME_WIDTH(3),.FRAME_HEIGHT(2),
        .MAX_NO_PROGRESS_CYCLES(4),.MAX_FRAME_DONE_DELAY(3)
    ) dut (.*);

    task automatic step(input bit act,input bit v,input bit r,
                        input integer x,input integer y,input logic [23:0] c,
                        input bit sof,input bit eol,input bit eof,input bit done);
        @(negedge clk);
        scan_active=act;pixel_valid=v;pixel_ready=r;
        pixel_x=16'(x);pixel_y=16'(y);pixel_color=c;
        start_of_frame=sof;end_of_line=eol;end_of_frame=eof;frame_done=done;
        @(posedge clk); #1;
    endtask
    task automatic idle_step(input bit act);
        step(act,0,0,0,0,0,0,0,0,0);
    endtask
    task automatic beat(input integer idx,input bit ready,input logic [23:0] c);
        step(1,1,ready,idx%3,idx/3,c,(idx==0),((idx%3)==2),(idx==5),0);
    endtask
    task automatic reset_dut;
        @(negedge clk);
        rst_n=0;scan_active=0;pixel_valid=0;pixel_ready=0;
        pixel_x=0;pixel_y=0;pixel_color=0;
        start_of_frame=0;end_of_line=0;end_of_frame=0;frame_done=0;
        repeat(2) @(posedge clk);
        @(negedge clk);rst_n=1;
    endtask
    initial begin
        rst_n=0;scan_active=0;pixel_valid=0;pixel_ready=0;
        pixel_x=0;pixel_y=0;pixel_color=0;
        start_of_frame=0;end_of_line=0;end_of_frame=0;frame_done=0;
        reset_dut();
        idle_step(1);
        beat(0,1,24'h123456);
        repeat(18) beat(1,0,24'habcdef); // external backpressure does not age watchdog
        if(fault_sticky || stalled_cycles!=18) $fatal(1,"backpressure treated as hang");
        beat(1,1,24'habcdef);
        beat(2,1,24'h123456);beat(3,1,24'h123456);
        beat(4,1,24'h123456);beat(5,1,24'h123456);
        idle_step(1); // register frame_done one cycle after the accepted last pixel
        step(1,0,0,0,0,0,0,0,0,1);
        if(fault_sticky || completed_frames!=1 || accepted_pixels!=6)
            $fatal(1,"complete frame counters wrong");

        // Another frame can start without scan_active dropping between frames.
        idle_step(1);
        for(integer i=0;i<6;i++) beat(i,1,24'h334455);
        step(1,0,0,0,0,0,0,0,0,1);
        if(completed_frames!=2 || fault_sticky) $fatal(1,"back-to-back frames broken");

        reset_dut();idle_step(1);beat(0,1,24'h123456);
        repeat(4) idle_step(1);
        if(!fault_sticky || timeout_count!=1 || last_fault_x!=1 || last_fault_y!=0)
            $fatal(1,"missing scanout pixel hang not detected");

        reset_dut();idle_step(1);beat(0,0,24'habcdef);
        beat(0,0,24'h001122);
        if(!fault_sticky || protocol_fault_count!=1)
            $fatal(1,"held pixel changed under backpressure");

        reset_dut();idle_step(1);beat(0,0,24'h123456);
        idle_step(1);
        if(!fault_sticky) $fatal(1,"held valid dropped");

        reset_dut();idle_step(1);
        for(integer i=0;i<6;i++) beat(i,1,24'h445566);
        repeat(3) idle_step(1);
        if(!fault_sticky || timeout_count!=1)
            $fatal(1,"missing delayed frame_done not detected");

        reset_dut();idle_step(1);beat(0,1,24'h123456);
        step(1,0,0,0,0,0,0,0,0,1);
        if(!fault_sticky || protocol_fault_count!=1)
            $fatal(1,"early frame_done not rejected");

        reset_dut();idle_step(1);beat(0,1,24'h123456);
        idle_step(0);
        if(!fault_sticky || protocol_fault_count!=1)
            $fatal(1,"aborted frame not rejected");

        $display("P114_REAL_RTL_SCANOUT_LIVENESS_PASS");
        $finish;
    end
endmodule
