`timescale 1ns/1ps
// P123 actual RTL test: non-power-of-two FIFO depth=3, full simultaneous
// pop/push, autonomous loss notice, partial-packet reset, reset clean slate.
// The Python runner independently validates all exported packets (CRC32 etc).
module a0_p123_depth3_reset_stream_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,frame_valid=0,frame_error=0,tx_ready=0;
    logic [31:0] frame_crc32=0,good_frame_count=0,bad_frame_count=0,aborted_frame_count=0;
    logic tx_valid,loss_notice_pending;
    logic [7:0] tx_byte;
    logic [31:0] dropped_frame_events;
    logic [1:0] queued_frame_events;
    logic [7:0] bytes_out[0:319];
    integer nbytes=0;

    a0_scanout_telemetry_loss_fifo_p118 #(.FIFO_DEPTH(3)) dut(.*);
    always @(posedge clk) if(rst_n && tx_valid && tx_ready) begin
        if(nbytes>=320) $fatal(1,"P123 output overflow");
        bytes_out[nbytes]=tx_byte;
        nbytes=nbytes+1;
    end

    task automatic send_frame(input logic [31:0] crc);
        @(negedge clk);frame_valid=1;frame_crc32=crc;
        @(negedge clk);frame_valid=0;
    endtask
    task automatic drain(input integer amount);
        integer at_start;
        at_start=nbytes;
        @(negedge clk);tx_ready=1;
        for(integer i=0;i<amount;i=i+1) begin
            if(tx_valid!==1'b1) $fatal(1,"P123 gap at byte %0d",i);
            @(negedge clk);
        end
        tx_ready=0;
        if(nbytes-at_start!=amount)
            $fatal(1,"P123 drain mismatch %0d != %0d",nbytes-at_start,amount);
    endtask
    task automatic packet_dump(input integer packet_no,input integer offset);
        $write("P123_PACKET %0d ",packet_no);
        for(integer b=0;b<32;b=b+1) $write("%02x",bytes_out[offset+b]);
        $write("\n");
    endtask

    initial begin #2000000;$fatal(1,"P123 simulation hard timeout");end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        send_frame(32'ha0000001);send_frame(32'ha0000002);send_frame(32'ha0000003);
        if(queued_frame_events!==3 || tx_valid!==1 || dropped_frame_events!==0)
            $fatal(1,"P123 depth3 initial fill failed");
        repeat(5) begin
            @(negedge clk);
            if(tx_byte!==8'h41 || queued_frame_events!==3)
                $fatal(1,"P123 held head byte changed");
        end
        drain(31);
        // FIFO is FULL. Read the last byte of A and simultaneously push D.
        // The producer wraps write pointer from slot 2 back to slot 0.
        @(negedge clk);tx_ready=1;frame_valid=1;frame_crc32=32'ha0000004;
        @(negedge clk);tx_ready=0;frame_valid=0;
        if(nbytes!==32 || queued_frame_events!==3 || dropped_frame_events!==0)
            $fatal(1,"P123 full pop+push lost a packet");
        drain(96);
        if(nbytes!==128 || queued_frame_events!==0 || tx_valid!==0)
            $fatal(1,"P123 full pop+push drain failed");

        send_frame(32'hb0000005);send_frame(32'hb0000006);
        send_frame(32'hb0000007);send_frame(32'hb0000008);
        if(queued_frame_events!==3 || dropped_frame_events!==1 || !loss_notice_pending)
            $fatal(1,"P123 did not flag expected overflow");
        drain(128); // E,F,G then spontaneous A0GL; no subsequent frame.
        if(nbytes!==256 || queued_frame_events!==0 || loss_notice_pending || tx_valid ||
           dropped_frame_events!==1)
            $fatal(1,"P123 autonomous loss notice did not drain");

        send_frame(32'hc0000009);
        drain(7); // Interrupt a live packet, then reset the FIFO and byte index.
        if(nbytes!==263 || !tx_valid || queued_frame_events!==1)
            $fatal(1,"P123 partial packet did not remain queued");
        @(negedge clk);rst_n=0;
        #1; // Let combinational async output gating settle before sampling.
        if(tx_valid!==0) $fatal(1,"P123 reset must gate TX immediately");
        @(negedge clk);
        if(queued_frame_events!==0 || dropped_frame_events!==0 || loss_notice_pending || tx_valid)
            $fatal(1,"P123 reset did not clear FIFO state");
        rst_n=1;
        send_frame(32'hd000000a);
        drain(32);
        if(nbytes!==295 || queued_frame_events!==0 || dropped_frame_events!==0 || tx_valid)
            $fatal(1,"P123 after-reset packet completion failed");
        for(integer i=0;i<8;i=i+1) packet_dump(i,i*32);
        packet_dump(8,263); // explicit discontinuity: 7 partial bytes discarded
        $display("P123_PARTIAL_DISCARDED 7");
        $display("P123_REAL_RTL_DEPTH3_RESET_PASS");
        $finish;
    end
endmodule
