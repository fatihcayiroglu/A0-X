`timescale 1ns/1ps
// P116 CANDIDATE E2E bench. Never claim RTL PASS until iverilog/vvp executes.
// Actual P44/P106 byte packets -> P104 double bank -> P42 pixels -> P47 CRC
// -> P114 liveness -> P115 frame audit -> P48/P49 host packets.
// Independent known-good CRCs were computed with Python zlib (IEEE CRC32);
// they are constants, not derived from the DUT's frame CRC output.
module a0_host_frame_audit_e2e_p116_tb;
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
    logic diagnostic_fault,diagnostic_pending;
    logic [15:0] diagnostic_active_tag,diagnostic_last_fault_tag;
    logic [31:0] diagnostic_timeouts,diagnostic_tag_mismatches;
    logic [31:0] diagnostic_protocol_faults,diagnostic_completed,diagnostic_present_pixels;
    logic frame_liveness_fault,frame_liveness_pending;
    logic [31:0] frame_liveness_timeouts,frame_liveness_protocol_faults;
    logic [31:0] frame_liveness_completed,frame_liveness_pixels,frame_liveness_stalls;
    logic [15:0] frame_liveness_fault_x,frame_liveness_fault_y;
    logic audit_fault_sticky,audit_pending;
    logic [31:0] audit_matched_good_frames,audit_untrusted_frames;
    logic [31:0] audit_event_faults,audit_crc_error_frames;
    logic [31:0] audit_liveness_fault_events,audit_telemetry_lost_events;
    logic [31:0] audit_last_crc32;

    int tx_count=0,pixel_count=0,registered_frame_events=0;
    logic [7:0] captured[0:255];
    localparam logic[31:0] GOLD_CRC0=32'h0b207310;
    localparam logic[31:0] GOLD_CRC1=32'h330e6e51;

    a0_host_fragment_dual_bank_frame_audit_p115 #(
        .FRAME_WIDTH(4),.FRAME_HEIGHT(4)
    ) dut(.*);

    task automatic send_packet(input logic[447:0] bits,input int n);
        int cycles;
        begin
            @(negedge clk);
            for(int i=0;i<n;i++) begin
                for(cycles=0;!rx_ready && cycles<5000;cycles++) @(negedge clk);
                if(!rx_ready) $fatal(1,"P116 RX timeout byte=%0d",i);
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
                for(int j=0;j<8;j++)
                    crc=crc[0]?((crc>>1)^32'hedb88320):(crc>>1);
            end
            return ~crc;
        end
    endfunction

    // Check what actually passed the pixel valid/ready interface,
    // not what the RTL monitor claims to have received.
    always @(posedge clk) if(rst_n) begin
        if(tx_valid && tx_ready) begin
            if(tx_count>=256) $fatal(1,"P116 host TX overflow");
            captured[tx_count]=tx_byte;tx_count++;
        end
        if(pixel_valid && pixel_ready) begin
            if(pixel_count>=32) $fatal(1,"P116 unexpected extra pixel");
            if(pixel_x !== (pixel_count%16)%4 ||
               pixel_y !== (pixel_count%16)/4)
                $fatal(1,"P116 XY mismatch pixel=%0d x=%0d y=%0d",pixel_count,pixel_x,pixel_y);
            if(pixel_color !== (pixel_count<16 ?
                 ((pixel_count==5) ? 24'h881119 : 24'h112233) : 24'h445566))
                $fatal(1,"P116 pixel content mismatch beat=%0d color=%h",pixel_count,pixel_color);
            if(start_of_frame !== (pixel_count%16==0) ||
               end_of_line !== (pixel_count%4==3) ||
               end_of_frame !== (pixel_count%16==15))
                $fatal(1,"P116 sideband mismatch beat=%0d",pixel_count);
            pixel_count++;
        end
        if(frame_done || frame_crc_valid) begin
            if(!frame_done || !frame_crc_valid || frame_crc_error)
                $fatal(1,"P116 P42/P47 registered EOF mismatch");
            if(registered_frame_events>=2)
                $fatal(1,"P116 unsolicited third EOF");
            if(frame_crc32 !== (registered_frame_events==0 ? GOLD_CRC0 : GOLD_CRC1))
                $fatal(1,"P116 wrong independent frame CRC index=%0d got=%h",registered_frame_events,frame_crc32);
            registered_frame_events++;
        end
    end

    initial begin #3000000; $fatal(1,"P116 global timeout");end
    initial begin : run
        int i,offset,len,results,telemetry;
        logic [31:0] actual_crc;
        repeat(4) @(negedge clk);
        rst_n=1;tx_ready=1;
        // Original P106 vector: legacy CLEAR, v2 scissor+blend TRIANGLE,
        // malformed v2 TRIANGLE (CRC failure), legacy PRESENT.
        send_packet(448'hcca12cfb00000000000000000000000000000000001122330001000143473041,32);
        send_packet(448'he5847223000000000000000000020002000100010000801d0000000a0000000000040000000000040000000000ff00000002010243473041,56);
        send_packet(448'he5847223000000000000000000020002000100010000801d0000000a0000000000040010000000040000000000ff00000002010243473041,56);
        send_packet(448'hc9351a6a00000000000000000000000000000000000000000003020143473041,32);
        for(i=0;!pixel_valid && i<8000;i++) @(negedge clk);
        if(!pixel_valid) $fatal(1,"P116 frame 1 did not start");
        pixel_ready=0;
        repeat(12) @(negedge clk);
        if(!pixel_valid || pixel_x!==0 || pixel_y!==0 || pixel_color!==24'h112233)
            $fatal(1,"P116 front frame payload not stable under sink stall");
        if(!scan_active || display_bank===render_bank)
            $fatal(1,"P116 dual bank not active");
        // Render the NEXT bank while the FIRST front frame is stalled.
        send_packet(448'h3bb867f500000000000000000000000000000000004455660004000143473041,32);
        if(!pixel_valid || pixel_color!==24'h112233)
            $fatal(1,"P116 render polluted held front pixel");
        send_packet(448'hbbc440ea00000000000000000000000000000000000000000005020143473041,32);
        if(!pixel_valid || pixel_color!==24'h112233)
            $fatal(1,"P116 pending swap changed held front pixel");
        pixel_ready=1;
        // P48 has a documented single-slot telemetry buffer. Do not confuse
        // an intentionally overloaded host output channel with an RTL
        // correctness failure: pause the SECOND frame at the sink so the
        // first telemetry and result packets can drain packet-atomically.
        // This also explicitly tests that prolonged external backpressure
        // does not create a false P114/P115 liveness failure.
        for(i=0;registered_frame_events<1 && i<10000;i++) @(negedge clk);
        if(registered_frame_events!=1) $fatal(1,"P116 first EOF missing");
        pixel_ready=0;
        repeat(160) @(negedge clk);
        if(registered_frame_events!=1 || audit_matched_good_frames!==1 ||
           frame_liveness_fault || audit_fault_sticky)
            $fatal(1,"P116 first frame audit failed while second is stalled");
        pixel_ready=1;
        for(i=0;(tx_count<144 || pixel_count<32 || audit_matched_good_frames<2)
             && i<30000;i++) @(negedge clk);
        if(i==30000 || tx_count!=144 || pixel_count!=32)
            $fatal(1,"P116 incomplete frames/TX tx=%0d pixel=%0d matched=%0d",tx_count,pixel_count,audit_matched_good_frames);
        if(registered_frame_events!=2 || good_frames!==2 || bad_frames!==0 ||
           aborted_frames!==0 || telemetry_dropped_frames!==0 || invalid_frame_count!==1)
            $fatal(1,"P116 frame/host counters inconsistent");
        if(diagnostic_fault || frame_liveness_fault || audit_fault_sticky ||
           audit_pending || audit_matched_good_frames!==2 || audit_untrusted_frames!==0 ||
           audit_event_faults!==0 || audit_crc_error_frames!==0 ||
           audit_telemetry_lost_events!==0 || audit_liveness_fault_events!==0 ||
           frame_liveness_completed!==2 || frame_liveness_pixels!==32 ||
           audit_last_crc32!==GOLD_CRC1 || frame_liveness_stalls<12)
            $fatal(1,"P116 monitors disagree: audit_good=%0d live_done=%0d live_pixel=%0d fault=%0d/%0d/%0d",
                audit_matched_good_frames,frame_liveness_completed,frame_liveness_pixels,
                diagnostic_fault,frame_liveness_fault,audit_fault_sticky);

        offset=0;results=0;telemetry=0;
        while(offset<tx_count) begin
            if(captured[offset]!=8'h41 || captured[offset+1]!=8'h30 ||
               captured[offset+2]!=8'h47) $fatal(1,"P116 invalid TX header");
            if(captured[offset+3]==8'h52) begin
                len=16;results++;
                if(results>5 || captured[offset+5]!==8'd0 ||
                   captured[offset+6]!==8'(results))
                    $fatal(1,"P116 result tag mismatch count=%0d",results);
            end else if(captured[offset+3]==8'h46) begin
                len=32;telemetry++;
                actual_crc={captured[offset+11],captured[offset+10],
                            captured[offset+9],captured[offset+8]};
                if(telemetry>2 || actual_crc !== (telemetry==1? GOLD_CRC0:GOLD_CRC1)
                   || captured[offset+12]!==8'(telemetry) || captured[offset+5]!==8'd0 ||
                   captured[offset+6]!==8'(telemetry-1))
                    $fatal(1,"P116 host telemetry does not match pixel golden CRC");
            end else $fatal(1,"P116 unexpected packet type");
            if({captured[offset+len-1],captured[offset+len-2],
                captured[offset+len-3],captured[offset+len-4]} !==
               crc_bytes(offset,len-4)) $fatal(1,"P116 host packet CRC failure");
            offset+=len;
        end
        if(results!=5 || telemetry!=2) $fatal(1,"P116 host results/telemetry missing");
        $display("P116_REAL_RTL_HOST_FRAME_AUDIT_E2E_PASS");
        $finish;
    end
endmodule
