`timescale 1ns/1ps

/* P31 selective STORE recovery: READ/WB/cache state must survive rearm.
 * Independent backend and client ledgers count only actual clock-edge events.
 * Every scenario drains before the next explicit cold global reset. */
module a0_production_store_commit_selective_recovery_subsystem_tb;
    localparam integer C=2, LT=2, CO=2, CP=2, LANES=2, S=2, LW=2, SETS=2;
    localparam integer WID=2, MWR=1, SWID=2, MSR=1, TO=64, GEN=8;
    localparam integer LAW=31, BRTW=4, BATW=4, RW=1, SRW=1;
    localparam integer SAID=GEN+SWID+SRW, TW=6, PIDW=1, CNTW=2, RCW=3;
    localparam integer TAGS=1<<LT, BOUND=64;
    localparam integer TUPW=2+BRTW+BATW+SAID+LAW+32*LW+64;
    localparam logic [1:0] K_READ=2'b00, K_WB=2'b01, K_STORE=2'b10;
    localparam logic [LAW-1:0] A=31'd1, B=31'd5, R=31'd3;
    localparam logic [31:0] DIRTY_DATA=32'hD031_0001;

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
    logic protocol_error_o;

    integer client_req_count, client_resp_count, read_issue_count, read_return_count;
    integer wb_issue_count, wb_return_count, store_issue_count, rearm_count;
    integer success_count [0:CP-1], abort_count [0:CP-1], fault_count;
    logic client_live [0:C-1][0:TAGS-1];
    logic backend_read_live [0:C-1][0:TAGS-1];
    logic [LAW-1:0] expected_client_line [0:C-1][0:TAGS-1];
    logic [31:0] expected_client_data [0:C-1][0:TAGS-1][0:LW-1];
    logic [LAW-1:0] backend_read_line [0:C-1][0:TAGS-1];
    logic wb_live, store_live, backend_ledger_cancelled;
    logic [BRTW-1:0] last_read_tag;
    logic [LAW-1:0] last_read_line, last_wb_line;
    logic [BATW-1:0] last_wb_id;
    logic [31:0] last_wb_data [0:LW-1];
    logic [SAID-1:0] last_store_id;
    logic [31:0] last_store_addr, last_store_data;
    logic [31:0] mem [0:15][0:LW-1];
    logic [PIDW-1:0] expected_fault_port;
    logic [31:0] expected_fault_addr [0:LANES-1], expected_fault_data [0:LANES-1];
    logic previous_rearm;
    logic previous_port0_commit_valid_q;
    logic stale_store_drive, rejected_expected_q, stalled_q;
    logic [TUPW-1:0] command_tuple, stalled_tuple_q;
    integer read_reset_edges, wb_reset_edges, stale_reset_edges, new_store_reset_edges, stall_cycles, drain_cycles;

    assign command_tuple={backend_cmd_kind_o,backend_cmd_read_tag_o,backend_cmd_wb_attempt_id_o,
        backend_cmd_store_attempt_id_o,backend_cmd_line_addr_o,backend_cmd_data_o[0],backend_cmd_data_o[1],
        backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o};

    a0_production_store_commit_selective_recovery_subsystem #(
        .CLIENT_COUNT(C), .LOCAL_TAG_W(LT), .CLIENT_MAX_OUTSTANDING(CO),
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
            if (!backend_ledger_cancelled)
                $fatal(1,"P31 memory global reset without explicit backend cancellation");
            client_req_count<=0; client_resp_count<=0; read_issue_count<=0; read_return_count<=0;
            wb_issue_count<=0; wb_return_count<=0; store_issue_count<=0; rearm_count<=0;
            fault_count<=0; wb_live<=1'b0; store_live<=1'b0; previous_rearm<=1'b0;
            previous_port0_commit_valid_q<=1'b0;
            rejected_expected_q<=1'b0; stalled_q<=1'b0; stalled_tuple_q<='0;
            read_reset_edges<=0; wb_reset_edges<=0; stale_reset_edges<=0; new_store_reset_edges<=0;
            stall_cycles<=0; drain_cycles<=0;
            last_read_tag<='0; last_read_line<='0; last_wb_line<='0; last_wb_id<='0;
            last_store_id<='0; last_store_addr<='0; last_store_data<='0;
            for (integer p=0;p<CP;p=p+1) begin success_count[p]<=0; abort_count[p]<=0; end
            for (integer w=0;w<LW;w=w+1) last_wb_data[w]<='0;
            for (integer c=0;c<C;c=c+1) begin
                for (integer t=0;t<TAGS;t=t+1) begin
                    client_live[c][t]<=1'b0;
                    backend_read_live[c][t]<=1'b0;
                    backend_read_line[c][t]<='0;
                end
            end
        end else begin
            if (stalled_q && (!backend_cmd_valid_o || command_tuple!=stalled_tuple_q))
                $fatal(1,"P31 full backend command tuple changed while backpressured");
            stalled_q<=backend_cmd_valid_o && !backend_cmd_ready_i;
            if (backend_cmd_valid_o && !backend_cmd_ready_i) begin
                stalled_tuple_q<=command_tuple; stall_cycles<=stall_cycles+1;
            end
            if (rejected_expected_q && !store_status_rejected_o)
                $fatal(1,"P31 reset-edge stale STORE rejection was not sticky");
            if (recovery_rearm_pulse_o || recovery_drain_active_o) begin
                if ((|client_req_ready_o) || (|commit_ready_o))
                    $fatal(1,"P31 new admission/commit success crossed STORE reset or memory drain");
                if (recovery_drain_active_o) drain_cycles<=drain_cycles+1;
            end
            if (protocol_error_o || line_resp_tag_error_o || line_resp_overflow_o )
                $fatal(1,"P31 memory unexpected protocol/tag/status diagnostic");
            if (store_status_timeout_seen_o || store_status_timeout_pulse_o || store_retry_count_o!='0)
                $fatal(1,"P31 memory unexpected timeout/retry");
            if (!store_status_timeout_live_o && store_status_timeout_age_o!='0)
                $fatal(1,"P31 memory inactive timeout age");
            if (store_status_timeout_live_o && !store_completion_busy_o)
                $fatal(1,"P31 memory live timeout without active STORE");
            if (store_terminal_failure_o && (!store_completion_busy_o || !commit_visibility_busy_o))
                $fatal(1,"P31 memory terminal STORE lost fail-closed ownership");
            if ((|wb_terminal_failure_o) || (|recovery_active_o) || (|recovery_complete_pulse_o)
                || (|backend_wb_recovery_safe_ready_o))
                $fatal(1,"P31 memory unexpected WB failure/recovery");
            for (integer s=0;s<S;s=s+1)
                if (wb_retry_count_o[s]!='0) $fatal(1,"P31 memory unexpected WB retry");
            if (integer'(client_read_outstanding_o)!=client_req_count-client_resp_count)
                $fatal(1,"P31 memory accepted client count disagrees with edge ledger");
            if (store_generation_next_o!=GEN'(store_issue_count) || store_generation_wrap_pending_o)
                $fatal(1,"P31 memory generation allocation changed without STORE handshake");

            previous_rearm<=recovery_rearm_pulse_o;
            previous_port0_commit_valid_q<=commit_valid_i[0];
            if (recovery_rearm_pulse_o) begin
                if (previous_rearm || store_live)
                    $fatal(1,"P31 selective reset exceeded one cycle or reset a live STORE");
                rearm_count<=rearm_count+1;
                if (backend_read_resp_valid_i) read_reset_edges<=read_reset_edges+1;
                if (backend_wb_status_valid_i) wb_reset_edges<=wb_reset_edges+1;
                if (commit_valid_i[0] && !previous_port0_commit_valid_q) begin
                    if (commit_ready_o[0] || commit_abort_o[0]
                        || (backend_cmd_valid_o && backend_cmd_kind_o==K_STORE))
                        $fatal(1,"P31 fresh reset-edge STORE was issued, retired, or aborted during rearm");
                    new_store_reset_edges<=new_store_reset_edges+1;
                end
            end

            client_req_count<=client_req_count+$countones(client_req_valid_i & client_req_ready_o);
            client_resp_count<=client_resp_count+$countones(client_resp_valid_o);
            for (integer c=0;c<C;c=c+1) begin
                if (client_req_valid_i[c] && client_req_ready_o[c]) begin
                    if (client_live[c][integer'(client_req_local_tag_i[c])])
                        $fatal(1,"P31 memory duplicate live client tag");
                    if (client_req_line_addr_i[c]!=expected_client_line[c][integer'(client_req_local_tag_i[c])])
                        $fatal(1,"P31 memory request payload differs from expectation");
                    client_live[c][integer'(client_req_local_tag_i[c])]<=1'b1;
                end
                if (client_resp_valid_o[c]) begin
                    if (!client_live[c][integer'(client_resp_local_tag_o[c])]
                        || client_resp_fault_o[c]
                        || client_resp_line_addr_o[c]!=expected_client_line[c][integer'(client_resp_local_tag_o[c])])
                        $fatal(1,"P31 memory unsolicited/misidentified client response");
                    for (integer w=0;w<LW;w=w+1)
                        if (client_resp_data_o[c][w]!=expected_client_data[c][integer'(client_resp_local_tag_o[c])][w])
                            $fatal(1,"P31 memory client response data mismatch");
                    client_live[c][integer'(client_resp_local_tag_o[c])]<=1'b0;
                end
            end
            for (integer p=0;p<CP;p=p+1) begin
                if (commit_ready_o[p] && (!commit_valid_i[p] || commit_abort_o[p] || commit_fault_valid_o))
                    $fatal(1,"P31 memory success is not a separate valid source handshake");
                if (commit_valid_i[p] && commit_ready_o[p]) success_count[p]<=success_count[p]+1;
                if (commit_abort_o[p] && (!commit_valid_i[p] || !commit_fault_valid_o || !commit_fault_ready_i))
                    $fatal(1,"P31 memory abort without actual architectural fault handshake");
                if (commit_valid_i[p] && commit_abort_o[p]) abort_count[p]<=abort_count[p]+1;
            end
            if (commit_fault_valid_o) begin
                if (commit_fault_port_id_o!=expected_fault_port || commit_fault_lane_mask_o!=2'b01
                    || commit_fault_store_timeout_o || commit_fault_store_retry_count_o!='0 || (|commit_ready_o))
                    $fatal(1,"P31 memory fault provenance/ready separation");
                for (integer w=0;w<LANES;w=w+1)
                    if (commit_fault_word_addr_o[w]!=expected_fault_addr[w]
                        || commit_fault_wdata_o[w]!=expected_fault_data[w])
                        $fatal(1,"P31 memory fault payload changed under backpressure");
                if (commit_fault_ready_i) fault_count<=fault_count+1;
            end

            if (backend_cmd_valid_o && backend_cmd_ready_i) begin
                case (backend_cmd_kind_o)
                    K_READ: begin
                        if (!client_live[integer'(backend_cmd_read_tag_o[LT])][integer'(backend_cmd_read_tag_o[LT-1:0])]
                            || backend_read_live[integer'(backend_cmd_read_tag_o[LT])][integer'(backend_cmd_read_tag_o[LT-1:0])]
                            || backend_cmd_wb_attempt_id_o!='0
                            || backend_cmd_store_word_addr_o!='0 || backend_cmd_store_wdata_o!='0)
                            $fatal(1,"P31 memory invalid typed READ command");
                        for (integer w=0;w<LW;w=w+1)
                            if (backend_cmd_data_o[w]!='0) $fatal(1,"P31 memory READ carried WB data");
                        backend_read_live[integer'(backend_cmd_read_tag_o[LT])][integer'(backend_cmd_read_tag_o[LT-1:0])]<=1'b1;
                        backend_read_line[integer'(backend_cmd_read_tag_o[LT])][integer'(backend_cmd_read_tag_o[LT-1:0])]<=backend_cmd_line_addr_o;
                        last_read_tag<=backend_cmd_read_tag_o; last_read_line<=backend_cmd_line_addr_o;
                        read_issue_count<=read_issue_count+1;
                    end
                    K_WB: begin
                        if (wb_live || backend_cmd_read_tag_o!='0
                            || backend_cmd_store_word_addr_o!='0 || backend_cmd_store_wdata_o!='0)
                            $fatal(1,"P31 memory invalid typed WRITEBACK command");
                        wb_live<=1'b1; wb_issue_count<=wb_issue_count+1;
                        last_wb_id<=backend_cmd_wb_attempt_id_o; last_wb_line<=backend_cmd_line_addr_o;
                        for (integer w=0;w<LW;w=w+1) last_wb_data[w]<=backend_cmd_data_o[w];
                    end
                    K_STORE: begin
                        if (store_live || backend_cmd_read_tag_o!='0 || backend_cmd_wb_attempt_id_o!='0
                            || backend_cmd_line_addr_o!='0
                            || backend_cmd_store_attempt_id_o[SAID-1 -: GEN]!=GEN'(store_issue_count))
                            $fatal(1,"P31 memory invalid typed STORE command");
                        for (integer w=0;w<LW;w=w+1)
                            if (backend_cmd_data_o[w]!='0) $fatal(1,"P31 memory STORE carried WB data");
                        store_live<=1'b1; store_issue_count<=store_issue_count+1;
                        last_store_id<=backend_cmd_store_attempt_id_o;
                        last_store_addr<=backend_cmd_store_word_addr_o; last_store_data<=backend_cmd_store_wdata_o;
                    end
                    default: $fatal(1,"P31 memory invalid backend command kind");
                endcase
            end
            if (backend_read_resp_valid_i) begin
                if (!backend_read_live[integer'(backend_read_resp_tag_i[LT])][integer'(backend_read_resp_tag_i[LT-1:0])]
                    || backend_read_resp_line_addr_i!=backend_read_line[integer'(backend_read_resp_tag_i[LT])][integer'(backend_read_resp_tag_i[LT-1:0])])
                    $fatal(1,"P31 memory backend returned an unissued READ");
                backend_read_live[integer'(backend_read_resp_tag_i[LT])][integer'(backend_read_resp_tag_i[LT-1:0])]<=1'b0;
                read_return_count<=read_return_count+1;
            end
            if (backend_wb_status_valid_i) begin
                if (!wb_live || backend_wb_status_attempt_id_i!=last_wb_id
                    || !backend_wb_status_success_i || backend_wb_status_retryable_i)
                    $fatal(1,"P31 memory WB status did not match the actual command");
                wb_live<=1'b0; wb_return_count<=wb_return_count+1;
            end
            if (backend_store_status_valid_i) begin
                if (stale_store_drive) begin
                    if (store_live || !recovery_rearm_pulse_o || backend_store_status_attempt_id_i!=last_store_id)
                        $fatal(1,"P31 stale STORE stimulus did not target the actual reset edge");
                    rejected_expected_q<=1'b1; stale_reset_edges<=stale_reset_edges+1;
                end else begin
                    if (!store_live || backend_store_status_attempt_id_i!=last_store_id || backend_store_status_retryable_i)
                        $fatal(1,"P31 memory unexpected STORE status");
                    store_live<=1'b0;
                end
            end
        end
    end

    task automatic reset_case(input logic cancel_old_case);
        begin
            @(negedge clk);
            if (!cancel_old_case && (client_req_count!=client_resp_count || read_issue_count!=read_return_count || wb_live || store_live))
                $fatal(1,"P31 memory reset discarded work without case cancellation");
            // The test backend cancels its entire ledger and will never emit
            // any old response/status.  The following reset starts a separate
            // scenario; its progress is never counted as STORE recovery.
            backend_ledger_cancelled=1'b1;
            stale_store_drive=1'b0;
            backend_read_resp_valid_i=1'b0; backend_wb_status_valid_i=1'b0; backend_store_status_valid_i=1'b0;
            rst_n=1'b0;
            client_req_valid_i='0; commit_valid_i='0; backend_cmd_ready_i=1'b1;
            backend_read_resp_tag_i='0; backend_read_resp_line_addr_i='0; backend_read_resp_fault_i=1'b0;
            backend_wb_status_attempt_id_i='0; backend_wb_status_success_i=1'b0; backend_wb_status_retryable_i=1'b0;
            backend_store_status_attempt_id_i='0; backend_store_status_success_i=1'b0; backend_store_status_retryable_i=1'b0;
            backend_store_status_reuse_safe_i=1'b0; backend_store_all_generations_quiescent_i=1'b0;
            backend_wb_recovery_safe_valid_i='0; commit_fault_ready_i=1'b0;
            expected_fault_port='0;
            for (integer c=0;c<C;c=c+1) begin
                client_req_local_tag_i[c]='0; client_req_line_addr_i[c]='0;
                for (integer t=0;t<TAGS;t=t+1) begin
                    expected_client_line[c][t]='0;
                    for (integer w=0;w<LW;w=w+1) expected_client_data[c][t][w]='0;
                end
            end
            for (integer p=0;p<CP;p=p+1) begin
                commit_lane_mask_i[p]='0;
                for (integer w=0;w<LANES;w=w+1) begin commit_word_addr_i[p][w]='0; commit_wdata_i[p][w]='0; end
            end
            for (integer w=0;w<LANES;w=w+1) begin expected_fault_addr[w]='0; expected_fault_data[w]='0; end
            for (integer w=0;w<LW;w=w+1) backend_read_resp_data_i[w]='0;
            for (integer a=0;a<16;a=a+1)
                for (integer w=0;w<LW;w=w+1) mem[a][w]=32'h3131_0000+32'(a*16+w);
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n=1'b1; backend_ledger_cancelled=1'b0; #1;
        end
    endtask

    task automatic wait_backend(input logic [1:0] kind, input integer target);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                if ((kind==K_READ && read_issue_count>=target) || (kind==K_WB && wb_issue_count>=target)
                    || (kind==K_STORE && store_issue_count>=target)) return;
                @(posedge clk); #1;
            end
            $fatal(1,"P31 memory bounded backend wait kind=%0d target=%0d",kind,target);
        end
    endtask

    task automatic wait_clients(input integer target);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                if (client_resp_count>=target) return;
                @(posedge clk); #1;
            end
            $fatal(1,"P31 memory bounded client response wait target=%0d",target);
        end
    endtask

    task automatic request_line(input logic [LT-1:0] tag, input logic [LAW-1:0] line);
        integer target;
        begin
            if (integer'(line)>=16) $fatal(1,"P31 memory line outside backend model");
            target=client_req_count+1;
            @(negedge clk);
            client_req_valid_i[1]=1'b1; client_req_local_tag_i[1]=tag; client_req_line_addr_i[1]=line;
            expected_client_line[1][integer'(tag)]=line;
            for (integer w=0;w<LW;w=w+1) expected_client_data[1][integer'(tag)][w]=mem[integer'(line)][w];
            if (line==A && dirty_present_o[1]) expected_client_data[1][integer'(tag)][0]=DIRTY_DATA;
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (client_req_count==target) begin
                    @(negedge clk); client_req_valid_i[1]=1'b0; return;
                end
            end
            $fatal(1,"P31 memory bounded client request acceptance");
        end
    endtask

    task automatic return_read(input logic [BRTW-1:0] tag, input logic [LAW-1:0] line);
        begin
            if (integer'(line)>=16) $fatal(1,"P31 memory response line outside backend model");
            @(negedge clk);
            backend_read_resp_valid_i=1'b1; backend_read_resp_tag_i=tag;
            backend_read_resp_line_addr_i=line; backend_read_resp_fault_i=1'b0;
            for (integer w=0;w<LW;w=w+1) backend_read_resp_data_i[w]=mem[integer'(line)][w];
            @(posedge clk); #1;
            @(negedge clk); backend_read_resp_valid_i=1'b0;
        end
    endtask

    task automatic drive_commit(input integer port, input logic [31:0] addr, input logic [31:0] data);
        begin
            if (port<0 || port>=CP) $fatal(1,"P31 memory commit port out of bounds");
            @(negedge clk); backend_store_status_reuse_safe_i=1'b0;
            commit_valid_i[port]=1'b1; commit_lane_mask_i[port]=2'b01;
            commit_word_addr_i[port][0]=addr; commit_wdata_i[port][0]=data;
            commit_word_addr_i[port][1]=addr+32'd1; commit_wdata_i[port][1]=data^32'hffff_ffff;
        end
    endtask

    task automatic dirty_a;
        integer successes_before, stores_before;
        begin
            successes_before=success_count[0]; stores_before=store_issue_count;
            drive_commit(0,32'(A)<<1,DIRTY_DATA);
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (success_count[0]==successes_before+1) begin
                    @(negedge clk); commit_valid_i[0]=1'b0;
                    if (store_issue_count!=stores_before || dirty_present_o!=2'b10 || store_completion_busy_o)
                        $fatal(1,"P31 memory resident hit did not stay on dirty fast path");
                    return;
                end
            end
            $fatal(1,"P31 memory bounded resident-hit commit wait");
        end
    endtask

    task automatic return_wb;
        begin
            if (!wb_live || integer'(last_wb_line)>=16) $fatal(1,"P31 memory no actual WB to complete");
            @(negedge clk);
            backend_wb_status_valid_i=1'b1; backend_wb_status_attempt_id_i=last_wb_id;
            backend_wb_status_success_i=1'b1; backend_wb_status_retryable_i=1'b0;
            @(posedge clk); #1;
            // The modeled memory changes only after the genuine WB status edge.
            for (integer w=0;w<LW;w=w+1) mem[integer'(last_wb_line)][w]=last_wb_data[w];
            @(negedge clk); backend_wb_status_valid_i=1'b0; backend_wb_status_success_i=1'b0;
        end
    endtask

    task automatic fill_a;
        integer reads_before, responses_before;
        begin
            reads_before=read_issue_count; responses_before=client_resp_count;
            request_line(2'd1,A); wait_backend(K_READ,reads_before+1);
            if (last_read_tag!=4'hD || last_read_line!=A) $fatal(1,"P31 memory READ A typed identity");
            return_read(last_read_tag,last_read_line); wait_clients(responses_before+1);
        end
    endtask

    task automatic begin_replace_a;
        integer wbs_before;
        begin
            wbs_before=wb_issue_count;
            request_line(2'd2,B); wait_backend(K_WB,wbs_before+1);
            if (last_wb_id!=4'h8 || last_wb_line!=A || last_wb_data[0]!=DIRTY_DATA
                || last_wb_data[1]!=mem[integer'(A)][1] || dirty_present_o!=2'b10
                || wb_busy_o!=2'b10 || wb_active_count_o!=CNTW'(1))
                $fatal(1,"P31 memory actual WRITEBACK identity/data/liveness");
        end
    endtask

    task automatic fail_and_abort;
        integer stores_before, aborts_before, faults_before, successes_before;
        begin
            stores_before=store_issue_count; aborts_before=abort_count[1]; faults_before=fault_count;
            successes_before=success_count[1];
            drive_commit(1,32'd14,32'hF031_0007);
            expected_fault_port=1'b1;
            for (integer w=0;w<LANES;w=w+1) begin
                expected_fault_addr[w]=commit_word_addr_i[1][w]; expected_fault_data[w]=commit_wdata_i[1][w];
            end
            wait_backend(K_STORE,stores_before+1);
            if (last_store_addr!=32'd14 || last_store_data!=32'hF031_0007)
                $fatal(1,"P31 memory failed STORE actual payload");
            @(negedge clk); backend_store_status_valid_i=1'b1; backend_store_status_attempt_id_i=last_store_id;
            backend_store_status_success_i=1'b0; backend_store_status_retryable_i=1'b0;
            @(posedge clk); #1; @(negedge clk); backend_store_status_valid_i=1'b0;
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (commit_fault_valid_o) break;
                if (n==BOUND-1) $fatal(1,"P31 memory bounded fault wait");
            end
            repeat (3) begin
                @(posedge clk); #1;
                if (!commit_fault_valid_o || (|commit_abort_o) || success_count[1]!=successes_before)
                    $fatal(1,"P31 memory fault backpressure produced success/abort");
            end
            @(negedge clk); commit_fault_ready_i=1'b1;
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (abort_count[1]==aborts_before+1) break;
                if (n==BOUND-1) $fatal(1,"P31 memory bounded abort wait");
            end
            @(negedge clk); commit_fault_ready_i=1'b0; commit_valid_i[1]=1'b0;
            if (!recovery_required_o || fault_count!=faults_before+1 || success_count[1]!=successes_before)
                $fatal(1,"P31 memory separate abort/recovery cardinality");
        end
    endtask


    task automatic arm_recovery;
        begin
            repeat (3) begin
                @(posedge clk); #1;
                if (!recovery_required_o || !recovery_reset_blocked_o || recovery_rearm_pulse_o)
                    $fatal(1,"P31 rearm did not wait for current failed STORE reuse safety");
            end
            @(negedge clk); backend_store_status_reuse_safe_i=1'b1;
            for (integer n=0;n<BOUND;n=n+1) begin
                @(negedge clk);
                if (recovery_rearm_pulse_o) return;
            end
            $fatal(1,"P31 bounded selective STORE rearm wait");
        end
    endtask

    task automatic wait_drain(input integer expected_rearms);
        begin
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (rearm_count==expected_rearms && !recovery_rearm_pulse_o
                    && !recovery_required_o && !recovery_drain_active_o) begin
                    if (client_read_outstanding_o!='0 || wb_live || store_live
                        || client_req_count!=client_resp_count || read_issue_count!=read_return_count
                        || wb_pending_count_o!='0 || wb_active_count_o!='0 || (|wb_busy_o)
                        || recovery_reset_blocked_o || drain_cycles==0)
                        $fatal(1,"P31 admission reopened before preserved work drained");
                    return;
                end
            end
            $fatal(1,"P31 bounded preserved-memory drain wait");
        end
    endtask

    // Called only at an observed negedge; responses remain asserted over the
    // next actual positive edge, including the selective STORE reset edge.
    task automatic drive_read_now(input logic [BRTW-1:0] tag, input logic [LAW-1:0] line);
        begin
            if (integer'(line)>=16) $fatal(1,"P31 response line outside model");
            backend_read_resp_valid_i=1'b1; backend_read_resp_tag_i=tag;
            backend_read_resp_line_addr_i=line; backend_read_resp_fault_i=1'b0;
            for (integer w=0;w<LW;w=w+1) backend_read_resp_data_i[w]=mem[integer'(line)][w];
        end
    endtask

    task automatic drive_wb_now;
        begin
            if (!wb_live) $fatal(1,"P31 reset-edge WB response has no live backend identity");
            backend_wb_status_valid_i=1'b1; backend_wb_status_attempt_id_i=last_wb_id;
            backend_wb_status_success_i=1'b1; backend_wb_status_retryable_i=1'b0;
        end
    endtask

    task automatic drive_stale_now;
        begin
            stale_store_drive=1'b1; backend_store_status_valid_i=1'b1;
            backend_store_status_attempt_id_i=last_store_id;
            backend_store_status_success_i=1'b1; backend_store_status_retryable_i=1'b0;
        end
    endtask

    task automatic sample_reset_edge;
        begin
            @(posedge clk); #1;
            if (backend_wb_status_valid_i) begin
                if (integer'(last_wb_line)>=16) $fatal(1,"P31 WB line outside model");
                for (integer w=0;w<LW;w=w+1) mem[integer'(last_wb_line)][w]=last_wb_data[w];
            end
            @(negedge clk);
            backend_read_resp_valid_i=1'b0; backend_wb_status_valid_i=1'b0; backend_wb_status_success_i=1'b0;
            backend_store_status_valid_i=1'b0; backend_store_status_success_i=1'b0; stale_store_drive=1'b0;
        end
    endtask

    task automatic finish_replacement(input integer expected_read_count, input integer expected_responses);
        begin
            wait_backend(K_READ,expected_read_count);
            if (last_read_tag!=4'hE || last_read_line!=B)
                $fatal(1,"P31 hidden replacement READ did not resume with its original identity");
            return_read(last_read_tag,last_read_line); wait_clients(expected_responses);
        end
    endtask

    task automatic complete_pending_store(input integer expected_issues, input integer expected_successes);
        begin
            wait_backend(K_STORE,expected_issues);
            if (last_store_addr!=32'd8 || last_store_data!=32'hE031_0004)
                $fatal(1,"P31 pending source identity changed across recovery/drain");
            @(negedge clk); backend_store_status_valid_i=1'b1;
            backend_store_status_attempt_id_i=last_store_id; backend_store_status_success_i=1'b1;
            @(posedge clk); #1;
            @(negedge clk); backend_store_status_valid_i=1'b0; backend_store_status_success_i=1'b0;
            for (integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk); #1;
                if (success_count[0]==expected_successes) begin
                    @(negedge clk); commit_valid_i[0]=1'b0; return;
                end
            end
            $fatal(1,"P31 bounded pending source actual success handshake");
        end
    endtask

    task automatic check_case_drained;
        begin
            repeat (3) begin @(posedge clk); #1; end
            if (client_req_count!=client_resp_count || read_issue_count!=read_return_count
                || wb_live || store_live || (|dirty_present_o) || (|wb_busy_o)
                || wb_pending_count_o!='0 || wb_active_count_o!='0 || (|commit_valid_i)
                || recovery_required_o || recovery_drain_active_o || recovery_rearm_pulse_o
                || commit_visibility_busy_o || store_completion_busy_o)
                $fatal(1,"P31 scenario did not actually drain before cold reset boundary");
        end
    endtask

    initial begin
        integer reads_before, responses_before, accepts_before;
        logic [TUPW-1:0] held_line_tuple;
        rst_n=1'b0; backend_ledger_cancelled=1'b1;
        reset_case(1'b1);

        // Dirty data remains resident through rearm and is readable without a
        // backend refill.  Its later writeback proves all words survived.
        fill_a(); dirty_a(); fail_and_abort(); arm_recovery(); drive_stale_now(); sample_reset_edge();
        wait_drain(1);
        if (dirty_present_o!=2'b10 || stale_reset_edges!=1 || !store_status_rejected_o)
            $fatal(1,"P31 dirty cache or stale status containment failed across selective reset");
        reads_before=read_issue_count; responses_before=client_resp_count;
        request_line(2'd2,A); wait_clients(responses_before+1);
        if (read_issue_count!=reads_before || dirty_present_o!=2'b10)
            $fatal(1,"P31 dirty cached READ refilled or lost residency after recovery");
        begin_replace_a(); return_wb(); finish_replacement(reads_before+1,responses_before+2);
        if (abort_count[1]!=1 || fault_count!=1 || success_count[0]!=1 || success_count[1]!=0 || rearm_count!=1)
            $fatal(1,"P31 dirty scenario actual retirement cardinality");
        check_case_drained();
        $display("PROD_SEAM_P31_DIRTY_SURVIVES_CACHED_READ_LATER_WB=PASS");
        $display("PROD_SEAM_P31_STALE_STORE_RESET_EDGE_CONTAINED=PASS");

        // An already accepted READ response on the reset sampling edge is
        // consumed by the untouched memory domain and reaches its requester.
        reset_case(1'b0);
        request_line(2'd3,R); wait_backend(K_READ,1);
        if (last_read_tag!=4'h7 || last_read_line!=R) $fatal(1,"P31 outstanding READ setup identity");
        fail_and_abort(); arm_recovery(); drive_read_now(4'h7,R); sample_reset_edge();
        wait_clients(1); wait_drain(1);
        if (read_reset_edges!=1 || read_issue_count!=1 || read_return_count!=1 || abort_count[1]!=1)
            $fatal(1,"P31 actual READ response/reset-edge cardinality");
        check_case_drained();
        $display("PROD_SEAM_P31_READ_RESPONSE_ON_REARM_EDGE=PASS");

        // A WB status on that edge releases the old victim.  The replacement
        // request hidden behind the failed STORE then issues and drains.
        reset_case(1'b0);
        fill_a(); dirty_a(); begin_replace_a(); fail_and_abort(); arm_recovery();
        backend_cmd_ready_i=1'b0; drive_wb_now(); sample_reset_edge();
        repeat (5) begin
            @(posedge clk); #1;
            if (!recovery_drain_active_o || client_read_outstanding_o!=RCW'(1) || (|commit_ready_o))
                $fatal(1,"P31 hidden replacement request escaped the recovery drain");
        end
        @(negedge clk); backend_cmd_ready_i=1'b1;
        finish_replacement(2,2); wait_drain(1);
        if (wb_reset_edges!=1 || wb_return_count!=1 || stall_cycles==0 || rearm_count!=1)
            $fatal(1,"P31 actual WB reset edge or resumed READ backpressure was not exercised");
        check_case_drained();
        $display("PROD_SEAM_P31_WB_STATUS_ON_REARM_EDGE=PASS");
        $display("PROD_SEAM_P31_HIDDEN_REPLACEMENT_READ_RESUMES=PASS");

        // READ+WB+failed STORE coexist.  Another commit port remains pending;
        // a new client request first appears on reset and must await old drain.
        reset_case(1'b0);
        fill_a(); dirty_a(); request_line(2'd3,R); wait_backend(K_READ,2);
        if (last_read_tag!=4'h7 || last_read_line!=R) $fatal(1,"P31 concurrent READ setup");
        begin_replace_a(); fail_and_abort();
        drive_commit(0,32'd8,32'hE031_0004);
        arm_recovery();
        accepts_before=client_req_count;
        client_req_valid_i[0]=1'b1; client_req_local_tag_i[0]=2'd1; client_req_line_addr_i[0]=31'd6;
        expected_client_line[0][1]=31'd6;
        for (integer w=0;w<LW;w=w+1) expected_client_data[0][1][w]=mem[6][w];
        backend_cmd_ready_i=1'b0;
        drive_read_now(4'h7,R); drive_wb_now(); drive_stale_now(); sample_reset_edge();
        repeat (5) begin
            @(posedge clk); #1;
            if (!recovery_drain_active_o || client_req_count!=accepts_before || success_count[0]!=1
                || !commit_valid_i[0] || commit_word_addr_i[0][0]!=32'd8
                || commit_wdata_i[0][0]!=32'hE031_0004 || rearm_count!=1)
                $fatal(1,"P31 new/pending source crossed memory drain or lost held payload");
        end
        @(negedge clk); backend_cmd_ready_i=1'b1;
        finish_replacement(3,3);
        // The held new client source may be admitted as soon as old drain ends.
        for (integer n=0;n<BOUND;n=n+1) begin
            @(posedge clk); #1;
            if (client_req_count==accepts_before+1) begin
                @(negedge clk); client_req_valid_i[0]=1'b0; break;
            end
            if (n==BOUND-1) $fatal(1,"P31 reset-edge new request never admitted after drain");
        end
        // Return whichever backend path wins arbitration first.  The new READ
        // and pending STORE are independent, and their real counters persist.
        for (integer n=0;n<BOUND;n=n+1) begin
            if (store_issue_count==2 || read_issue_count==4) break;
            @(posedge clk); #1;
            if (n==BOUND-1) $fatal(1,"P31 pending post-drain traffic never issued");
        end
        if (store_issue_count==2) complete_pending_store(2,2);
        wait_backend(K_READ,4);
        if (last_read_tag!=4'h9 || last_read_line!=31'd6) $fatal(1,"P31 newly admitted client identity");
        return_read(4'h9,31'd6); wait_clients(4);
        if (success_count[0]!=2) complete_pending_store(2,2);
        if (read_reset_edges!=1 || wb_reset_edges!=1 || stale_reset_edges!=1 || rearm_count!=1
            || abort_count[1]!=1 || fault_count!=1 || success_count[1]!=0 || stall_cycles==0)
            $fatal(1,"P31 concurrent preservation actual edge totals");
        check_case_drained();
        $display("PROD_SEAM_P31_CONCURRENT_READ_WB_STORE_RECOVERY=PASS");
        $display("PROD_SEAM_P31_PENDING_COMMIT_AND_RESET_EDGE_ADMISSION=PASS");
        $display("PROD_SEAM_P31_RECOVERY_BACKPRESSURE_FULL_TUPLE=PASS");

        // This STORE is not an older pending source: port 0 stays withdrawn
        // until the negedge immediately before the actual local reset edge.
        // Its first sampled valid coincides with rearm, but only a later real
        // STORE status may retire it after the old recovery drain has ended.
        reset_case(1'b0);
        fail_and_abort(); arm_recovery();
        if (commit_valid_i[0] || previous_port0_commit_valid_q || !recovery_rearm_pulse_o)
            $fatal(1,"P31 fresh reset-edge STORE precondition was not exercised");
        commit_valid_i[0]=1'b1; commit_lane_mask_i[0]=2'b01;
        commit_word_addr_i[0][0]=32'd8; commit_wdata_i[0][0]=32'hE031_0004;
        commit_word_addr_i[0][1]=32'd9; commit_wdata_i[0][1]=32'hE031_0004^32'hffff_ffff;
        sample_reset_edge();
        if (new_store_reset_edges!=1 || rearm_count!=1 || store_issue_count!=1
            || success_count[0]!=0 || abort_count[0]!=0 || !commit_valid_i[0])
            $fatal(1,"P31 fresh STORE reset-edge event/cardinality mismatch");
        wait_drain(1); complete_pending_store(2,1);
        if (store_issue_count!=2 || success_count[0]!=1 || success_count[1]!=0
            || abort_count[0]!=0 || abort_count[1]!=1 || fault_count!=1
            || new_store_reset_edges!=1 || rearm_count!=1)
            $fatal(1,"P31 reset-edge fresh STORE lost or duplicated actual work");
        check_case_drained();
        $display("PROD_SEAM_P31_FRESH_STORE_ON_REARM_EDGE=PASS");

        // Offer an actual dirty WRITEBACK while ready is low, before any new
        // STORE. A different-line STORE then traverses L2 classification into
        // its completion guard. That public busy transition proves a pending
        // STORE exists, but it must not replace the older held LINE tuple.
        reset_case(1'b0);
        fill_a(); dirty_a();
        @(negedge clk); backend_cmd_ready_i=1'b0;
        request_line(2'd2,B);
        for (integer n=0;n<BOUND;n=n+1) begin
            @(posedge clk); #1;
            if (backend_cmd_valid_o && backend_cmd_kind_o==K_WB) break;
            if (n==BOUND-1) $fatal(1,"P31 held LINE offer was never presented");
        end
        if (wb_issue_count!=0 || store_issue_count!=0 || commit_visibility_busy_o
            || store_completion_busy_o || backend_cmd_wb_attempt_id_o!=4'h8
            || backend_cmd_line_addr_o!=A || backend_cmd_data_o[0]!=DIRTY_DATA
            || backend_cmd_data_o[1]!=mem[integer'(A)][1])
            $fatal(1,"P31 pre-STORE held LINE identity/data precondition");
        held_line_tuple=command_tuple;
        drive_commit(0,32'd8,32'hE031_0004);
        for (integer n=0;n<BOUND;n=n+1) begin
            @(posedge clk); #1;
            if (!backend_cmd_valid_o || command_tuple!=held_line_tuple
                || wb_issue_count!=0 || store_issue_count!=0 || (|commit_ready_o))
                $fatal(1,"P31 held LINE changed during L2 classification to STORE MISS");
            if (store_completion_busy_o) break;
            if (n==BOUND-1) $fatal(1,"P31 STORE never reached completion guard behind held LINE");
        end
        repeat (5) begin
            @(posedge clk); #1;
            if (!store_completion_busy_o || !commit_visibility_busy_o
                || !backend_cmd_valid_o || command_tuple!=held_line_tuple
                || wb_issue_count!=0 || store_issue_count!=0 || (|commit_ready_o))
                $fatal(1,"P31 held LINE failed full-tuple stability with STORE pending");
        end
        @(negedge clk); backend_cmd_ready_i=1'b1;
        wait_backend(K_WB,1);
        if (last_wb_id!=4'h8 || last_wb_line!=A || last_wb_data[0]!=DIRTY_DATA
            || last_wb_data[1]!=mem[integer'(A)][1])
            $fatal(1,"P31 held LINE handshake lost exact dirty WRITEBACK payload");
        complete_pending_store(1,2);
        return_wb(); finish_replacement(2,2);
        if (read_issue_count!=2 || read_return_count!=2 || wb_issue_count!=1 || wb_return_count!=1
            || store_issue_count!=1 || success_count[0]!=2 || success_count[1]!=0
            || abort_count[0]!=0 || abort_count[1]!=0 || fault_count!=0 || rearm_count!=0
            || stall_cycles<5)
            $fatal(1,"P31 held LINE/STORE real completion cardinality mismatch");
        check_case_drained();
        $display("PROD_SEAM_P31_HELD_LINE_ACROSS_STORE_MISS=PASS");
        $display("PROD_SEAM_P31_MEMORY_END_TO_END=PASS");
        $finish;
    end

    initial begin
        repeat (8192) @(posedge clk);
        $fatal(1,"P31 memory global bounded watchdog");
    end
endmodule
