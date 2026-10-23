`timescale 1ns/1ps

// P33 ordering through public interfaces only. Backend READs capture memory
// at their accepted command edge. A matching successful physical WB status
// is the only event that updates model memory in these cache-hit STORE cases.
// Each separate cold-reset case first drains every client and backend ledger.
module a0_p33_store_read_order_tb;
    localparam integer C=1, LT=1, OUT=1, CP=1, LANES=1, S=1, LW=2, SETS=1;
    localparam integer WID=2, MWR=1, SWID=2, MSR=1, GEN=8, TO=64;
    localparam integer LAW=31, BRTW=3, BATW=4, SAID=11;
    localparam integer RW=1, SRW=1, CNTW=1, TW=6, PIDW=1, RCW=1;
    localparam integer BOUND=96;
    localparam logic [1:0] K_READ=2'b00, K_WB=2'b01, K_STORE=2'b10;
    // Distinct lines alias the only home/set and cannot coexist in the cache.
    localparam logic [LAW-1:0] A=31'd1, B=31'd3;
    localparam logic [31:0] STORE_ADDR=32'd2;
    localparam logic [31:0] OLD0=32'h0A31_0000, OLD1=32'h0A31_0001;
    localparam logic [31:0] NEW0=32'hCA32_0000;
    localparam logic [31:0] B0=32'h0B32_0000, B1=32'h0B32_0001;

    logic clk, rst_n;
    logic [C-1:0] client_req_valid_i, client_req_ready_o, client_resp_valid_o;
    logic [LT-1:0] client_req_local_tag_i [0:C-1];
    logic [LAW-1:0] client_req_line_addr_i [0:C-1];
    logic [LT-1:0] client_resp_local_tag_o [0:C-1];
    logic [LAW-1:0] client_resp_line_addr_o [0:C-1];
    logic client_resp_fault_o [0:C-1];
    logic [31:0] client_resp_data_o [0:C-1][0:LW-1];
    logic [CP-1:0] commit_valid_i, commit_ready_o, commit_abort_o;
    logic [LANES-1:0] commit_lane_mask_i [0:CP-1];
    logic [31:0] commit_word_addr_i [0:CP-1][0:LANES-1];
    logic [31:0] commit_wdata_i [0:CP-1][0:LANES-1];
    logic backend_cmd_valid_o, backend_cmd_ready_i;
    logic [1:0] backend_cmd_kind_o;
    logic [BRTW-1:0] backend_cmd_read_tag_o;
    logic [BATW-1:0] backend_cmd_wb_attempt_id_o;
    logic [SAID-1:0] backend_cmd_store_attempt_id_o;
    logic [LAW-1:0] backend_cmd_line_addr_o;
    logic [31:0] backend_cmd_data_o [0:LW-1];
    logic [31:0] backend_cmd_store_word_addr_o, backend_cmd_store_wdata_o;
    logic backend_read_resp_valid_i, backend_read_resp_fault_i;
    logic [BRTW-1:0] backend_read_resp_tag_i;
    logic [LAW-1:0] backend_read_resp_line_addr_i;
    logic [31:0] backend_read_resp_data_i [0:LW-1];
    logic backend_wb_status_valid_i, backend_wb_status_success_i, backend_wb_status_retryable_i;
    logic [BATW-1:0] backend_wb_status_attempt_id_i;
    logic backend_store_status_valid_i, backend_store_status_success_i, backend_store_status_retryable_i;
    logic [SAID-1:0] backend_store_status_attempt_id_i;
    logic backend_store_status_reuse_safe_i, backend_store_all_generations_quiescent_i;
    logic [S-1:0] backend_wb_recovery_safe_valid_i, backend_wb_recovery_safe_ready_o;
    logic [S-1:0] dirty_present_o, wb_busy_o, wb_terminal_failure_o;
    logic [S-1:0] recovery_active_o, recovery_complete_pulse_o;
    logic [RW-1:0] wb_retry_count_o [0:S-1];
    logic [CNTW-1:0] wb_pending_count_o, wb_active_count_o;
    logic commit_visibility_busy_o, store_completion_busy_o, store_terminal_failure_o;
    logic [SRW-1:0] store_retry_count_o;
    logic line_resp_tag_error_o, line_resp_overflow_o;
    logic store_status_timeout_live_o, store_status_timeout_pulse_o, store_status_timeout_seen_o;
    logic [TW-1:0] store_status_timeout_age_o;
    logic commit_fault_valid_o, commit_fault_ready_i;
    logic [PIDW-1:0] commit_fault_port_id_o;
    logic [LANES-1:0] commit_fault_lane_mask_o;
    logic [31:0] commit_fault_word_addr_o [0:LANES-1];
    logic [31:0] commit_fault_wdata_o [0:LANES-1];
    logic commit_fault_store_timeout_o;
    logic [SRW-1:0] commit_fault_store_retry_count_o;
    logic recovery_required_o, recovery_rearm_pulse_o, recovery_drain_active_o;
    logic [GEN-1:0] store_generation_next_o;
    logic store_generation_wrap_pending_o, store_status_rejected_o, recovery_reset_blocked_o;
    logic [RCW-1:0] client_read_outstanding_o;
    logic [C-1:0] client_store_conflict_o;
    logic [CP-1:0] commit_read_wait_o;
    logic protocol_error_o;

    integer case_id;
    integer client_req_count, client_resp_count, read_issue_count, read_return_count;
    integer store_issue_count, store_status_count, commit_success_count;
    integer wb_issue_count, wb_status_count, old_read_wait_edges;
    integer backend_return_wait_edges, client_return_wait_edges;
    integer alias_request_wait_edges, exact_request_wait_edges;
    logic client_live, backend_read_live, backend_wb_live;
    logic [LT-1:0] live_client_tag;
    logic [LAW-1:0] live_client_line;
    logic [31:0] offered_expected_data [0:LW-1];
    logic [31:0] live_expected_data [0:LW-1];
    logic [BRTW-1:0] captured_read_tag;
    logic [LAW-1:0] captured_read_line, captured_wb_line;
    logic [31:0] captured_read_snapshot [0:LW-1];
    logic [BATW-1:0] captured_wb_id;
    logic [31:0] captured_wb_data [0:LW-1];
    logic [31:0] model_memory [0:1][0:LW-1];
    logic commit_source_wait_q, client_source_wait_q;
    logic [LT+LAW-1:0] held_client_source_q;

    a0_production_store_commit_scoped_progress_subsystem #(
        .CLIENT_COUNT(C), .LOCAL_TAG_W(LT), .CLIENT_MAX_OUTSTANDING(OUT),
        .COMMIT_PORT_COUNT(CP), .STORE_LANES(LANES), .SLICE_COUNT(S),
        .LINE_WORDS(LW), .SET_COUNT_PER_SLICE(SETS), .WRITE_ID_W(WID),
        .MAX_WB_RETRIES(MWR), .STORE_WRITE_ID_W(SWID), .MAX_STORE_RETRIES(MSR),
        .STORE_STATUS_TIMEOUT_CYCLES(TO), .STORE_GENERATION_W(GEN),
        .CLIENT_READ_COUNT_W(RCW)
    ) dut (.*);

    initial clk=1'b0;
    always #5 clk=~clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            client_req_count<=0; client_resp_count<=0; read_issue_count<=0; read_return_count<=0;
            store_issue_count<=0; store_status_count<=0; commit_success_count<=0;
            wb_issue_count<=0; wb_status_count<=0; old_read_wait_edges<=0;
            backend_return_wait_edges<=0; client_return_wait_edges<=0;
            alias_request_wait_edges<=0; exact_request_wait_edges<=0;
            client_live<=1'b0; backend_read_live<=1'b0; backend_wb_live<=1'b0;
            live_client_tag<='0; live_client_line<='0;
            captured_read_tag<='0; captured_read_line<='0;
            captured_wb_id<='0; captured_wb_line<='0;
            model_memory[0][0]<=OLD0; model_memory[0][1]<=OLD1;
            model_memory[1][0]<=B0; model_memory[1][1]<=B1;
            commit_source_wait_q<=1'b0; client_source_wait_q<=1'b0; held_client_source_q<='0;
            for (integer w=0;w<LW;w=w+1) begin
                captured_read_snapshot[w]<='0; captured_wb_data[w]<='0; live_expected_data[w]<='0;
            end
        end else begin
            if (protocol_error_o || line_resp_tag_error_o || line_resp_overflow_o
                || store_terminal_failure_o || (|commit_abort_o)
                || recovery_required_o || recovery_rearm_pulse_o || recovery_drain_active_o
                || recovery_reset_blocked_o || store_generation_wrap_pending_o || store_status_rejected_o)
                $fatal(1,"P33 ordering case=%0d unexpected protocol/fault/recovery diagnostic",case_id);
            if (commit_fault_valid_o)
                $fatal(1,"P33 ordering unexpected architectural fault port=%0d mask=%0h addr=%0h data=%0h timeout=%0b retry=%0d",
                    commit_fault_port_id_o,commit_fault_lane_mask_o,commit_fault_word_addr_o[0],
                    commit_fault_wdata_o[0],commit_fault_store_timeout_o,commit_fault_store_retry_count_o);
            if ((|wb_terminal_failure_o) || (|recovery_active_o)
                || (|recovery_complete_pulse_o) || (|backend_wb_recovery_safe_ready_o))
                $fatal(1,"P33 ordering unexpected WB failure/recovery");
            for (integer s=0;s<S;s=s+1)
                if (wb_retry_count_o[s]!='0) $fatal(1,"P33 ordering unexpected WB retry");
            if (store_completion_busy_o || store_status_timeout_live_o || store_status_timeout_age_o!='0
                || store_status_timeout_seen_o || store_status_timeout_pulse_o || store_retry_count_o!='0
                || store_generation_next_o!='0)
                $fatal(1,"P33 ordering cache-hit STORE reached physical STORE completion/generation state");
            if (integer'(client_read_outstanding_o)!=client_req_count-client_resp_count)
                $fatal(1,"P33 ordering client outstanding output disagrees with accepted-event ledger");
            if (commit_source_wait_q && !commit_valid_i[0])
                $fatal(1,"P33 ordering stimulus withdrew STORE before its actual success edge");
            if (commit_valid_i[0] && (commit_lane_mask_i[0]!=LANES'(1)
                || commit_word_addr_i[0][0]!=STORE_ADDR || commit_wdata_i[0][0]!=NEW0))
                $fatal(1,"P33 ordering held STORE source changed its enabled lane/address/data");
            commit_source_wait_q<=commit_valid_i[0] && !commit_ready_o[0];
            if (client_source_wait_q && (!client_req_valid_i[0]
                || {client_req_local_tag_i[0],client_req_line_addr_i[0]}!=held_client_source_q))
                $fatal(1,"P33 ordering stimulus changed blocked client tag/line/valid");
            client_source_wait_q<=client_req_valid_i[0] && !client_req_ready_o[0];
            if (client_req_valid_i[0] && !client_req_ready_o[0])
                held_client_source_q<={client_req_local_tag_i[0],client_req_line_addr_i[0]};

            if (commit_valid_i[0] && client_live) begin
                if (!commit_read_wait_o[0] || commit_ready_o[0]
                    || (backend_cmd_valid_o && backend_cmd_kind_o==K_STORE))
                    $fatal(1,"P33 ordering STORE crossed an older accepted READ, including its completion edge");
                old_read_wait_edges<=old_read_wait_edges+1;
                if (backend_read_resp_valid_i) backend_return_wait_edges<=backend_return_wait_edges+1;
                if (client_resp_valid_o[0]) client_return_wait_edges<=client_return_wait_edges+1;
            end
            if (commit_read_wait_o[0] && (!commit_valid_i[0] || !client_live))
                $fatal(1,"P33 ordering commit wait has no actual pending STORE/older READ");
            if (commit_valid_i[0] && client_req_valid_i[0]) begin
                if (!client_store_conflict_o[0] || client_req_ready_o[0])
                    $fatal(1,"P33 ordering new conflicting READ accepted while raw STORE remains valid");
                if (client_req_line_addr_i[0]==A) exact_request_wait_edges<=exact_request_wait_edges+1;
                else if (client_req_line_addr_i[0]==B) alias_request_wait_edges<=alias_request_wait_edges+1;
                else $fatal(1,"P33 ordering conflict scenario offered an unmodeled line");
            end
            if (client_store_conflict_o[0] && (!commit_valid_i[0] || !client_req_valid_i[0]))
                $fatal(1,"P33 ordering request conflict has no actual raw source pair");

            if (client_req_valid_i[0] && client_req_ready_o[0]) begin
                if (client_live || (client_req_line_addr_i[0]!=A && client_req_line_addr_i[0]!=B)
                    || client_req_local_tag_i[0]!=LT'(client_req_count))
                    $fatal(1,"P33 ordering invalid/duplicate client request ledger entry");
                client_live<=1'b1; live_client_tag<=client_req_local_tag_i[0];
                live_client_line<=client_req_line_addr_i[0]; client_req_count<=client_req_count+1;
                for (integer w=0;w<LW;w=w+1) live_expected_data[w]<=offered_expected_data[w];
            end
            if (client_resp_valid_o[0]) begin
                if (!client_live || client_resp_local_tag_o[0]!=live_client_tag
                    || client_resp_line_addr_o[0]!=live_client_line || client_resp_fault_o[0])
                    $fatal(1,"P33 ordering unsolicited/misidentified client response");
                for (integer w=0;w<LW;w=w+1)
                    if (client_resp_data_o[0][w]!=live_expected_data[w])
                        $fatal(1,"P33 ordering case=%0d client=%0d tag=%0h line=%0d word=%0d expected=%08x actual=%08x",
                            case_id,client_resp_count,live_client_tag,live_client_line,w,
                            live_expected_data[w],client_resp_data_o[0][w]);
                if (client_resp_count==0 && (read_return_count!=1 || commit_success_count!=0))
                    $fatal(1,"P33 ordering initial READ must deliver OLD before STORE retirement");
                if (client_resp_count>0 && commit_success_count!=1)
                    $fatal(1,"P33 ordering newer READ reached its client before actual STORE success");
                client_live<=1'b0; client_resp_count<=client_resp_count+1;
            end

            if (commit_ready_o[0]) begin
                if (!commit_valid_i[0] || commit_success_count!=0 || client_live || backend_read_live
                    || client_req_count!=1 || client_resp_count!=1 || read_issue_count!=1 || read_return_count!=1
                    || store_issue_count!=0 || store_status_count!=0 || wb_issue_count!=0
                    || model_memory[0][0]!=OLD0 || model_memory[0][1]!=OLD1 || !(|dirty_present_o))
                    $fatal(1,"P33 ordering STORE success was not one real cache-only dirty update after older READ delivery");
                commit_success_count<=commit_success_count+1;
                $display("P33_ORDER_CACHE_HIT_COMMIT case=%0d addr=%0d data=%08x physical_store_issues=%0d",
                    case_id,commit_word_addr_i[0][0],commit_wdata_i[0][0],store_issue_count);
            end

            if (backend_cmd_valid_o && backend_cmd_ready_i) begin
                case (backend_cmd_kind_o)
                    K_READ: begin
                        if (!client_live || backend_read_live || backend_wb_live
                            || backend_cmd_line_addr_o!=live_client_line
                            || backend_cmd_read_tag_o!=BRTW'(live_client_tag)
                            || backend_cmd_wb_attempt_id_o!='0 || backend_cmd_store_attempt_id_o!='0
                            || backend_cmd_store_word_addr_o!='0 || backend_cmd_store_wdata_o!='0
                            || read_issue_count>=3)
                            $fatal(1,"P33 ordering invalid accepted full typed READ identity");
                        if (read_issue_count==0 && (live_client_line!=A || commit_success_count!=0))
                            $fatal(1,"P33 ordering initial physical READ was not cold A");
                        if (read_issue_count==1 && (live_client_line!=B || wb_status_count!=1))
                            $fatal(1,"P33 ordering alias replacement READ preceded actual successful dirty WB");
                        if (read_issue_count==2 && (live_client_line!=A || model_memory[0][0]!=NEW0
                            || model_memory[0][1]!=OLD1 || wb_status_count!=1))
                            $fatal(1,"P33 ordering final external A refill did not snapshot the successful WB data");
                        for (integer w=0;w<LW;w=w+1) begin
                            if (backend_cmd_data_o[w]!='0) $fatal(1,"P33 ordering READ carried WB payload");
                            captured_read_snapshot[w]<=model_memory[(backend_cmd_line_addr_o==A)?0:1][w];
                        end
                        backend_read_live<=1'b1; captured_read_tag<=backend_cmd_read_tag_o;
                        captured_read_line<=backend_cmd_line_addr_o; read_issue_count<=read_issue_count+1;
                    end
                    K_WB: begin
                        if (!client_live || live_client_line!=B || backend_wb_live || backend_read_live
                            || wb_issue_count!=0 || commit_success_count!=1 || backend_cmd_line_addr_o!=A
                            || backend_cmd_wb_attempt_id_o!=BATW'(0) || backend_cmd_read_tag_o!='0
                            || backend_cmd_store_attempt_id_o!='0 || backend_cmd_store_word_addr_o!='0
                            || backend_cmd_store_wdata_o!='0 || backend_cmd_data_o[0]!=NEW0
                            || backend_cmd_data_o[1]!=OLD1 || model_memory[0][0]!=OLD0)
                            $fatal(1,"P33 ordering dirty WB lost full NEW/untouched payload or accepted typed identity");
                        backend_wb_live<=1'b1; captured_wb_id<=backend_cmd_wb_attempt_id_o;
                        captured_wb_line<=backend_cmd_line_addr_o; wb_issue_count<=wb_issue_count+1;
                        for (integer w=0;w<LW;w=w+1) captured_wb_data[w]<=backend_cmd_data_o[w];
                        $display("P33_ORDER_DIRTY_WB_ACCEPT case=%0d id=%0h line=%0d data0=%08x data1=%08x",
                            case_id,backend_cmd_wb_attempt_id_o,backend_cmd_line_addr_o,
                            backend_cmd_data_o[0],backend_cmd_data_o[1]);
                    end
                    K_STORE: begin
                        store_issue_count<=store_issue_count+1;
                        $fatal(1,"P33 ordering issued physical STORE despite required post-fill cache HIT");
                    end
                    default: $fatal(1,"P33 ordering invalid backend command kind");
                endcase
            end
            if (backend_read_resp_valid_i) begin
                if (!backend_read_live || backend_read_resp_tag_i!=captured_read_tag
                    || backend_read_resp_line_addr_i!=captured_read_line || backend_read_resp_fault_i)
                    $fatal(1,"P33 ordering READ return did not match the entire accepted tag/line identity");
                for (integer w=0;w<LW;w=w+1)
                    if (backend_read_resp_data_i[w]!=captured_read_snapshot[w])
                        $fatal(1,"P33 ordering READ return differs from its command-edge memory snapshot");
                backend_read_live<=1'b0; read_return_count<=read_return_count+1;
            end
            if (backend_wb_status_valid_i) begin
                if (!backend_wb_live || backend_wb_status_attempt_id_i!=captured_wb_id
                    || captured_wb_line!=A || !backend_wb_status_success_i || backend_wb_status_retryable_i
                    || wb_status_count!=0 || captured_wb_data[0]!=NEW0 || captured_wb_data[1]!=OLD1)
                    $fatal(1,"P33 ordering WB SUCCESS did not match full accepted attempt/payload ledger");
                for (integer w=0;w<LW;w=w+1) model_memory[0][w]<=captured_wb_data[w];
                backend_wb_live<=1'b0; wb_status_count<=wb_status_count+1;
            end
            if (backend_store_status_valid_i) begin
                store_status_count<=store_status_count+1;
                $fatal(1,"P33 ordering backend supplied unsolicited physical STORE status");
            end
        end
    end

    task automatic cold_reset_case(input integer next_case);
        begin
            @(negedge clk);
            if (next_case>1 && (client_req_count!=client_resp_count || read_issue_count!=read_return_count
                || wb_issue_count!=wb_status_count || client_live || backend_read_live || backend_wb_live
                || (|dirty_present_o) || (|wb_busy_o) || (|commit_valid_i) || (|client_req_valid_i)))
                $fatal(1,"P33 ordering cold reset attempted before the previous physical work drained");
            rst_n=1'b0; case_id=next_case;
            client_req_valid_i='0; commit_valid_i='0; backend_cmd_ready_i=1'b1;
            client_req_local_tag_i[0]='0; client_req_line_addr_i[0]='0;
            commit_lane_mask_i[0]='0; commit_word_addr_i[0][0]='0; commit_wdata_i[0][0]='0;
            backend_read_resp_valid_i=1'b0; backend_read_resp_tag_i='0;
            backend_read_resp_line_addr_i='0; backend_read_resp_fault_i=1'b0;
            for (integer w=0;w<LW;w=w+1) begin
                backend_read_resp_data_i[w]='0; offered_expected_data[w]='0;
            end
            backend_wb_status_valid_i=1'b0; backend_wb_status_attempt_id_i='0;
            backend_wb_status_success_i=1'b0; backend_wb_status_retryable_i=1'b0;
            backend_store_status_valid_i=1'b0; backend_store_status_attempt_id_i='0;
            backend_store_status_success_i=1'b0; backend_store_status_retryable_i=1'b0;
            backend_store_status_reuse_safe_i=1'b0; backend_store_all_generations_quiescent_i=1'b0;
            backend_wb_recovery_safe_valid_i='0; commit_fault_ready_i=1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n=1'b1;
        end
    endtask

    // The *_now tasks are called only on a negedge. Both source payloads stay
    // asserted until their own actual counted handshake, including arbitration.
    task automatic offer_line_now(input logic [LAW-1:0] line, input logic [31:0] word0,
        input logic [31:0] word1);
        begin
            client_req_valid_i[0]=1'b1; client_req_local_tag_i[0]=LT'(client_req_count);
            client_req_line_addr_i[0]=line; offered_expected_data[0]=word0; offered_expected_data[1]=word1;
        end
    endtask

    task automatic offer_store_now;
        begin
            commit_valid_i[0]=1'b1; commit_lane_mask_i[0]=LANES'(1);
            commit_word_addr_i[0][0]=STORE_ADDR; commit_wdata_i[0][0]=NEW0;
        end
    endtask

    task automatic wait_client_accept(input integer expected_accepts);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (client_req_count==expected_accepts) begin
                    @(negedge clk); client_req_valid_i[0]=1'b0; return;
                end
            end
            $fatal(1,"P33 ordering bounded client admission wait case=%0d expected=%0d",case_id,expected_accepts);
        end
    endtask

    task automatic request_line(input logic [LAW-1:0] line, input logic [31:0] word0,
        input logic [31:0] word1, input integer expected_accepts);
        begin
            @(negedge clk); offer_line_now(line,word0,word1); wait_client_accept(expected_accepts);
        end
    endtask

    task automatic wait_clients(input integer expected_responses);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                if (client_resp_count==expected_responses) return;
                @(posedge clk); #1;
            end
            $fatal(1,"P33 ordering bounded client completion wait case=%0d expected=%0d",case_id,expected_responses);
        end
    endtask

    task automatic wait_read_issue(input integer expected_issues, input logic [LAW-1:0] line);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                if (read_issue_count==expected_issues) begin
                    if (!backend_read_live || captured_read_line!=line)
                        $fatal(1,"P33 ordering expected actual live backend READ identity absent");
                    return;
                end
                @(posedge clk); #1;
            end
            $fatal(1,"P33 ordering bounded backend READ command wait");
        end
    endtask

    task automatic return_read_snapshot;
        begin
            @(negedge clk);
            if (!backend_read_live) $fatal(1,"P33 ordering attempted READ return without accepted command");
            backend_read_resp_valid_i=1'b1; backend_read_resp_tag_i=captured_read_tag;
            backend_read_resp_line_addr_i=captured_read_line; backend_read_resp_fault_i=1'b0;
            for (integer w=0;w<LW;w=w+1) backend_read_resp_data_i[w]=captured_read_snapshot[w];
            @(posedge clk); #1;
            @(negedge clk); backend_read_resp_valid_i=1'b0;
        end
    endtask

    task automatic wait_store_success;
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (commit_success_count==1) begin
                    @(negedge clk); commit_valid_i[0]=1'b0; return;
                end
            end
            $fatal(1,"P33 ordering bounded cache-hit STORE retirement wait");
        end
    endtask

    task automatic fill_a;
        begin
            request_line(A,OLD0,OLD1,1); wait_read_issue(1,A);
            return_read_snapshot(); wait_clients(1);
            if ((|dirty_present_o) || model_memory[0][0]!=OLD0 || model_memory[0][1]!=OLD1)
                $fatal(1,"P33 ordering initial A fill was not clean OLD data");
        end
    endtask

    task automatic finish_alias_and_external_a(input integer alias_client_number);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                if (wb_issue_count==1) break;
                @(posedge clk); #1;
                if (n==BOUND-1) $fatal(1,"P33 ordering bounded dirty-victim WB issue wait");
            end
            repeat (3) begin
                @(posedge clk); #1;
                if (!backend_wb_live || !(|wb_busy_o) || wb_active_count_o!=CNTW'(1)
                    || wb_status_count!=0 || read_issue_count!=1 || model_memory[0][0]!=OLD0
                    || model_memory[0][1]!=OLD1 || client_resp_count!=alias_client_number-1)
                    $fatal(1,"P33 ordering victim/replacement progressed without actual matching WB SUCCESS");
            end
            @(negedge clk);
            backend_wb_status_valid_i=1'b1; backend_wb_status_attempt_id_i=captured_wb_id;
            backend_wb_status_success_i=1'b1; backend_wb_status_retryable_i=1'b0;
            @(posedge clk); #1;
            if (wb_status_count!=1 || model_memory[0][0]!=NEW0 || model_memory[0][1]!=OLD1)
                $fatal(1,"P33 ordering matching WB status edge did not update full model memory");
            @(negedge clk); backend_wb_status_valid_i=1'b0; backend_wb_status_success_i=1'b0;
            wait_read_issue(2,B); return_read_snapshot(); wait_clients(alias_client_number);
            request_line(A,NEW0,OLD1,alias_client_number+1); wait_read_issue(3,A);
            if (captured_read_snapshot[0]!=NEW0 || captured_read_snapshot[1]!=OLD1)
                $fatal(1,"P33 ordering final physical A READ snapshot lost completed STORE/WB data");
            return_read_snapshot(); wait_clients(alias_client_number+1);
        end
    endtask

    task automatic check_case_drained(input integer expected_clients);
        begin
            repeat (3) begin @(posedge clk); #1; end
            if (client_req_count!=expected_clients || client_resp_count!=expected_clients
                || read_issue_count!=3 || read_return_count!=3 || wb_issue_count!=1 || wb_status_count!=1
                || store_issue_count!=0 || store_status_count!=0 || commit_success_count!=1
                || client_live || backend_read_live || backend_wb_live || client_read_outstanding_o!='0
                || (|client_req_valid_i) || (|commit_valid_i) || (|commit_ready_o)
                || (|client_store_conflict_o) || (|commit_read_wait_o)
                || commit_visibility_busy_o || store_completion_busy_o || (|dirty_present_o) || (|wb_busy_o)
                || wb_pending_count_o!='0 || wb_active_count_o!='0 || backend_cmd_valid_o
                || model_memory[0][0]!=NEW0 || model_memory[0][1]!=OLD1
                || model_memory[1][0]!=B0 || model_memory[1][1]!=B1)
                $fatal(1,"P33 ordering case=%0d final exact physical/client ledger or drain mismatch",case_id);
            $display("P33_ORDER_CASE_DRAINED case=%0d clients=%0d reads=%0d read_returns=%0d wbs=%0d wb_statuses=%0d stores=%0d commits=%0d",
                case_id,client_resp_count,read_issue_count,read_return_count,wb_issue_count,wb_status_count,
                store_issue_count,commit_success_count);
        end
    endtask

    initial begin
        rst_n=1'b0; case_id=0;
        cold_reset_case(1);
        request_line(A,OLD0,OLD1,1); wait_read_issue(1,A);
        if (captured_read_snapshot[0]!=OLD0 || captured_read_snapshot[1]!=OLD1
            || client_resp_count!=0 || (|dirty_present_o))
            $fatal(1,"P33 ordering older held READ did not capture the actual cold memory snapshot");
        @(negedge clk); offer_store_now();
        repeat (5) begin
            @(posedge clk); #1;
            if (!commit_read_wait_o[0] || !backend_read_live || commit_success_count!=0
                || store_issue_count!=0 || store_status_count!=0 || read_return_count!=0
                || client_resp_count!=0 || commit_ready_o[0] || (|dirty_present_o))
                $fatal(1,"P33 ordering pending STORE did not wait behind held older READ");
        end
        return_read_snapshot(); wait_clients(1); wait_store_success();
        if (old_read_wait_edges<5 || backend_return_wait_edges!=1 || client_return_wait_edges!=1
            || !(|dirty_present_o) || model_memory[0][0]!=OLD0)
            $fatal(1,"P33 ordering did not exercise both actual old-response wait edges before dirty HIT");
        request_line(A,NEW0,OLD1,2); wait_clients(2);
        if (read_issue_count!=1 || read_return_count!=1 || !(|dirty_present_o))
            $fatal(1,"P33 ordering newer A READ was not a dirty cached NEW hit");
        request_line(B,B0,B1,3); finish_alias_and_external_a(3); check_case_drained(4);
        $display("PROD_SEAM_P33_OLD_READ_BLOCKS_STORE_CLASSIFICATION=PASS");
        $display("PROD_SEAM_P33_SAME_EDGE_OLD_READ_COMPLETION_WAITS=PASS");
        $display("PROD_SEAM_P33_ORDERED_STORE_HIT_CACHED_NEW=PASS");

        cold_reset_case(2); fill_a();
        @(negedge clk); offer_store_now(); offer_line_now(B,B0,B1);
        wait_store_success();
        if (client_req_count!=1 || client_resp_count!=1 || !client_req_valid_i[0]
            || alias_request_wait_edges==0 || old_read_wait_edges!=0 || commit_read_wait_o[0])
            $fatal(1,"P33 ordering simultaneous alias READ did not remain held through actual STORE retirement");
        wait_client_accept(2); finish_alias_and_external_a(2); check_case_drained(3);
        $display("PROD_SEAM_P33_ALIAS_READ_WAITS_FOR_RAW_STORE=PASS");

        cold_reset_case(3); fill_a();
        @(negedge clk); offer_store_now(); offer_line_now(A,NEW0,OLD1);
        wait_store_success();
        if (client_req_count!=1 || client_resp_count!=1 || !client_req_valid_i[0]
            || exact_request_wait_edges==0 || old_read_wait_edges!=0 || commit_read_wait_o[0])
            $fatal(1,"P33 ordering simultaneous exact-line READ did not remain held through STORE retirement");
        wait_client_accept(2); wait_clients(2);
        if (read_issue_count!=1 || !(|dirty_present_o))
            $fatal(1,"P33 ordering simultaneous exact-line READ missed updated cached NEW data");
        request_line(B,B0,B1,3); finish_alias_and_external_a(3); check_case_drained(4);
        $display("PROD_SEAM_P33_EXACT_READ_WAITS_FOR_RAW_STORE=PASS");
        $display("PROD_SEAM_P33_ORDERED_DIRTY_WB_AND_EXTERNAL_REFILL=PASS");
        $display("PROD_SEAM_P33_STORE_READ_ORDER_END_TO_END=PASS");
        $finish;
    end

    initial begin
        repeat (4096) @(posedge clk);
        $fatal(1,"P33 ordering global bounded watchdog");
    end
endmodule

