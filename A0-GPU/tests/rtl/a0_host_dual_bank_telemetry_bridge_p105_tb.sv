`timescale 1ns/1ps
// Real RTL testbench (NOT executed without iverilog/vvp).
// End-to-end P44 CLEAR/PRESENT twice -> dual bank pixels -> result/CRC host stream.
module a0_host_dual_bank_telemetry_bridge_p105_tb;
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
    logic [7:0] captured [0:255];

    a0_host_dual_bank_telemetry_bridge_p105 #(
        .FRAME_WIDTH(4),.FRAME_HEIGHT(4)
    ) dut(.*);

    function automatic logic [31:0] crc_bytes(input int start,input int n);
        logic [31:0] crc;
        begin
            crc=32'hffffffff;
            for(int i=0;i<n;i++) begin
                crc=crc^{24'd0,captured[start+i]};
                for(int b=0;b<8;b++)
                    crc=crc[0] ? ((crc>>1)^32'hedb88320):(crc>>1);
            end
            return ~crc;
        end
    endfunction

    task automatic send_packet(input logic [255:0] bits);
        int cycles;
        begin
            @(negedge clk);
            for(int i=0;i<32;i++) begin
                for(cycles=0;!rx_ready && cycles<2000;cycles++) @(negedge clk);
                if(!rx_ready) $fatal(1,"P105 RX timed out at byte %0d",i);
                rx_valid=1'b1;
                rx_byte=bits[i*8+:8];
                @(negedge clk);
                rx_valid=1'b0;
            end
        end
    endtask

    always @(posedge clk) if(rst_n) begin
        if(tx_valid && tx_ready) begin
            if(tx_count>=256) $fatal(1,"P105 excessive TX bytes");
            captured[tx_count]=tx_byte;
            tx_count=tx_count+1;
        end
        if(pixel_valid && pixel_ready) begin
            if(pixel_count>=32) $fatal(1,"P105 unsolicited pixel");
            if(pixel_x !== (pixel_count%4) || pixel_y !== ((pixel_count%16)/4))
                $fatal(1,"P105 unexpected pixel coordinates at %0d",pixel_count);
            if(pixel_color !== (pixel_count<16 ? 24'h112233 : 24'h445566))
                $fatal(1,"P105 frame tearing at %0d: %h",pixel_count,pixel_color);
            if(start_of_frame !== ((pixel_count%16)==0) ||
               end_of_line !== ((pixel_count%4)==3) ||
               end_of_frame !== ((pixel_count%16)==15))
                $fatal(1,"P105 invalid sidebands at %0d",pixel_count);
            pixel_count=pixel_count+1;
        end
    end

    initial begin #1000000; $fatal(1,"P105 global watchdog"); end
    initial begin : sequence
        int i,offset,len,results,telemetry;
        logic [31:0] actual_crc;
        repeat(4) @(negedge clk);
        rst_n=1;tx_ready=1;
        send_packet(256'hcca12cfb00000000000000000000000000000000001122330001000143473041);
        send_packet(256'hde1d7eaa00000000000000000000000000000000000000000002020143473041);
        // Withhold scan ready: first frame must not tear while second clear runs.
        for(i=0;!pixel_valid && i<1500;i++) @(negedge clk);
        if(!pixel_valid) $fatal(1,"P105 no first frame pixels");
        send_packet(256'h5e6159b500000000000000000000000000000000004455660003000143473041);
        repeat(8) @(negedge clk);
        if(!pixel_valid || pixel_color!==24'h112233)
            $fatal(1,"P105 held front pixel changed");
        send_packet(256'hacec242a00000000000000000000000000000000000000000004020143473041);
        // Host stalls and scan stalls exercise both ready/valid boundaries.
        tx_ready=0;repeat(9) @(negedge clk);tx_ready=1;
        pixel_ready=1;
        // P48 has a SINGLE telemetry slot. Deliberately allow frame 1's
        // telemetry to drain before consuming frame 2; otherwise drops are
        // legitimate and asserting two packets would be a false test.
        for(i=0;pixel_count<16 && i<4000;i++) @(negedge clk);
        if(pixel_count!=16) $fatal(1,"P105 frame one not completed");
        pixel_ready=0;
        for(i=0;tx_count<96 && i<7000;i++) @(negedge clk);
        if(tx_count!=96) $fatal(1,"P105 first telemetry not fully sent");
        pixel_ready=1;
        for(i=0;(pixel_count<32 || tx_count<128) && i<15000;i++) @(negedge clk);
        if(pixel_count!=32 || tx_count!=128)
            $fatal(1,"P105 incomplete pixels=%0d hostbytes=%0d",pixel_count,tx_count);
        if(good_frames!==2 || bad_frames!==0 || aborted_frames!==0 ||
           telemetry_dropped_frames!==0 || invalid_frame_count!==0)
            $fatal(1,"P105 unexpected counters good=%0d bad=%0d drop=%0d",
                   good_frames,bad_frames,telemetry_dropped_frames);
        offset=0;results=0;telemetry=0;
        while(offset<tx_count) begin
            if(captured[offset]!==8'h41 || captured[offset+1]!==8'h30 ||
               captured[offset+2]!==8'h47)
                $fatal(1,"P105 invalid host magic at %0d",offset);
            if(captured[offset+3]==8'h52) begin
                len=16;
                results=results+1;
                if(captured[offset+5]!==0 || captured[offset+6]!==8'(results))
                    $fatal(1,"P105 bad result #%0d",results);
            end else if(captured[offset+3]==8'h46) begin
                len=32;
                telemetry=telemetry+1;
                if(captured[offset+5]!==0 || captured[offset+6]!==8'(telemetry-1) ||
                   captured[offset+12]!==8'(telemetry))
                    $fatal(1,"P105 bad frame telemetry #%0d",telemetry);
                // CRC32/IEEE over 16 accepted RGB888 pixels, little endian.
                if({captured[offset+11],captured[offset+10],
                    captured[offset+9],captured[offset+8]} !==
                   (telemetry==1 ? 32'h05a53b43 : 32'h330e6e51))
                    $fatal(1,"P105 frame pixel CRC mismatch #%0d",telemetry);
            end else $fatal(1,"P105 unknown TX record");
            actual_crc=crc_bytes(offset,len-4);
            if({captured[offset+len-1],captured[offset+len-2],
                captured[offset+len-3],captured[offset+len-4]}!==actual_crc)
                $fatal(1,"P105 invalid TX CRC at byte %0d",offset);
            offset=offset+len;
        end
        if(results!=4 || telemetry!=2)
            $fatal(1,"P105 unexpected host packets result=%0d frame=%0d",results,telemetry);
        repeat(10) @(negedge clk);
        if(pixel_valid || scan_active || tx_valid)
            $fatal(1,"P105 unsolicited stream beyond two frames");
        $display("P105_REAL_RTL_PASS");
        $finish;
    end
endmodule
