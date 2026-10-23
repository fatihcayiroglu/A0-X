`timescale 1ns/1ps
module a0_store_word_completion_guard_tb;
    localparam integer WID=3, MR=1, RW=1, AID=WID+RW;
    logic clk,rst_n;
    logic store_valid_i,store_ready_o;
    logic [31:0] store_word_addr_i,store_wdata_i;
    logic backend_store_valid_o,backend_store_ready_i;
    logic [AID-1:0] backend_store_attempt_id_o;
    logic [31:0] backend_store_word_addr_o,backend_store_wdata_o;
    logic backend_store_status_valid_i;
    logic [AID-1:0] backend_store_status_attempt_id_i;
    logic backend_store_status_success_i,backend_store_status_retryable_i;
    logic busy_o,terminal_failure_o,protocol_error_o;
    logic [RW-1:0] retry_count_o;

    a0_store_word_completion_guard #(.WRITE_ID_W(WID),.MAX_RETRIES(MR)) dut(.*);
    initial clk=0; always #5 clk=~clk;

    task automatic clear_inputs;
        begin
            store_valid_i=0; store_word_addr_i='0; store_wdata_i='0;
            backend_store_ready_i=0; backend_store_status_valid_i=0;
            backend_store_status_attempt_id_i='0; backend_store_status_success_i=0;
            backend_store_status_retryable_i=0;
        end
    endtask
    task automatic reset_dut;
        begin
            rst_n=0; clear_inputs(); repeat(3) @(posedge clk);
            @(negedge clk); rst_n=1; #1;
        end
    endtask
    task automatic start_store(input logic [31:0] addr,input logic [31:0] data);
        begin
            @(negedge clk); store_valid_i=1; store_word_addr_i=addr; store_wdata_i=data; #1;
            while(!backend_store_valid_o) begin @(posedge clk); @(negedge clk); #1; end
        end
    endtask
    task automatic send_status(input logic [AID-1:0] id,input logic ok,input logic retryable);
        begin
            @(negedge clk); backend_store_status_valid_i=1;
            backend_store_status_attempt_id_i=id; backend_store_status_success_i=ok;
            backend_store_status_retryable_i=retryable; #1; @(posedge clk); #1;
            @(negedge clk); backend_store_status_valid_i=0; backend_store_status_success_i=0;
            backend_store_status_retryable_i=0; #1;
        end
    endtask

    initial begin
        logic [AID-1:0] id0,id1,id2;
        logic [31:0] held_addr,held_data;
        reset_dut();

        start_store(32'h0000_0044,32'hA5A5_2601);
        held_addr=backend_store_word_addr_o; held_data=backend_store_wdata_o;
        id0=backend_store_attempt_id_o;
        repeat(2) begin
            @(posedge clk); #1;
            if(!backend_store_valid_o || backend_store_word_addr_o!=held_addr
               || backend_store_wdata_o!=held_data || store_ready_o)
                $fatal(1,"P26 store issue backpressure instability");
        end
        $display("PROD_SEAM_P26_STORE_ATTEMPT_BACKPRESSURE_STABLE=PASS");

        @(negedge clk); backend_store_ready_i=1; #1; @(posedge clk); #1;
        @(negedge clk); backend_store_ready_i=0; #1;
        repeat(2) begin @(posedge clk); #1; if(store_ready_o)$fatal(1,"P26 accepted store acknowledged early"); end
        $display("PROD_SEAM_P26_ACCEPT_ALONE_NO_SOURCE_ACK=PASS");

        send_status(id0,1'b0,1'b1);
        while(!backend_store_valid_o) begin @(posedge clk); #1; end
        id1=backend_store_attempt_id_o;
        if(id1==id0 || backend_store_word_addr_o!=held_addr || backend_store_wdata_o!=held_data
           || retry_count_o!=RW'(1)) $fatal(1,"P26 retry identity/payload");
        $display("PROD_SEAM_P26_RETRY_EXACT_PAYLOAD_NEW_ATTEMPT=PASS");

        // Second attempt is accepted and succeeds in that same cycle.
        @(negedge clk); backend_store_ready_i=1; backend_store_status_valid_i=1;
        backend_store_status_attempt_id_i=id1; backend_store_status_success_i=1;
        backend_store_status_retryable_i=0; #1;
        if(!store_ready_o)$fatal(1,"P26 same-cycle success did not release source");
        @(posedge clk); #1; @(negedge clk);
        store_valid_i=0; backend_store_ready_i=0; backend_store_status_valid_i=0;
        backend_store_status_success_i=0; #1;
        if(busy_o || terminal_failure_o || protocol_error_o)$fatal(1,"P26 success drain");
        $display("PROD_SEAM_P26_SAME_CYCLE_ACCEPT_SUCCESS=PASS");
        $display("PROD_SEAM_P26_MATCHING_SUCCESS_ONLY_RELEASE=PASS");

        // Stale/unknown status is diagnosed and cannot release the source.
        start_store(32'h0000_0050,32'hB6B6_2602); id2=backend_store_attempt_id_o;
        @(negedge clk); backend_store_ready_i=1; #1; @(posedge clk); #1;
        @(negedge clk); backend_store_ready_i=0;
        backend_store_status_valid_i=1; backend_store_status_attempt_id_i=id2+ AID'(1);
        backend_store_status_success_i=1; #1;
        if(store_ready_o || !protocol_error_o || terminal_failure_o)$fatal(1,"P26 stale status containment");
        @(posedge clk); #1;
        $display("PROD_SEAM_P26_STALE_STATUS_CONTAINED=PASS");

        // Reset clears the deliberate protocol-error injection; then prove retry exhaustion fails closed.
        reset_dut();
        start_store(32'h0000_0060,32'hC7C7_2603); id0=backend_store_attempt_id_o;
        @(negedge clk); backend_store_ready_i=1; #1; @(posedge clk); #1;
        @(negedge clk); backend_store_ready_i=0; #1;
        send_status(id0,1'b0,1'b1);
        while(!backend_store_valid_o) begin @(posedge clk); #1; end
        id1=backend_store_attempt_id_o;
        @(negedge clk); backend_store_ready_i=1; #1; @(posedge clk); #1;
        @(negedge clk); backend_store_ready_i=0; #1;
        send_status(id1,1'b0,1'b1);
        if(!terminal_failure_o || store_ready_o || backend_store_valid_o || !busy_o)
            $fatal(1,"P26 retry exhaustion did not fail closed");
        if(protocol_error_o)$fatal(1,"P26 expected terminal failure is not protocol error");
        $display("PROD_SEAM_P26_RETRY_EXHAUSTION_FAIL_CLOSED=PASS");
        $display("PROD_SEAM_P26_GUARD_BEHAVIOR=PASS");
        $finish;
    end
endmodule
