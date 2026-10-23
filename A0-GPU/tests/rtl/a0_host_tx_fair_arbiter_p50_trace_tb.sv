`timescale 1ns/1ps
// P50 true HDL pin-level checker. Inputs + reference outputs are generated
// by the separate Python software reference; no expected values derived
// from DUT internals. Run only with a real SystemVerilog simulator.
module a0_host_tx_fair_arbiter_p50_trace_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic result_valid = 1'b0, telemetry_valid = 1'b0;
    logic [7:0] result_byte = 8'd0, telemetry_byte = 8'd0;
    logic host_ready = 1'b0;
    wire result_ready, telemetry_ready, host_valid;
    wire [7:0] host_byte;

    a0_host_tx_fair_arbiter_p49 dut (
        .clk(clk), .rst_n(rst_n),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_byte(result_byte),
        .telemetry_valid(telemetry_valid), .telemetry_ready(telemetry_ready),
        .telemetry_byte(telemetry_byte),
        .host_valid(host_valid), .host_ready(host_ready),
        .host_byte(host_byte)
    );

    integer fd, nread, cycles=0, accepted=0;
    integer ir, ivr, ibr, ivt, ibt, ihr, iev, ieb, ierr, ietr;
    reg [1023:0] path;

    initial begin
        if (!$value$plusargs("TRACE=%s", path))
            $fatal(1, "P50 requires +TRACE=<absolute fixture file>");
        fd = $fopen(path, "r");
        if (fd == 0)
            $fatal(1, "P50 failed to open trace %s", path);
        // Header line is non-numeric; discard it once.
        nread = $fgets(path, fd);
        if (nread == 0)
            $fatal(1, "P50 empty trace");
        repeat (2) @(negedge clk);
        while (!$feof(fd)) begin
            nread = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n",
                            ir, ivr, ibr, ivt, ibt, ihr, iev, ieb, ierr, ietr);
            if (nread == 10) begin
                @(negedge clk);
                rst_n = (ir != 0);
                result_valid = (ivr != 0);
                result_byte = ibr[7:0];
                telemetry_valid = (ivt != 0);
                telemetry_byte = ibt[7:0];
                host_ready = (ihr != 0);
                #1;
                if (host_valid !== (iev != 0))
                    $fatal(1, "P50 cycle %0d host_valid mismatch got=%b expected=%0d",
                           cycles, host_valid, iev);
                if (result_ready !== (ierr != 0))
                    $fatal(1, "P50 cycle %0d result_ready mismatch got=%b expected=%0d",
                           cycles, result_ready, ierr);
                if (telemetry_ready !== (ietr != 0))
                    $fatal(1, "P50 cycle %0d telemetry_ready mismatch got=%b expected=%0d",
                           cycles, telemetry_ready, ietr);
                if (iev != 0 && host_byte !== ieb[7:0])
                    $fatal(1, "P50 cycle %0d host_byte mismatch got=%h expected=%h",
                           cycles, host_byte, ieb[7:0]);
                if (host_valid && host_ready)
                    accepted = accepted + 1;
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end else if (!$feof(fd)) begin
                $fatal(1, "P50 malformed trace at cycle %0d scanf=%0d", cycles, nread);
            end
        end
        $fclose(fd);
        if (cycles < 2300 || accepted < 100)
            $fatal(1, "P50 vacuous coverage: cycles=%0d accepted=%0d",cycles,accepted);
        $display("P50 RTL TRACE PASS cycles=%0d accepted=%0d", cycles,accepted);
        $finish;
    end
endmodule
