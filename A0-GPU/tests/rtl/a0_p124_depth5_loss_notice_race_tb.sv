`timescale 1ns/1ps
// P124 REAL RTL test (not a software model): depth-five circular FIFO,
// frozen output during backpressure, simultaneous last-byte pop/loss notice
// enqueue/new frame DROP, secondary autonomous notice, metadata snapshots.
module a0_p124_depth5_loss_notice_race_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,frame_valid=0,frame_error=0,tx_ready=0;
    logic [31:0] frame_crc32=0,good_frame_count=11,bad_frame_count=22,
                 aborted_frame_count=33;
    logic tx_valid,loss_notice_pending;
    logic [7:0] tx_byte;
    logic [31:0] dropped_frame_events;
    logic [2:0] queued_frame_events;
    logic [7:0] bytes_out[0:287];
    integer nbytes=0;

    a0_scanout_telemetry_loss_fifo_p118 #(.FIFO_DEPTH(5)) dut(.*);
    always @(posedge clk) if (rst_n && tx_valid && tx_ready) begin
        if (nbytes>=288) $fatal(1,"P124 output overflow");
        bytes_out[nbytes]=tx_byte;
        nbytes=nbytes+1;
    end

    task automatic send_frame(input logic [31:0] crc,input logic err);
        @(negedge clk);frame_valid=1;frame_crc32=crc;frame_error=err;
        @(negedge clk);frame_valid=0;
    endtask

    task automatic drain(input integer amount);
        integer at_start;
        at_start=nbytes;
        @(negedge clk);tx_ready=1;
        for (integer i=0;i<amount;i=i+1) begin
            if (tx_valid!==1'b1) $fatal(1,"P124 unexpected TX gap at byte %0d",i);
            @(negedge clk);
        end
        tx_ready=0;
        if (nbytes-at_start!=amount)
            $fatal(1,"P124 drain mismatch %0d vs %0d",nbytes-at_start,amount);
    endtask

    task automatic packet_dump(input integer n);
        $write("P124_PACKET %0d ",n);
        for (integer b=0;b<32;b=b+1) $write("%02x",bytes_out[n*32+b]);
        $write("\n");
    endtask

    initial begin #3000000;$fatal(1,"P124 real RTL simulation timeout");end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for (integer k=0;k<5;k=k+1)
            send_frame(32'hA5000001+k,k[0]);
        if (queued_frame_events!==3'd5 || dropped_frame_events!==0 || !tx_valid)
            $fatal(1,"P124 failed to fill depth-five FIFO");
        send_frame(32'hB5000001,1'b1);  // attempted seq=5, first DROP
        if (queued_frame_events!==3'd5 || dropped_frame_events!==32'd1 ||
            !loss_notice_pending) $fatal(1,"P124 initial overflow not recorded");

        // All queued frame payloads are immutable despite changing input data.
        @(negedge clk);good_frame_count=99;bad_frame_count=98;
        aborted_frame_count=97;frame_crc32=32'hffffffff;frame_error=1;
        repeat (8) begin
            @(negedge clk);
            if (queued_frame_events!==3'd5 || tx_byte!==8'h41 ||
                dropped_frame_events!==32'd1 || !loss_notice_pending)
                $fatal(1,"P124 stalled FIFO head or loss state changed");
        end

        drain(31);
        // Last byte of A pops, first A0GL is enqueued, and G is DROPPED.
        // The notice being enqueued summarizes first drop only (count=1),
        // while fresh loss MUST cause another notice later (count=2).
        @(negedge clk);tx_ready=1;frame_valid=1;
        frame_crc32=32'hB5000002;frame_error=0;
        @(negedge clk);tx_ready=0;frame_valid=0;
        if (nbytes!==32 || queued_frame_events!==3'd5 ||
            dropped_frame_events!==32'd2 || !loss_notice_pending)
            $fatal(1,"P124 lost second owed summary during simultaneous pop/drop");

        repeat (9) begin
            @(negedge clk);
            if (queued_frame_events!==3'd5 || tx_byte!==8'h41 ||
                dropped_frame_events!==32'd2 || !loss_notice_pending)
                $fatal(1,"P124 stalled second head changed");
        end
        drain(32); // B pops; autonomously enqueues second A0GL (count=2).
        if (queued_frame_events!==3'd5 || loss_notice_pending ||
            dropped_frame_events!==32'd2)
            $fatal(1,"P124 autonomous second loss notice was not enqueued");
        drain(160); // C,D,E, old notice and new notice.
        if (nbytes!==224 || queued_frame_events!==0 || tx_valid ||
            loss_notice_pending || dropped_frame_events!==32'd2)
            $fatal(1,"P124 FIFO did not empty or reports were duplicated");

        // Following frame uses next attempted sequence=7, accumulated drop=2.
        @(negedge clk);good_frame_count=123;bad_frame_count=124;
        aborted_frame_count=125;
        send_frame(32'hC5000003,1'b1);
        drain(32);
        if (nbytes!==256 || queued_frame_events!==0 || loss_notice_pending ||
            dropped_frame_events!==32'd2 || tx_valid)
            $fatal(1,"P124 post-notice frame retained stale state");
        for (integer k=0;k<8;k=k+1) packet_dump(k);
        $display("P124_DEPTH5_TWO_GENERATIONS_OF_LOSS_NOTICES");
        $display("P124_REAL_RTL_DEPTH5_LOSS_RACE_PASS");
        $finish;
    end
endmodule
