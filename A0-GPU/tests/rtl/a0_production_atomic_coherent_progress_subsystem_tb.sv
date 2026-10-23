`timescale 1ns/1ps
// P35 staged production proof: real frozen P34 cache, no private array access.
module a0_production_atomic_coherent_progress_subsystem_tb #(parameter integer VARIANT=0);
    localparam integer C=2,LT=2,CO=2,CP=2,LANES=2,S=1<<VARIANT,SETS=1<<VARIANT,LW=1<<VARIANT;
    localparam integer WSEL=VARIANT,LAW=32-WSEL,SID=(S<=1)?1:$clog2(S);
    localparam integer WID=2,RW=1,SWID=2,SRW=1,GEN=8,CGEN=8,BRTW=SID+2+LT,BATW=SID+WID+RW,SAID=GEN+SWID+SRW;
    localparam integer CNTW=(S<=1)?1:$clog2(S+1),RCW=3,TO=256,TW=8,MEM_LINES=8*S*SETS+16;
    localparam integer ATOMIC_SOURCE_W=2,ATOMIC_CONTEXT_W=2,ATOMIC_REQUEST_ID_W=8,ATOMIC_GENERATION_W=2;
    localparam integer TUPW=2+BRTW+BATW+SAID+LAW+32*LW+64;
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

    logic [S-1:0] probe_reuse_safe_i,remote_owned_present_o,probe_generation_exhausted_o;
    logic [SETS-1:0] coherence_block_set_o[0:S-1];
    logic coherence_protocol_error_o;


    logic atomic_req_valid_i;
    logic atomic_req_ready_o;
    logic [ATOMIC_SOURCE_W-1:0] atomic_req_source_i;
    logic [ATOMIC_CONTEXT_W-1:0] atomic_req_context_i;
    logic [ATOMIC_REQUEST_ID_W-1:0] atomic_req_request_id_i;
    logic [ATOMIC_GENERATION_W-1:0] atomic_req_generation_i;
    logic [31:0] atomic_req_word_addr_i;
    logic atomic_req_is64_i;
    logic [3:0] atomic_req_op_i;
    logic [63:0] atomic_req_operand_i,atomic_req_compare_i;
    logic atomic_resp_valid_o;
    logic atomic_resp_ready_i;
    logic [ATOMIC_SOURCE_W-1:0] atomic_resp_source_o;
    logic [ATOMIC_CONTEXT_W-1:0] atomic_resp_context_o;
    logic [ATOMIC_REQUEST_ID_W-1:0] atomic_resp_request_id_o;
    logic [ATOMIC_GENERATION_W-1:0] atomic_resp_generation_o;
    logic [31:0] atomic_resp_word_addr_o;
    logic atomic_resp_is64_o;
    logic [3:0] atomic_resp_op_o;
    logic [63:0] atomic_resp_operand_o,atomic_resp_compare_o,atomic_resp_old_o;
    logic atomic_resp_cas_success_o;
    logic [3:0] atomic_resp_fault_o;
    logic atomic_resp_replay_o;
    logic atomic_epoch_advance_valid_i;
    logic atomic_epoch_advance_ready_o;
    logic atomic_epoch_quiescent_i,atomic_all_generations_quiescent_i;
    logic [ATOMIC_GENERATION_W-1:0] atomic_current_generation_o;
    logic atomic_epoch_advance_pulse_o,atomic_table_full_o,atomic_busy_o,atomic_protocol_error_o;
    logic [31:0] mem[0:MEM_LINES-1][0:LW-1],expected_cache[0:MEM_LINES-1][0:LW-1];
    logic read_pending,wb_pending,store_pending,manual_backend_ready,permit_response;
    logic [BRTW-1:0] read_tag;
    logic [LAW-1:0] read_line;
    logic [BATW-1:0] wb_id;
    logic [SAID-1:0] store_id;
    logic [C-1:0] client_live;
    logic [LAW-1:0] expected_client_line[0:C-1];
    logic [CP-1:0] withdraw_store;
    logic stalled;
    logic [TUPW-1:0] command_tuple,held_command;
    integer cycles,checks,scenarios,reads,read_returns,wbs,wb_returns,stores,store_returns;
    integer atomic_accepts,atomic_returns,client_accepts,client_returns;
    integer retired[0:CP-1],next_id;
    logic [63:0] first_old;
    logic inject_store_failure,store_fail_pending,allow_recovery,exercise_recovery;
    integer aborted[0:CP-1],rearms,drain_cycles;

    a0_production_atomic_coherent_progress_subsystem #(
        .CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.COMMIT_PORT_COUNT(CP),
        .STORE_LANES(LANES),.SLICE_COUNT(S),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),
        .WRITE_ID_W(WID),.MAX_WB_RETRIES(1),.STORE_WRITE_ID_W(SWID),.MAX_STORE_RETRIES(1),
        .STORE_GENERATION_W(GEN),.STORE_STATUS_TIMEOUT_CYCLES(TO),.CLIENT_READ_COUNT_W(RCW),
        .COHERENCE_GEN_W(CGEN),.ATOMIC_SOURCE_W(ATOMIC_SOURCE_W),.ATOMIC_CONTEXT_W(ATOMIC_CONTEXT_W),
        .ATOMIC_REQUEST_ID_W(ATOMIC_REQUEST_ID_W),.ATOMIC_GENERATION_W(ATOMIC_GENERATION_W),
        .ATOMIC_ENTRY_COUNT(64)
    ) dut(.*);
    initial begin clk=0;forever #5 clk=~clk;end
    task automatic check(input bit ok,input string detail);
        if(!ok)$fatal(1,"P35_INTEGRATED_CHECK_FAILED cycle=%0d %s",cycles,detail);
        checks=checks+1;
    endtask
    task automatic tick; @(negedge clk);#1;endtask
    task automatic mark(input string name);
        scenarios=scenarios+1;$display("P35_INTEGRATED_SCENARIO_PASS id=%0d name=%s",scenarios,name);
    endtask
    function automatic logic [63:0] ref_result(input logic [63:0] old,input logic wide,
        input logic [3:0] op,input logic [63:0] operand,compare);
        logic [63:0] mask,a,b,c,r;
        begin
            mask=wide?64'hffff_ffff_ffff_ffff:64'h0000_0000_ffff_ffff;
            a=old&mask;b=operand&mask;c=compare&mask;r=a;
            case(op)
                0:r=b; 1:if(a==c)r=b; 2:r=(a+b)&mask; 3:r=(a-b)&mask;
                4:if(wide ? $signed(a)>$signed(b) : $signed(a[31:0])>$signed(b[31:0]))r=b;
                5:if(wide ? $signed(a)<$signed(b) : $signed(a[31:0])<$signed(b[31:0]))r=b;
                6:if(a>b)r=b; 7:if(a<b)r=b; 8:r=a&b; 9:r=a|b; 10:r=a^b;
                default:r=a;
            endcase
            ref_result=r;
        end
    endfunction

    function automatic logic [63:0] current_value(input logic wide);
        logic [63:0] v;
        begin
            v='0;
            for(integer w=0;w<LW;w=w+1)begin
                if(w==0)v[31:0]=expected_cache[0][w];
                if(w==1&&wide)v[63:32]=expected_cache[0][w];
            end
            current_value=v;
        end
    endfunction
    always_comb begin
        command_tuple='0;
        command_tuple[TUPW-1 -: (2+BRTW+BATW+SAID+LAW+64)]={backend_cmd_kind_o,backend_cmd_read_tag_o,
            backend_cmd_wb_attempt_id_o,backend_cmd_store_attempt_id_o,backend_cmd_line_addr_o,
            backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o};
        for(integer w=0;w<LW;w=w+1)command_tuple[w*32+:32]=backend_cmd_data_o[w];
    end

    initial begin : monitor
        forever begin
            @(posedge clk);cycles=cycles+1;if(cycles>40000)$fatal(1,"P35 integrated watchdog");
            if(rst_n)begin
                check(!protocol_error_o&&!atomic_protocol_error_o&&!coherence_protocol_error_o
                    &&!line_resp_tag_error_o&&!line_resp_overflow_o,"production protocol identity fault");
                check(!( |(commit_ready_o&commit_read_wait_o))&&!(|(client_req_valid_i&client_req_ready_o&client_store_conflict_o)),"admission violation");
                check(!store_status_timeout_seen_o&&!store_status_timeout_pulse_o&&store_retry_count_o==0
                    &&(!store_terminal_failure_o||allow_recovery)&&!store_generation_wrap_pending_o&&!store_status_rejected_o,"STORE fault/timeout");
                check(store_status_timeout_live_o||store_status_timeout_age_o==0,"timer age without STORE");
                check(!store_completion_busy_o||commit_visibility_busy_o,"STORE visibility busy lost");
                check(wb_terminal_failure_o==0&&recovery_active_o==0&&recovery_complete_pulse_o==0
                    &&backend_wb_recovery_safe_ready_o==0,"unexpected WB recovery");
                check(allow_recovery||(!recovery_required_o&&!recovery_rearm_pulse_o&&!recovery_drain_active_o&&!recovery_reset_blocked_o),"unexpected STORE recovery");
                if(recovery_rearm_pulse_o)rearms=rearms+1;
                if(recovery_drain_active_o)drain_cycles=drain_cycles+1;
                check(client_read_outstanding_o<=RCW'(6)
                    &&integer'(wb_pending_count_o)+integer'(wb_active_count_o)<=S,"bounded pending plus active WB ledger");
                check(store_generation_next_o==GEN'(stores),"physical STORE generation count");
                for(integer h=0;h<S;h=h+1)begin
                    check(wb_retry_count_o[h]==0,"WB retry");
                    check(!remote_owned_present_o[h]||(|coherence_block_set_o[h]),"ownership lost reservation");
                end
                check(probe_generation_exhausted_o==0,"unexpected coherence generation exhaustion");
                if(commit_fault_valid_o)begin
                    check(allow_recovery&&commit_fault_port_id_o==1&&commit_fault_lane_mask_o==1
                        &&!commit_fault_store_timeout_o&&commit_fault_store_retry_count_o==0,"exact STORE fault provenance");
                    check(commit_fault_word_addr_o[0]==32'((4*S*SETS+8)*LW)&&commit_fault_wdata_o[0]==32'hfa11_0035
                        &&commit_fault_word_addr_o[1]==0&&commit_fault_wdata_o[1]==0,"full STORE fault payload");
                end
                for(integer p=0;p<CP;p=p+1)if(commit_abort_o[p])begin
                    check(allow_recovery&&p==1&&commit_valid_i[p]&&commit_fault_valid_o&&commit_fault_ready_i&&!commit_ready_o[p],"abort separate from success");
                    aborted[p]=aborted[p]+1;withdraw_store[p]=1;
                end
                if(stalled)check(backend_cmd_valid_o&&command_tuple===held_command,"backend changed under backpressure");
                stalled=backend_cmd_valid_o&&!backend_cmd_ready_i;if(stalled)held_command=command_tuple;
                if(atomic_req_valid_i&&atomic_req_ready_o)atomic_accepts=atomic_accepts+1;
                if(atomic_resp_valid_o&&atomic_resp_ready_i)atomic_returns=atomic_returns+1;
                if(backend_read_resp_valid_i)begin check(read_pending,"duplicate READ return");read_pending=0;read_returns=read_returns+1;end
                if(backend_wb_status_valid_i)begin check(wb_pending,"duplicate WB status");wb_pending=0;wb_returns=wb_returns+1;end
                if(backend_store_status_valid_i)begin check(store_pending,"duplicate STORE status");store_pending=0;store_returns=store_returns+1;end
                if(backend_cmd_valid_o&&backend_cmd_ready_i)begin
                    case(backend_cmd_kind_o)
                        0:begin
                            check(!read_pending&&integer'(backend_cmd_line_addr_o)<MEM_LINES,"READ model capacity");
                            check(integer'(backend_cmd_read_tag_o[LT+:2])<=C,"exact physical requester ID width");
                            if(backend_cmd_read_tag_o[LT+:2]==2'(C))check(backend_cmd_read_tag_o[LT-1:0]==0,"reserved atomic local tag");
                            read_pending=1;read_tag=backend_cmd_read_tag_o;read_line=backend_cmd_line_addr_o;reads=reads+1;
                        end
                        1:begin
                            check(!wb_pending&&integer'(backend_cmd_line_addr_o)<MEM_LINES,"WB model capacity");
                            for(integer w=0;w<LW;w=w+1)begin
                                check(backend_cmd_data_o[w]===expected_cache[integer'(backend_cmd_line_addr_o)][w],"exact dirty atomic WB bytes");
                                mem[integer'(backend_cmd_line_addr_o)][w]=backend_cmd_data_o[w];
                            end
                            wb_pending=1;wb_id=backend_cmd_wb_attempt_id_o;wbs=wbs+1;
                        end
                        2:begin
                            check(!store_pending&&integer'(backend_cmd_store_word_addr_o)<MEM_LINES*LW,"STORE model range");
                            if(!inject_store_failure)
                                mem[integer'(backend_cmd_store_word_addr_o)/LW][integer'(backend_cmd_store_word_addr_o)%LW]=backend_cmd_store_wdata_o;
                            store_fail_pending=inject_store_failure;
                            store_pending=1;store_id=backend_cmd_store_attempt_id_o;stores=stores+1;
                        end
                        default:check(0,"unknown backend kind");
                    endcase
                end
                for(integer c=0;c<C;c=c+1)begin
                    if(client_req_valid_i[c]&&client_req_ready_o[c])begin
                        check(!client_live[c],"public client duplicate acceptance");client_live[c]=1;client_accepts=client_accepts+1;
                    end
                    if(client_resp_valid_o[c])begin
                        check(client_live[c]&&!client_resp_fault_o[c]&&client_resp_local_tag_o[c]==0
                            &&client_resp_line_addr_o[c]===expected_client_line[c],"exact public response tuple");
                        for(integer w=0;w<LW;w=w+1)check(client_resp_data_o[c][w]===expected_cache[integer'(expected_client_line[c])][w],"public cache observation");
                        client_live[c]=0;client_returns=client_returns+1;
                    end
                end
                for(integer p=0;p<CP;p=p+1)if(commit_ready_o[p])begin
                    check(commit_valid_i[p]&&!commit_abort_o[p],"success-only retirement");
                    retired[p]=retired[p]+1;withdraw_store[p]=1;
                    for(integer l=0;l<LANES;l=l+1)if(commit_lane_mask_i[p][l])
                        expected_cache[integer'(commit_word_addr_i[p][l])/LW][integer'(commit_word_addr_i[p][l])%LW]=commit_wdata_i[p][l];
                end
            end
        end
    end
    initial begin : backend
        forever begin
            @(negedge clk);
            backend_cmd_ready_i=rst_n&&manual_backend_ready&&!read_pending&&!wb_pending&&!store_pending;
            backend_read_resp_valid_i=rst_n&&read_pending&&permit_response;
            backend_read_resp_tag_i=read_tag;backend_read_resp_line_addr_i=read_line;backend_read_resp_fault_i=0;
            for(integer w=0;w<LW;w=w+1)backend_read_resp_data_i[w]=mem[integer'(read_line)][w];
            backend_wb_status_valid_i=rst_n&&wb_pending&&permit_response;backend_wb_status_attempt_id_i=wb_id;
            backend_wb_status_success_i=1;backend_wb_status_retryable_i=0;
            backend_store_status_valid_i=rst_n&&store_pending&&permit_response;backend_store_status_attempt_id_i=store_id;
            backend_store_status_success_i=!store_fail_pending;backend_store_status_retryable_i=0;
            for(integer p=0;p<CP;p=p+1)if(withdraw_store[p])begin commit_valid_i[p]=0;withdraw_store[p]=0;end
        end
    end

    task automatic public_read(input integer line);
        integer bound,before_count;
        begin
            check(line>=0&&line<MEM_LINES,"public model line");
            before_count=client_returns;
            expected_client_line[0]=LAW'(line);client_req_line_addr_i[0]=LAW'(line);client_req_valid_i[0]=1;
            #1;bound=0;while(!client_req_ready_o[0])begin tick();bound=bound+1;check(bound<400,"public read admission");end
            tick();client_req_valid_i[0]=0;
            bound=0;while(client_returns==before_count)begin tick();bound=bound+1;check(bound<400,"public read response");end
            tick();
        end
    endtask
    task automatic recover_store_with_held_atomic_result;
        integer bound,base_atomic_returns;
        logic [63:0] saved_result;
        begin
            check(atomic_resp_valid_o&&!atomic_resp_ready_i&&atomic_busy_o,"real completed atomic held before recovery");
            base_atomic_returns=atomic_returns;saved_result=atomic_resp_old_o;
            allow_recovery=1;inject_store_failure=1;backend_store_status_reuse_safe_i=0;
            commit_lane_mask_i[1]=1;commit_word_addr_i[1][0]=32'((4*S*SETS+8)*LW);
            commit_wdata_i[1][0]=32'hfa11_0035;commit_valid_i[1]=1;
            bound=0;while(!commit_fault_valid_o)begin tick();bound=bound+1;check(bound<400,"terminal STORE fault");end
            repeat(3)begin tick();check(commit_abort_o==0&&commit_ready_o==0&&atomic_resp_valid_o
                &&atomic_resp_old_o===saved_result,"fault backpressure corrupted atomic result");end
            commit_fault_ready_i=1;
            bound=0;while(aborted[1]==0)begin tick();bound=bound+1;check(bound<400,"separate STORE abort");end
            commit_fault_ready_i=0;
            repeat(3)begin tick();check(recovery_required_o&&recovery_reset_blocked_o
                &&atomic_resp_valid_o&&atomic_resp_old_o===saved_result,"quarantine lost atomic response");end
            backend_store_status_reuse_safe_i=1;
            bound=0;
            while(rearms!=1||recovery_required_o||recovery_rearm_pulse_o||recovery_drain_active_o)begin
                tick();bound=bound+1;check(bound<400,"STORE-only rearm/drain");
                check(atomic_resp_valid_o&&atomic_resp_old_o===saved_result&&atomic_returns==base_atomic_returns,
                    "STORE recovery fabricated/dropped atomic completion");
            end
            tick();check(aborted[0]==0&&aborted[1]==1&&retired[1]==0&&drain_cycles>0&&(|dirty_present_o),
                "atomic dirty state or exact STORE abort accounting");
            allow_recovery=0;inject_store_failure=0;exercise_recovery=0;
        end
    endtask

    task automatic atomic_op(input integer id,input logic [3:0] op,input logic wide,input logic [63:0] operand,compare,
        input logic replay,input logic [63:0] saved_old,input logic [3:0] fault,input logic stall_backend);
        logic [63:0] old,next_value;
        integer bound,base_reads,base_wbs;
        logic cas_result;
        begin
            check(id>=0&&id<256,"atomic ID range");
            base_reads=reads;base_wbs=wbs;
            atomic_req_request_id_i=8'(id);atomic_req_op_i=op;atomic_req_is64_i=wide;atomic_req_operand_i=operand;
            atomic_req_compare_i=compare;atomic_req_generation_i=atomic_current_generation_o;atomic_req_word_addr_i=0;
            atomic_req_valid_i=1;atomic_resp_ready_i=0;
            manual_backend_ready=!stall_backend;permit_response=!stall_backend;
            #1;bound=0;while(!atomic_req_ready_o)begin tick();bound=bound+1;check(bound<400,"atomic admission");end
            tick();atomic_req_valid_i=0;
            if(stall_backend)begin
                repeat(4)begin tick();check(!atomic_resp_valid_o,"fabricated result under backend stall");end
                manual_backend_ready=1;permit_response=1;
            end
            bound=0;while(!atomic_resp_valid_o)begin tick();bound=bound+1;check(bound<400,"atomic completion");end
            old=replay?saved_old:current_value(wide);
            next_value=ref_result(old,wide,op,operand,compare);
            cas_result=(op==1)&&(wide?old==compare:old[31:0]==compare[31:0]);
            check(atomic_resp_source_o===atomic_req_source_i&&atomic_resp_context_o===atomic_req_context_i
                &&atomic_resp_request_id_o===8'(id)&&atomic_resp_generation_o===atomic_req_generation_i
                &&atomic_resp_word_addr_o==0&&atomic_resp_is64_o===wide&&atomic_resp_op_o===op
                &&atomic_resp_operand_o===operand&&atomic_resp_compare_o===compare,"exact full atomic response identity");
            check(atomic_resp_replay_o===replay&&atomic_resp_fault_o===fault,"atomic replay/fault classification");
            if(fault==0)begin
                check(atomic_resp_old_o===old&&atomic_resp_cas_success_o===cas_result,"cache-backed original value/CAS outcome");
                if(!replay)begin
                    expected_cache[0][0]=next_value[31:0];
                    for(integer w=0;w<LW;w=w+1)if(w==1&&wide)expected_cache[0][w]=next_value[63:32];
                end
            end
            if(replay||fault!=0)check(reads==base_reads&&wbs==base_wbs,"replay/rejection caused backend work");
            if(exercise_recovery)recover_store_with_held_atomic_result();
            repeat(4)begin tick();check(atomic_resp_valid_o&&atomic_resp_old_o===(fault==0?old:64'b0),"held atomic result stable");end
            atomic_resp_ready_i=1;tick();atomic_resp_ready_i=0;tick();
            check(!atomic_busy_o&&!atomic_resp_valid_o&&remote_owned_present_o==0,"atomic retired with ownership still live");
        end
    endtask

    initial begin : stimulus
        cycles=0;checks=0;scenarios=0;reads=0;read_returns=0;wbs=0;wb_returns=0;stores=0;store_returns=0;
        atomic_accepts=0;atomic_returns=0;client_accepts=0;client_returns=0;next_id=10;
        inject_store_failure=0;store_fail_pending=0;allow_recovery=0;exercise_recovery=0;rearms=0;drain_cycles=0;
        rst_n=0;client_req_valid_i=0;commit_valid_i=0;client_live=0;withdraw_store=0;stalled=0;held_command=0;
        read_pending=0;wb_pending=0;store_pending=0;manual_backend_ready=1;permit_response=1;read_tag=0;read_line=0;wb_id=0;store_id=0;
        backend_store_status_reuse_safe_i=1;backend_store_all_generations_quiescent_i=1;backend_wb_recovery_safe_valid_i=0;
        commit_fault_ready_i=0;probe_reuse_safe_i=0;
        atomic_req_valid_i=0;atomic_resp_ready_i=0;atomic_req_source_i=0;atomic_req_context_i=0;atomic_req_request_id_i=0;
        atomic_req_generation_i=0;atomic_req_word_addr_i=0;atomic_req_is64_i=0;atomic_req_op_i=0;atomic_req_operand_i=0;atomic_req_compare_i=0;
        atomic_epoch_advance_valid_i=0;atomic_epoch_quiescent_i=0;atomic_all_generations_quiescent_i=0;
        for(integer c=0;c<C;c=c+1)begin client_req_local_tag_i[c]=0;client_req_line_addr_i[c]=0;expected_client_line[c]=0;end
        for(integer p=0;p<CP;p=p+1)begin
            retired[p]=0;aborted[p]=0;commit_lane_mask_i[p]=0;
            for(integer l=0;l<LANES;l=l+1)begin commit_word_addr_i[p][l]=0;commit_wdata_i[p][l]=0;end
        end
        for(integer line=0;line<MEM_LINES;line=line+1)
            for(integer w=0;w<LW;w=w+1)begin mem[line][w]=32'(10+line*LW+w);expected_cache[line][w]=mem[line][w];end
        repeat(3)tick();rst_n=1;tick();mark("RESET");
        first_old=64'd10;
        atomic_op(1,2,0,64'd7,0,0,0,0,1);
        public_read(0);check(reads==1&&expected_cache[0][0]==17,"real cold fill and atomic update");
        mark("COLD_FILL_ACTUAL_CACHE_RMW_BACKPRESSURE");
        atomic_op(1,2,0,64'd7,0,1,first_old,0,0);
        public_read(0);check(expected_cache[0][0]==17,"lost result retry double mutation");
        mark("LOST_RESPONSE_REPLAY_REAL_CACHE");
        atomic_op(1,2,0,64'd8,0,0,0,3,0);public_read(0);
        mark("MUTATED_DESCRIPTOR_REJECTED");
        atomic_req_source_i=1;
        atomic_op(2,1,0,64'd100,64'd17,0,0,0,0);
        atomic_req_source_i=2;
        atomic_op(2,1,0,64'd200,64'd17,0,0,0,0);
        check(expected_cache[0][0]==100,"two-source compare-exchange has one winner");public_read(0);
        mark("TWO_SOURCE_CAS_SERIAL_ORDER");
        commit_lane_mask_i[0]=1;commit_word_addr_i[0][0]=0;commit_wdata_i[0][0]=32'd300;commit_valid_i[0]=1;
        atomic_req_source_i=0;
        atomic_op(3,2,0,64'd5,0,0,0,0,0);
        check(retired[0]==1&&retired[1]==0&&expected_cache[0][0]==305,"normal STORE before atomic order");
        public_read(0);mark("NORMAL_STORE_THEN_ATOMIC_ORDER");
        for(integer wide=0;wide<2;wide=wide+1)
            for(integer op=0;op<11;op=op+1)begin
                atomic_op(next_id,4'(op),1'(wide),64'h8000_0000_8000_0001,64'hffff_ffff_ffff_fffe,
                    0,0,(wide!=0&&LW==1)?4'd1:4'd0,0);
                next_id=next_id+1;public_read(0);
            end
        mark("ALL_OPERATIONS_OBSERVED_THROUGH_PUBLIC_READ");
        first_old=current_value(0);exercise_recovery=1;
        atomic_op(40,2,0,64'd3,0,0,0,0,0);
        public_read(0);mark("STORE_RECOVERY_PRESERVES_HELD_ATOMIC_RESULT_AND_DIRTY_LINE");
        atomic_op(40,2,0,64'd3,0,1,first_old,0,0);
        public_read(0);mark("STORE_RECOVERY_PRESERVES_COMMITTED_DEDUP");
        check((|dirty_present_o),"atomic dirty responsibility lost");
        public_read(S*SETS);
        check(wbs==1&&wb_returns==1,"dirty victim not written back exactly once");
        for(integer w=0;w<LW;w=w+1)check(mem[0][w]===expected_cache[0][w],"exact full dirty payload in memory");
        public_read(0);mark("DIRTY_ATOMIC_WRITEBACK_AND_REFILL");
        check(atomic_accepts==atomic_returns&&client_accepts==client_returns&&reads==read_returns&&stores==store_returns
            &&client_read_outstanding_o==0&&wb_busy_o==0&&wb_pending_count_o==0&&wb_active_count_o==0
            &&!atomic_table_full_o&&!atomic_epoch_advance_ready_o
            &&!atomic_epoch_advance_pulse_o&&atomic_current_generation_o==0&&stores==1&&store_returns==1
            &&rearms==1&&aborted[0]==0&&aborted[1]==1,"final exact accounting/namespace");
        $display("P35_INTEGRATED_PASS variant=%0d scenarios=%0d checks=%0d atomic_accepts=%0d atomic_returns=%0d reads=%0d read_returns=%0d wb=%0d wb_returns=%0d clients=%0d client_returns=%0d stores=%0d store_returns=%0d aborts=%0d rearms=%0d",
            VARIANT,scenarios,checks,atomic_accepts,atomic_returns,reads,read_returns,wbs,wb_returns,client_accepts,client_returns,
            stores,store_returns,aborted[1],rearms);
        $finish;
    end
endmodule
