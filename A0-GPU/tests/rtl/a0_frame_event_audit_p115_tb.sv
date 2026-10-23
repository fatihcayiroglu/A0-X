`timescale 1ns/1ps
// Prospective Icarus bench; not actual RTL evidence unless executed by Icarus.
module a0_frame_event_audit_p115_tb;
    logic clk=0;always #5 clk=~clk;
    logic rst_n,scan_active,frame_done,frame_crc_valid,frame_crc_error;
    logic [31:0] frame_crc32,frame_liveness_completed,telemetry_dropped_frames;
    logic frame_liveness_pending,frame_liveness_fault;
    wire fault_sticky,confirmation_pending;
    wire [31:0] matched_good_frames,untrusted_frames,event_fault_count;
    wire [31:0] crc_error_frame_count,liveness_fault_event_count;
    wire [31:0] telemetry_lost_event_count,last_crc32;
    a0_frame_event_audit_p115 dut (.*);

    task automatic step(input bit active,input bit done,input bit crc_event,
        input bit crc_bad,input bit live_pending,input bit live_fault,
        input logic [31:0] live_completed,input logic [31:0] dropped);
        @(negedge clk);
        scan_active=active;frame_done=done;frame_crc_valid=crc_event;
        frame_crc_error=crc_bad;frame_crc32=32'h12345678;
        frame_liveness_pending=live_pending;
        frame_liveness_fault=live_fault;
        frame_liveness_completed=live_completed;
        telemetry_dropped_frames=dropped;
        @(posedge clk);#1;
    endtask
    task automatic reset_dut;
        @(negedge clk);
        rst_n=0;scan_active=0;frame_done=0;frame_crc_valid=0;
        frame_crc_error=0;frame_crc32=0;frame_liveness_pending=0;
        frame_liveness_fault=0;frame_liveness_completed=0;
        telemetry_dropped_frames=0;
        repeat(2) @(posedge clk);
        @(negedge clk);rst_n=1;
    endtask
    initial begin
        rst_n=0;scan_active=0;frame_done=0;frame_crc_valid=0;
        frame_crc_error=0;frame_crc32=0;frame_liveness_pending=0;
        frame_liveness_fault=0;frame_liveness_completed=0;
        telemetry_dropped_frames=0;
        reset_dut();
        step(1,1,1,0,1,0,0,0);
        if(!confirmation_pending || matched_good_frames!=0)
            $fatal(1,"counted frame without liveness confirmation");
        step(0,0,0,0,0,0,1,0);
        if(confirmation_pending || matched_good_frames!=1 || fault_sticky ||
           last_crc32!=32'h12345678) $fatal(1,"clean frame audit failed");
        step(1,1,1,0,1,0,1,0);
        step(0,0,0,0,0,0,2,0);
        if(matched_good_frames!=2 || fault_sticky) $fatal(1,"two good frames failed");

        reset_dut();step(1,1,0,0,1,0,0,0);
        if(!fault_sticky || event_fault_count!=1 || untrusted_frames!=1)
            $fatal(1,"missing CRC event was not rejected");
        reset_dut();step(1,0,1,0,1,0,0,0);
        if(!fault_sticky || event_fault_count!=1) $fatal(1,"orphan CRC accepted");
        reset_dut();step(0,1,1,0,1,0,0,0);
        if(!fault_sticky) $fatal(1,"off-scan event accepted");
        reset_dut();step(1,1,1,0,0,0,0,0);
        if(!fault_sticky) $fatal(1,"without pending liveness accepted");
        reset_dut();step(1,1,1,0,1,0,0,0);
        step(0,0,0,0,0,0,0,0);
        if(!fault_sticky || event_fault_count!=1 || matched_good_frames!=0)
            $fatal(1,"missing liveness increment accepted");

        reset_dut();step(1,1,1,1,1,0,0,0);
        if(crc_error_frame_count!=1 || matched_good_frames!=0)
            $fatal(1,"bad CRC counted good");
        step(0,0,0,0,0,0,1,0);
        if(untrusted_frames!=1 || matched_good_frames!=0)
            $fatal(1,"bad CRC confirmation counted good");

        reset_dut();step(1,1,1,0,1,0,0,0);
        step(0,0,0,0,0,1,1,0);
        if(!fault_sticky || liveness_fault_event_count!=1 || matched_good_frames!=0)
            $fatal(1,"sticky liveness error not propagated");
        repeat(20) step(0,0,0,0,0,1,1,0);
        if(liveness_fault_event_count!=1) $fatal(1,"sticky fault counted repeatedly");

        reset_dut();step(0,0,0,0,0,0,0,4);
        if(!fault_sticky || telemetry_lost_event_count!=4)
            $fatal(1,"telemetry loss not detected");
        step(0,0,0,0,0,0,0,6);
        if(telemetry_lost_event_count!=6) $fatal(1,"loss delta count wrong");
        step(0,0,0,0,0,0,0,2);
        if(event_fault_count!=1) $fatal(1,"telemetry rollback not rejected");
        $display("P115_REAL_RTL_FRAME_EVENT_AUDIT_PASS");
        $finish;
    end
endmodule
