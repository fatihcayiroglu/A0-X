`timescale 1ns/1ps
// Real RTL proof ONLY when Icarus compiles+simulates this bench.
module a0_telemetry_loss_fifo_p118_tb;
    logic clk=0;always #5 clk=~clk;
    logic rst_n=0,frame_valid=0,frame_error=0,tx_ready=0;
    logic [31:0] frame_crc32=0,good_frame_count=0,bad_frame_count=0,aborted_frame_count=0;
    logic tx_valid,loss_notice_pending;
    logic [7:0] tx_byte;
    logic [31:0] dropped_frame_events;
    logic [2:0] queued_frame_events;
    logic [7:0] host_bytes[0:255];
    int sent_count=0;
    a0_scanout_telemetry_loss_fifo_p118 #(.FIFO_DEPTH(4)) dut(.*);
    always @(posedge clk) if(rst_n && tx_valid && tx_ready) begin
        if(sent_count>=256) $fatal(1,"P118 host overrun");
        host_bytes[sent_count]=tx_byte;sent_count++;
    end
    task automatic push(input logic [31:0] crc);
        @(negedge clk);frame_crc32=crc;frame_valid=1;
        @(negedge clk);frame_valid=0;
    endtask
    task automatic drain(input int count);
        int start;
        start=sent_count;
        @(negedge clk);tx_ready=1;
        for(int i=0;i<count;i++) begin
            if(!tx_valid) $fatal(1,"P118 unexpected TX gap i=%0d",i);
            @(negedge clk);
        end
        tx_ready=0;
        if(sent_count-start!=count) $fatal(1,"P118 wrong drain count");
    endtask
    function automatic logic[31:0] word_at(input int off);
       return {host_bytes[off+3],host_bytes[off+2],host_bytes[off+1],host_bytes[off]};
    endfunction
    function automatic logic[31:0] crc_packet(input int start);
        logic[31:0] c;
        c=32'hffffffff;
        for(int i=0;i<28;i++)begin
            c=c^{24'd0,host_bytes[start+i]};
            for(int j=0;j<8;j++) c=c[0]?((c>>1)^32'hedb88320):(c>>1);
        end
        return ~c;
    endfunction
    initial begin #100000;$fatal(1,"P118 global timeout");end
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(int i=0;i<4;i++)push(32'(500+i));
        push(32'd999); // overflows, and this is the LAST frame event.
        if(dropped_frame_events!==32'd1 || !loss_notice_pending || queued_frame_events!==3'd4)
            $fatal(1,"P118 missing owed loss report");
        // No new frame events: report must still reach host after draining.
        drain(160); // 4 original A0GF packets + one synthetic A0GL LOSS record.
        if(queued_frame_events!==0 || loss_notice_pending || dropped_frame_events!==1)
            $fatal(1,"P118 notice stuck/lost");
        for(int i=0;i<4;i++)begin
            if(word_at(i*32)!==32'h46473041 || word_at(i*32+8)!==32'(500+i)
               || host_bytes[i*32+6]!==8'(i) || word_at(i*32+28)!==crc_packet(i*32))
               $fatal(1,"P118 corrupted predecessor A0GF packet %0d",i);
        end
        if(word_at(128)!==32'h4c473041 || host_bytes[132]!==8'd1 || host_bytes[133]!==8'd1
           || {host_bytes[135],host_bytes[134]}!==16'd5 || word_at(136)!==32'd1
           || word_at(152)!==32'd0 || word_at(156)!==crc_packet(128))
           $fatal(1,"P118 A0GL loss notice invalid");
        @(negedge clk);rst_n=0;
        @(negedge clk);
        if(queued_frame_events!==0 || dropped_frame_events!==0 || tx_valid || loss_notice_pending)
           $fatal(1,"P118 reset did not clear state");
        $display("P118_REAL_RTL_LOSS_NOTICE_PASS");
        $finish;
    end
endmodule
