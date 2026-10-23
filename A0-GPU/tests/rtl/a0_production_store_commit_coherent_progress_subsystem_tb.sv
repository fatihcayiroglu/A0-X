`timescale 1ns/1ps

// P34 integrated public-port evidence. One startup reset, no private array
// access. This receiver acquires bytes only at a real accepted TAKE response.
// VARIANT 0/1/2: slices/sets/words = 1/1/1, 2/2/2, 4/4/4.
module a0_production_store_commit_coherent_progress_subsystem_tb #(
    parameter integer VARIANT=0
);
    localparam integer C=2, LT=2, CO=2, CP=2, LANES=2;
    localparam integer S=(1<<VARIANT), SETS=(1<<VARIANT), LW=(1<<VARIANT);
    localparam integer WSEL=(LW<=1)?0:$clog2(LW), LAW=32-WSEL;
    localparam integer SID=(S<=1)?1:$clog2(S), HSHIFT=(SETS<=1)?0:$clog2(SETS);
    localparam integer WID=2, RW=1, SWID=2, SRW=1, GEN=8, CGEN=2;
    localparam integer BRTW=SID+1+LT, BATW=SID+WID+RW, SAID=GEN+SWID+SRW;
    localparam integer CNTW=(S<=1)?1:$clog2(S+1), RCW=3, TO=256, TW=8;
    localparam integer TAGS=(1<<LT), MEM_LINES=4*S*SETS+16, BOUND=160;
    localparam integer TUPW=2+BRTW+BATW+SAID+LAW+32*LW+64;
    localparam logic [1:0] K_READ=2'b00, K_WB=2'b01, K_STORE=2'b10;
    localparam logic [LAW-1:0] A=LAW'(S*SETS), B=LAW'(2*S*SETS);
    localparam logic [LAW-1:0] F=LAW'(3*S*SETS), DS=LAW'(SETS+1), DH=LAW'(SETS);

    logic clk,rst_n;
    logic [C-1:0] client_req_valid_i,client_req_ready_o,client_resp_valid_o;
    logic [LT-1:0] client_req_local_tag_i[0:C-1],client_resp_local_tag_o[0:C-1];
    logic [LAW-1:0] client_req_line_addr_i[0:C-1],client_resp_line_addr_o[0:C-1];
    logic client_resp_fault_o[0:C-1];
    logic [31:0] client_resp_data_o[0:C-1][0:LW-1];
    logic [C-1:0] client_store_conflict_o;
    logic [CP-1:0] commit_valid_i,commit_ready_o,commit_abort_o,commit_read_wait_o;
    logic [LANES-1:0] commit_lane_mask_i[0:CP-1];
    logic [31:0] commit_word_addr_i[0:CP-1][0:LANES-1],commit_wdata_i[0:CP-1][0:LANES-1];
    logic backend_cmd_valid_o,backend_cmd_ready_i;
    logic [1:0] backend_cmd_kind_o;
    logic [BRTW-1:0] backend_cmd_read_tag_o;
    logic [BATW-1:0] backend_cmd_wb_attempt_id_o;
    logic [SAID-1:0] backend_cmd_store_attempt_id_o;
    logic [LAW-1:0] backend_cmd_line_addr_o;
    logic [31:0] backend_cmd_data_o[0:LW-1];
    logic [31:0] backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o;
    logic backend_read_resp_valid_i,backend_read_resp_fault_i;
    logic [BRTW-1:0] backend_read_resp_tag_i;
    logic [LAW-1:0] backend_read_resp_line_addr_i;
    logic [31:0] backend_read_resp_data_i[0:LW-1];
    logic backend_wb_status_valid_i,backend_wb_status_success_i,backend_wb_status_retryable_i;
    logic [BATW-1:0] backend_wb_status_attempt_id_i;
    logic backend_store_status_valid_i,backend_store_status_success_i,backend_store_status_retryable_i;
    logic [SAID-1:0] backend_store_status_attempt_id_i;
    logic backend_store_status_reuse_safe_i,backend_store_all_generations_quiescent_i;
    logic [S-1:0] backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o;
    logic [S-1:0] dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;
    logic [RW-1:0] wb_retry_count_o[0:S-1];
    logic [CNTW-1:0] wb_pending_count_o,wb_active_count_o;
    logic commit_visibility_busy_o,store_completion_busy_o,store_terminal_failure_o;
    logic [SRW-1:0] store_retry_count_o;
    logic line_resp_tag_error_o,line_resp_overflow_o;
    logic store_status_timeout_live_o,store_status_timeout_pulse_o,store_status_timeout_seen_o;
    logic [TW-1:0] store_status_timeout_age_o;
    logic commit_fault_valid_o,commit_fault_ready_i,commit_fault_port_id_o;
    logic [LANES-1:0] commit_fault_lane_mask_o;
    logic [31:0] commit_fault_word_addr_o[0:LANES-1],commit_fault_wdata_o[0:LANES-1];
    logic commit_fault_store_timeout_o;
    logic [SRW-1:0] commit_fault_store_retry_count_o;
    logic recovery_required_o,recovery_rearm_pulse_o,recovery_drain_active_o,recovery_reset_blocked_o;
    logic [GEN-1:0] store_generation_next_o;
    logic store_generation_wrap_pending_o,store_status_rejected_o;
    logic [RCW-1:0] client_read_outstanding_o;
    logic protocol_error_o;

    logic probe_req_valid_i,probe_req_ready_o,probe_req_take_i;
    logic [SID-1:0] probe_req_home_i,probe_resp_home_o,reclaim_home_i;
    logic [3:0] probe_req_node_i,probe_req_txn_i,probe_resp_node_o,probe_resp_txn_o,reclaim_node_i;
    logic [LAW-1:0] probe_req_line_addr_i,probe_resp_line_addr_o,reclaim_line_addr_i;
    logic probe_resp_valid_o,probe_resp_ready_i,probe_resp_take_o,probe_resp_hit_o,probe_resp_dirty_o;
    logic [CGEN-1:0] probe_resp_generation_o,reclaim_generation_i;
    logic [31:0] probe_resp_data_o[0:LW-1],reclaim_data_i[0:LW-1];
    logic reclaim_valid_i,reclaim_ready_o,reclaim_dirty_i;
    logic [S-1:0] probe_reuse_safe_i,remote_owned_present_o,probe_generation_exhausted_o;
    logic [SETS-1:0] coherence_block_set_o[0:S-1];
    logic coherence_protocol_error_o;

    integer cycles,checks,scenarios,reqs,resps,reads,read_returns,wbs,wb_returns;
    integer stores,store_returns,probes,probe_responses,transfers,reclaims,rejects;
    integer errors,rearms,drains,stalls,probe_stalls,faults;
    integer retired[0:CP-1],aborted[0:CP-1],next_generation[0:S-1];
    logic client_live[0:C-1][0:TAGS-1],read_live[0:(1<<BRTW)-1];
    logic [LAW-1:0] client_line[0:C-1][0:TAGS-1],read_line[0:(1<<BRTW)-1];
    logic [31:0] client_data[0:C-1][0:TAGS-1][0:LW-1];
    logic [31:0] mem[0:MEM_LINES-1][0:LW-1],cache_expected[0:MEM_LINES-1][0:LW-1];
    logic wb_live,store_live,stalled,probe_pending,receiver_owned,expect_coherence_error;
    logic [BRTW-1:0] last_read_tag;
    logic [LAW-1:0] last_read_line,last_wb_line;
    logic [BATW-1:0] last_wb_id;
    logic [SAID-1:0] last_store_id;
    logic [31:0] last_wb_data[0:LW-1],last_store_addr,last_store_data;
    logic [TUPW-1:0] command_tuple,stalled_tuple;
    logic [SID-1:0] pending_home,receiver_home;
    logic [LAW-1:0] pending_line,receiver_line;
    logic [3:0] pending_node,pending_txn,receiver_node;
    logic [CGEN-1:0] pending_generation,receiver_generation;
    logic pending_take,pending_hit,pending_dirty,receiver_dirty,planned_hit,planned_dirty;
    logic [31:0] pending_data[0:LW-1],receiver_data[0:LW-1],planned_data[0:LW-1];
    logic [SETS-1:0] expected_blocks[0:S-1];
    logic [S-1:0] expected_remote;

    function automatic logic [SID-1:0] home_of(input logic [LAW-1:0] line);
        if(S<=1) home_of='0;
        else home_of=SID'(line)^SID'(line>>HSHIFT);
    endfunction
    function automatic bit same_resource(input logic [LAW-1:0] left,input logic [LAW-1:0] right);
        same_resource=(home_of(left)==home_of(right)) && ((32'(left)%SETS)==(32'(right)%SETS));
    endfunction
    function automatic logic [31:0] word_addr(input logic [LAW-1:0] line);
        word_addr=32'(line)<<WSEL;
    endfunction

    always_comb begin
        command_tuple='0;
        command_tuple[TUPW-1 -: (2+BRTW+BATW+SAID+LAW+64)]={backend_cmd_kind_o,
            backend_cmd_read_tag_o,backend_cmd_wb_attempt_id_o,backend_cmd_store_attempt_id_o,
            backend_cmd_line_addr_o,backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o};
        for(integer w=0;w<LW;w=w+1) command_tuple[w*32 +: 32]=backend_cmd_data_o[w];
    end

    a0_production_store_commit_coherent_progress_subsystem #(
        .CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),
        .COMMIT_PORT_COUNT(CP),.STORE_LANES(LANES),.SLICE_COUNT(S),
        .LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),.WRITE_ID_W(WID),.MAX_WB_RETRIES(1),
        .STORE_WRITE_ID_W(SWID),.MAX_STORE_RETRIES(1),.STORE_GENERATION_W(GEN),
        .STORE_STATUS_TIMEOUT_CYCLES(TO),.CLIENT_READ_COUNT_W(RCW),
        .COHERENCE_NODE_W(4),.COHERENCE_TXN_W(4),.COHERENCE_GEN_W(CGEN)
    ) dut(.*);

    initial begin : clock_driver
        clk=0;
        forever #5 clk=~clk;
    end
    task automatic check(input bit okay,input string detail);
        begin
            if(!okay) $fatal(1,"P34_INTEGRATED_CHECK_FAILED cycle=%0d detail=%s",cycles,detail);
            checks=checks+1;
        end
    endtask
    task automatic mark(input string name);
        begin
            scenarios=scenarios+1;
            $display("P34_INTEGRATED_SCENARIO_PASS id=%0d name=%s",scenarios,name);
        end
    endtask

    // Sample the actual pre-NBA handshakes, update the independent software
    // model immediately, and only then compare registered state after #1.
    initial begin : edge_monitor
        forever begin
            @(posedge clk);
            cycles=cycles+1;
            if(cycles>20000) $fatal(1,"P34 integrated watchdog");
            if(rst_n) begin
                check(!protocol_error_o && !line_resp_tag_error_o && !line_resp_overflow_o,
                    "unexpected production route/protocol error");
                check(!( |(client_req_valid_i & client_req_ready_o & client_store_conflict_o)),
                    "conflicting client crossed admission");
                check(!( |(commit_ready_o & commit_read_wait_o)),"waiting commit retired");
                check(integer'(client_read_outstanding_o)==reqs-resps,"production outstanding READ ledger");
                check(!store_status_timeout_seen_o && !store_status_timeout_pulse_o && store_retry_count_o=='0,
                    "unexpected STORE retry/timeout");
                check(store_status_timeout_live_o || store_status_timeout_age_o=='0,"inactive timer age");
                check(!store_status_timeout_live_o || store_completion_busy_o,"timer without live STORE");
                check(!store_terminal_failure_o || (store_completion_busy_o && commit_visibility_busy_o),
                    "terminal STORE lost fail-closed ownership");
                check(wb_terminal_failure_o=='0 && recovery_active_o=='0 && recovery_complete_pulse_o=='0
                    && backend_wb_recovery_safe_ready_o=='0,"unexpected WB recovery");
                for(integer h=0;h<S;h=h+1) check(wb_retry_count_o[h]=='0,"unexpected WB retry");
                check(store_generation_next_o==GEN'(stores) && !store_generation_wrap_pending_o
                    && !store_status_rejected_o,"STORE generation changed or stale status fabricated");
                check(recovery_reset_blocked_o==(recovery_required_o && !recovery_rearm_pulse_o),
                    "STORE recovery blocked-state contract");
                if(recovery_rearm_pulse_o) rearms=rearms+1;
                if(recovery_drain_active_o) drains=drains+1;

                if(stalled) check(backend_cmd_valid_o && command_tuple===stalled_tuple,
                    "full backend command changed under backpressure");
                stalled=backend_cmd_valid_o && !backend_cmd_ready_i;
                if(stalled) begin stalled_tuple=command_tuple;stalls=stalls+1;end

                // The older ledger is tested BEFORE retiring this edge's READ.
                if(probe_req_valid_i && probe_req_ready_o) begin
                    for(integer c=0;c<C;c=c+1)
                        for(integer t=0;t<TAGS;t=t+1)
                            check(!client_live[c][t] || !same_resource(client_line[c][t],probe_req_line_addr_i),
                                "probe bypassed accepted READ, including its response edge");
                    for(integer p=0;p<CP;p=p+1)
                        for(integer l=0;l<LANES;l=l+1)
                            check(!commit_valid_i[p] || !commit_lane_mask_i[p][l]
                                || !same_resource(LAW'(commit_word_addr_i[p][l]>>WSEL),probe_req_line_addr_i),
                                "probe bypassed raw STORE reservation");
                end
                for(integer c=0;c<C;c=c+1) begin
                    if(client_req_valid_i[c] && client_req_ready_o[c]) begin
                        check(!client_live[c][client_req_local_tag_i[c]],"duplicate live client tag");
                        check(client_req_line_addr_i[c]===client_line[c][client_req_local_tag_i[c]],
                            "accepted client line identity");
                        client_live[c][client_req_local_tag_i[c]]=1;
                        reqs=reqs+1;
                    end
                    if(client_resp_valid_o[c]) begin
                        check(client_live[c][client_resp_local_tag_o[c]],"unissued or double client response");
                        check(!client_resp_fault_o[c] && client_resp_line_addr_o[c]===client_line[c][client_resp_local_tag_o[c]],
                            "client response identity/fault");
                        for(integer w=0;w<LW;w=w+1)
                            check(client_resp_data_o[c][w]===client_data[c][client_resp_local_tag_o[c]][w],
                                "client returned stale or corrupted full line");
                        client_live[c][client_resp_local_tag_o[c]]=0;
                        resps=resps+1;
                    end
                end
                for(integer p=0;p<CP;p=p+1) begin
                    if(commit_ready_o[p]) begin
                        check(commit_valid_i[p] && !commit_abort_o[p] && !commit_fault_valid_o,
                            "commit_ready must represent successful retirement only");
                        retired[p]=retired[p]+1;
                    end
                    if(commit_abort_o[p]) begin
                        check(commit_valid_i[p] && commit_fault_valid_o && commit_fault_ready_i && !commit_ready_o[p],
                            "abort without independent actual fault handshake");
                        aborted[p]=aborted[p]+1;
                    end
                end
                if(commit_fault_valid_o) begin
                    check(commit_fault_port_id_o==1 && commit_fault_lane_mask_o==2'b01
                        && !commit_fault_store_timeout_o && commit_fault_store_retry_count_o=='0,
                        "fault port/lane/type provenance");
                    check(commit_fault_word_addr_o[0]===word_addr(F)
                        && commit_fault_word_addr_o[1]===word_addr(F)+32'd1
                        && commit_fault_wdata_o[0]===32'hfa11_0034
                        && commit_fault_wdata_o[1]===(32'hfa11_0034^32'hffff_ffff),
                        "held fault full payload provenance");
                    if(commit_fault_ready_i) faults=faults+1;
                end
                if(backend_cmd_valid_o && backend_cmd_ready_i) begin
                    case(backend_cmd_kind_o)
                        K_READ: begin
                            check(!read_live[backend_cmd_read_tag_o],"backend READ tag reused while live");
                            check(backend_cmd_read_tag_o[BRTW-1 -: SID]===home_of(backend_cmd_line_addr_o),
                                "backend READ exact home identity");
                            check(client_live[backend_cmd_read_tag_o[LT]][backend_cmd_read_tag_o[LT-1:0]]
                                && client_line[backend_cmd_read_tag_o[LT]][backend_cmd_read_tag_o[LT-1:0]]===backend_cmd_line_addr_o,
                                "backend READ exact requester/tag/line identity");
                            check(backend_cmd_wb_attempt_id_o=='0 && backend_cmd_store_attempt_id_o=='0
                                && backend_cmd_store_word_addr_o=='0 && backend_cmd_store_wdata_o=='0,
                                "typed READ inactive fields");
                            for(integer w=0;w<LW;w=w+1) check(backend_cmd_data_o[w]=='0,"READ carried WB payload");
                            read_live[backend_cmd_read_tag_o]=1;read_line[backend_cmd_read_tag_o]=backend_cmd_line_addr_o;
                            last_read_tag=backend_cmd_read_tag_o;last_read_line=backend_cmd_line_addr_o;reads=reads+1;
                        end
                        K_WB: begin
                            check(!wb_live && backend_cmd_read_tag_o=='0 && backend_cmd_store_attempt_id_o=='0
                                && backend_cmd_store_word_addr_o=='0 && backend_cmd_store_wdata_o=='0,"typed WB identity");
                            check(backend_cmd_wb_attempt_id_o[BATW-1 -: SID]===home_of(backend_cmd_line_addr_o),
                                "WB source home identity");
                            check(integer'(backend_cmd_line_addr_o)<MEM_LINES,"WB model line range");
                            for(integer w=0;w<LW;w=w+1) begin
                                check(backend_cmd_data_o[w]===cache_expected[integer'(backend_cmd_line_addr_o)][w],
                                    "actual dirty WB bytes differ from receiver-returned cache bytes");
                                last_wb_data[w]=backend_cmd_data_o[w];
                            end
                            wb_live=1;last_wb_id=backend_cmd_wb_attempt_id_o;last_wb_line=backend_cmd_line_addr_o;wbs=wbs+1;
                        end
                        K_STORE: begin
                            check(!store_live && backend_cmd_read_tag_o=='0 && backend_cmd_wb_attempt_id_o=='0
                                && backend_cmd_line_addr_o=='0,"typed STORE identity");
                            check(backend_cmd_store_attempt_id_o[SAID-1 -: GEN]==GEN'(stores),"STORE generation allocation");
                            for(integer w=0;w<LW;w=w+1) check(backend_cmd_data_o[w]=='0,"STORE carried WB payload");
                            store_live=1;last_store_id=backend_cmd_store_attempt_id_o;
                            last_store_addr=backend_cmd_store_word_addr_o;last_store_data=backend_cmd_store_wdata_o;stores=stores+1;
                        end
                        default: check(0,"invalid backend kind");
                    endcase
                end
                if(backend_read_resp_valid_i) begin
                    check(read_live[backend_read_resp_tag_i] && read_line[backend_read_resp_tag_i]===backend_read_resp_line_addr_i
                        && !backend_read_resp_fault_i,"backend READ response not bound to a real command");
                    read_live[backend_read_resp_tag_i]=0;read_returns=read_returns+1;
                end
                if(backend_wb_status_valid_i) begin
                    check(wb_live && backend_wb_status_attempt_id_i===last_wb_id
                        && backend_wb_status_success_i && !backend_wb_status_retryable_i,"WB status exact live attempt");
                    wb_live=0;wb_returns=wb_returns+1;
                end
                if(backend_store_status_valid_i) begin
                    check(store_live && backend_store_status_attempt_id_i===last_store_id
                        && !backend_store_status_retryable_i,"STORE status exact live attempt");
                    store_live=0;store_returns=store_returns+1;
                end

                if(probe_req_valid_i && probe_req_ready_o) begin
                    check(!probe_pending,"multiple global pending probes");
                    check(probe_req_home_i===home_of(probe_req_line_addr_i),"accepted probe home/line mismatch");
                    probe_pending=1;pending_home=probe_req_home_i;pending_line=probe_req_line_addr_i;
                    pending_node=probe_req_node_i;pending_txn=probe_req_txn_i;pending_take=probe_req_take_i;
                    pending_hit=planned_hit;pending_dirty=planned_dirty;
                    pending_generation=(pending_take && pending_hit)?CGEN'(next_generation[pending_home]):'0;
                    for(integer w=0;w<LW;w=w+1) pending_data[w]=planned_data[w];
                    if(pending_take && pending_hit) begin
                        check(next_generation[pending_home]<(1<<CGEN),"coherence generation silently wrapped");
                        next_generation[pending_home]=next_generation[pending_home]+1;
                    end
                    probes=probes+1;
                end
                if(probe_resp_valid_o) begin
                    check(probe_pending && probe_resp_home_o===pending_home && probe_resp_line_addr_o===pending_line
                        && probe_resp_node_o===pending_node && probe_resp_txn_o===pending_txn
                        && probe_resp_take_o===pending_take && probe_resp_generation_o===pending_generation
                        && probe_resp_hit_o===pending_hit && probe_resp_dirty_o===pending_dirty,"probe full held response identity");
                    for(integer w=0;w<LW;w=w+1) check(probe_resp_data_o[w]===pending_data[w],"probe held full byte payload");
                    if(!probe_resp_ready_i) probe_stalls=probe_stalls+1;
                    else begin
                        if(pending_take && pending_hit) begin
                            check(!receiver_owned,"receiver owns more than one transfer");
                            receiver_owned=1;receiver_home=probe_resp_home_o;receiver_line=probe_resp_line_addr_o;
                            receiver_node=probe_resp_node_o;receiver_generation=probe_resp_generation_o;receiver_dirty=probe_resp_dirty_o;
                            for(integer w=0;w<LW;w=w+1) receiver_data[w]=probe_resp_data_o[w];
                            transfers=transfers+1;
                        end
                        probe_pending=0;probe_responses=probe_responses+1;
                    end
                end
                if(reclaim_valid_i) begin
                    if(reclaim_ready_o) begin
                        check(receiver_owned && reclaim_home_i===receiver_home && reclaim_line_addr_i===receiver_line
                            && reclaim_node_i===receiver_node && reclaim_generation_i===receiver_generation
                            && reclaim_dirty_i===receiver_dirty,"accepted reclaim full receiver identity");
                        for(integer w=0;w<LW;w=w+1) check(reclaim_data_i[w]===receiver_data[w],"reclaim must use actual receiver bytes");
                        receiver_owned=0;reclaims=reclaims+1;
                    end else if(expect_coherence_error) rejects=rejects+1;
                end
                expected_remote='0;
                for(integer h=0;h<S;h=h+1) expected_blocks[h]='0;
                if(probe_pending) expected_blocks[pending_home][integer'(pending_line)%SETS]=1;
                if(receiver_owned) begin
                    expected_blocks[receiver_home][integer'(receiver_line)%SETS]=1;
                    expected_remote[receiver_home]=1;
                end
                #1;
                check(remote_owned_present_o===expected_remote,"remote ownership after actual handoff/reclaim edge");
                for(integer h=0;h<S;h=h+1) check(coherence_block_set_o[h]===expected_blocks[h],"registered coherence resource bitmap");
                check(coherence_protocol_error_o===expect_coherence_error,"coherence rejection pulse timing");
                if(coherence_protocol_error_o) errors=errors+1;
            end
        end
    end

    task automatic wait_count(input logic [1:0] kind,input integer target);
        begin
            for(integer n=0;n<BOUND;n=n+1) begin
                if((kind==K_READ && reads>=target) || (kind==K_WB && wbs>=target) || (kind==K_STORE && stores>=target)) return;
                @(posedge clk);#2;
            end
            check(0,"bounded backend command wait");
        end
    endtask
    task automatic wait_responses(input integer target);
        begin
            for(integer n=0;n<BOUND;n=n+1) begin
                if(resps>=target) return;
                @(posedge clk);#2;
            end
            check(0,"bounded client response wait");
        end
    endtask
    task automatic request_line(input integer client,input logic [LT-1:0] tag,input logic [LAW-1:0] line);
        integer target;
        begin
            check(client>=0 && client<C && integer'(line)<MEM_LINES,"request model bounds");target=reqs+1;
            @(negedge clk);
            client_line[client][tag]=line;
            for(integer w=0;w<LW;w=w+1) client_data[client][tag][w]=cache_expected[integer'(line)][w];
            client_req_valid_i[client]=1;client_req_local_tag_i[client]=tag;client_req_line_addr_i[client]=line;
            for(integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk);#2;
                if(reqs==target) begin @(negedge clk);client_req_valid_i[client]=0;return;end
            end
            check(0,"bounded client acceptance wait");
        end
    endtask
    task automatic return_read;
        begin
            check(integer'(last_read_line)<MEM_LINES && read_live[last_read_tag],"return a real backend READ");
            @(negedge clk);backend_read_resp_valid_i=1;backend_read_resp_tag_i=last_read_tag;
            backend_read_resp_line_addr_i=last_read_line;
            for(integer w=0;w<LW;w=w+1) backend_read_resp_data_i[w]=mem[integer'(last_read_line)][w];
            @(posedge clk);#2;@(negedge clk);backend_read_resp_valid_i=0;
        end
    endtask
    task automatic fill_line(input integer client,input logic [LAW-1:0] line);
        integer old_reads,old_resps;
        begin
            old_reads=reads;old_resps=resps;request_line(client,LT'(1),line);
            wait_count(K_READ,old_reads+1);return_read();wait_responses(old_resps+1);
        end
    endtask
    task automatic hit_line(input integer client,input logic [LAW-1:0] line);
        integer old_reads,old_resps;
        begin
            old_reads=reads;old_resps=resps;request_line(client,LT'(2),line);wait_responses(old_resps+1);
            check(reads==old_reads,"resident cache bytes came from stale backend refill");
        end
    endtask
    task automatic drive_commit(input integer port,input logic [LAW-1:0] line,input logic [31:0] data);
        begin
            check(port>=0 && port<CP,"commit port range");
            @(negedge clk);commit_valid_i[port]=1;commit_lane_mask_i[port]=2'b01;
            commit_word_addr_i[port][0]=word_addr(line);commit_word_addr_i[port][1]=word_addr(line)+32'd1;
            commit_wdata_i[port][0]=data;commit_wdata_i[port][1]=data^32'hffff_ffff;
        end
    endtask
    task automatic wait_retirement(input integer port,input integer target);
        begin
            check(port>=0 && port<CP,"retirement port range");
            for(integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk);#2;
                if(retired[port]==target) begin @(negedge clk);commit_valid_i[port]=0;return;end
            end
            check(0,"bounded successful commit retirement wait");
        end
    endtask
    task automatic resident_store(input integer port,input logic [LAW-1:0] line,input logic [31:0] data);
        integer old_retired,old_stores;
        begin
            check(port>=0 && port<CP && integer'(line)<MEM_LINES,"resident store model bounds");
            old_retired=retired[port];old_stores=stores;drive_commit(port,line,data);
            wait_retirement(port,old_retired+1);cache_expected[integer'(line)][0]=data;
            check(stores==old_stores && dirty_present_o[home_of(line)],"resident STORE must update real dirty cache");
        end
    endtask
    task automatic drive_probe(input logic [LAW-1:0] line,input bit take,input bit hit,input bit dirty);
        begin
            check(integer'(line)<MEM_LINES,"probe model bounds");
            @(negedge clk);probe_req_valid_i=1;probe_req_home_i=home_of(line);probe_req_line_addr_i=line;
            probe_req_node_i=4'h1;probe_req_txn_i=4'(probes);probe_req_take_i=take;
            planned_hit=hit;planned_dirty=dirty;
            for(integer w=0;w<LW;w=w+1) planned_data[w]=hit?cache_expected[integer'(line)][w]:32'b0;
            #1;
        end
    endtask
    task automatic capture_probe;
        integer target;
        begin
            target=probes+1;
            for(integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk);#2;
                if(probes==target) begin
                    @(negedge clk);probe_req_valid_i=0;
                    // An inactive input route must never steer the held response.
                    probe_req_home_i=SID'(S-1);probe_req_line_addr_i=F;#1;
                    check(probe_resp_valid_o,"accepted probe response missing");return;
                end
            end
            check(0,"bounded probe capture wait");
        end
    endtask
    task automatic consume_probe;
        integer target;
        begin
            target=probe_responses+1;
            @(negedge clk);probe_resp_ready_i=1;
            @(posedge clk);#2;
            check(probe_responses==target,"receiver failed to accept exactly one response");
            @(negedge clk);probe_resp_ready_i=0;#1;check(!probe_resp_valid_o,"double probe response after handoff");
        end
    endtask
    task automatic query(input logic [LAW-1:0] line,input bit hit,input bit dirty);
        begin drive_probe(line,0,hit,dirty);capture_probe();consume_probe();end
    endtask
    task automatic take_a;
        begin drive_probe(A,1,1,1);capture_probe();consume_probe();end
    endtask
    task automatic return_receiver(input logic [31:0] salt);
        integer target;
        begin
            check(receiver_owned && integer'(receiver_line)<MEM_LINES,"no fabricated receiver return");target=reclaims+1;
            @(negedge clk);receiver_dirty=1;
            for(integer w=0;w<LW;w=w+1) begin
                receiver_data[w]=receiver_data[w]^salt^(32'(w)<<8);
                reclaim_data_i[w]=receiver_data[w];cache_expected[integer'(receiver_line)][w]=receiver_data[w];
            end
            reclaim_home_i=receiver_home;reclaim_line_addr_i=receiver_line;reclaim_node_i=receiver_node;
            reclaim_generation_i=receiver_generation;reclaim_dirty_i=receiver_dirty;reclaim_valid_i=1;#1;
            check(reclaim_ready_o,"exact receiver return not ready");
            @(posedge clk);#2;check(reclaims==target && !receiver_owned,"exact return failed ownership conservation");
            @(negedge clk);reclaim_valid_i=0;#1;
        end
    endtask
    // Exercise public frontend admission while a previously accepted response
    // is held. The raw STORE/READ sources stay offered until real completion.
    task automatic pending_probe_admission(input bit take);
        integer old_reqs,old_resps,old_reads,old_stores,old_wbs,old_retired;
        logic [31:0] update_word;
        begin
            old_reqs=reqs;old_resps=resps;old_reads=reads;
            old_stores=stores;old_wbs=wbs;old_retired=retired[0];
            update_word=take?32'hc034_0002:32'hc034_0001;
            drive_probe(A,take,1,1);capture_probe();
            drive_commit(0,A,update_word);
            client_req_valid_i[0]=1;client_req_local_tag_i[0]=LT'(2);
            client_req_line_addr_i[0]=A;client_line[0][LT'(2)]=A;
            for(integer w=0;w<LW;w=w+1)
                client_data[0][LT'(2)][w]=cache_expected[integer'(A)][w];
            repeat(4) begin
                @(negedge clk);#1;
                check(probe_resp_valid_o && !receiver_owned
                    && !client_req_ready_o[0] && commit_read_wait_o[0]
                    && !commit_visibility_busy_o && !store_completion_busy_o
                    && commit_ready_o=='0 && commit_abort_o=='0
                    && reqs==old_reqs && resps==old_resps && reads==old_reads
                    && stores==old_stores && wbs==old_wbs,
                    "held accepted probe must block frontend STORE capture and READ");
            end
            if(take) mark("PENDING_TAKE_BLOCKS_LOCAL_ADMISSION");
            else mark("PENDING_QUERY_BLOCKS_LOCAL_ADMISSION");
            consume_probe();
            if(take) begin
                repeat(3) begin
                    @(negedge clk);#1;
                    check(receiver_owned && commit_read_wait_o[0]
                        && !client_req_ready_o[0] && !commit_visibility_busy_o
                        && reqs==old_reqs && stores==old_stores,
                        "handoff must retain queued local sources outside frontend");
                end
                // Same home, independent set: global probe response is now held
                // while exact reclaim must progress through the production bank.
                if(SETS>1) begin
                    check(home_of(DS)==home_of(A) && !same_resource(DS,A),
                        "pending query resource construction");
                    drive_probe(DS,0,0,0);capture_probe();
                end
                return_receiver(32'h0077_4400);
                check(!receiver_owned && reqs==old_reqs,
                    "reclaim edge must use pre-edge ownership for local admission");
                if(SETS>1) check(probe_resp_valid_o && probe_pending,
                    "reclaim must preserve unrelated held QUERY response");
                mark("RECLAIM_WITH_WAITING_LOCAL_WORK");
            end
            // No client admission can occur before the retained raw STORE retires.
            cache_expected[integer'(A)][0]=update_word;
            for(integer w=0;w<LW;w=w+1)
                client_data[0][LT'(2)][w]=cache_expected[integer'(A)][w];
            wait_retirement(0,old_retired+1);
            for(integer n=0;n<BOUND;n=n+1) begin
                @(posedge clk);#2;
                if(reqs==old_reqs+1) break;
                if(n==BOUND-1) check(0,"pending local READ failed to resume");
            end
            @(negedge clk);client_req_valid_i[0]=0;
            wait_responses(old_resps+1);
            check(reqs==old_reqs+1 && resps==old_resps+1
                && reads==old_reads && stores==old_stores && wbs==old_wbs
                && retired[0]==old_retired+1,
                "waiting work must complete exactly once from updated real cache");
            if(take && SETS>1) begin
                check(probe_resp_valid_o && probe_pending,
                    "unrelated held QUERY lost during local progress");
                consume_probe();mark("RECLAIM_WITH_DISJOINT_PENDING_QUERY");
            end
        end
    endtask
    task automatic bad_return(input integer kind,input logic [CGEN-1:0] stale_generation);
        integer before_rejects;
        begin
            check(receiver_owned && kind>=0 && kind<=4,"rejection stimulus bounds");before_rejects=rejects;
            @(negedge clk);reclaim_home_i=receiver_home;reclaim_line_addr_i=receiver_line;
            reclaim_node_i=receiver_node;reclaim_generation_i=receiver_generation;reclaim_dirty_i=receiver_dirty;
            for(integer w=0;w<LW;w=w+1) reclaim_data_i[w]=32'hbad0_0000+32'(w);
            case(kind)
                0: reclaim_home_i=SID'(1);
                1: reclaim_line_addr_i=B;
                2: reclaim_node_i=4'h2;
                3: reclaim_generation_i=receiver_generation^CGEN'(1);
                4: reclaim_generation_i=stale_generation;
                default: check(0,"bad return selector");
            endcase
            reclaim_valid_i=1;expect_coherence_error=1;#1;check(!reclaim_ready_o,"malformed return accepted");
            @(posedge clk);#2;check(receiver_owned && rejects==before_rejects+1,"rejected return changed receiver ownership");
            @(negedge clk);reclaim_valid_i=0;expect_coherence_error=0;
            @(posedge clk);#2;check(!coherence_protocol_error_o,"coherence error not a pulse");
        end
    endtask
    task automatic return_wb;
        begin
            check(wb_live && integer'(last_wb_line)<MEM_LINES,"return actual issued WB only");
            @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_success_i=1;
            backend_wb_status_attempt_id_i=last_wb_id;
            @(posedge clk);#2;
            for(integer w=0;w<LW;w=w+1) mem[integer'(last_wb_line)][w]=last_wb_data[w];
            @(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;
        end
    endtask

    initial begin : stimulus
        integer before_req,before_resp,before_read,before_wb,before_store,before_probe,before_retire;
        logic [CGEN-1:0] old_generation;
        if(VARIANT<0 || VARIANT>2) $fatal(1,"P34 integration VARIANT must be 0, 1 or 2");
        cycles=0;checks=0;scenarios=0;reqs=0;resps=0;reads=0;read_returns=0;wbs=0;wb_returns=0;
        stores=0;store_returns=0;probes=0;probe_responses=0;transfers=0;reclaims=0;rejects=0;
        errors=0;rearms=0;drains=0;stalls=0;probe_stalls=0;faults=0;
        wb_live=0;store_live=0;stalled=0;probe_pending=0;receiver_owned=0;expect_coherence_error=0;
        rst_n=0;client_req_valid_i='0;commit_valid_i='0;backend_cmd_ready_i=1;
        backend_read_resp_valid_i=0;backend_read_resp_fault_i=0;backend_read_resp_tag_i='0;backend_read_resp_line_addr_i='0;
        backend_wb_status_valid_i=0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_wb_status_attempt_id_i='0;
        backend_store_status_valid_i=0;backend_store_status_success_i=0;backend_store_status_retryable_i=0;backend_store_status_attempt_id_i='0;
        backend_store_status_reuse_safe_i=0;backend_store_all_generations_quiescent_i=0;backend_wb_recovery_safe_valid_i='0;
        commit_fault_ready_i=0;probe_req_valid_i=0;probe_req_take_i=0;probe_req_home_i='0;probe_req_line_addr_i='0;
        probe_req_node_i=1;probe_req_txn_i=0;probe_resp_ready_i=0;reclaim_valid_i=0;
        reclaim_home_i='0;reclaim_line_addr_i='0;reclaim_node_i='0;reclaim_generation_i='0;reclaim_dirty_i=0;
        probe_reuse_safe_i='1;planned_hit=0;planned_dirty=0;
        for(integer p=0;p<CP;p=p+1) begin
            retired[p]=0;aborted[p]=0;commit_lane_mask_i[p]='0;
            for(integer l=0;l<LANES;l=l+1) begin commit_word_addr_i[p][l]='0;commit_wdata_i[p][l]='0;end
        end
        for(integer c=0;c<C;c=c+1) begin
            client_req_local_tag_i[c]='0;client_req_line_addr_i[c]='0;
            for(integer t=0;t<TAGS;t=t+1) begin
                client_live[c][t]=0;client_line[c][t]='0;
                for(integer w=0;w<LW;w=w+1) client_data[c][t][w]='0;
            end
        end
        for(integer t=0;t<(1<<BRTW);t=t+1) begin read_live[t]=0;read_line[t]='0;end
        for(integer h=0;h<S;h=h+1) next_generation[h]=0;
        for(integer w=0;w<LW;w=w+1) begin backend_read_resp_data_i[w]='0;reclaim_data_i[w]='0;planned_data[w]='0;end
        for(integer a=0;a<MEM_LINES;a=a+1)
            for(integer w=0;w<LW;w=w+1) begin
                mem[a][w]=32'h3400_0000+32'(a*32+w);cache_expected[a][w]=mem[a][w];
            end
        repeat(3) @(posedge clk);
        @(negedge clk);rst_n=1;#1;
        check(dirty_present_o=='0 && remote_owned_present_o=='0 && probe_generation_exhausted_o=='0,"cold empty state");
        mark("RESET_EMPTY");

        // An already accepted client READ must drain through both the retained
        // backend offer and the no-ready client response before this probe wins.
        backend_cmd_ready_i=0;before_resp=resps;before_read=reads;
        request_line(0,LT'(1),A);drive_probe(A,0,1,0);
        for(integer n=0;n<BOUND;n=n+1) begin
            if(backend_cmd_valid_o) break;
            @(negedge clk);#1;if(n==BOUND-1) check(0,"older READ backend offer missing");
        end
        repeat(3) begin @(negedge clk);#1;check(!probe_req_ready_o && backend_cmd_valid_o,"waiting probe starved retained READ");end
        backend_cmd_ready_i=1;wait_count(K_READ,before_read+1);
        return_read();check(!probe_req_ready_o,"probe accepted before old client response drained");
        wait_responses(before_resp+1);capture_probe();consume_probe();
        mark("OLDER_READ_DRAINS_BEFORE_PROBE");

        resident_store(0,A,32'hd134_0001);query(A,1,1);hit_line(1,A);
        mark("RESIDENT_STORE_QUERY");
        pending_probe_admission(0);
        pending_probe_admission(1);
        before_retire=retired[0];before_store=stores;
        drive_commit(0,A,32'hd234_0002);
        // Both valids are driven in the same negedge interval, before an edge.
        probe_req_valid_i=1;probe_req_take_i=0;probe_req_home_i=home_of(A);probe_req_line_addr_i=A;
        probe_req_node_i=1;probe_req_txn_i=4'(probes);planned_hit=1;planned_dirty=1;
        cache_expected[integer'(A)][0]=32'hd234_0002;
        for(integer w=0;w<LW;w=w+1) planned_data[w]=cache_expected[integer'(A)][w];
        #1;check(!probe_req_ready_o,"raw STORE must win simultaneous raw probe");
        wait_retirement(0,before_retire+1);check(stores==before_store,"raw-priority resident STORE escaped to memory");
        capture_probe();consume_probe();mark("RAW_STORE_WINS_RAW_PROBE");

        drive_probe(A,1,1,1);capture_probe();
        repeat(4) begin @(negedge clk);#1;check(!receiver_owned && dirty_present_o[home_of(A)] && probe_resp_valid_o,
            "offered TAKE moved ownership before receiver acceptance");end
        consume_probe();old_generation=receiver_generation;
        check(receiver_owned && !dirty_present_o[home_of(A)],"TAKE handoff did not remove source dirty residency");
        mark("TAKE_RESPONSE_BACKPRESSURE");
        before_req=reqs;before_read=reads;before_store=stores;
        @(negedge clk);client_req_valid_i='1;client_req_line_addr_i[0]=A;client_req_line_addr_i[1]=B;
        commit_valid_i='1;
        for(integer p=0;p<CP;p=p+1) begin
            commit_lane_mask_i[p]=2'b01;commit_word_addr_i[p][0]=word_addr((p==0)?A:B);
            commit_wdata_i[p][0]=32'hbad0_0000+32'(p);
        end
        repeat(4) begin @(negedge clk);#1;check(client_req_ready_o=='0 && commit_ready_o=='0
            && !backend_cmd_valid_o && reqs==before_req && reads==before_read && stores==before_store,
            "remote ownership admitted exact/alias READ or STORE");end
        @(negedge clk);client_req_valid_i='0;commit_valid_i='0;
        mark("REMOTE_HOLD_READ_STORE_ALIAS_BLOCK");
        if(SETS>1) begin
            check(home_of(DS)==home_of(A) && !same_resource(DS,A),"same-home disjoint-set address construction");
            fill_line(1,DS);resident_store(1,DS,32'hd534_0003);hit_line(1,DS);
            check(receiver_owned,"disjoint set disturbed remote receiver");mark("DISJOINT_SET_PROGRESS");
        end
        if(S>1) begin
            check(home_of(DH)!=home_of(A),"disjoint-home address construction");
            fill_line(1,DH);resident_store(1,DH,32'hd634_0004);hit_line(1,DH);
            check(receiver_owned,"disjoint home disturbed remote receiver");mark("DISJOINT_HOME_PROGRESS");
        end
        for(integer bad=0;bad<4;bad=bad+1) bad_return(bad,'0);
        mark("RECLAIM_TUPLE_REJECTIONS");
        return_receiver(32'h1248_369c);hit_line(0,A);query(A,1,1);
        mark("EXACT_RECLAIM_REAL_CACHE_BYTES");
        take_a();check(receiver_generation!==old_generation,"fresh TAKE reused previous generation");
        bad_return(4,old_generation);return_receiver(32'h5566_7788);
        mark("STALE_GENERATION_REPLAY");
        while(next_generation[home_of(A)]<(1<<CGEN)) begin take_a();return_receiver(32'h00ff_3300);end
        query(A,1,1);drive_probe(A,1,1,1);
        repeat(3) begin @(negedge clk);#1;check(!probe_req_ready_o && probe_generation_exhausted_o[home_of(A)],
            "already-high reuse certificate bypassed exhaustion");end
        @(negedge clk);probe_req_valid_i=0;
        mark("GENERATION_EXHAUSTION_HOLDS_QUERY_PROGRESS");
        check(!receiver_owned && !probe_pending && reqs==resps && reads==read_returns && !wb_live && !store_live,
            "reuse certificate lacks drained real ledgers");
        @(negedge clk);probe_reuse_safe_i[home_of(A)]=0;
        @(posedge clk);#2;@(negedge clk);probe_reuse_safe_i[home_of(A)]=1;
        for(integer n=0;n<BOUND;n=n+1) begin
            @(posedge clk);#2;
            if(!probe_generation_exhausted_o[home_of(A)]) break;
            if(n==BOUND-1) check(0,"truthful idle LOW/HIGH certificate failed");
        end
        next_generation[home_of(A)]=0;hit_line(0,A);take_a();
        check(receiver_generation=='0,"certified generation reuse did not restart at zero");
        return_receiver(32'h9876_5432);mark("TRUTHFUL_IDLE_CERTIFICATE_REARMS");

        // Real dirty eviction after receiver modification. WB bytes and attempt
        // identity stay held, and the waiting probe cannot steal the old READ.
        before_resp=resps;before_read=reads;before_wb=wbs;backend_cmd_ready_i=0;
        request_line(0,LT'(3),B);drive_probe(B,0,1,0);
        for(integer n=0;n<BOUND;n=n+1) begin
            if(backend_cmd_valid_o) break;
            @(negedge clk);#1;if(n==BOUND-1) check(0,"dirty victim WB offer missing");
        end
        repeat(3) begin @(negedge clk);#1;check(backend_cmd_kind_o==K_WB && !probe_req_ready_o,"probe bypassed held dirty WB");end
        backend_cmd_ready_i=1;wait_count(K_WB,before_wb+1);
        check(last_wb_line===A && (|wb_busy_o),"dirty WB victim route/liveness");
        repeat(3) begin @(negedge clk);#1;check(!probe_req_ready_o,"probe bypassed WB status wait");end
        return_wb();wait_count(K_READ,before_read+1);return_read();wait_responses(before_resp+1);
        capture_probe();consume_probe();hit_line(1,B);mark("DIRTY_WRITEBACK_PAYLOAD");

        // The failed STORE is a miss on F, which aliases B's home/set. Keep a
        // QUERY to B pending from captured STORE through abort-source withdrawal.
        before_store=stores;before_probe=probes;backend_cmd_ready_i=0;
        drive_commit(1,F,32'hfa11_0034);drive_probe(B,0,1,0);
        for(integer n=0;n<BOUND;n=n+1) begin
            if(backend_cmd_valid_o) break;
            @(negedge clk);#1;if(n==BOUND-1) check(0,"captured STORE backend offer missing");
        end
        repeat(3) begin @(negedge clk);#1;check(backend_cmd_kind_o==K_STORE && !probe_req_ready_o,"probe starved captured STORE");end
        backend_cmd_ready_i=1;wait_count(K_STORE,before_store+1);
        check(last_store_addr===word_addr(F) && last_store_data===32'hfa11_0034,"failed STORE actual physical tuple");
        @(negedge clk);backend_store_status_valid_i=1;backend_store_status_attempt_id_i=last_store_id;
        backend_store_status_success_i=0;
        @(posedge clk);#2;@(negedge clk);backend_store_status_valid_i=0;
        for(integer n=0;n<BOUND;n=n+1) begin
            @(posedge clk);#2;if(commit_fault_valid_o) break;
            if(n==BOUND-1) check(0,"terminal STORE architectural fault missing");
        end
        repeat(3) begin @(negedge clk);#1;check(!probe_req_ready_o && commit_abort_o=='0 && commit_ready_o=='0,
            "fault backpressure released captured resource");end
        @(negedge clk);commit_fault_ready_i=1;
        for(integer n=0;n<BOUND;n=n+1) begin
            @(posedge clk);#2;if(aborted[1]==1) break;
            if(n==BOUND-1) check(0,"separate fault abort missing");
        end
        @(negedge clk);commit_fault_ready_i=0;commit_valid_i[1]=0;
        repeat(4) begin @(negedge clk);#1;check(recovery_required_o && recovery_reset_blocked_o
            && !probe_req_ready_o && probes==before_probe,"raw-withdrawn captured STORE quarantine lost");end
        mark("CAPTURED_STORE_QUARANTINE_AFTER_WITHDRAWAL");
        @(negedge clk);backend_store_status_reuse_safe_i=1;
        for(integer n=0;n<BOUND;n=n+1) begin
            @(negedge clk);#1;
            if(recovery_rearm_pulse_o || recovery_drain_active_o)
                check(!probe_req_ready_o,"probe bypassed STORE-only rearm/drain reservation");
            if(rearms==1 && !recovery_required_o && !recovery_rearm_pulse_o && !recovery_drain_active_o) break;
            if(n==BOUND-1) check(0,"bounded STORE-only recovery/drain failed");
        end
        mark("RECOVERY_REARM_PROBE_ORDERING");
        // The request has remained offered throughout. It may be accepted on
        // the first edge after drain release, so inspect its actual ledger.
        if(probes==before_probe) capture_probe();
        else begin
            check(probes==before_probe+1 && probe_pending,"recovery released multiple probes");
            @(negedge clk);probe_req_valid_i=0;#1;
        end
        consume_probe();hit_line(0,B);
        check(stores==1 && store_returns==1 && faults==1 && aborted[0]==0 && aborted[1]==1
            && retired[0]==4 && retired[1]==((S>1)?2:0),"recovery fabricated/doubled commit retirement or abort");
        check(rearms==1 && drains>0 && store_generation_next_o==GEN'(1),"STORE recovery changed live generation identity");
        mark("POST_RECOVERY_QUERY_NO_FABRICATED_COMPLETION");

        repeat(3) @(negedge clk);
        check(reqs==resps && reads==read_returns && wbs==wb_returns && wbs==1
            && probes==probe_responses && transfers==reclaims && transfers==(1<<CGEN)+1,
            "final exact transaction conservation");
        check(!wb_live && !store_live && !receiver_owned && !probe_pending && !probe_resp_valid_o
            && client_read_outstanding_o=='0 && wb_pending_count_o=='0 && wb_active_count_o=='0
            && wb_busy_o=='0 && remote_owned_present_o=='0,"final live transaction leaked");
        for(integer c=0;c<C;c=c+1)
            for(integer t=0;t<TAGS;t=t+1) check(!client_live[c][t],"final live client ledger entry");
        for(integer t=0;t<(1<<BRTW);t=t+1) check(!read_live[t],"final live backend READ ledger entry");
        check(rejects==5 && errors==5 && stalls>=9 && probe_stalls>=4,"rejection/backpressure evidence cardinality");
        mark("HANDSHAKE_ACCOUNTING");
        check(scenarios==((S>1)?22:19),"integrated scenario cardinality");
        $display("P34_INTEGRATED_DEVELOPMENT_PASS={\"variant\":%0d,\"slices\":%0d,\"sets\":%0d,\"line_words\":%0d,\"scenarios\":%0d,\"checks\":%0d,\"client_accepts\":%0d,\"client_responses\":%0d,\"reads\":%0d,\"read_returns\":%0d,\"wb\":%0d,\"wb_returns\":%0d,\"stores\":%0d,\"store_returns\":%0d,\"probes\":%0d,\"probe_responses\":%0d,\"transfers\":%0d,\"reclaims\":%0d,\"rejects\":%0d,\"errors\":%0d,\"rearms\":%0d,\"drains\":%0d,\"backend_stalls\":%0d,\"probe_stalls\":%0d}",
            VARIANT,S,SETS,LW,scenarios,checks,reqs,resps,reads,read_returns,wbs,wb_returns,stores,store_returns,
            probes,probe_responses,transfers,reclaims,rejects,errors,rearms,drains,stalls,probe_stalls);
        $finish;
    end
endmodule
