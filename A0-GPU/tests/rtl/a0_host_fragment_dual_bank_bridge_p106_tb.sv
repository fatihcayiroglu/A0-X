`timescale 1ns/1ps
// P106 behavioral RTL test (needs iverilog/vvp, NOT a device test).
// Mix legacy 32-byte CLEAR/PRESENT and 56-byte v2 TRIANGLE;
// reject malformed v2 without ACK, check blend+scissor pixel and frame CRC.
module a0_host_fragment_dual_bank_bridge_p106_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,rx_valid=0,rx_ready;
    logic [7:0] rx_byte=0,tx_byte;
    logic tx_valid,tx_ready=0,scan_enable=1;
    logic pixel_valid,pixel_ready=0;
    logic [15:0] pixel_x,pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame,end_of_line,end_of_frame,frame_done;
    logic display_bank,render_bank,display_initialized,render_initialized;
    logic render_busy,swap_pending,scan_active;
    logic [31:0] invalid_frame_count,frame_crc32,good_frames,bad_frames;
    logic [31:0] aborted_frames,telemetry_dropped_frames;
    logic frame_crc_valid,frame_crc_error;
    int tx_count=0,pixel_count=0;
    logic [7:0] captured[0:255];

    a0_host_fragment_dual_bank_bridge_p106 #(
        .FRAME_WIDTH(4),.FRAME_HEIGHT(4)
    ) dut(.*);

    task automatic send_packet(input logic[447:0] bits,input int n);
        int cycles;
        begin
            @(negedge clk);
            for(int i=0;i<n;i++) begin
                for(cycles=0;!rx_ready && cycles<4000;cycles++) @(negedge clk);
                if(!rx_ready) $fatal(1,"P106 input timeout byte=%0d",i);
                rx_byte=bits[i*8+:8];rx_valid=1'b1;
                @(negedge clk);
                rx_valid=1'b0;
            end
        end
    endtask

    function automatic logic[31:0] crc_bytes(input int offset,input int n);
        logic[31:0] crc;
        begin
            crc=32'hffffffff;
            for(int i=0;i<n;i++) begin
                crc=crc^{24'd0,captured[offset+i]};
                for(int j=0;j<8;j++) begin
                    if(crc[0])crc=(crc>>1)^32'hedb88320;
                    else crc=crc>>1;
                end
            end
            return ~crc;
        end
    endfunction

    always @(posedge clk) if(rst_n) begin
        if(tx_valid && tx_ready) begin
            if(tx_count>=256)$fatal(1,"P106 too many TX bytes");
            captured[tx_count]=tx_byte;tx_count++;
        end
        if(pixel_valid && pixel_ready) begin
            if(pixel_count>=16)$fatal(1,"P106 unsolicited pixel");
            if(pixel_x !== pixel_count%4 || pixel_y !== pixel_count/4)
                $fatal(1,"P106 pixel coordinate mismatch %0d",pixel_count);
            if(pixel_color !== (pixel_count==5 ? 24'h881119 : 24'h112233))
                $fatal(1,"P106 scissor/blend output mismatch pixel %0d=%h",pixel_count,pixel_color);
            if(start_of_frame !== (pixel_count==0) ||
               end_of_line !== (pixel_count%4==3) ||
               end_of_frame !== (pixel_count==15))
                $fatal(1,"P106 invalid frame sidebands");
            pixel_count++;
        end
    end
    initial begin #1400000; $fatal(1,"P106 global watchdog");end
    initial begin : check
        int i,offset,len,results,telemetry;
        logic [31:0] frame_crc;
        repeat(4) @(negedge clk);
        rst_n=1;tx_ready=1;
        // Legacy clear, extended TRIANGLE, bad CRC TRIANGLE, legacy present.
        send_packet(448'hcca12cfb00000000000000000000000000000000001122330001000143473041,32);
        send_packet(448'he5847223000000000000000000020002000100010000801d0000000a0000000000040000000000040000000000ff00000002010243473041,56);
        send_packet(448'he5847223000000000000000000020002000100010000801d0000000a0000000000040010000000040000000000ff00000002010243473041,56);
        send_packet(448'hc9351a6a00000000000000000000000000000000000000000003020143473041,32);
        for(i=0;!pixel_valid && i<8000;i++) @(negedge clk);
        if(!pixel_valid) $fatal(1,"P106 no scanout");
        pixel_ready=0;
        repeat(8) @(negedge clk);
        if(!pixel_valid || pixel_x!==0 || pixel_y!==0 || pixel_color!==24'h112233)
            $fatal(1,"P106 stalled output not stable");
        tx_ready=0;
        repeat(10) @(negedge clk);
        tx_ready=1;pixel_ready=1;
        for(i=0;(tx_count<80 || pixel_count<16) && i<15000;i++) @(negedge clk);
        if(tx_count!=80 || pixel_count!=16)
            $fatal(1,"P106 incomplete TX=%0d pixels=%0d",tx_count,pixel_count);
        if(invalid_frame_count!==1 || good_frames!==1 || bad_frames!==0 ||
           aborted_frames!==0 || telemetry_dropped_frames!==0)
            $fatal(1,"P106 invalid status bad_rx=%0d good=%0d drop=%0d",
                   invalid_frame_count,good_frames,telemetry_dropped_frames);
        offset=0;results=0;telemetry=0;
        while(offset<tx_count) begin
            if(captured[offset]!=8'h41 || captured[offset+1]!=8'h30 ||
               captured[offset+2]!=8'h47) $fatal(1,"P106 bad TX packet");
            if(captured[offset+3]==8'h52) begin
                len=16;results++;
                if(captured[offset+5]!==8'd0 || captured[offset+6]!==8'(results))
                    $fatal(1,"P106 bad command ACK");
            end else if(captured[offset+3]==8'h46) begin
                len=32;telemetry++;
                frame_crc={captured[offset+11],captured[offset+10],
                           captured[offset+9],captured[offset+8]};
                if(frame_crc!==32'h0b207310 || captured[offset+12]!==8'd1 ||
                   captured[offset+5]!==8'd0 || captured[offset+6]!==8'd0)
                    $fatal(1,"P106 image CRC mismatch=%h",frame_crc);
            end else $fatal(1,"P106 unrecognized TX kind");
            if({captured[offset+len-1],captured[offset+len-2],
                captured[offset+len-3],captured[offset+len-4]} !==
               crc_bytes(offset,len-4))$fatal(1,"P106 TX packet CRC invalid");
            offset+=len;
        end
        if(results!=3 || telemetry!=1)$fatal(1,"P106 missing records");
        $display("P106_REAL_RTL_PASS");
        $finish;
    end
endmodule
