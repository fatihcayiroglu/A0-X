`timescale 1ns/1ps
// P36 real hierarchy proof. Public ledgers are independent of DUT busy flags.
module a0_production_atomic_fenced_subsystem_tb #(parameter integer VARIANT=0);
    localparam integer C=2,LT=2,CO=2,CP=2,LANES=2,S=1<<VARIANT,SETS=2<<VARIANT,LW=1<<VARIANT;
    localparam integer WSEL=VARIANT,LAW=32-WSEL,SID=(S<=1)?1:$clog2(S),CID=$clog2(C+1);
    localparam integer WID=2,RW=1,SWID=2,SRW=1,GEN=3,CGEN=8,BRTW=SID+CID+LT,BATW=SID+WID+RW,SAID=GEN+SWID+SRW;
    localparam integer CNTW=(S<=1)?1:$clog2(S+1),RCW=3,TO=512,TW=9,MEM_LINES=48*S*SETS+64;
    localparam integer ASW=2,ACW=2,AIW=8,AGW=2,AE=8,AOW=$clog2(AE+1),FSW=2,FCW=2,FIW=8,FGW=2;
    localparam integer READ_CAP=1<<BRTW,WB_CAP=1<<BATW,STORE_CAP=1<<SAID,TAGS=1<<LT;
    localparam integer TUPW=2+BRTW+BATW+SAID+LAW+32*LW+64;
    localparam integer ARW=ASW+ACW+AIW+AGW+32+1+4+64+64+64+1+4;
    localparam integer FRW=FSW+FCW+FIW+FGW+2+5;
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
    logic [S-1:0] probe_reuse_safe_i,remote_owned_present_o,probe_generation_exhausted_o;
    logic [SETS-1:0] coherence_block_set_o[0:S-1];
    logic coherence_protocol_error_o,protocol_error_o;
    logic atomic_new_issue_o,atomic_issue_rejected_o,atomic_transport_duplicate_o,atomic_response_rejected_o,atomic_transport_replay_o;
    logic [AOW-1:0] atomic_requester_outstanding_o;
    logic atomic_req_valid_i,atomic_req_ready_o,atomic_req_is64_i;
    logic [ASW-1:0] atomic_req_source_i,atomic_retire_source_o;
    logic [ACW-1:0] atomic_req_context_i,atomic_retire_context_o;
    logic [AIW-1:0] atomic_req_request_id_i,atomic_retire_request_id_o;
    logic [AGW-1:0] atomic_req_generation_i,atomic_retire_generation_o;
    logic [31:0] atomic_req_word_addr_i,atomic_retire_word_addr_o;
    logic [3:0] atomic_req_op_i,atomic_retire_op_o,atomic_retire_fault_o;
    logic [63:0] atomic_req_operand_i,atomic_req_compare_i,atomic_retire_operand_o,atomic_retire_compare_o,atomic_retire_old_o;
    logic atomic_retire_valid_o,atomic_retire_ready_i,atomic_retire_is64_o,atomic_retire_cas_success_o;
    logic atomic_epoch_advance_valid_i,atomic_epoch_advance_ready_o,atomic_epoch_quiescent_i,atomic_all_generations_quiescent_i;
    logic [AGW-1:0] atomic_current_generation_o;
    logic atomic_epoch_advance_pulse_o,atomic_table_full_o,atomic_busy_o,atomic_protocol_error_o;
    logic fence_req_valid_i,fence_req_ready_o,fence_resp_valid_o,fence_resp_ready_i;
    logic [FSW-1:0] fence_req_source_i,fence_resp_source_o;
    logic [FCW-1:0] fence_req_context_i,fence_resp_context_o;
    logic [FIW-1:0] fence_req_request_id_i,fence_resp_request_id_o;
    logic [FGW-1:0] fence_req_generation_i,fence_resp_generation_o;
    logic fence_req_acquire_i,fence_req_release_i,fence_resp_acquire_o,fence_resp_release_o;
    logic [4:0] fence_resp_fault_bits_o;
    logic fence_busy_o,fence_protocol_error_o;
    logic [CP-1:0] fence_pending_store_o;

    logic [31:0] mem[0:MEM_LINES-1][0:LW-1],expected_cache[0:MEM_LINES-1][0:LW-1];
    logic read_live[0:READ_CAP-1],read_fault[0:READ_CAP-1];
    logic [LAW-1:0] read_line[0:READ_CAP-1];
    logic wb_live[0:WB_CAP-1],wb_fail[0:WB_CAP-1];
    logic [LAW-1:0] wb_line[0:WB_CAP-1];
    logic [31:0] wb_data[0:WB_CAP-1][0:LW-1];
    logic store_live[0:STORE_CAP-1],store_fail[0:STORE_CAP-1];
    logic [31:0] store_addr[0:STORE_CAP-1],store_data[0:STORE_CAP-1];
    logic public_live[0:C-1][0:TAGS-1];
    logic [LAW-1:0] public_line[0:C-1][0:TAGS-1];
    logic public_fault[0:C-1][0:TAGS-1];
    logic atomic_known[0:255],atomic_live[0:255],atomic_effect_accounted[0:255];
    logic [ASW-1:0] saved_asource[0:255];
    logic [ACW-1:0] saved_acontext[0:255];
    logic [AGW-1:0] saved_ageneration[0:255];
    logic [31:0] saved_aaddr[0:255];
    logic saved_awide[0:255],saved_acas[0:255];
    logic [3:0] saved_aop[0:255],saved_afault[0:255];
    logic [63:0] saved_aoperand[0:255],saved_acompare[0:255],saved_aold[0:255],saved_anew[0:255];
    logic [CP-1:0] withdraw_store,pending_store_mask;
    logic [LANES-1:0] fence_store_mask[0:CP-1];
    logic [31:0] fence_store_addr[0:CP-1][0:LANES-1],fence_store_data[0:CP-1][0:LANES-1];
    logic manual_backend_ready,permit_read,permit_wb,permit_store,permit_store_reuse,permit_wb_recovery;
    logic inject_read_failure,inject_wb_failure,inject_stale_store_status,stale_status_driven;
    logic [31:0] fail_store_addr;
    logic [SAID-1:0] stale_store_id,last_store_id;
    logic command_stalled,atomic_stalled,fence_stalled,fence_live;
    logic [TUPW-1:0] command_tuple,held_command;
    logic [ARW-1:0] atomic_tuple,held_atomic;
    logic [FRW-1:0] fence_tuple,held_fence;
    logic [FSW-1:0] expected_fsource;
    logic [FCW-1:0] expected_fcontext;
    logic [FIW-1:0] expected_fid;
    logic [FGW-1:0] expected_fgeneration;
    logic expected_facquire,expected_frelease;
    logic [4:0] expected_ffault;
    integer cycles,checks,scenarios,read_commands,read_statuses,wb_commands,wb_statuses,wb_successes;
    integer store_commands,store_statuses,store_successes,client_accepts,client_returns;
    integer atomic_accepts,atomic_retires,atomic_allocations,atomic_duplicates,atomic_replays;
    integer fence_accepts,fence_returns,fence_errors,store_rearms,wb_recoveries,wb_certificates,stale_packets,status_rejects;
    integer retired[0:CP-1],aborted[0:CP-1],next_atomic_id,next_fence_id,store_sequence,epoch_issued;

    a0_production_atomic_fenced_subsystem #(
        .CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.COMMIT_PORT_COUNT(CP),
        .STORE_LANES(LANES),.SLICE_COUNT(S),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),
        .WRITE_ID_W(WID),.MAX_WB_RETRIES(1),.STORE_WRITE_ID_W(SWID),.MAX_STORE_RETRIES(1),
        .STORE_GENERATION_W(GEN),.STORE_STATUS_TIMEOUT_CYCLES(TO),.CLIENT_READ_COUNT_W(RCW),
        .COHERENCE_GEN_W(CGEN),.ATOMIC_SOURCE_W(ASW),.ATOMIC_CONTEXT_W(ACW),.ATOMIC_REQUEST_ID_W(AIW),
        .ATOMIC_GENERATION_W(AGW),.ATOMIC_ENTRY_COUNT(AE),.FENCE_SOURCE_W(FSW),.FENCE_CONTEXT_W(FCW),
        .FENCE_REQUEST_ID_W(FIW),.FENCE_GENERATION_W(FGW)
    ) dut(.*);
    initial begin clk=0;forever #5 clk=~clk;end
    task automatic check(input bit ok,input string detail);
        if(!ok)$fatal(1,"P36_INTEGRATED_CHECK_FAILED cycle=%0d %s",cycles,detail);
        checks=checks+1;
    endtask
    task automatic tick;
        @(negedge clk);#1;
        if(rst_n&&fence_live)check(fence_pending_store_o===pending_store_mask,"captured STORE obligation mask");
    endtask
    task automatic mark(input string name);
        scenarios=scenarios+1;$display("P36_INTEGRATED_SCENARIO_PASS id=%0d name=%s",scenarios,name);
    endtask
    function automatic integer count_reads;
        integer n;
        begin n=0;for(integer i=0;i<READ_CAP;i=i+1)if(read_live[i])n=n+1;count_reads=n;end
    endfunction
    function automatic integer count_wbs;
        integer n;
        begin n=0;for(integer i=0;i<WB_CAP;i=i+1)if(wb_live[i])n=n+1;count_wbs=n;end
    endfunction
    function automatic integer count_stores;
        integer n;
        begin n=0;for(integer i=0;i<STORE_CAP;i=i+1)if(store_live[i])n=n+1;count_stores=n;end
    endfunction
    function automatic integer count_clients;
        integer n;
        begin n=0;for(integer c=0;c<C;c=c+1)for(integer t=0;t<TAGS;t=t+1)if(public_live[c][t])n=n+1;count_clients=n;end
    endfunction
    function automatic integer count_atomics;
        integer n;
        begin n=0;for(integer i=0;i<256;i=i+1)if(atomic_live[i])n=n+1;count_atomics=n;end
    endfunction
    function automatic logic [63:0] model_old(input logic [31:0] addr,input logic wide);
        logic [63:0] value;
        begin
            value='0;value[31:0]=expected_cache[integer'(addr)/LW][integer'(addr)%LW];
            for(integer w=0;w<LW;w=w+1)
                if(wide&&w==integer'(addr)%LW+1)value[63:32]=expected_cache[integer'(addr)/LW][w];
            model_old=value;
        end
    endfunction
    function automatic logic [63:0] ref_result(input logic [63:0] old,input logic wide,
        input logic [3:0] op,input logic [63:0] operand,compare);
        logic [63:0] mask,a,b,c,r;
        begin
            mask=wide?64'hffff_ffff_ffff_ffff:64'h0000_0000_ffff_ffff;
            a=old&mask;b=operand&mask;c=compare&mask;r=a;
            case(op)
                0:r=b;1:if(a==c)r=b;2:r=(a+b)&mask;3:r=(a-b)&mask;
                4:if(wide?$signed(a)>$signed(b):$signed(a[31:0])>$signed(b[31:0]))r=b;
                5:if(wide?$signed(a)<$signed(b):$signed(a[31:0])<$signed(b[31:0]))r=b;
                6:if(a>b)r=b;7:if(a<b)r=b;8:r=a&b;9:r=a|b;10:r=a^b;
                default:r=a;
            endcase
            ref_result=r;
        end
    endfunction
    always_comb begin
        command_tuple='0;
        command_tuple[TUPW-1 -: (2+BRTW+BATW+SAID+LAW+64)]={backend_cmd_kind_o,backend_cmd_read_tag_o,
            backend_cmd_wb_attempt_id_o,backend_cmd_store_attempt_id_o,backend_cmd_line_addr_o,
            backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o};
        for(integer w=0;w<LW;w=w+1)command_tuple[w*32+:32]=backend_cmd_data_o[w];
        atomic_tuple={atomic_retire_source_o,atomic_retire_context_o,atomic_retire_request_id_o,
            atomic_retire_generation_o,atomic_retire_word_addr_o,atomic_retire_is64_o,atomic_retire_op_o,
            atomic_retire_operand_o,atomic_retire_compare_o,atomic_retire_old_o,atomic_retire_cas_success_o,atomic_retire_fault_o};
        fence_tuple={fence_resp_source_o,fence_resp_context_o,fence_resp_request_id_o,fence_resp_generation_o,
            fence_resp_acquire_o,fence_resp_release_o,fence_resp_fault_bits_o};
    end

    initial begin : monitor
        integer id,line,word,port_id;
        logic store_match;
        forever begin
            @(posedge clk);cycles=cycles+1;if(cycles>120000)$fatal(1,"P36 integrated watchdog");
            if(rst_n)begin
                check(!protocol_error_o&&!atomic_protocol_error_o&&!coherence_protocol_error_o&&!fence_protocol_error_o,
                    "production protocol identity fault");
                check(!line_resp_tag_error_o&&!line_resp_overflow_o&&!atomic_response_rejected_o&&!atomic_issue_rejected_o,
                    "unexpected identity rejection");
                check(!( |(commit_ready_o&commit_read_wait_o))&&!(|(client_req_valid_i&client_req_ready_o&client_store_conflict_o)),
                    "READ/STORE ordering admission violation");
                check(!store_status_timeout_seen_o&&!store_status_timeout_pulse_o,"unexpected STORE timeout");
                check(store_status_timeout_live_o||store_status_timeout_age_o==0,"timer age without live STORE");
                check(!store_completion_busy_o||commit_visibility_busy_o,"STORE completion lost visibility reservation");
                check(integer'(wb_pending_count_o)+integer'(wb_active_count_o)<=S,"bounded physical WB queue");
                check(store_generation_next_o==GEN'(store_commands),"P30 STORE generation exact");
                for(integer h=0;h<S;h=h+1)begin
                    check(wb_retry_count_o[h]==0,"unexpected WB retry");
                    check(!remote_owned_present_o[h]||(|coherence_block_set_o[h]),"remote owner lost reservation");
                    if(recovery_complete_pulse_o[h])wb_recoveries=wb_recoveries+1;
                end
                check(probe_generation_exhausted_o==0,"coherence generation exhausted");
                for(integer h=0;h<S;h=h+1)if(backend_wb_recovery_safe_valid_i[h]&&backend_wb_recovery_safe_ready_o[h])
                    wb_certificates=wb_certificates+1;
                check(store_retry_count_o==0,"unexpected STORE retry");
                check(!recovery_reset_blocked_o||recovery_required_o,"STORE reset block without recovery");
                if(recovery_rearm_pulse_o)store_rearms=store_rearms+1;
                if(store_status_rejected_o)status_rejects=status_rejects+1;
                if(command_stalled)check(backend_cmd_valid_o&&command_tuple===held_command,"backend promise changed under backpressure");
                command_stalled=backend_cmd_valid_o&&!backend_cmd_ready_i;if(command_stalled)held_command=command_tuple;
                if(atomic_stalled)check(atomic_retire_valid_o&&atomic_tuple===held_atomic,"architectural atomic result changed under backpressure");
                atomic_stalled=atomic_retire_valid_o&&!atomic_retire_ready_i;if(atomic_stalled)held_atomic=atomic_tuple;
                if(fence_stalled)check(fence_resp_valid_o&&fence_tuple===held_fence,"fence response changed under backpressure");
                fence_stalled=fence_resp_valid_o&&!fence_resp_ready_i;if(fence_stalled)held_fence=fence_tuple;

                if(fence_live||(fence_req_valid_i&&fence_req_ready_o))begin
                    check(!( |(client_req_valid_i&client_req_ready_o))&&!(atomic_req_valid_i&&atomic_req_ready_o)
                        &&!(atomic_epoch_advance_valid_i&&atomic_epoch_advance_ready_o),"P36 younger admission crossed fence cut");
                end
                if(fence_req_valid_i&&fence_req_ready_o)begin
                    check(!fence_live,"second fence acceptance");fence_live=1;fence_accepts=fence_accepts+1;
                    expected_fsource=fence_req_source_i;expected_fcontext=fence_req_context_i;
                    expected_fid=fence_req_request_id_i;expected_fgeneration=fence_req_generation_i;
                    expected_facquire=fence_req_acquire_i;expected_frelease=fence_req_release_i;
                    expected_ffault=(!fence_req_acquire_i&&!fence_req_release_i)?5'b10000:5'b00000;
                    if(|wb_terminal_failure_o)expected_ffault[3]=1;
                    pending_store_mask=commit_valid_i;
                    for(integer p=0;p<CP;p=p+1)begin
                        fence_store_mask[p]=commit_lane_mask_i[p];
                        for(integer l=0;l<LANES;l=l+1)begin
                            fence_store_addr[p][l]=commit_word_addr_i[p][l];fence_store_data[p][l]=commit_wdata_i[p][l];
                        end
                    end
                end

                if(backend_read_resp_valid_i)begin
                    id=integer'(backend_read_resp_tag_i);check(id>=0&&id<READ_CAP,"backend READ response index range");
                    check(read_live[id],"duplicate or unknown backend READ response");
                    check(backend_read_resp_line_addr_i===read_line[id]&&backend_read_resp_fault_i===read_fault[id],"exact backend READ identity/fault");
                    read_live[id]=0;read_statuses=read_statuses+1;
                end
                if(backend_wb_status_valid_i)begin
                    id=integer'(backend_wb_status_attempt_id_i);check(id>=0&&id<WB_CAP,"backend WB status index range");
                    check(wb_live[id],"duplicate or unknown WB status");
                    check(backend_wb_status_success_i===!wb_fail[id]&&!backend_wb_status_retryable_i,"exact WB status");
                    if(backend_wb_status_success_i)begin
                        for(integer w=0;w<LW;w=w+1)mem[integer'(wb_line[id])][w]=wb_data[id][w];
                        wb_successes=wb_successes+1;
                    end
                    wb_live[id]=0;wb_statuses=wb_statuses+1;
                end
                if(backend_store_status_valid_i)begin
                    id=integer'(backend_store_status_attempt_id_i);
                    check(id>=0&&id<STORE_CAP,"backend STORE status index range");
                    if(stale_status_driven)begin
                        check(!store_live[id],"stale fixture accidentally used live STORE identity");stale_packets=stale_packets+1;
                    end else begin
                        check(store_live[id],"duplicate or unknown STORE status");
                        check(backend_store_status_success_i===!store_fail[id]&&!backend_store_status_retryable_i,"exact STORE status");
                        if(backend_store_status_success_i)begin
                            mem[integer'(store_addr[id])/LW][integer'(store_addr[id])%LW]=store_data[id];store_successes=store_successes+1;
                        end
                        store_live[id]=0;store_statuses=store_statuses+1;last_store_id=SAID'(id);
                    end
                end
                if(backend_cmd_valid_o&&backend_cmd_ready_i)begin
                    line=integer'(backend_cmd_line_addr_o);
                    case(backend_cmd_kind_o)
                        0:begin
                            id=integer'(backend_cmd_read_tag_o);check(id>=0&&id<READ_CAP,"backend READ command index range");
                            check(!read_live[id]&&line<MEM_LINES,"READ ledger capacity");
                            check(integer'(backend_cmd_read_tag_o[LT+:CID])<=C,"physical requester ID width");
                            if(backend_cmd_read_tag_o[LT+:CID]==CID'(C))check(backend_cmd_read_tag_o[LT-1:0]==0,"reserved atomic local tag");
                            read_live[id]=1;read_line[id]=backend_cmd_line_addr_o;read_fault[id]=inject_read_failure;
                            inject_read_failure=0;read_commands=read_commands+1;
                        end
                        1:begin
                            id=integer'(backend_cmd_wb_attempt_id_o);check(id>=0&&id<WB_CAP,"backend WB command index range");
                            check(!wb_live[id]&&line<MEM_LINES,"WB ledger capacity");
                            wb_live[id]=1;wb_line[id]=backend_cmd_line_addr_o;wb_fail[id]=inject_wb_failure;inject_wb_failure=0;
                            for(integer w=0;w<LW;w=w+1)begin
                                check(backend_cmd_data_o[w]===expected_cache[line][w],"exact byte-for-byte dirty WB payload");
                                wb_data[id][w]=backend_cmd_data_o[w];
                            end
                            wb_commands=wb_commands+1;
                        end
                        2:begin
                            id=integer'(backend_cmd_store_attempt_id_o);check(id>=0&&id<STORE_CAP,"backend STORE command index range");
                            check(!store_live[id]&&integer'(backend_cmd_store_word_addr_o)<MEM_LINES*LW,
                                "STORE ledger capacity");
                            store_match=0;
                            for(integer p=0;p<CP;p=p+1)for(integer l=0;l<LANES;l=l+1)begin
                                if(fence_live)begin
                                    if(pending_store_mask[p]&&fence_store_mask[p][l]
                                        &&fence_store_addr[p][l]===backend_cmd_store_word_addr_o&&fence_store_data[p][l]===backend_cmd_store_wdata_o)
                                        store_match=1;
                                end else if(commit_valid_i[p]&&commit_lane_mask_i[p][l]
                                    &&commit_word_addr_i[p][l]===backend_cmd_store_word_addr_o&&commit_wdata_i[p][l]===backend_cmd_store_wdata_o)
                                    store_match=1;
                            end
                            check(store_match,"P36 non-predecessor STORE command crossed cut or captured payload changed");
                            store_live[id]=1;store_addr[id]=backend_cmd_store_word_addr_o;store_data[id]=backend_cmd_store_wdata_o;
                            store_fail[id]=backend_cmd_store_word_addr_o==fail_store_addr;store_commands=store_commands+1;
                        end
                        default:check(0,"unknown backend command kind");
                    endcase
                end

                for(integer c=0;c<C;c=c+1)begin
                    if(client_req_valid_i[c]&&client_req_ready_o[c])begin
                        id=integer'(client_req_local_tag_i[c]);check(id>=0&&id<TAGS,"public READ request tag index range");
                        check(!public_live[c][id],"duplicate public READ acceptance");
                        public_live[c][id]=1;public_line[c][id]=client_req_line_addr_i[c];
                        client_accepts=client_accepts+1;
                    end
                    if(client_resp_valid_o[c])begin
                        id=integer'(client_resp_local_tag_o[c]);line=integer'(client_resp_line_addr_o[c]);
                        check(id>=0&&id<TAGS,"public READ response tag index range");
                        check(public_live[c][id]&&client_resp_line_addr_o[c]===public_line[c][id],"exact public READ requester/tag/line");
                        check(client_resp_fault_o[c]===public_fault[c][id],"exact public READ fault");
                        if(!client_resp_fault_o[c])for(integer w=0;w<LW;w=w+1)
                            check(client_resp_data_o[c][w]===expected_cache[line][w],"public READ exact data");
                        if(fence_live&&client_resp_fault_o[c])expected_ffault[0]=1;
                        public_live[c][id]=0;client_returns=client_returns+1;
                    end
                end
                if(atomic_epoch_advance_pulse_o)begin
                    check(count_atomics()==0,"epoch advance dropped architectural work");epoch_issued=0;
                    for(integer i=0;i<256;i=i+1)begin atomic_known[i]=0;atomic_effect_accounted[i]=0;end
                end
                if(atomic_new_issue_o)atomic_allocations=atomic_allocations+1;
                if(atomic_transport_duplicate_o)atomic_duplicates=atomic_duplicates+1;
                if(atomic_transport_replay_o)atomic_replays=atomic_replays+1;
                if(atomic_req_valid_i&&atomic_req_ready_o)begin
                    id=integer'(atomic_req_request_id_i);check(id>=0&&id<256,"atomic request identity index range");
                    atomic_accepts=atomic_accepts+1;
                    if(!atomic_known[id])begin
                        atomic_known[id]=1;atomic_live[id]=1;atomic_effect_accounted[id]=0;epoch_issued=epoch_issued+1;
                        saved_asource[id]=atomic_req_source_i;saved_acontext[id]=atomic_req_context_i;
                        saved_ageneration[id]=atomic_req_generation_i;saved_aaddr[id]=atomic_req_word_addr_i;
                        saved_awide[id]=atomic_req_is64_i;saved_aop[id]=atomic_req_op_i;
                        saved_aoperand[id]=atomic_req_operand_i;saved_acompare[id]=atomic_req_compare_i;
                        saved_afault[id]=(atomic_req_op_i>10||(atomic_req_is64_i&&(LW<2||atomic_req_word_addr_i[0])))?4'd1:4'd0;
                        saved_aold[id]=(saved_afault[id]!=0)?64'd0:model_old(atomic_req_word_addr_i,atomic_req_is64_i);
                        saved_anew[id]=ref_result(saved_aold[id],atomic_req_is64_i,atomic_req_op_i,atomic_req_operand_i,atomic_req_compare_i);
                        saved_acas[id]=(saved_afault[id]==0&&atomic_req_op_i==1)
                            &&(atomic_req_is64_i?saved_aold[id]==atomic_req_compare_i:saved_aold[id][31:0]==atomic_req_compare_i[31:0]);
                    end else check(!atomic_live[id],"retry while architectural predecessor still live");
                end
                if(atomic_retire_valid_o)begin
                    id=integer'(atomic_retire_request_id_o);check(id>=0&&id<256,"atomic retirement identity index range");
                    check(atomic_known[id]&&atomic_live[id],"double or unknown architectural retire");
                    check(atomic_retire_source_o===saved_asource[id]&&atomic_retire_context_o===saved_acontext[id]
                        &&atomic_retire_generation_o===saved_ageneration[id]&&atomic_retire_word_addr_o===saved_aaddr[id]
                        &&atomic_retire_is64_o===saved_awide[id]&&atomic_retire_op_o===saved_aop[id]
                        &&atomic_retire_operand_o===saved_aoperand[id]&&atomic_retire_compare_o===saved_acompare[id],"full architectural atomic descriptor");
                    check(atomic_retire_old_o===saved_aold[id]&&atomic_retire_cas_success_o===saved_acas[id]
                        &&atomic_retire_fault_o===saved_afault[id],"original atomic result and fault");
                    if(!atomic_effect_accounted[id])begin
                        if(saved_afault[id]==0)begin
                            line=integer'(saved_aaddr[id])/LW;word=integer'(saved_aaddr[id])%LW;
                            expected_cache[line][word]=saved_anew[id][31:0];
                            for(integer w=0;w<LW;w=w+1)if(saved_awide[id]&&w==word+1)expected_cache[line][w]=saved_anew[id][63:32];
                        end
                        atomic_effect_accounted[id]=1;
                    end
                    if(atomic_retire_ready_i)begin
                        if(fence_live&&atomic_retire_fault_o!=0)expected_ffault[1]=1;
                        atomic_live[id]=0;atomic_retires=atomic_retires+1;
                    end
                end
                if(commit_fault_valid_o)begin
                    port_id=integer'(commit_fault_port_id_o);
                    check(port_id>=0&&port_id<CP,"STORE fault port identity index range");
                    check(commit_valid_i[port_id]&&commit_fault_lane_mask_o===commit_lane_mask_i[port_id]
                        &&!commit_fault_store_timeout_o&&commit_fault_store_retry_count_o==0,"exact STORE fault provenance");
                    for(integer l=0;l<LANES;l=l+1)
                        check(commit_fault_word_addr_o[l]===commit_word_addr_i[port_id][l]
                            &&commit_fault_wdata_o[l]===commit_wdata_i[port_id][l],"full STORE fault payload");
                end
                for(integer p=0;p<CP;p=p+1)begin
                    if(fence_live&&pending_store_mask[p])begin
                        check(commit_valid_i[p]&&commit_lane_mask_i[p]===fence_store_mask[p],"captured STORE source changed");
                        for(integer l=0;l<LANES;l=l+1)check(commit_word_addr_i[p][l]===fence_store_addr[p][l]
                            &&commit_wdata_i[p][l]===fence_store_data[p][l],"captured full STORE source payload changed");
                    end
                    if(fence_live&&!pending_store_mask[p])check(!commit_ready_o[p]&&!commit_abort_o[p],"younger/completed STORE port reached terminal");
                    if(commit_ready_o[p])begin
                        check(commit_valid_i[p]&&!commit_abort_o[p],"commit_ready not success-only");retired[p]=retired[p]+1;withdraw_store[p]=1;
                        for(integer l=0;l<LANES;l=l+1)if(commit_lane_mask_i[p][l])
                            expected_cache[integer'(commit_word_addr_i[p][l])/LW][integer'(commit_word_addr_i[p][l])%LW]=commit_wdata_i[p][l];
                        if(fence_live)pending_store_mask[p]=0;
                    end
                    if(commit_abort_o[p])begin
                        check(commit_valid_i[p]&&!commit_ready_o[p]&&commit_fault_valid_o&&commit_fault_ready_i,"abort separate from success");
                        aborted[p]=aborted[p]+1;withdraw_store[p]=1;
                        if(fence_live)begin pending_store_mask[p]=0;expected_ffault[2]=1;end
                    end
                end
                if(fence_live&&(|wb_terminal_failure_o))expected_ffault[3]=1;
                if(fence_resp_valid_o)begin
                    check(fence_live,"fence response without accepted request");
                    check(count_clients()==0&&count_atomics()==0&&count_reads()==0&&count_wbs()==0&&count_stores()==0&&pending_store_mask==0,
                        "P36_FENCE_EARLY_RESPONSE independent predecessor obligations remain");
                    check(!commit_visibility_busy_o&&!store_completion_busy_o&&!store_terminal_failure_o
                        &&!recovery_required_o&&!recovery_drain_active_o&&!recovery_rearm_pulse_o
                        &&wb_busy_o==0&&wb_pending_count_o==0&&wb_active_count_o==0&&wb_terminal_failure_o==0
                        &&recovery_active_o==0&&recovery_complete_pulse_o==0&&!backend_cmd_valid_o
                        &&!atomic_busy_o&&atomic_requester_outstanding_o==0&&!atomic_retire_valid_o&&client_read_outstanding_o==0,
                        "fence response before production recovery/transport drain");
                    check(fence_resp_source_o===expected_fsource&&fence_resp_context_o===expected_fcontext
                        &&fence_resp_request_id_o===expected_fid&&fence_resp_generation_o===expected_fgeneration
                        &&fence_resp_acquire_o===expected_facquire&&fence_resp_release_o===expected_frelease
                        &&fence_resp_fault_bits_o===expected_ffault,"full fence response key/mode/fault");
                    if(fence_resp_ready_i)begin
                        fence_returns=fence_returns+1;if(expected_ffault!=0)fence_errors=fence_errors+1;fence_live=0;
                    end
                end
                check(!fence_live||fence_busy_o||(fence_req_valid_i&&fence_req_ready_o),"accepted fence lost busy state");
            end
        end
    end

    initial begin : backend
        integer selected;
        forever begin
            @(negedge clk);
            backend_cmd_ready_i=rst_n&&manual_backend_ready;
            selected=-1;for(integer i=0;i<READ_CAP;i=i+1)if(read_live[i]&&selected<0)selected=i;
            backend_read_resp_valid_i=rst_n&&permit_read&&selected>=0;
            backend_read_resp_tag_i=(selected>=0)?BRTW'(selected):'0;
            backend_read_resp_line_addr_i=(selected>=0)?read_line[selected]:'0;
            backend_read_resp_fault_i=(selected>=0)?read_fault[selected]:1'b0;
            for(integer w=0;w<LW;w=w+1)backend_read_resp_data_i[w]=(selected>=0)?mem[integer'(read_line[selected])][w]:'0;
            selected=-1;for(integer i=0;i<WB_CAP;i=i+1)if(wb_live[i]&&selected<0)selected=i;
            backend_wb_status_valid_i=rst_n&&permit_wb&&selected>=0;
            backend_wb_status_attempt_id_i=(selected>=0)?BATW'(selected):'0;
            backend_wb_status_success_i=(selected>=0)?!wb_fail[selected]:1'b0;backend_wb_status_retryable_i=0;
            selected=-1;for(integer i=0;i<STORE_CAP;i=i+1)if(store_live[i]&&selected<0)selected=i;
            stale_status_driven=rst_n&&inject_stale_store_status;
            backend_store_status_valid_i=rst_n&&(inject_stale_store_status||(permit_store&&selected>=0));
            backend_store_status_attempt_id_i=inject_stale_store_status?stale_store_id:((selected>=0)?SAID'(selected):'0);
            backend_store_status_success_i=inject_stale_store_status?1'b1:((selected>=0)?!store_fail[selected]:1'b0);
            backend_store_status_retryable_i=0;
            backend_store_status_reuse_safe_i=rst_n&&permit_store_reuse;
            backend_store_all_generations_quiescent_i=rst_n&&count_stores()==0&&!inject_stale_store_status;
            backend_wb_recovery_safe_valid_i=permit_wb_recovery?wb_terminal_failure_o:'0;
            for(integer p=0;p<CP;p=p+1)if(withdraw_store[p])begin commit_valid_i[p]=0;withdraw_store[p]=0;end
        end
    end

    task automatic wait_idle;
        integer bound;
        begin
            bound=0;
            while(count_clients()!=0||count_atomics()!=0||count_reads()!=0||count_wbs()!=0||count_stores()!=0
                ||commit_valid_i!=0||commit_visibility_busy_o||store_completion_busy_o||atomic_busy_o
                ||(|wb_busy_o)||(|recovery_active_o)||recovery_required_o||recovery_drain_active_o||recovery_rearm_pulse_o)begin
                tick();bound=bound+1;check(bound<500,"bounded production idle");
            end
            tick();
        end
    endtask
    task automatic advance_epoch;
        integer bound;
        begin
            check(!fence_live&&count_atomics()==0,"epoch helper requires retired namespace");
            atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;repeat(2)tick();
            atomic_epoch_quiescent_i=1;atomic_all_generations_quiescent_i=1;atomic_epoch_advance_valid_i=1;
            #1;bound=0;while(!atomic_epoch_advance_ready_o)begin tick();bound=bound+1;check(bound<100,"joint epoch certificate");end
            tick();atomic_epoch_advance_valid_i=0;atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;
            check(atomic_epoch_advance_pulse_o&&!atomic_req_ready_o,"P35 synchronization bubble preserved");repeat(2)tick();
        end
    endtask
    task automatic begin_atomic(input logic [3:0] op,input logic hold_result);
        integer bound;
        begin
            if(epoch_issued>=AE)advance_epoch();
            atomic_req_source_i=ASW'(next_atomic_id%4);atomic_req_context_i=ACW'((next_atomic_id/4)%4);
            atomic_req_request_id_i=AIW'(next_atomic_id);next_atomic_id=next_atomic_id+1;
            atomic_req_generation_i=atomic_current_generation_o;atomic_req_word_addr_i=0;
            atomic_req_is64_i=0;atomic_req_op_i=op;atomic_req_operand_i=3;atomic_req_compare_i=0;
            atomic_req_valid_i=1;atomic_retire_ready_i=0;
            #1;bound=0;while(!atomic_req_ready_o)begin tick();bound=bound+1;check(bound<500,"atomic request admission");end
            tick();atomic_req_valid_i=0;
            bound=0;while(!atomic_retire_valid_o)begin tick();bound=bound+1;check(bound<500,"real atomic result");end
            tick();if(!hold_result)begin atomic_retire_ready_i=1;tick();atomic_retire_ready_i=0;tick();end
        end
    endtask
    task automatic release_atomic;
        integer before_count;
        begin
            before_count=atomic_retires;check(atomic_retire_valid_o,"architectural result genuinely held");
            atomic_retire_ready_i=1;tick();atomic_retire_ready_i=0;tick();check(atomic_retires==before_count+1,"unique architectural retire handshake");
        end
    endtask
    task automatic begin_read(input integer c,input integer tag,input integer line,input logic fault);
        integer bound;
        begin
            check(c>=0&&c<C&&tag>=0&&tag<TAGS&&line>=0&&line<MEM_LINES,"public READ model range");
            public_fault[c][tag]=fault;client_req_local_tag_i[c]=LT'(tag);client_req_line_addr_i[c]=LAW'(line);client_req_valid_i[c]=1;
            #1;bound=0;while(!client_req_ready_o[c])begin tick();bound=bound+1;check(bound<500,"public READ admission");end
            tick();client_req_valid_i[c]=0;
        end
    endtask
    task automatic public_read(input integer line);
        integer before_count,bound;
        begin
            before_count=client_returns;begin_read(0,0,line,0);
            bound=0;while(client_returns==before_count)begin tick();bound=bound+1;check(bound<500,"public READ delivery");end
            tick();
        end
    endtask
    task automatic offer_store(input integer p,input logic two_lanes,input logic fail);
        integer line;
        begin
            check(p>=0&&p<CP&&!commit_valid_i[p],"free STORE source port");
            line=(8+store_sequence)*S*SETS+1;store_sequence=store_sequence+1;
            check(line+S*SETS<MEM_LINES,"STORE model range");
            commit_lane_mask_i[p]=two_lanes?2'b11:2'b01;
            commit_word_addr_i[p][0]=32'(line*LW);commit_wdata_i[p][0]=32'h3600_0000+32'(store_sequence*16+p);
            commit_word_addr_i[p][1]=32'((line+S*SETS)*LW);commit_wdata_i[p][1]=32'h3600_8000+32'(store_sequence*16+p);
            if(fail)fail_store_addr=commit_word_addr_i[p][0];commit_valid_i[p]=1;
        end
    endtask
    task automatic start_fence(input logic acquire_mode,input logic release_mode);
        integer before_count,bound;
        begin
            before_count=fence_accepts;fence_req_source_i=FSW'(next_fence_id%4);fence_req_context_i=FCW'((next_fence_id/4)%4);
            fence_req_request_id_i=FIW'(next_fence_id);fence_req_generation_i=FGW'(next_fence_id/16);next_fence_id=next_fence_id+1;
            fence_req_acquire_i=acquire_mode;fence_req_release_i=release_mode;fence_req_valid_i=1;fence_resp_ready_i=0;
            #1;bound=0;while(!fence_req_ready_o)begin tick();bound=bound+1;check(bound<500,"fence acceptance");end
            tick();fence_req_valid_i=0;check(fence_accepts==before_count+1&&fence_live,"exact fence acceptance count");
        end
    endtask
    task automatic finish_fence(input logic [4:0] expected_fault);
        integer bound,before_count;
        begin
            bound=0;while(!fence_resp_valid_o)begin tick();bound=bound+1;check(bound<500,"fence genuine drain response");end
            check(fence_resp_fault_bits_o===expected_fault,"directed fence fault classification");
            before_count=fence_returns;fence_resp_ready_i=1;tick();fence_resp_ready_i=0;tick();
            check(fence_returns==before_count+1&&!fence_live&&!fence_busy_o,"one fence response handshake");
        end
    endtask
    task automatic blocked_fence_cycles(input integer n);
        repeat(n)begin tick();check(!fence_resp_valid_o,"P36_FENCE_EARLY_RESPONSE directed live predecessor");end
    endtask
    task automatic wait_read_command;
        integer bound;
        begin bound=0;while(count_reads()==0)begin tick();bound=bound+1;check(bound<500,"genuine READ backend command");end end
    endtask
    task automatic wait_wb_command;
        integer bound;
        begin bound=0;while(count_wbs()==0)begin tick();bound=bound+1;check(bound<500,"genuine WB backend command");end end
    endtask
    task automatic wait_store_command;
        integer bound;
        begin bound=0;while(count_stores()==0)begin tick();bound=bound+1;check(bound<500,"genuine STORE backend command");end end
    endtask

    initial begin : stimulus
        integer before_wb,before_read,before_retire,before_abort,before_status,bound,saved_id;
        cycles=0;checks=0;scenarios=0;read_commands=0;read_statuses=0;wb_commands=0;wb_statuses=0;wb_successes=0;
        store_commands=0;store_statuses=0;store_successes=0;client_accepts=0;client_returns=0;atomic_accepts=0;atomic_retires=0;
        atomic_allocations=0;atomic_duplicates=0;atomic_replays=0;fence_accepts=0;fence_returns=0;fence_errors=0;
        store_rearms=0;wb_recoveries=0;wb_certificates=0;stale_packets=0;status_rejects=0;next_atomic_id=1;next_fence_id=1;store_sequence=0;epoch_issued=0;
        rst_n=0;client_req_valid_i=0;commit_valid_i=0;withdraw_store=0;pending_store_mask=0;
        manual_backend_ready=1;permit_read=1;permit_wb=1;permit_store=1;permit_store_reuse=1;permit_wb_recovery=0;
        inject_read_failure=0;inject_wb_failure=0;inject_stale_store_status=0;stale_status_driven=0;
        fail_store_addr=32'hffff_ffff;stale_store_id=0;last_store_id=0;
        command_stalled=0;atomic_stalled=0;fence_stalled=0;fence_live=0;held_command=0;held_atomic=0;held_fence=0;
        probe_reuse_safe_i=0;commit_fault_ready_i=0;atomic_req_valid_i=0;atomic_retire_ready_i=0;
        atomic_req_source_i=0;atomic_req_context_i=0;atomic_req_request_id_i=0;atomic_req_generation_i=0;
        atomic_req_word_addr_i=0;atomic_req_is64_i=0;atomic_req_op_i=0;atomic_req_operand_i=0;atomic_req_compare_i=0;
        atomic_epoch_advance_valid_i=0;atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;
        fence_req_valid_i=0;fence_resp_ready_i=0;fence_req_source_i=0;fence_req_context_i=0;fence_req_request_id_i=0;
        fence_req_generation_i=0;fence_req_acquire_i=0;fence_req_release_i=0;
        expected_fsource=0;expected_fcontext=0;expected_fid=0;expected_fgeneration=0;expected_facquire=0;expected_frelease=0;expected_ffault=0;
        for(integer c=0;c<C;c=c+1)begin
            client_req_local_tag_i[c]=0;client_req_line_addr_i[c]=0;
            for(integer t=0;t<TAGS;t=t+1)begin public_live[c][t]=0;public_line[c][t]=0;public_fault[c][t]=0;end
        end
        for(integer p=0;p<CP;p=p+1)begin
            retired[p]=0;aborted[p]=0;commit_lane_mask_i[p]=0;fence_store_mask[p]=0;
            for(integer l=0;l<LANES;l=l+1)begin
                commit_word_addr_i[p][l]=0;commit_wdata_i[p][l]=0;fence_store_addr[p][l]=0;fence_store_data[p][l]=0;
            end
        end
        for(integer i=0;i<READ_CAP;i=i+1)begin read_live[i]=0;read_fault[i]=0;read_line[i]=0;end
        for(integer i=0;i<WB_CAP;i=i+1)begin
            wb_live[i]=0;wb_fail[i]=0;wb_line[i]=0;for(integer w=0;w<LW;w=w+1)wb_data[i][w]=0;
        end
        for(integer i=0;i<STORE_CAP;i=i+1)begin store_live[i]=0;store_fail[i]=0;store_addr[i]=0;store_data[i]=0;end
        for(integer i=0;i<256;i=i+1)begin
            atomic_known[i]=0;atomic_live[i]=0;atomic_effect_accounted[i]=0;saved_asource[i]=0;saved_acontext[i]=0;saved_ageneration[i]=0;
            saved_aaddr[i]=0;saved_awide[i]=0;saved_acas[i]=0;saved_aop[i]=0;saved_afault[i]=0;
            saved_aoperand[i]=0;saved_acompare[i]=0;saved_aold[i]=0;saved_anew[i]=0;
        end
        for(integer line=0;line<MEM_LINES;line=line+1)for(integer w=0;w<LW;w=w+1)begin
            mem[line][w]=32'h0100_0000+32'(line*LW+w);expected_cache[line][w]=mem[line][w];
        end
        repeat(3)tick();rst_n=1;tick();

        start_fence(1,1);finish_fence(0);check(read_commands==0&&wb_commands==0&&store_commands==0,"empty fence generated work");
        mark("EMPTY_FENCE_EXACT_RESPONSE");

        begin_atomic(2,0);check((|dirty_present_o),"real dirty line before fence");before_wb=wb_commands;
        start_fence(1,1);finish_fence(0);check((|dirty_present_o)&&wb_commands==before_wb,"drain fence flushed/lost dirty line");
        public_read(S*SETS);check(wb_commands==before_wb+1,"later exact dirty eviction");public_read(0);wait_idle();
        mark("DIRTY_RESIDENT_DRAIN_NOT_FLUSH_AND_LATER_EXACT_WB");

        permit_read=0;begin_read(0,1,2*S*SETS,0);wait_read_command();start_fence(1,0);blocked_fence_cycles(5);
        permit_read=1;finish_fence(0);wait_idle();mark("OUTSTANDING_READ_DELIVERY_DRAINS_FENCE");

        permit_read=0;begin_read(1,2,3*S*SETS,0);wait_read_command();permit_read=1;
        bound=0;while(!client_resp_valid_o[1])begin tick();bound=bound+1;check(bound<100,"READ pulse align at cut");end
        before_read=client_returns;start_fence(1,0);check(client_returns==before_read+1,"READ delivery exact on acceptance edge");
        finish_fence(0);mark("SAME_EDGE_READ_DELIVERY_AND_FENCE_CUT");

        permit_store=0;offer_store(0,0,0);offer_store(1,1,0);
        client_req_valid_i[0]=1;client_req_local_tag_i[0]=3;client_req_line_addr_i[0]=LAW'(4*S*SETS);
        atomic_req_valid_i=1;atomic_req_request_id_i=200;atomic_req_op_i=2;atomic_req_generation_i=atomic_current_generation_o;
        atomic_epoch_advance_valid_i=1;atomic_epoch_quiescent_i=1;atomic_all_generations_quiescent_i=1;
        before_retire=retired[0]+retired[1];start_fence(0,1);
        check(pending_store_mask==2'b11&&!client_req_ready_o[0]&&!atomic_req_ready_o&&!atomic_epoch_advance_ready_o,"all raw STORE ports enrolled at cut");
        client_req_valid_i=0;atomic_req_valid_i=0;atomic_epoch_advance_valid_i=0;atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;
        wait_store_command();blocked_fence_cycles(4);permit_store=1;finish_fence(0);
        check(retired[0]+retired[1]==before_retire+2,"two exact success-only STORE ports");wait_idle();
        mark("SAME_EDGE_ALL_STORE_PORTS_CAPTURE_AND_NEW_ADMISSION_BLOCK");

        permit_store=0;manual_backend_ready=0;offer_store(0,1,0);start_fence(0,1);blocked_fence_cycles(5);
        manual_backend_ready=1;wait_store_command();blocked_fence_cycles(3);permit_store=1;finish_fence(0);wait_idle();
        mark("CAPTURED_FULL_STORE_PAYLOAD_AND_BACKEND_PROMISE_BACKPRESSURE");

        begin_atomic(2,0);permit_wb=0;permit_read=0;before_wb=wb_successes;
        begin_read(0,2,S*SETS,0);wait_wb_command();check(count_clients()==1,"eviction READ genuinely outstanding with WB");
        permit_wb=1;bound=0;while(!backend_wb_status_valid_i)begin tick();bound=bound+1;check(bound<100,"WB pulse align at cut");end
        start_fence(1,1);check(wb_successes==before_wb+1,"WB status exact on acceptance edge");blocked_fence_cycles(4);
        permit_read=1;finish_fence(0);wait_idle();mark("LIVE_WB_EXACT_PAYLOAD_AND_SAME_EDGE_STATUS_CUT");

        begin_atomic(2,1);before_retire=atomic_retires;start_fence(1,1);blocked_fence_cycles(6);
        check(atomic_retires==before_retire&&atomic_retire_valid_o,"transport result cannot substitute architectural retirement");
        release_atomic();finish_fence(0);wait_idle();
        begin_atomic(2,1);before_retire=atomic_retires;atomic_retire_ready_i=1;start_fence(1,1);atomic_retire_ready_i=0;
        check(atomic_retires==before_retire+1,"same-edge atomic retirement exact");finish_fence(0);
        mark("HELD_ARCHITECTURAL_RETIRE_AND_SAME_EDGE_RETIRE_CUT");

        begin_atomic(2,1);permit_read=0;permit_wb=0;permit_store=0;
        begin_read(0,1,S*SETS,0);wait_wb_command();offer_store(1,0,0);start_fence(1,1);wait_store_command();
        check(count_clients()>0&&count_wbs()>0&&count_stores()>0&&count_atomics()==1,"four real independent predecessor domains reached");
        blocked_fence_cycles(4);permit_store=1;bound=0;while(pending_store_mask!=0)begin tick();bound=bound+1;check(bound<100,"mixed STORE drain");end
        blocked_fence_cycles(3);permit_wb=1;bound=0;while(count_wbs()!=0)begin tick();bound=bound+1;check(bound<100,"mixed WB drain");end
        blocked_fence_cycles(3);permit_read=1;bound=0;while(count_clients()!=0)begin tick();bound=bound+1;check(bound<100,"mixed READ drain");end
        blocked_fence_cycles(3);release_atomic();finish_fence(0);wait_idle();mark("MIXED_PUBLIC_READ_WB_STORE_AND_HELD_ATOMIC_RETIRE");

        permit_store=0;offer_store(0,0,0);offer_store(1,0,0);before_retire=retired[0]+retired[1];start_fence(0,1);
        wait_store_command();permit_store=1;
        bound=0;while(retired[0]+retired[1]==before_retire)begin tick();bound=bound+1;check(bound<100,"first STORE port terminal");end
        permit_store=0;check(pending_store_mask!=0&&!fence_resp_valid_o,"one completed port cannot drain another captured port");
        blocked_fence_cycles(3);permit_store=1;finish_fence(0);check(retired[0]+retired[1]==before_retire+2,"each STORE port retires once");
        mark("MULTIPLE_STORE_PORTS_INDEPENDENT_TERMINAL_ACCOUNTING");

        permit_store_reuse=0;offer_store(1,0,1);before_abort=aborted[1];before_retire=retired[1];start_fence(0,1);
        bound=0;while(!commit_fault_valid_o)begin tick();bound=bound+1;check(bound<100,"genuine terminal STORE fault");end
        blocked_fence_cycles(4);check(!commit_abort_o[1]&&!commit_ready_o[1],"fault backpressure preserves separate abort");
        commit_fault_ready_i=1;bound=0;while(aborted[1]==before_abort)begin tick();bound=bound+1;check(bound<100,"STORE abort handshake");end
        commit_fault_ready_i=0;blocked_fence_cycles(4);check(recovery_required_o&&recovery_reset_blocked_o,"STORE quarantine remains live");
        permit_store_reuse=1;finish_fence(5'b00100);fail_store_addr=32'hffff_ffff;
        check(aborted[1]==before_abort+1&&retired[1]==before_retire&&store_rearms==1,"exact abort/rearm without success");wait_idle();
        mark("STORE_ABORT_FAULT_BACKPRESSURE_SELECTIVE_REARM");

        begin_atomic(15,1);permit_read=0;inject_read_failure=1;begin_read(1,1,7*S*SETS,1);wait_read_command();
        start_fence(1,1);blocked_fence_cycles(3);permit_read=1;release_atomic();finish_fence(5'b00011);wait_idle();
        mark("READ_FAULT_AND_ATOMIC_FAULT_REQUIRE_REAL_DELIVERY_RETIRE");

        begin_atomic(2,0);permit_wb=0;permit_read=0;inject_wb_failure=1;before_wb=wb_commands;
        begin_read(0,2,S*SETS,0);wait_wb_command();start_fence(1,1);permit_wb=1;
        bound=0;while(wb_terminal_failure_o==0)begin tick();bound=bound+1;check(bound<100,"WB genuine terminal failure");end
        blocked_fence_cycles(4);permit_wb_recovery=1;
        bound=0;while(wb_recoveries==0)begin tick();bound=bound+1;check(bound<100,"truthful WB recovery certificate");end
        permit_wb_recovery=0;permit_read=1;finish_fence(5'b01000);wait_idle();
        check(wb_commands==before_wb+2&&wb_recoveries==1,"retained exact WB retries once after recovery");
        mark("WB_TERMINAL_FAILURE_RETAINED_PAYLOAD_AND_RECOVERY_DRAIN");

        start_fence(1,1);bound=0;while(!fence_resp_valid_o)begin tick();bound=bound+1;check(bound<100,"held fence response reached");end
        held_fence=fence_tuple;client_req_valid_i[1]=1;client_req_local_tag_i[1]=3;client_req_line_addr_i[1]=LAW'(6*S*SETS);
        atomic_req_valid_i=1;atomic_req_request_id_i=201;atomic_req_generation_i=atomic_current_generation_o;
        atomic_epoch_advance_valid_i=1;atomic_epoch_quiescent_i=1;atomic_all_generations_quiescent_i=1;
        offer_store(0,0,0);fence_req_valid_i=1;fence_req_request_id_i=222;fence_req_source_i=3;fence_req_context_i=2;
        fence_req_generation_i=3;fence_req_acquire_i=0;fence_req_release_i=1;
        repeat(6)begin tick();check(fence_resp_valid_o&&fence_tuple===held_fence&&!fence_req_ready_o
            &&client_req_ready_o==0&&!atomic_req_ready_o&&!atomic_epoch_advance_ready_o&&commit_ready_o==0&&commit_abort_o==0,
            "response backpressure blocks every younger domain and preserves key");end
        client_req_valid_i=0;atomic_req_valid_i=0;atomic_epoch_advance_valid_i=0;atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;
        commit_valid_i=0;fence_req_valid_i=0;finish_fence(0);mark("HELD_FENCE_RESPONSE_IDENTITY_AND_ALL_YOUNGER_DOMAINS_BLOCKED");

        stale_store_id=last_store_id;permit_store=0;offer_store(0,0,0);start_fence(0,1);wait_store_command();
        check(!store_live[integer'(stale_store_id)],"old STORE generation differs from fresh pending attempt");
        before_status=store_statuses;inject_stale_store_status=1;tick();inject_stale_store_status=0;tick();
        check(store_statuses==before_status&&pending_store_mask!=0&&count_stores()==1&&!fence_resp_valid_o,"stale status did not complete fresh STORE/fence");
        blocked_fence_cycles(3);permit_store=1;finish_fence(0);check(stale_packets==1&&status_rejects>=1,"P30 stale packet rejection retained");
        mark("P30_GENERATION_STALE_STORE_STATUS_CANNOT_RELEASE_FENCE");

        start_fence(0,0);finish_fence(5'b10000);start_fence(1,1);finish_fence(0);
        check(!store_terminal_failure_o&&!recovery_required_o&&wb_terminal_failure_o==0,"old failures fully recovered");
        mark("INVALID_MODE_EXACT_ERROR_AND_FRESH_FENCE_IGNORES_HISTORY");

        advance_epoch();for(integer i=0;i<AE;i=i+1)begin_atomic(2,0);
        check(atomic_table_full_o&&atomic_requester_outstanding_o==0&&!atomic_busy_o,"retired tombstones fill real atomic table");
        atomic_epoch_advance_valid_i=1;atomic_epoch_quiescent_i=1;atomic_all_generations_quiescent_i=1;
        start_fence(1,1);check(!atomic_epoch_advance_ready_o,"fence blocks epoch admission even with full table");
        atomic_epoch_advance_valid_i=0;atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;finish_fence(0);
        advance_epoch();saved_id=next_atomic_id;check(saved_id>=0&&saved_id<256,"saved atomic identity index range");
        begin_atomic(2,0);public_read(0);offer_store(0,0,0);wait_idle();
        check(atomic_known[saved_id]&&!atomic_live[saved_id],"fresh generation work accepted and retired after fence");
        mark("FULL_RETIRED_TABLE_NOT_LIVE_WORK_AND_POST_FENCE_NAMESPACE_PROGRESS");

        wait_idle();
        check(scenarios==17&&fence_accepts==fence_returns&&fence_errors==4&&atomic_accepts==atomic_retires+atomic_duplicates
            &&atomic_allocations==atomic_retires&&atomic_duplicates==atomic_replays&&client_accepts==client_returns
            &&read_commands==read_statuses&&wb_commands==wb_statuses&&store_commands==store_statuses
            &&store_commands==store_successes+1&&wb_commands==wb_successes+1
            &&aborted[0]==0&&aborted[1]==1&&store_rearms==1&&wb_recoveries==1&&wb_certificates==1&&stale_packets==1
            &&count_clients()==0&&count_atomics()==0&&count_reads()==0&&count_wbs()==0&&count_stores()==0
            &&client_read_outstanding_o==0&&atomic_requester_outstanding_o==0&&!store_generation_wrap_pending_o
            &&!fence_live&&!fence_busy_o&&!fence_resp_valid_o,
            "final independent acceptance/retirement/abort/recovery accounting");
        $display("P36_INTEGRATED_PASS variant=%0d scenarios=%0d checks=%0d fence_accepts=%0d fence_returns=%0d fence_errors=%0d atomic_accepts=%0d atomic_retires=%0d allocations=%0d duplicates=%0d replay_packets=%0d reads=%0d read_returns=%0d wb=%0d wb_returns=%0d wb_successes=%0d clients=%0d client_returns=%0d stores=%0d store_returns=%0d store_successes=%0d port0_retires=%0d port1_retires=%0d aborts=%0d store_rearms=%0d wb_recoveries=%0d wb_certificates=%0d stale_packets=%0d status_rejects=%0d",
            VARIANT,scenarios,checks,fence_accepts,fence_returns,fence_errors,atomic_accepts,atomic_retires,atomic_allocations,
            atomic_duplicates,atomic_replays,read_commands,read_statuses,wb_commands,wb_statuses,wb_successes,client_accepts,client_returns,
            store_commands,store_statuses,store_successes,retired[0],retired[1],aborted[1],store_rearms,wb_recoveries,wb_certificates,stale_packets,status_rejects);
        $finish;
    end
endmodule
