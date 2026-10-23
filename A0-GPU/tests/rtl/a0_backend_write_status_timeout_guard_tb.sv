`timescale 1ns/1ps
module a0_backend_write_status_timeout_guard_tb;
    localparam integer ID_W=5;
    localparam integer TO=3;
    localparam integer CW=$clog2(TO);
    logic clk;
    initial clk = 1'b0;
    always #5 clk=~clk;
    logic rst_n;
    logic issue_fire;
    logic [ID_W-1:0] issue_id;
    logic st_v;
    logic [ID_W-1:0] st_id;
    logic st_success, st_retry;
    logic o_v;
    logic [ID_W-1:0] o_id;
    logic o_success,o_retry;
    logic timeout_pulse, timeout_seen, live;
    logic [CW-1:0] count;
    integer timeout_count;

    a0_backend_write_status_timeout_guard #(
        .ATTEMPT_ID_W(ID_W), .STATUS_TIMEOUT_CYCLES(TO)
    ) dut (
        .clk(clk),.rst_n(rst_n),
        .write_issue_fire_i(issue_fire),.write_issue_attempt_id_i(issue_id),
        .backend_status_valid_i(st_v),.backend_status_attempt_id_i(st_id),
        .backend_status_success_i(st_success),.backend_status_retryable_i(st_retry),
        .p13_status_valid_o(o_v),.p13_status_attempt_id_o(o_id),
        .p13_status_success_o(o_success),.p13_status_retryable_o(o_retry),
        .timeout_pulse_o(timeout_pulse),.timeout_seen_o(timeout_seen),
        .watchdog_live_o(live),.watchdog_count_o(count)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) timeout_count <= 0;
        else if (timeout_pulse) timeout_count <= timeout_count + 1;
    end

    task automatic reset_dut;
        begin
            @(negedge clk); rst_n=0; issue_fire=0; issue_id='0;
            st_v=0; st_id='0; st_success=0; st_retry=0;
            repeat(3) @(posedge clk);
            @(negedge clk); rst_n=1; repeat(1) @(posedge clk); #1;
        end
    endtask

    task automatic issue(input logic [ID_W-1:0] id);
        begin
            @(negedge clk); issue_id=id; issue_fire=1;
            @(posedge clk); #1;
            @(negedge clk); issue_fire=0;
        end
    endtask

    task automatic status(input logic [ID_W-1:0] id,input logic succ,input logic retry);
        begin
            @(negedge clk); st_id=id; st_success=succ; st_retry=retry; st_v=1;
            @(posedge clk); #1;
            @(negedge clk); st_v=0; st_success=0; st_retry=0;
        end
    endtask

    initial begin
        rst_n=0; issue_fire=0; issue_id='0; st_v=0; st_id='0; st_success=0; st_retry=0;
        reset_dut();

        // Exact same-cycle SUCCESS passes through and never arms watchdog.
        @(negedge clk); issue_id=5'h03; issue_fire=1; st_v=1; st_id=5'h03; st_success=1; st_retry=0; #1;
        if (!(o_v && o_id==5'h03 && o_success && !o_retry)) $fatal(1,"samecycle exact status not passed");
        @(posedge clk); #1;
        if (live || timeout_pulse) $fatal(1,"samecycle exact status armed watchdog");
        @(negedge clk); issue_fire=0; st_v=0; st_success=0;
        $display("PROD_SEAM_P14_SAMECYCLE_EXACT_STATUS=PASS");

        // Lost attempt: stale status must pass through but not reset timer.
        issue(5'h09);
        if (!live || count!=0) $fatal(1,"watchdog did not arm");
        @(posedge clk); #1;
        if (!live || count!=1) $fatal(1,"watchdog count step1 bad");
        @(negedge clk); st_v=1; st_id=5'h08; st_success=1; st_retry=0; #1;
        if (!(o_v && o_id==5'h08 && o_success && !o_retry)) $fatal(1,"stale status not preserved");
        @(posedge clk); #1;
        if (!live || count!=2) $fatal(1,"stale status reset watchdog");
        @(negedge clk); st_v=0; st_success=0; #1;
        if (!(timeout_pulse && o_v && o_id==5'h09 && !o_success && o_retry)) $fatal(1,"timeout retry event bad");
        $display("PROD_SEAM_P14_STALE_STATUS_DOES_NOT_RESET=PASS");
        $display("PROD_SEAM_P14_LOST_STATUS_SYNTH_RETRYABLE=PASS");
        @(posedge clk); #1;
        if (live) $fatal(1,"watchdog did not clear after timeout");
        if (timeout_count!=1 || !timeout_seen) $fatal(1,"timeout accounting bad");
        @(negedge clk); #1;
        if (o_v || timeout_pulse) $fatal(1,"timeout duplicated");
        $display("PROD_SEAM_P14_TIMEOUT_EXACTLY_ONCE=PASS");
        $display("PROD_SEAM_P14_NO_SYNTHETIC_SUCCESS=PASS");

        // Retry incarnation gets an independent watchdog and real retryable status passes.
        issue(5'h19);
        if (!live || count!=0) $fatal(1,"retry watchdog not rearmed");
        status(5'h19,0,1);
        if (live) $fatal(1,"exact retryable status did not clear watchdog");
        $display("PROD_SEAM_P14_RETRY_ATTEMPT_REARMS_WATCHDOG=PASS");
        $display("PROD_SEAM_P14_REAL_RETRYABLE_PRESERVED=PASS");

        // Real exact SUCCESS on the timeout boundary must win over synthetic timeout.
        issue(5'h11);
        @(posedge clk); #1;
        @(posedge clk); #1;
        if (count!=2) $fatal(1,"did not reach timeout boundary");
        @(negedge clk); st_v=1; st_id=5'h11; st_success=1; st_retry=0; #1;
        if (timeout_pulse) $fatal(1,"timeout beat exact boundary status");
        if (!(o_v && o_success && !o_retry && o_id==5'h11)) $fatal(1,"boundary success not passed");
        @(posedge clk); #1;
        @(negedge clk); st_v=0; st_success=0;
        if (timeout_count!=1) $fatal(1,"boundary exact status created timeout");
        $display("PROD_SEAM_P14_BOUNDARY_REAL_STATUS_WINS=PASS");

        // Unknown status while idle remains visible to frozen P13; watchdog stays idle.
        @(negedge clk); st_v=1; st_id=5'h1f; st_success=0; st_retry=0; #1;
        if (!(o_v && o_id==5'h1f && !o_success && !o_retry)) $fatal(1,"unknown status not preserved");
        if (live || timeout_pulse) $fatal(1,"idle unknown status affected watchdog");
        @(posedge clk); #1; @(negedge clk); st_v=0;
        $display("PROD_SEAM_P14_UNKNOWN_STATUS_PRESERVED_FOR_P13=PASS");
        $display("PROD_SEAM_P14_IDLE_WATCHDOG_NO_SPURIOUS_TIMEOUT=PASS");

        $display("PROD_SEAM_P14_BEHAVIOR=PASS");
        $finish;
    end
endmodule
