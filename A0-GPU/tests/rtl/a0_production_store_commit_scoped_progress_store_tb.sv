`timescale 1ns/1ps

// STORE-only tests; typed READ/WB traffic has a separate end-to-end testbench.
module a0_production_store_commit_scoped_progress_store_tb #(
    parameter integer MODE = 0,
    parameter integer GEN = 5,
    parameter integer MSR = 2,
    parameter integer TO = 64
);
    localparam integer C=1, LT=1, CP=2, LANES=2, LW=1;
    localparam integer SRW=(MSR<1)?1:$clog2(MSR+1);
    localparam integer LOW=2+SRW, SAID=GEN+LOW;
    localparam integer TW=(TO<=1)?1:$clog2(TO);
    logic clk, rst_n;
    logic [C-1:0] client_store_conflict_o;
    logic [CP-1:0] commit_read_wait_o;
    initial clk=0;
    always #5 clk=~clk;
    logic [CP-1:0] commit_valid_i,commit_ready_o,commit_abort_o;
    logic [LANES-1:0] commit_lane_mask_i[0:CP-1];
    logic [31:0] commit_word_addr_i[0:CP-1][0:LANES-1];
    logic [31:0] commit_wdata_i[0:CP-1][0:LANES-1];
    logic [C-1:0] client_req_valid_i,client_req_ready_o,client_resp_valid_o;
    logic [LT-1:0] client_req_local_tag_i[0:C-1];
    logic [31:0] client_req_line_addr_i[0:C-1];
    logic backend_cmd_valid_o,backend_cmd_ready_i;
    logic [1:0] backend_cmd_kind_o;
    logic [SAID-1:0] backend_cmd_store_attempt_id_o,backend_store_status_attempt_id_i;
    logic [31:0] backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o;
    logic backend_store_status_valid_i,backend_store_status_success_i;
    logic backend_store_status_retryable_i,backend_store_status_reuse_safe_i;
    logic backend_store_all_generations_quiescent_i;
    logic [31:0] backend_read_resp_data_i[0:LW-1];
    logic [0:0] dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o;
    logic [0:0] wb_pending_count_o,wb_active_count_o;
    logic store_completion_busy_o,commit_visibility_busy_o,store_terminal_failure_o;
    logic line_resp_tag_error_o,line_resp_overflow_o;
    logic [SRW-1:0] store_retry_count_o,commit_fault_store_retry_count_o;
    logic store_status_timeout_live_o,store_status_timeout_pulse_o,store_status_timeout_seen_o;
    logic [TW-1:0] store_status_timeout_age_o;
    logic commit_fault_valid_o,commit_fault_ready_i,commit_fault_store_timeout_o;
    logic [0:0] commit_fault_port_id_o;
    logic [LANES-1:0] commit_fault_lane_mask_o;
    logic [31:0] commit_fault_word_addr_o[0:LANES-1],commit_fault_wdata_o[0:LANES-1];
    logic recovery_required_o,recovery_rearm_pulse_o,recovery_drain_active_o,protocol_error_o;
    logic [GEN-1:0] store_generation_next_o;
    logic store_generation_wrap_pending_o,store_status_rejected_o,recovery_reset_blocked_o;
    logic [0:0] client_read_outstanding_o;
    // These payloads are semantically unused in a STORE-only test (any READ
    // response is fatal). The companion memory TB checks the real typed paths.
    logic [LT-1:0] unused_read_local_tag[0:C-1];
    logic [31:0] unused_read_line[0:C-1],unused_read_data[0:C-1][0:LW-1];
    logic unused_read_fault[0:C-1];
    logic [2:0] unused_cmd_read_tag,unused_cmd_wb_id;
    logic [31:0] unused_cmd_line,unused_cmd_line_data[0:LW-1];
    logic [0:0] wb_retry_count_o[0:0],recovery_complete_pulse_o,backend_wb_recovery_safe_ready_o;

    a0_production_store_commit_scoped_progress_subsystem #(
        .CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(1),
        .COMMIT_PORT_COUNT(CP),.STORE_LANES(LANES),.SLICE_COUNT(1),.LINE_WORDS(LW),
        .SET_COUNT_PER_SLICE(1),.WRITE_ID_W(1),.MAX_WB_RETRIES(0),
        .STORE_WRITE_ID_W(2),.MAX_STORE_RETRIES(MSR),.STORE_GENERATION_W(GEN),
        .STORE_STATUS_TIMEOUT_CYCLES(TO)
    ) dut (
        .client_resp_local_tag_o(unused_read_local_tag),.client_resp_line_addr_o(unused_read_line),
        .client_resp_fault_o(unused_read_fault),.client_resp_data_o(unused_read_data),
        .backend_cmd_read_tag_o(unused_cmd_read_tag),.backend_cmd_wb_attempt_id_o(unused_cmd_wb_id),
        .backend_cmd_line_addr_o(unused_cmd_line),.backend_cmd_data_o(unused_cmd_line_data),
        .backend_read_resp_valid_i(1'b0),.backend_read_resp_tag_i(3'b0),
        .backend_read_resp_line_addr_i(32'b0),.backend_read_resp_fault_i(1'b0),
        .backend_wb_status_valid_i(1'b0),.backend_wb_status_attempt_id_i(3'b0),
        .backend_wb_status_success_i(1'b0),.backend_wb_status_retryable_i(1'b0),
        .backend_wb_recovery_safe_valid_i(1'b0),.*
    );

    integer issues,successes,aborts,faults,rearms,timeouts;
    logic [SAID-1:0] history[0:63];
    logic [63:0] replayable;
    logic backend_model_all_drained;
    logic [SAID-1:0] active_id;
    logic [0:0] current_port;
    logic previous_rearm;

    always @(posedge clk) begin
        if(!rst_n) begin
            issues<=0;successes<=0;aborts<=0;faults<=0;rearms<=0;timeouts<=0;
            replayable<=0;previous_rearm<=0;
        end else begin
            if ((|(client_req_valid_i&client_req_ready_o&client_store_conflict_o))
                || (|(commit_ready_o&commit_read_wait_o)))
                $fatal(1,"P33 protected resource crossed an admission/commit fence");
            if(protocol_error_o || line_resp_tag_error_o || line_resp_overflow_o)
                $fatal(1,"P33 unexpected protocol error");
            if((|dirty_present_o)||(|wb_busy_o)||(|wb_terminal_failure_o)||
               (|recovery_active_o)||wb_pending_count_o!=0||wb_active_count_o!=0||
               (|client_resp_valid_o)||client_read_outstanding_o!=0||wb_retry_count_o[0]!=0||
               (|recovery_complete_pulse_o)||(|backend_wb_recovery_safe_ready_o))
                $fatal(1,"P33 STORE-only case changed line subsystem");
            if((|commit_ready_o)&&(|commit_abort_o)) $fatal(1,"P33 success/abort overlap");
            if(backend_cmd_valid_o&&backend_cmd_ready_i) begin
                if(backend_cmd_kind_o!=2'b10 || issues>=64)
                    $fatal(1,"P33 wrong kind/history overflow");
                for(integer h=0;h<issues;h=h+1)
                    if(replayable[h]&&history[h]==backend_cmd_store_attempt_id_o)
                        $fatal(1,"P33 reused non-quiescent full identity");
                history[issues]<=backend_cmd_store_attempt_id_o;
                replayable[issues]<=1'b1;
                issues<=issues+1;
            end
            if(backend_model_all_drained) replayable<=0;
            if(!$onehot0(commit_valid_i&commit_ready_o)||!$onehot0(commit_valid_i&commit_abort_o))
                $fatal(1,"P33 multiple simultaneous commit acknowledgments");
            successes<=successes+$countones(commit_valid_i&commit_ready_o);
            aborts<=aborts+$countones(commit_valid_i&commit_abort_o);
            if(commit_fault_valid_o&&commit_fault_ready_i) faults<=faults+1;
            if(recovery_rearm_pulse_o) begin
                if(previous_rearm) $fatal(1,"P33 multi-cycle rearm");
                rearms<=rearms+1;
            end
            if(store_status_timeout_pulse_o) timeouts<=timeouts+1;
            previous_rearm<=recovery_rearm_pulse_o;
        end
    end

    task automatic step;
        @(posedge clk); #1; @(negedge clk);
    endtask
    task automatic drive(input integer port,input logic[31:0] addr,input logic[31:0] data);
        if(port<0||port>=CP) $fatal(1,"P33 invalid drive port");
        current_port=1'(port);
        commit_valid_i[port]=1;
        commit_lane_mask_i[port]=2'b01;
        for(integer l=0;l<LANES;l=l+1) begin
            commit_word_addr_i[port][l]=addr+32'(l);
            commit_wdata_i[port][l]=data+32'(l);
        end
    endtask
    task automatic wait_command(input integer stall);
        integer n;
        logic [GEN-1:0] generation;
        n=0;
        while(!backend_cmd_valid_o&&n<64) begin step(); n=n+1; end
        if(!backend_cmd_valid_o||backend_cmd_kind_o!=2'b10) $fatal(1,"P33 bounded STORE wait");
        active_id=backend_cmd_store_attempt_id_o;
        generation=store_generation_next_o;
        for(integer s=0;s<stall;s=s+1) begin
            if(backend_cmd_store_word_addr_o!=commit_word_addr_i[current_port][0]||
               backend_cmd_store_wdata_o!=commit_wdata_i[current_port][0]||
               backend_cmd_store_attempt_id_o!=active_id||store_generation_next_o!=generation||
               !backend_cmd_valid_o||store_status_timeout_live_o||store_status_timeout_age_o!=0)
                $fatal(1,"P33 backpressure payload/id/timer instability");
            step();
        end
    endtask
    task automatic accept_command;
        integer before_issue;
        before_issue=issues;
        backend_cmd_ready_i=1;
        step();
        backend_cmd_ready_i=0;
        if(issues!=before_issue+1) $fatal(1,"P33 command not accepted exactly once");
    endtask
    task automatic send_status(input logic[SAID-1:0] id,input logic good,input logic retryable);
        backend_store_status_valid_i=1;
        backend_store_status_attempt_id_i=id;
        backend_store_status_success_i=good;
        backend_store_status_retryable_i=retryable;
        step();
        backend_store_status_valid_i=0;
        backend_store_status_success_i=0;
        backend_store_status_retryable_i=0;
    endtask
    task automatic retire(input integer before_success);
        integer n;
        n=0;
        while(successes==before_success&&n<64) begin step();n=n+1;end
        if(successes!=before_success+1||commit_fault_valid_o||store_terminal_failure_o)
            $fatal(1,"P33 current SUCCESS retirement");
        commit_valid_i[current_port]=0;
        repeat(2)step();
        if(successes!=before_success+1) $fatal(1,"P33 double retirement");
    endtask
    task automatic success_word(input integer port,input logic[31:0] addr);
        integer base;
        base=successes;
        drive(port,addr,32'h3030_1000+addr);
        wait_command(3);
        accept_command();
        send_status(active_id,1,0);
        retire(base);
    endtask
    task automatic take_fault(input logic expected_timeout,input logic[SRW-1:0] expected_retries);
        integer n,base_abort,base_fault,base_success;
        n=0;base_abort=aborts;base_fault=faults;base_success=successes;
        while(!commit_fault_valid_o&&n<64) begin step();n=n+1;end
        if(!commit_fault_valid_o) $fatal(1,"P33 bounded fault wait");
        repeat(3)begin
            if(commit_fault_port_id_o!=1'(current_port)||
               commit_fault_lane_mask_o!=commit_lane_mask_i[current_port]||
               commit_fault_store_timeout_o!=expected_timeout||
               commit_fault_store_retry_count_o!=SRW'(expected_retries)||
               (|commit_ready_o)||(|commit_abort_o)||!store_terminal_failure_o)
                $fatal(1,"P33 held fault metadata or success/abort separation");
            for(integer l=0;l<LANES;l=l+1)
                if(commit_fault_word_addr_o[l]!=commit_word_addr_i[current_port][l]||
                   commit_fault_wdata_o[l]!=commit_wdata_i[current_port][l])
                    $fatal(1,"P33 fault payload identity");
            step();
        end
        commit_fault_ready_i=1;step();commit_fault_ready_i=0;
        if(aborts!=base_abort+1||faults!=base_fault+1||successes!=base_success||!recovery_required_o)
            $fatal(1,"P33 abort handshake accounting");
        // Aborted source must withdraw; a distinct pending port need not.
        backend_store_status_reuse_safe_i=1;
        
        repeat(2)step();
        if(recovery_rearm_pulse_o||!recovery_reset_blocked_o)
            $fatal(1,"P33 rearm before aborted source withdrawal");
        backend_store_status_reuse_safe_i=0;
        commit_valid_i[current_port]=0;
    endtask
    task automatic recover;
        integer base,n;
        logic [GEN-1:0] generation;
        base=rearms;generation=store_generation_next_o;
        repeat(2)step();
        if(!recovery_required_o||rearms!=base) $fatal(1,"P33 early proof remembered");
        backend_store_status_reuse_safe_i=1;
        n=0;
        while(rearms==base&&n<64) begin step();n=n+1;end
        backend_store_status_reuse_safe_i=0;
        n=0;
        while(recovery_required_o&&n<64) begin step();n=n+1;end
        if(rearms!=base+1||recovery_required_o||recovery_rearm_pulse_o||recovery_drain_active_o
           ||store_generation_next_o!=generation)
            $fatal(1,"P33 STORE-only reset or persistent generation contract");
    endtask
    task automatic stale_history;
        integer base_success,base_abort,base_issues;
        logic [SRW-1:0] retry_count;
        base_success=successes;base_abort=aborts;base_issues=issues;retry_count=store_retry_count_o;
        for(integer h=0;h<issues-1;h=h+1) begin
            if(replayable[h]) begin
                send_status(history[h],1,0);
                send_status(history[h],0,0);
                send_status(history[h],0,1);
                if(successes!=base_success||aborts!=base_abort||issues!=base_issues||
                   store_retry_count_o!=retry_count||commit_fault_valid_o||(|commit_ready_o))
                    $fatal(1,"P33 old status affected fresh attempt");
            end
        end
        if(!store_status_rejected_o) $fatal(1,"P33 stale diagnostic not observed");
    endtask

    initial begin : scenarios
        integer base;
        logic [5:0] old_index;
        logic [SAID-1:0] first_retry_id;
        rst_n=0;current_port=0;backend_model_all_drained=0;
        client_req_valid_i=0;client_req_local_tag_i[0]=0;client_req_line_addr_i[0]=0;
        commit_valid_i=0;
        for(integer p=0;p<CP;p=p+1) begin
            commit_lane_mask_i[p]=0;
            for(integer l=0;l<LANES;l=l+1) begin commit_word_addr_i[p][l]=0;commit_wdata_i[p][l]=0;end
        end
        backend_cmd_ready_i=0;backend_store_status_valid_i=0;backend_store_status_attempt_id_i=0;
        backend_store_status_success_i=0;backend_store_status_retryable_i=0;
        backend_store_status_reuse_safe_i=0;backend_store_all_generations_quiescent_i=0;
        backend_read_resp_data_i[0]=0;commit_fault_ready_i=0;
        repeat(3)step();rst_n=1;step();
        if(client_req_ready_o!=0||commit_visibility_busy_o||store_completion_busy_o)
            $fatal(1,"P33 initial idle contract");
        if(MODE==0) begin
            success_word(0,32'h80);
            // Local STORE reset may reuse low bits; the persistent full generation must not alias.
            drive(0,32'h100,32'ha030_0100);wait_command(4);accept_command();
            old_index=0;send_status(active_id,0,0);take_fault(0,0);
            // A legal second port remains pending across the other port's abort.
            drive(1,32'h200,32'ha030_0200);recover();wait_command(4);
            if(active_id[LOW-1:0]!=history[old_index][LOW-1:0]||active_id==history[old_index])
                $fatal(1,"P33 directed low-id collision setup");
            base=successes;
            backend_store_status_valid_i=1;backend_store_status_attempt_id_i=history[old_index];
            backend_store_status_success_i=1;accept_command();backend_store_status_valid_i=0;
            backend_store_status_success_i=0;
            if(successes!=base||(|commit_ready_o)) $fatal(1,"P33 same-cycle stale SUCCESS");
            stale_history();send_status(active_id,1,0);retire(base);
            $display("PROD_SEAM_P33_FIRST_RECOVERY_ALIAS_CONTAINED=PASS");
            $display("PROD_SEAM_P33_OTHER_PENDING_PORT_PRESERVED=PASS");
            drive(1,32'h300,32'ha030_0300);wait_command(4);accept_command();
            send_status(active_id,0,0);take_fault(0,0);recover();
            base=successes;drive(0,32'h400,32'ha030_0400);wait_command(3);
            backend_store_status_valid_i=1;backend_store_status_attempt_id_i=history[0];
            backend_store_status_success_i=0;backend_store_status_retryable_i=1;
            accept_command();backend_store_status_valid_i=0;backend_store_status_retryable_i=0;
            stale_history();send_status(active_id,1,0);retire(base);
            if(rearms!=2||aborts!=2||faults!=2) $fatal(1,"P33 repeated recovery counts");
            $display("PROD_SEAM_P33_REPEATED_RECOVERY_HISTORY=PASS");
            $display("PROD_SEAM_P33_SAME_CYCLE_OLD_SUCCESS_FAILURE=PASS");
            base=successes;drive(1,32'h500,32'ha030_0500);wait_command(5);
            first_retry_id=active_id;
            backend_store_status_valid_i=1;backend_store_status_attempt_id_i=active_id;
            backend_store_status_success_i=0;backend_store_status_retryable_i=1;
            accept_command();backend_store_status_valid_i=0;backend_store_status_retryable_i=0;
            wait_command(5);
            if(active_id==first_retry_id||store_retry_count_o!=SRW'(1)) $fatal(1,"P33 retry identity");
            accept_command();send_status(first_retry_id,1,0);
            if(successes!=base||(|commit_ready_o)) $fatal(1,"P33 stale retry success");
            send_status(active_id,1,0);retire(base);
            $display("PROD_SEAM_P33_RETRY_BACKPRESSURE_PAYLOAD=PASS");
            // Both enabled lanes must complete before the one commit retires.
            base=successes;drive(0,32'h600,32'ha030_0600);commit_lane_mask_i[0]=2'b11;
            wait_command(1);accept_command();send_status(active_id,1,0);
            if(successes!=base) $fatal(1,"P33 first lane prematurely retired");
            begin : lane_two
                integer n;
                n=0;while(!backend_cmd_valid_o&&n<64)begin step();n=n+1;end
                if(!backend_cmd_valid_o||backend_cmd_store_word_addr_o!=32'h601||
                   backend_cmd_store_wdata_o!=32'ha030_0601) $fatal(1,"P33 second lane payload");
                active_id=backend_cmd_store_attempt_id_o;
            end
            accept_command();send_status(active_id,1,0);retire(base);
            $display("PROD_SEAM_P33_MULTILANE_SUCCESS_ONLY_RETIRE=PASS");
            // A terminal first miss aborts the captured commit. The untouched
            // second miss must not be issued during or after local rearm.
            begin : abort_remaining_lanes
                integer issued_before_rearm,abort_before;
                base=successes;abort_before=aborts;
                drive(1,32'h700,32'ha031_0700);commit_lane_mask_i[1]=2'b11;
                wait_command(3);accept_command();issued_before_rearm=issues;
                send_status(active_id,0,0);take_fault(0,0);recover();
                repeat(5)step();
                if(issues!=issued_before_rearm||successes!=base||aborts!=abort_before+1||
                   backend_cmd_valid_o||store_completion_busy_o||commit_visibility_busy_o)
                    $fatal(1,"P33 aborted remaining miss lane issued or fabricated retirement");
                success_word(0,32'h800);
                if(issues!=issued_before_rearm+1||successes!=base+1||aborts!=abort_before+1)
                    $fatal(1,"P33 fresh commit replayed cancelled miss lane");
            end
            $display("PROD_SEAM_P33_ABORT_CANCELS_ONLY_REMAINING_STORE_MISSES=PASS");
        end else if(MODE==1) begin
            if(GEN>3) $fatal(1,"P33 wrap test bounded generation width required");
            backend_store_all_generations_quiescent_i=1;step();backend_store_all_generations_quiescent_i=0;
            for(integer k=0;k<(1<<GEN);k=k+1) success_word(0,32'h100+32'(k));
            if(!store_generation_wrap_pending_o) $fatal(1,"P33 wrap barrier missing");
            base=issues;drive(1,32'h200,32'ha030_0200);backend_cmd_ready_i=1;
            backend_store_status_reuse_safe_i=1;
            repeat(5)begin step();if(backend_cmd_valid_o||issues!=base||store_status_timeout_live_o)
                $fatal(1,"P33 exhausted namespace issued or started timeout");end
            backend_store_status_reuse_safe_i=0;backend_cmd_ready_i=0;
            for(integer h=0;h<issues;h=h+1)begin send_status(history[h],1,0);send_status(history[h],0,1);end
            if(!store_generation_wrap_pending_o||commit_fault_valid_o||(|commit_ready_o))
                $fatal(1,"P33 pending-wrap late status handling");
            // Backend model now drains EVERY historical status; none may be replayed after this proof.
            backend_model_all_drained=1;step();backend_model_all_drained=0;
            backend_store_all_generations_quiescent_i=1;step();backend_store_all_generations_quiescent_i=0;
            if(store_generation_wrap_pending_o||store_generation_next_o!=0) $fatal(1,"P33 safe wrap not performed");
            base=successes;wait_command(3);accept_command();send_status(active_id,1,0);retire(base);
            $display("PROD_SEAM_P33_TRUTHFUL_ALL_GENERATION_WRAP=PASS");
        end else if(MODE==2) begin
            if(TO!=1||MSR!=0) $fatal(1,"P33 deadline parameters");
            // Same-cycle matching status allocates and retires without a ghost live slot.
            base=successes;drive(0,32'h80,32'ha030_0080);wait_command(4);
            backend_store_status_valid_i=1;backend_store_status_attempt_id_i=active_id;
            backend_store_status_success_i=1;accept_command();backend_store_status_valid_i=0;
            backend_store_status_success_i=0;retire(base);
            if(store_status_timeout_live_o||timeouts!=0) $fatal(1,"P33 samecycle live ghost");
            base=successes;drive(0,32'h100,32'ha030_0100);wait_command(4);accept_command();
            send_status(active_id,1,0);retire(base);
            if(timeouts!=0) $fatal(1,"P33 current matching deadline lost");
            drive(1,32'h200,32'ha030_0200);wait_command(4);accept_command();
            send_status(history[0],1,0);take_fault(1,0);
            if(!store_status_timeout_seen_o||timeouts!=1) $fatal(1,"P33 stale deadline masked timeout");
            recover();base=successes;drive(0,32'h300,32'ha030_0300);wait_command(2);
            accept_command();send_status(active_id,1,0);retire(base);
            // A matching terminal FAILURE on the accepting edge is never success,
            // and it must retain backend-failure (not timeout) provenance.
            drive(1,32'h400,32'ha030_0400);wait_command(2);
            backend_store_status_valid_i=1;backend_store_status_attempt_id_i=active_id;
            backend_store_status_success_i=0;backend_store_status_retryable_i=0;
            accept_command();backend_store_status_valid_i=0;
            take_fault(0,0);recover();
            $display("PROD_SEAM_P33_DEADLINE_PROVENANCE_AND_SAME_CYCLE_MATCH=PASS");
        end else $fatal(1,"P33 invalid test mode");
        if(protocol_error_o||(|commit_ready_o)||(|commit_abort_o)||commit_fault_valid_o||
           store_status_timeout_live_o||recovery_required_o) $fatal(1,"P33 final idle");
        $display("PROD_SEAM_P33_STORE_BEHAVIOR=PASS mode=%0d issues=%0d success=%0d abort=%0d rearm=%0d",MODE,issues,successes,aborts,rearms);
        $finish;
    end
endmodule

