`timescale 1ns/1ps
// P46 end-to-end byte protocol -> P45 -> P43/P42 -> P46 result TB.
// Not executed unless an HDL runtime is actually available.
module a0_host_graphics_bridge_p46_tb;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0;
    logic rx_valid=0, rx_ready;
    logic [7:0] rx_byte=0;
    logic tx_valid,tx_ready=0;
    logic [7:0] tx_byte;
    logic scan_enable=0;
    logic pixel_valid,pixel_ready=1;
    logic [15:0] pixel_x,pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame,end_of_line,end_of_frame,frame_done;
    logic display_bank,render_bank,display_initialized,render_initialized,render_busy,swap_pending;
    logic [31:0] invalid_frame_count;
    logic [127:0] received;

    a0_host_graphics_bridge_p46 #(.FRAME_WIDTH(8),.FRAME_HEIGHT(8)) dut(.*);
    localparam logic [255:0] CMD_CLEAR = 256'h701c367f00000000000000000000000000000000001020300100000143473041;
    localparam logic [255:0] CMD_TRI = 256'h378dff88000000000004000000000004000000000000ff000101010143473041;
    localparam logic [255:0] CMD_PRESENT = 256'h41c7fd3400000000000000000000000000000000000000000102020143473041;
    localparam logic [255:0] CMD_INVALID = 256'hcd9c732000000000000000000000000000000000000000000103030143473041;

    function automatic logic [31:0] crc_12(input logic [95:0] data);
        logic [31:0] crc;
        crc=32'hffffffff;
        for (int i=0;i<12;i++) begin
            crc ^= {24'd0,data[(8*i)+:8]};
            for (int j=0;j<8;j++) begin
                crc = crc[0] ? (crc>>1)^32'hedb88320 : crc>>1;
            end
        end
        return ~crc;
    endfunction

    task automatic send_frame(input logic [255:0] frame);
        for (int i=0;i<32;i++) begin
            @(negedge clk);
            while (!rx_ready) @(negedge clk);
            rx_valid=1'b1;
            rx_byte=frame[(8*i)+:8];
            @(negedge clk);
            rx_valid=1'b0;
        end
    endtask

    task automatic expect_result(input logic [15:0] tag,
                                 input logic [7:0] status);
        logic [127:0] response;
        response='0;
        for (int i=0;i<16;i++) begin
            @(negedge clk);
            while (!tx_valid) @(negedge clk);
            if ((i%4)==0) begin
                begin
                    logic [7:0] held;
                    held=tx_byte;
                    repeat(5) begin
                        if (!tx_valid || tx_byte !== held)
                            $fatal(1,"P46 bridge TX data changed during stall");
                        @(negedge clk);
                    end
                end
            end
            response[(8*i)+:8]=tx_byte;
            tx_ready=1'b1;
            @(negedge clk);
            tx_ready=1'b0;
        end
        if (response[31:0] !== 32'h52473041 || response[39:32] !== 8'd1 ||
            response[47:40] !== status || response[63:48] !== tag ||
            response[127:96] !== crc_12(response[95:0]))
            $fatal(1,"P46 end-to-end bad P44 result frame %h",response);
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        send_frame(CMD_CLEAR);
        expect_result(16'h0100,8'd0);
        if (!render_initialized) $fatal(1,"CLEAR did not initialize back bank");
        send_frame(CMD_TRI);
        expect_result(16'h0101,8'd0);
        send_frame(CMD_PRESENT);
        expect_result(16'h0102,8'd0);
        if (!display_initialized) $fatal(1,"PRESENT did not initialize display bank");
        send_frame(CMD_INVALID);
        expect_result(16'h0103,8'd1);
        // A corrupted packet must never generate a completion.
        send_frame(CMD_CLEAR ^ (256'h1 << 8*28));
        repeat(64) @(negedge clk);
        if (tx_valid || invalid_frame_count != 32'd1)
            $fatal(1,"P46 corrupted CRC generated reply or bad diagnostic count");
        send_frame(CMD_CLEAR);
        expect_result(16'h0100,8'd0);
        // Clean reset is synchronous across receiver/display/transmitter.
        rst_n=0;
        @(posedge clk); @(negedge clk);
        if (tx_valid || rx_ready || invalid_frame_count != 0)
            $fatal(1,"P46 common reset failed");
        $display("P46 END-TO-END RTL TB PASS");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1,"P46 bridge TB watchdog timeout");
    end
endmodule
