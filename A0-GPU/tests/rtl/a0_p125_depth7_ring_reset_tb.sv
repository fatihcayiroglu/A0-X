`timescale 1ns/1ps
// P125 actual HDL witness, only qualified if run in a real simulator.
// Depth 7 exercises non-power-of-two pointers, queued notices across wrap,
// stalled output, and reset during a partially transmitted packet.
module a0_p125_depth7_ring_reset_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,frame_valid=0,frame_error=0,tx_ready=0;
    logic [31:0] frame_crc32=0,good_frame_count=10,bad_frame_count=20,
                 aborted_frame_count=30;
    logic tx_valid,loss_notice_pending;
    logic [7:0] tx_byte;
    logic [31:0] dropped_frame_events;
    logic [2:0] queued_frame_events;
    logic [7:0] wire_bytes[0:351];
    integer nbytes=0;

    a0_scanout_telemetry_loss_fifo_p118 #(.FIFO_DEPTH(7)) dut(.*);
    always @(posedge clk) if (rst_n && tx_valid && tx_ready) begin
        if (nbytes>=352) $fatal(1,"P125 output overflow");
        wire_bytes[nbytes]=tx_byte;
        nbytes=nbytes+1;
    end

    task automatic send_frame(input logic [31:0] crc,input logic err);
        @(negedge clk);frame_valid=1;frame_crc32=crc;frame_error=err;
        @(negedge clk);frame_valid=0;
    endtask
    task automatic drain(input integer count);
        integer start;
        start=nbytes;
        @(negedge clk);tx_ready=1;
        for(integer i=0;i<count;i=i+1) begin
            if(tx_valid!==1'b1) $fatal(1,"P125 unexpected transmit gap at %0d",i);
            @(negedge clk);
        end
        tx_ready=0;
        if(nbytes-start!=count) $fatal(1,"P125 drain count mismatch");
    endtask
    task automatic dump_packet(input integer id,input integer offset);
        $write("P125_PACKET %0d ",id);
        for(integer i=0;i<32;i=i+1) $write("%02x",wire_bytes[offset+i]);
        $write("\n");
    endtask

    initial begin #4000000; $fatal(1,"P125 simulation timeout"); end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(integer k=0;k<7;k=k+1)
            send_frame(32'hC4000001+k,k[0]);
        if(queued_frame_events!==3'd7 || dropped_frame_events!==0 || !tx_valid)
            $fatal(1,"P125 initial depth-seven FIFO fill failed");
        send_frame(32'hB4000001,1'b1); // seq 7 dropped, first notice owed.
        if(dropped_frame_events!==32'd1 || !loss_notice_pending)
            $fatal(1,"P125 first loss not recorded");

        @(negedge clk);good_frame_count=40;bad_frame_count=50;
        aborted_frame_count=60;frame_crc32=32'hffffffff;
        repeat(11) begin
            @(negedge clk);
            if(tx_byte!==8'h41 || queued_frame_events!==3'd7 ||
               dropped_frame_events!==32'd1 || !loss_notice_pending)
                $fatal(1,"P125 stalled output or overflow state changed");
        end
        drain(32); // F0 pops; notice seq=8, dropped=1 enqueued (pointer wraps).
        if(queued_frame_events!==3'd7 || loss_notice_pending ||
           dropped_frame_events!==32'd1)
            $fatal(1,"P125 first autonomous notice missing");
        send_frame(32'hB4000002,1'b0); // seq 8 dropped, next notice owed.
        if(dropped_frame_events!==32'd2 || !loss_notice_pending)
            $fatal(1,"P125 second loss not recorded");
        drain(32); // F1 pops, notice seq=9 dropped=2 enqueued.
        if(queued_frame_events!==3'd7 || loss_notice_pending)
            $fatal(1,"P125 second autonomous notice missing");
        drain(224); // F2-F6 followed by two loss notices, in FIFO order.
        if(nbytes!==288 || queued_frame_events!==0 || tx_valid ||
           dropped_frame_events!==32'd2 || loss_notice_pending)
            $fatal(1,"P125 depth-seven FIFO did not finish cleanly");

        good_frame_count=100;bad_frame_count=200;aborted_frame_count=300;
        send_frame(32'hC600000A,1'b1); // seq=9, retained drop count=2
        drain(9); // Deliberately cut a live packet at an epoch boundary.
        if(nbytes!==297 || !tx_valid || queued_frame_events!==3'd1)
            $fatal(1,"P125 partial packet did not remain pending");
        @(negedge clk);rst_n=0;
        if(tx_valid!==1'b0) $fatal(1,"P125 reset must gate TX immediately");
        @(negedge clk);
        if(queued_frame_events!==0 || dropped_frame_events!==0 ||
           loss_notice_pending || tx_valid)
            $fatal(1,"P125 reset retained stale telemetry state");
        good_frame_count=4;bad_frame_count=5;aborted_frame_count=6;
        rst_n=1;
        send_frame(32'hD600000B,1'b0); // New epoch starts at seq=0.
        drain(32);
        if(nbytes!==329 || queued_frame_events!==0 || dropped_frame_events!==0 ||
           loss_notice_pending || tx_valid)
            $fatal(1,"P125 new epoch did not complete cleanly");

        for(integer p=0;p<9;p=p+1) dump_packet(p,p*32);
        $write("P125_DISCARDED_PREFIX ");
        for(integer p=288;p<297;p=p+1) $write("%02x",wire_bytes[p]);
        $write("\n");
        dump_packet(9,297);
        $display("P125_DEPTH7_RING_TWO_LOSS_RESET_EPOCH_WITNESS");
        $display("P125_REAL_RTL_DEPTH7_RING_RESET_PASS");
        $finish;
    end
endmodule
