`timescale 1ns/1ps
// P122 adversarial REAL RTL bench, requires Icarus+vvp. Exercises two loss
// notices when an overflow collides with the cycle that makes room for the
// previous owed notice. Independent packet CRCs and bounded end-to-end drain.
module a0_p122_overflow_race_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,frame_valid=0,frame_error=0,tx_ready=0;
    logic [31:0] frame_crc32=0,good_frame_count=0,bad_frame_count=0,aborted_frame_count=0;
    logic tx_valid,loss_notice_pending;
    logic [7:0] tx_byte;
    logic [31:0] dropped_frame_events;
    logic [1:0] queued_frame_events;
    logic [7:0] stream[0:127];
    integer byte_count=0;

    a0_scanout_telemetry_loss_fifo_p118 #(.FIFO_DEPTH(2)) dut(.*);
    always @(posedge clk) if(rst_n && tx_valid && tx_ready) begin
        if (byte_count>=128) $fatal(1,"P122 unexpected extra output");
        stream[byte_count]=tx_byte;
        byte_count=byte_count+1;
    end

    task automatic submit(input logic [31:0] crc);
        @(negedge clk);frame_valid=1;frame_crc32=crc;
        @(negedge clk);frame_valid=0;
    endtask
    task automatic drain(input integer n);
        integer beginning;
        beginning=byte_count;
        @(negedge clk);tx_ready=1;
        for(integer i=0;i<n;i=i+1) begin
            if(!tx_valid) $fatal(1,"P122 TX gap at %0d",i);
            @(negedge clk);
        end
        tx_ready=0;
        if(byte_count-beginning!=n) $fatal(1,"P122 wrong drain count %0d",byte_count-beginning);
    endtask
    function automatic logic [31:0] u32(input integer off);
        return {stream[off+3],stream[off+2],stream[off+1],stream[off]};
    endfunction
    function automatic logic [31:0] crc28(input integer off);
        logic [31:0] crc;
        crc=32'hffffffff;
        for(integer i=0;i<28;i=i+1) begin
            crc=crc ^ {24'd0,stream[off+i]};
            for(integer j=0;j<8;j=j+1)
                crc=crc[0]?((crc>>1)^32'hedb88320):(crc>>1);
        end
        return ~crc;
    endfunction
    initial begin #200000;$fatal(1,"P122 HARD TIMEOUT");end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        submit(32'h11111111);submit(32'h22222222);
        submit(32'h33333333); // depth 2 full: one drop, notice owed
        if(queued_frame_events!==2 || dropped_frame_events!==1 || !loss_notice_pending)
            $fatal(1,"P122 first overflow not accounted");
        // A blocked host must see a stable first byte, never a phantom pop.
        repeat(8) begin
            @(negedge clk);
            if(!tx_valid || tx_byte!==8'h41 || queued_frame_events!==2)
                $fatal(1,"P122 stalled FIFO unstable");
        end
        drain(31); // leave just the last byte of first A0GF
        // Exactly on first packet's last accepted byte: fresh frame tries to
        // enter while the old loss notice is queued. Both notices are owed.
        @(negedge clk);tx_ready=1;frame_valid=1;frame_crc32=32'h44444444;
        @(negedge clk);tx_ready=0;frame_valid=0;
        if(byte_count!==32 || dropped_frame_events!==2 || !loss_notice_pending ||
           queued_frame_events!==2)
            $fatal(1,"P122 collision lost an owed notice / frame accounting");
        drain(96); // remaining good frame + notice(dropped=1) + notice(dropped=2)
        if(byte_count!==128 || queued_frame_events!==0 || loss_notice_pending ||
           dropped_frame_events!==2 || tx_valid)
            $fatal(1,"P122 wrong final idle/overflow state");
        for(integer i=0;i<4;i=i+1)
            if(u32(i*32+28)!==crc28(i*32)) $fatal(1,"P122 CRC mismatch at %0d",i);
        if(u32(0)!==32'h46473041 || u32(8)!==32'h11111111 ||
           u32(32)!==32'h46473041 || u32(40)!==32'h22222222)
            $fatal(1,"P122 frame order/corruption");
        if(u32(64)!==32'h4c473041 || u32(72)!==1 ||
           u32(96)!==32'h4c473041 || u32(104)!==2)
            $fatal(1,"P122 lost or reordered overflow notice");
        if({stream[71],stream[70]}!==16'd3 ||
           {stream[103],stream[102]}!==16'd4)
            $fatal(1,"P122 wrong attempted sequence in notices");
        $display("P122_REAL_RTL_OVERFLOW_RACE_PASS");
        $finish;
    end
endmodule
