`timescale 1ns/1ps
// Candidate REAL RTL qualification. Requires Icarus; do not claim PASS
// based on Python software model or inspection alone.
module a0_telemetry_fifo_p117_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,frame_valid=0,frame_error=0,tx_ready=0;
    logic [31:0] frame_crc32=0,good_frame_count=0,bad_frame_count=0;
    logic [31:0] aborted_frame_count=0,dropped_frame_events;
    logic tx_valid;
    logic [7:0] tx_byte;
    logic [2:0] queued_frame_events;
    logic [7:0] host_bytes [0:255];
    int sent_count=0;
    a0_scanout_telemetry_fifo_p117 #(.FIFO_DEPTH(4)) dut (
       .clk(clk),.rst_n(rst_n),.frame_valid(frame_valid),.frame_error(frame_error),
       .frame_crc32(frame_crc32),.good_frame_count(good_frame_count),
       .bad_frame_count(bad_frame_count),.aborted_frame_count(aborted_frame_count),
       .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_byte(tx_byte),
       .dropped_frame_events(dropped_frame_events),
       .queued_frame_events(queued_frame_events)
    );
    always @(posedge clk) if(rst_n && tx_valid && tx_ready) begin
       if(sent_count>=256) $fatal(1,"P117 host buffer overflow");
       host_bytes[sent_count]=tx_byte;
       sent_count++;
    end
    task automatic push(input logic[31:0] crc);
       @(negedge clk);
       frame_crc32=crc;
       frame_valid=1;
       @(negedge clk);
       frame_valid=0;
    endtask
    task automatic drain(input int bytes_to_send);
       int initial_sent_count;
       initial_sent_count=sent_count;
       @(negedge clk);
       tx_ready=1;
       for(int i=0;i<bytes_to_send;i++) begin
          if (!tx_valid) $fatal(1,"P117 TX missing at byte=%0d",i);
          @(negedge clk);
       end
       tx_ready=0;
       if(sent_count-initial_sent_count!=bytes_to_send)
          $fatal(1,"P117 drain count mismatch %0d vs %0d",sent_count-initial_sent_count,bytes_to_send);
    endtask
    function automatic logic[31:0] crc_packet(input int base);
       logic[31:0] crc;
       crc=32'hffffffff;
       for(int i=0;i<28;i++) begin
          crc=crc^{24'd0,host_bytes[base+i]};
          for(int j=0;j<8;j++)
              crc=crc[0]?((crc>>1)^32'hedb88320):(crc>>1);
       end
       return ~crc;
    endfunction
    function automatic logic [31:0] le32(input int i);
        return {host_bytes[i+3],host_bytes[i+2],host_bytes[i+1],host_bytes[i]};
    endfunction
    task automatic validate(input int p,input int seq,input logic [31:0] crc,input int dropped);
        int base;
        base=p*32;
        if(host_bytes[base]!==8'h41 || host_bytes[base+1]!==8'h30 ||
           host_bytes[base+2]!==8'h47 || host_bytes[base+3]!==8'h46 ||
           host_bytes[base+4]!==8'h01 || host_bytes[base+5]!==8'h00)
           $fatal(1,"P117 malformed header at packet %0d",p);
        if({host_bytes[base+7],host_bytes[base+6]} !== 16'(seq) ||
           le32(base+8)!==crc || le32(base+24)!==32'(dropped))
           $fatal(1,"P117 seq/crc/drop mismatch packet %0d",p);
        if(le32(base+28)!==crc_packet(base))
           $fatal(1,"P117 CRC32 mismatch packet %0d",p);
    endtask
    initial begin #200000; $fatal(1,"P117 global timeout"); end
    initial begin : run
        logic [7:0] held_byte;
        repeat(4) @(negedge clk);
        rst_n=1;
        for(int i=0;i<4;i++) push(32'(100+i));
        if(queued_frame_events!==3'd4 || dropped_frame_events!==0)
           $fatal(1,"P117 did not buffer four frames");
        held_byte=tx_byte;
        repeat(25) begin
           @(negedge clk);
           if(!tx_valid || tx_byte!==held_byte)
              $fatal(1,"P117 stalled front byte changed");
        end
        push(32'd104); // full: event seq=4 dropped
        if(dropped_frame_events!==1 || queued_frame_events!==4)
           $fatal(1,"P117 missing overflow report");
        drain(31); // leave front packet on final byte
        if(queued_frame_events!==4 || dut.byte_index_q!==5'd31)
           $fatal(1,"P117 wrong pre-pop condition");
        // Simultaneous accept FINAL byte and a new event while FIFO full.
        @(negedge clk);
        frame_crc32=32'd105;
        frame_valid=1;tx_ready=1;
        @(negedge clk);
        frame_valid=0;tx_ready=0;
        if(queued_frame_events!==4 || dropped_frame_events!==1 || sent_count!==32)
           $fatal(1,"P117 simultaneous full pop+push failed");
        drain(128);
        if(sent_count!==160 || queued_frame_events!==0 || tx_valid)
           $fatal(1,"P117 host drain incomplete");
        validate(0,0,32'd100,0);
        validate(1,1,32'd101,0);
        validate(2,2,32'd102,0);
        validate(3,3,32'd103,0);
        validate(4,5,32'd105,1);
        @(negedge clk);rst_n=0;
        @(negedge clk);
        if(queued_frame_events!==0 || dropped_frame_events!==0 || tx_valid)
           $fatal(1,"P117 reset did not flush FIFO");
        $display("P117_REAL_RTL_TELEMETRY_FIFO_PASS");
        $finish;
    end
endmodule
