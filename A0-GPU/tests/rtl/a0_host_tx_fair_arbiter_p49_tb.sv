`timescale 1ns/1ps
// P49 experimental independent on-pin acceptance/ordering checks.
// Must run on a real HDL simulator before P49 can be declared RTL-verified.
module a0_host_tx_fair_arbiter_p49_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n, result_valid, telemetry_valid, host_ready;
    logic [7:0] result_byte, telemetry_byte, host_byte;
    logic result_ready, telemetry_ready, host_valid;
    logic [4:0] result_index;
    logic [5:0] telemetry_index;
    logic [5:0] expected_index;
    logic expected_telemetry;
    logic hold_active;
    logic [7:0] hold_byte;
    int result_frames, telemetry_frames;

    a0_host_tx_fair_arbiter_p49 dut(
       .clk(clk), .rst_n(rst_n), .result_valid(result_valid),
       .result_ready(result_ready), .result_byte(result_byte),
       .telemetry_valid(telemetry_valid), .telemetry_ready(telemetry_ready),
       .telemetry_byte(telemetry_byte), .host_valid(host_valid),
       .host_ready(host_ready), .host_byte(host_byte)
    );
    assign result_byte = 8'h40 + {3'd0,result_index};
    assign telemetry_byte = 8'h80 + {2'd0,telemetry_index};

    always @(posedge clk) begin
        if (!rst_n) begin
            result_index <= 0;
            telemetry_index <= 0;
            expected_index <= 0;
            expected_telemetry <= 1'b0;  // result should win first tie
            result_frames <= 0;
            telemetry_frames <= 0;
            hold_active <= 1'b0;
            hold_byte <= 0;
        end else begin
            if (result_valid && result_ready)
                result_index <= (result_index == 15) ? 0 : result_index + 1'b1;
            if (telemetry_valid && telemetry_ready)
                telemetry_index <= (telemetry_index == 31) ? 0 : telemetry_index + 1'b1;

            if (hold_active && (!host_valid || host_byte !== hold_byte))
                $fatal(1, "P49 host output changed under backpressure");
            hold_active <= host_valid && !host_ready;
            hold_byte <= host_byte;

            if (result_ready && telemetry_ready)
                $fatal(1, "P49 consumed two lanes in one cycle");
            if (host_valid && host_ready) begin
                if (expected_telemetry) begin
                    if (!telemetry_ready || result_ready ||
                        host_byte !== (8'h80 + expected_index))
                        $fatal(1,"P49 corrupted/incorrect telemetry byte");
                    if (expected_index == 31) begin
                        telemetry_frames <= telemetry_frames + 1;
                        expected_telemetry <= 1'b0;
                        expected_index <= 0;
                    end else expected_index <= expected_index + 1'b1;
                end else begin
                    if (!result_ready || telemetry_ready ||
                        host_byte !== (8'h40 + expected_index))
                        $fatal(1,"P49 corrupted/incorrect result byte");
                    if (expected_index == 15) begin
                        result_frames <= result_frames + 1;
                        expected_telemetry <= 1'b1;
                        expected_index <= 0;
                    end else expected_index <= expected_index + 1'b1;
                end
            end
        end
    end

    initial begin
        rst_n=1'b0;
        result_valid=1'b1;
        telemetry_valid=1'b1;
        host_ready=1'b0;
        repeat (3) @(negedge clk);
        rst_n=1'b1;
        // Deterministic stalls must not change packet order or bytes.
        for (int i=0; i<600; i++) begin
            @(negedge clk);
            host_ready = ((i%7)!=0) && ((i%13)!=0);
        end
        @(negedge clk);
        host_ready=0;
        if (result_frames < 4 || telemetry_frames < 4)
            $fatal(1, "P49 sustained both-lane fairness not demonstrated");
        $display("P49 FAIR ARBITER TB PASS result_frames=%0d telemetry_frames=%0d",
                 result_frames, telemetry_frames);
        $finish;
    end
endmodule
