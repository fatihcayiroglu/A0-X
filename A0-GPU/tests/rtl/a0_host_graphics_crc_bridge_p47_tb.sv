`timescale 1ns/1ps
// End-to-end P44 CLEAR/PRESENT -> P45/P43/P42/P46 -> P47 monitor.
// The display is a synthetic 8x8 pixel stream, NOT HDMI/DisplayPort or PCIe.
module a0_host_graphics_crc_bridge_p47_tb;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0, rx_valid=0, rx_ready;
    logic [7:0] rx_byte=0;
    logic tx_valid, tx_ready=0;
    logic [7:0] tx_byte;
    logic scan_enable=0, pixel_valid, pixel_ready=0;
    logic [15:0] pixel_x, pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame, end_of_line, end_of_frame, frame_done;
    logic display_bank, render_bank, display_initialized, render_initialized,render_busy,swap_pending;
    logic [31:0] invalid_frame_count;
    logic crc_frame_valid,crc_frame_error;
    logic [31:0] crc_frame_value, crc_good_frames,crc_bad_frames,crc_aborted_frames;
    a0_host_graphics_crc_bridge_p47 #(.FRAME_WIDTH(8), .FRAME_HEIGHT(8)) dut(.*);
    localparam logic [255:0] CMD_CLEAR =
        256'h701c367f00000000000000000000000000000000001020300100000143473041;
    localparam logic [255:0] CMD_PRESENT =
        256'h41c7fd3400000000000000000000000000000000000000000102020143473041;
    localparam logic [31:0] EXPECT_CRC = 32'hcc1199e5; // zlib.crc32(B,G,R repeated 64)

    function automatic logic [31:0] crc_12(input logic [95:0] data);
        logic [31:0] crc;
        crc=32'hffffffff;
        for(int i=0;i<12;i++) begin
            crc^={24'd0,data[(i*8)+:8]};
            for(int k=0;k<8;k++) crc=crc[0] ? ((crc >> 1)^32'hedb88320) : (crc >> 1);
        end
        return ~crc;
    endfunction
    task automatic send_frame(input logic [255:0] frame);
        for (int i=0;i<32;i++) begin
            @(negedge clk);
            while (!rx_ready) @(negedge clk);
            rx_valid=1;
            rx_byte=frame[(i*8)+:8];
            @(negedge clk);
            rx_valid=0;
        end
    endtask
    task automatic expect_result(input logic [15:0] tag);
        logic [127:0] frame;
        frame='0;
        for(int i=0;i<16;i++) begin
            @(negedge clk);
            while(!tx_valid) @(negedge clk);
            frame[i*8+:8]=tx_byte;
            tx_ready=1;
            @(negedge clk);
            tx_ready=0;
        end
        if(frame[31:0] !== 32'h52473041 || frame[39:32] !== 8'd1 ||
           frame[47:40] !== 8'd0 || frame[63:48] !== tag ||
           frame[127:96] !== crc_12(frame[95:0]))
            $fatal(1,"P47 inherited result protocol mismatch: %h",frame);
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        send_frame(CMD_CLEAR);
        expect_result(16'h0100);
        send_frame(CMD_PRESENT);
        expect_result(16'h0102);
        if (!display_initialized) $fatal(1,"P47 frame was not presented");
        @(negedge clk); scan_enable=1;
        for(int i=0;i<64;i++) begin
            @(negedge clk);
            while (!pixel_valid) @(negedge clk);
            pixel_ready=0;
            repeat(2) begin
                @(negedge clk);
                if(!pixel_valid || pixel_x !== (i%8) ||
                   pixel_y !== (i/8) || pixel_color !== 24'h102030)
                    $fatal(1,"P47 stalled scanout changed before accepted beat %0d",i);
            end
            if(pixel_x !== (i%8) || pixel_y !== (i/8) || pixel_color !== 24'h102030 ||
               start_of_frame !== (i==0) || end_of_line !== (i%8==7) ||
               end_of_frame !== (i==63))
                $fatal(1,"P47 unexpected scanout beat %0d",i);
            pixel_ready=1;
            @(negedge clk);
            pixel_ready=0;
        end
        if(!crc_frame_valid || crc_frame_error || crc_frame_value !== EXPECT_CRC ||
           crc_good_frames !== 32'd1 || crc_bad_frames !== 32'd0 ||
           crc_aborted_frames !== 32'd0)
            $fatal(1,"P47 monitor bad frame crc=%h good=%d bad=%d",crc_frame_value,
                   crc_good_frames,crc_bad_frames);
        $display("P47 BRIDGE RTL TB PASS");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1,"P47 BRIDGE watchdog timeout");
    end
endmodule
