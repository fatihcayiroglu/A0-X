`timescale 1ns/1ps
module a0_scanout_telemetry_tx_p48_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, frame_valid=0, frame_error=0, tx_ready=0;
    logic [31:0] frame_crc32=0, good_frame_count=0;
    logic [31:0] bad_frame_count=0, aborted_frame_count=0;
    logic tx_valid;
    logic [7:0] tx_byte;
    logic [31:0] dropped_frame_events;
    a0_scanout_telemetry_tx_p48 dut(.*);
    logic [7:0] observed [0:31];

    task automatic event_pulse(input logic error, input logic [31:0] crc,
                               input logic [31:0] good, bad, aborted);
        @(negedge clk);
        frame_valid=1; frame_error=error; frame_crc32=crc;
        good_frame_count=good;bad_frame_count=bad;
        aborted_frame_count=aborted;
        @(negedge clk);
        frame_valid=0;
    endtask

    task automatic read_packet;
        for (int i=0;i<32;i++) begin
            @(negedge clk);
            tx_ready=0;
            if (!tx_valid) $fatal(1,"P48 telemetry underrun byte %0d",i);
            observed[i]=tx_byte;
            for (int j=0;j<3;j++) begin
                @(negedge clk);
                if (!tx_valid || tx_byte !== observed[i])
                    $fatal(1,"P48 telemetry unstable on stall byte %0d",i);
            end
            tx_ready=1;
        end
        @(negedge clk);
        tx_ready=0;
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        event_pulse(0,32'h12345678,1,0,0);
        if (!tx_valid) $fatal(1,"P48 no telemetry frame");
        event_pulse(1,32'h55555555,1,1,0);
        event_pulse(1,32'h77777777,1,2,0);
        if (dropped_frame_events != 2) $fatal(1,"P48 missed overflow count");
        read_packet();
        if (tx_valid) $fatal(1,"P48 frame not discharged");
        if ({observed[3],observed[2],observed[1],observed[0]} !== 32'h46473041)
            $fatal(1,"P48 wrong magic");
        if (observed[4] !== 8'd1 || observed[5] !== 8'd0 || observed[6] !== 0 || observed[7] !== 0)
            $fatal(1,"P48 wrong version/flags/sequence");
        if ({observed[11],observed[10],observed[9],observed[8]} !== 32'h12345678)
            $fatal(1,"P48 CRC field mismatch");
        if ({observed[31],observed[30],observed[29],observed[28]} !== 32'hc72a4488)
            $fatal(1,"P48 wire checksum mismatch");
        event_pulse(1,32'habcdef01,1,2,3);
        read_packet();
        if (observed[6] !== 8'd3 || observed[7] !== 8'd0 ||
            observed[5] !== 8'd1 ||
            {observed[27],observed[26],observed[25],observed[24]} !== 32'd2)
            $fatal(1,"P48 next telemetry does not expose loss/sequence");
        @(negedge clk);
        rst_n=0;
        @(negedge clk);
        if (tx_valid || dropped_frame_events != 0)
            $fatal(1,"P48 reset failed");
        $display("P48 TELEMETRY RTL TB PASS");
        $finish;
    end
    initial begin #1000000; $fatal(1,"P48 telemetry watchdog"); end
endmodule
