`timescale 1ns/1ps
module a0_host_tx_frame_arbiter_p48_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, result_valid, result_ready, telemetry_valid, telemetry_ready;
    logic host_valid,host_ready=0;
    logic [7:0] result_byte,telemetry_byte,host_byte;
    logic [7:0] result_data[0:15];
    logic [7:0] telemetry_data[0:31];
    integer result_idx=0, telemetry_idx=0,host_idx=0;
    integer cycles=0;
    a0_host_tx_frame_arbiter_p48 dut(.*);
    assign result_valid = rst_n && result_idx < 16;
    assign telemetry_valid = rst_n && telemetry_idx < 32;
    assign result_byte = (result_idx < 16) ? result_data[result_idx] : 8'd0;
    assign telemetry_byte = (telemetry_idx < 32) ? telemetry_data[telemetry_idx] : 8'd0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (result_valid && result_ready) result_idx <= result_idx+1;
            if (telemetry_valid && telemetry_ready) telemetry_idx <= telemetry_idx+1;
            if (host_valid && host_ready) begin
                if (host_idx < 16) begin
                    if (host_byte !== result_data[host_idx])
                        $fatal(1,"P48 arbiter result mixed at byte %0d",host_idx);
                end else if (host_idx < 48) begin
                    if (host_byte !== telemetry_data[host_idx-16])
                        $fatal(1,"P48 arbiter telemetry mixed at byte %0d",host_idx);
                end else $fatal(1,"P48 arbiter extra byte");
                host_idx <= host_idx+1;
            end
        end
    end

    initial begin
        for (int i=0;i<16;i++)result_data[i]=8'h40+i[7:0];
        for (int i=0;i<32;i++)telemetry_data[i]=8'h80+i[7:0];
        repeat(3) @(negedge clk);
        rst_n=1;
        for (int i=0;i<1000 && host_idx<48;i++) begin
            @(negedge clk);
            // Periodic stalls exercise data hold and frame boundaries.
            host_ready=(i%7 == 0 || i%7 == 4);
            cycles=i;
        end
        @(negedge clk);
        if (host_idx != 48 || result_idx != 16 || telemetry_idx != 32)
            $fatal(1,"P48 arbiter incomplete host=%0d result=%0d telemetry=%0d",
                   host_idx,result_idx,telemetry_idx);
        if (host_valid) $fatal(1,"P48 arbiter keeps sending after completion");
        $display("P48 ARBITER RTL TB PASS");
        $finish;
    end
    initial begin #1000000; $fatal(1,"P48 arbiter watchdog"); end
endmodule
