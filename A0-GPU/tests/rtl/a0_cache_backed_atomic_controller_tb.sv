`timescale 1ns/1ps
// P35 controller component model only; not production integration evidence.
module a0_cache_backed_atomic_controller_tb #(parameter integer VARIANT=0);
    localparam integer LINE_WORDS=1<<VARIANT, LINE_ADDR_W=32-VARIANT;
    localparam integer SLICE_COUNT=1<<VARIANT,SLICE_ID_W=(VARIANT==0)?1:VARIANT,SLICE_HASH_SHIFT=VARIANT;
    localparam integer COHERENCE_NODE_W=4,COHERENCE_TXN_W=4,COHERENCE_GEN_W=8;
    localparam integer SOURCE_W=2,CONTEXT_W=2,REQUEST_ID_W=8,GENERATION_W=VARIANT+1,ENTRY_COUNT=4,READ_TAG_W=2;
    logic clk,rst_n;
    logic req_valid_i;
    logic req_ready_o;
    logic [SOURCE_W-1:0] req_source_i;
    logic [CONTEXT_W-1:0] req_context_i;
    logic [REQUEST_ID_W-1:0] req_request_id_i;
    logic [GENERATION_W-1:0] req_generation_i;
    logic [31:0] req_word_addr_i;
    logic req_is64_i;
    logic [3:0] req_op_i;
    logic [63:0] req_operand_i,req_compare_i;
    logic resp_valid_o;
    logic resp_ready_i;
    logic [SOURCE_W-1:0] resp_source_o;
    logic [CONTEXT_W-1:0] resp_context_o;
    logic [REQUEST_ID_W-1:0] resp_request_id_o;
    logic [GENERATION_W-1:0] resp_generation_o;
    logic [31:0] resp_word_addr_o;
    logic resp_is64_o;
    logic [3:0] resp_op_o;
    logic [63:0] resp_operand_o,resp_compare_o,resp_old_o;
    logic resp_cas_success_o;
    logic [3:0] resp_fault_o;
    logic resp_replay_o;
    logic epoch_advance_valid_i;
    logic epoch_advance_ready_o;
    logic epoch_quiescent_i,all_generations_quiescent_i;
    logic [GENERATION_W-1:0] current_generation_o;
    logic epoch_advance_pulse_o,table_full_o,busy_o,protocol_error_o;
    logic read_req_valid_o;
    logic read_req_ready_i;
    logic [READ_TAG_W-1:0] read_req_tag_o;
    logic [LINE_ADDR_W-1:0] read_req_line_addr_o;
    logic read_resp_valid_i;
    logic [READ_TAG_W-1:0] read_resp_tag_i;
    logic [LINE_ADDR_W-1:0] read_resp_line_addr_i;
    logic read_resp_fault_i;
    logic probe_req_valid_o;
    logic probe_req_ready_i;
    logic probe_req_take_o;
    logic [COHERENCE_NODE_W-1:0] probe_req_node_o;
    logic [COHERENCE_TXN_W-1:0] probe_req_txn_o;
    logic [SLICE_ID_W-1:0] probe_req_home_o;
    logic [LINE_ADDR_W-1:0] probe_req_line_addr_o;
    logic probe_resp_valid_i;
    logic probe_resp_ready_o;
    logic probe_resp_take_i;
    logic [COHERENCE_NODE_W-1:0] probe_resp_node_i;
    logic [COHERENCE_TXN_W-1:0] probe_resp_txn_i;
    logic [SLICE_ID_W-1:0] probe_resp_home_i;
    logic [LINE_ADDR_W-1:0] probe_resp_line_addr_i;
    logic [COHERENCE_GEN_W-1:0] probe_resp_generation_i;
    logic probe_resp_hit_i,probe_resp_dirty_i;
    logic [31:0] probe_resp_data_i[0:LINE_WORDS-1];
    logic reclaim_valid_o;
    logic reclaim_ready_i;
    logic [SLICE_ID_W-1:0] reclaim_home_o;
    logic [COHERENCE_NODE_W-1:0] reclaim_node_o;
    logic [COHERENCE_GEN_W-1:0] reclaim_generation_o;
    logic [LINE_ADDR_W-1:0] reclaim_line_addr_o;
    logic reclaim_dirty_o;
    logic [31:0] reclaim_data_o[0:LINE_WORDS-1];
    logic [31:0] model[0:LINE_WORDS-1],expected[0:LINE_WORDS-1],held_line[0:LINE_WORDS-1];
    logic dirty,owned,read_pending,probe_pending,return_stalled,result_stalled;
    logic permit_return,permit_read,permit_probe;
    logic fail_next_read,pending_read_fault,miss_next_probe,pending_probe_hit;
    logic [COHERENCE_GEN_W-1:0] owner_generation,next_owner;
    logic [SLICE_ID_W-1:0] owner_home;
    logic [LINE_ADDR_W-1:0] owner_line;
    logic [COHERENCE_NODE_W-1:0] owner_node;
    logic [COHERENCE_TXN_W-1:0] owner_txn;
    logic [READ_TAG_W-1:0] pending_read_tag;
    logic [LINE_ADDR_W-1:0] pending_read_line;
    logic [63:0] held_result;
    logic [3:0] held_fault;
    logic held_cas,held_replay,held_dirty;
    integer cycles,checks,scenarios,accepted,responses,read_count,takes,returns;
    integer next_id,epoch_events,probe_misses;
    a0_cache_backed_atomic_controller #(
        .LINE_WORDS(LINE_WORDS),.LINE_ADDR_W(LINE_ADDR_W),.SLICE_COUNT(SLICE_COUNT),
        .SLICE_ID_W(SLICE_ID_W),.SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .COHERENCE_NODE_W(COHERENCE_NODE_W),.COHERENCE_TXN_W(COHERENCE_TXN_W),
        .COHERENCE_GEN_W(COHERENCE_GEN_W),.SOURCE_W(SOURCE_W),.CONTEXT_W(CONTEXT_W),
        .REQUEST_ID_W(REQUEST_ID_W),.GENERATION_W(GENERATION_W),.ENTRY_COUNT(ENTRY_COUNT),.READ_TAG_W(READ_TAG_W)
    ) dut(.*);
    initial begin clk=0; forever #5 clk=~clk; end
    task automatic check(input bit ok,input string detail);
        if(!ok) $fatal(1,"P35_COMPONENT_CHECK_FAILED cycle=%0d %s",cycles,detail);
        checks=checks+1;
    endtask
    task automatic tick; @(negedge clk); #1; endtask
    task automatic mark(input string name);
        scenarios=scenarios+1; $display("P35_COMPONENT_SCENARIO_PASS id=%0d name=%s",scenarios,name);
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
    function automatic logic [63:0] model_value(input logic wide);
        logic [63:0] value;
        begin
            value='0;
            for(integer w=0;w<LINE_WORDS;w=w+1) begin
                if(w==0)value[31:0]=model[w];
                if(w==1 && wide)value[63:32]=model[w];
            end
            model_value=value;
        end
    endfunction

    initial begin : monitor
        forever begin
            @(posedge clk); cycles=cycles+1;
            if(cycles>40000)$fatal(1,"P35 component watchdog");
            if(rst_n) begin
                check(!protocol_error_o,"unexpected protocol fault");
                if(req_valid_i&&req_ready_o) accepted=accepted+1;
                if(resp_valid_o&&resp_ready_i)responses=responses+1;
                if(epoch_advance_pulse_o)epoch_events=epoch_events+1;
                if(result_stalled) check(resp_valid_o && resp_old_o===held_result && resp_fault_o===held_fault
                    && resp_cas_success_o===held_cas && resp_replay_o===held_replay,"held atomic result changed");
                result_stalled=resp_valid_o&&!resp_ready_i;
                if(result_stalled)begin held_result=resp_old_o;held_fault=resp_fault_o;held_cas=resp_cas_success_o;held_replay=resp_replay_o;end
                if(return_stalled)begin
                    check(reclaim_valid_o&&reclaim_dirty_o===held_dirty,"held return control");
                    for(integer w=0;w<LINE_WORDS;w=w+1)check(reclaim_data_o[w]===held_line[w],"held return payload");
                end
                return_stalled=reclaim_valid_o&&!reclaim_ready_i;
                if(return_stalled)begin held_dirty=reclaim_dirty_o;for(integer w=0;w<LINE_WORDS;w=w+1)held_line[w]=reclaim_data_o[w];end
                if(read_resp_valid_i)begin check(read_pending,"unsolicited model READ");read_pending=0;end
                if(read_req_valid_o&&read_req_ready_i)begin
                    check(!read_pending&&!owned,"READ while owned or overlapping");
                    pending_read_tag=read_req_tag_o;pending_read_line=read_req_line_addr_o;
                    pending_read_fault=fail_next_read;fail_next_read=0;
                    read_pending=1;read_count=read_count+1;
                end
                if(probe_resp_valid_i&&probe_resp_ready_o)begin
                    check(probe_pending&&!owned,"duplicate model TAKE response");
                    probe_pending=0;
                    if(pending_probe_hit)begin owned=1;takes=takes+1;end
                    else probe_misses=probe_misses+1;
                end
                if(probe_req_valid_o&&probe_req_ready_i)begin
                    check(!probe_pending&&!owned&&probe_req_take_o,"probe exclusivity/kind");
                    owner_home=probe_req_home_o;owner_line=probe_req_line_addr_o;
                    owner_node=probe_req_node_o;owner_txn=probe_req_txn_o;
                    pending_probe_hit=!miss_next_probe;miss_next_probe=0;
                    owner_generation=next_owner;
                    if(pending_probe_hit)next_owner=next_owner+1'b1;
                    probe_pending=1;
                end
                if(reclaim_valid_o&&reclaim_ready_i)begin
                    check(owned && reclaim_home_o===owner_home && reclaim_node_o===owner_node
                        && reclaim_generation_o===owner_generation && reclaim_line_addr_o===owner_line,"exact accepting ownership return");
                    check(!resp_valid_o,"result preceded cache install");
                    for(integer w=0;w<LINE_WORDS;w=w+1)begin
                        check(reclaim_data_o[w]===expected[w],"return effect or untouched bytes differ");
                        model[w]=reclaim_data_o[w];
                    end
                    dirty=reclaim_dirty_o;owned=0;returns=returns+1;
                end
            end
        end
    end
    initial begin : responder
        forever begin
            @(negedge clk);
            read_req_ready_i=rst_n&&!read_pending&&!owned;
            read_resp_valid_i=rst_n&&read_pending&&permit_read;
            read_resp_tag_i=pending_read_tag;read_resp_line_addr_i=pending_read_line;read_resp_fault_i=pending_read_fault;
            probe_req_ready_i=rst_n&&!probe_pending&&!owned;
            probe_resp_valid_i=rst_n&&probe_pending&&permit_probe;
            probe_resp_take_i=1;probe_resp_home_i=owner_home;probe_resp_line_addr_i=owner_line;
            probe_resp_node_i=owner_node;probe_resp_txn_i=owner_txn;probe_resp_generation_i=owner_generation;
            probe_resp_hit_i=pending_probe_hit;probe_resp_dirty_i=dirty;
            for(integer w=0;w<LINE_WORDS;w=w+1)probe_resp_data_i[w]=model[w];
            reclaim_ready_i=rst_n&&owned&&permit_return;
        end
    end

    task automatic advance_epoch;
        logic [GENERATION_W-1:0] old_generation;
        begin
            old_generation=current_generation_o;
            check(!busy_o,"epoch must not reset active work");
            epoch_quiescent_i=0;all_generations_quiescent_i=0;repeat(2)tick();
            epoch_quiescent_i=1;all_generations_quiescent_i=1;epoch_advance_valid_i=1;
            #1;check(epoch_advance_ready_o,"fresh truthful certificates did not rearm");
            tick();epoch_advance_valid_i=0;
            check(current_generation_o==GENERATION_W'(old_generation+1'b1)&&!table_full_o,"finite namespace advance");
            tick();
        end
    endtask

    task automatic transact(input integer id,input logic [3:0] op,input logic wide,
        input logic [63:0] operand,compare,input logic [3:0] fault,
        input logic replay,input logic [63:0] replay_old,input logic [GENERATION_W-1:0] generation,
        input logic stall_work,input logic [31:0] address=0);
        logic [63:0] old,changed;
        integer base_returns,base_reads,base_takes,bound;
        logic expected_cas;
        begin
            check(id>=0 && id<(1<<REQUEST_ID_W),"request ID representable before narrowing");
            old=(replay)?replay_old:model_value(wide);
            changed=ref_result(old,wide,op,operand,compare);
            expected_cas=(op==1)&& (wide ? old==compare : old[31:0]==compare[31:0]);
            for(integer w=0;w<LINE_WORDS;w=w+1)expected[w]=model[w];
            if(fault==0&&!replay)begin
                expected[0]=changed[31:0];
                for(integer w=0;w<LINE_WORDS;w=w+1)if(w==1&&wide)expected[w]=changed[63:32];
            end
            base_returns=returns;base_reads=read_count;base_takes=takes;
            req_request_id_i=REQUEST_ID_W'(id);req_op_i=op;req_is64_i=wide;req_operand_i=operand;req_compare_i=compare;
            req_generation_i=generation;req_word_addr_i=address;req_valid_i=1;resp_ready_i=0;
            permit_return=!stall_work;permit_read=!stall_work;permit_probe=!stall_work;
            #1;bound=0;
            while(!req_ready_o)begin tick();bound=bound+1;check(bound<200,"request admission timeout");end
            tick();req_valid_i=0;
            if(stall_work && fault==0&&!replay)begin
                // Exact duplicate before commit remains unaccepted; no side effect.
                req_valid_i=1;repeat(3)begin tick();check(!req_ready_o&&!resp_valid_o&&returns==base_returns,"pending replay fabricated effect");end
                req_valid_i=0;permit_read=1;permit_probe=1;
                bound=0;while(!reclaim_valid_o)begin tick();bound=bound+1;check(bound<200,"return timeout");end
                repeat(4)begin tick();check(!resp_valid_o&&owned,"reclaim backpressure lost ownership");end
                permit_return=1;
            end
            bound=0;
            while(!resp_valid_o)begin tick();bound=bound+1;check(bound<200,"response timeout");end
            check(resp_source_o===req_source_i&&resp_context_o===req_context_i&&resp_request_id_o===REQUEST_ID_W'(id)
                &&resp_generation_o===generation&&resp_word_addr_o===address&&resp_is64_o===wide&&resp_op_o===op
                &&resp_operand_o===operand&&resp_compare_o===compare,"response full immutable identity");
            check(resp_fault_o===fault&&resp_replay_o===replay,"response fault/replay");
            if(fault==0)begin
                check(resp_old_o===old&&resp_cas_success_o===expected_cas,"original result or CAS outcome");
                check(returns==base_returns+(replay?0:1),"exactly one effect, including replay");
                if(replay)check(read_count==base_reads&&takes==base_takes,"replay reacquired cache");
            end else if(fault==4)begin
                check(returns==base_returns&&takes==base_takes&&read_count==base_reads+(replay?0:1),"READ fault touched ownership or repeated read");
                check(resp_old_o==0&&!resp_cas_success_o,"READ fault fabricated result");
            end else check(returns==base_returns&&read_count==base_reads&&takes==base_takes,"rejected request touched cache");
            repeat(4)tick();
            resp_ready_i=1;tick();resp_ready_i=0;tick();
            check(!busy_o&&!resp_valid_o&&!owned,"response retirement left live work");
            for(integer w=0;w<LINE_WORDS;w=w+1)check(model[w]===expected[w],"final line mismatch");
            permit_return=1;permit_read=1;permit_probe=1;
        end
    endtask

    initial begin : stimulus
        cycles=0;checks=0;scenarios=0;accepted=0;responses=0;read_count=0;takes=0;returns=0;next_id=1;epoch_events=0;probe_misses=0;
        rst_n=0;req_valid_i=0;resp_ready_i=0;req_source_i=0;req_context_i=0;
        req_request_id_i=0;req_generation_i=0;req_word_addr_i=0;req_is64_i=0;req_op_i=0;req_operand_i=0;req_compare_i=0;
        epoch_advance_valid_i=0;epoch_quiescent_i=1;all_generations_quiescent_i=1;
        dirty=0;owned=0;read_pending=0;probe_pending=0;return_stalled=0;result_stalled=0;
        fail_next_read=0;pending_read_fault=0;miss_next_probe=0;pending_probe_hit=1;
        permit_return=1;permit_read=1;permit_probe=1;next_owner=0;owner_generation=0;owner_home=0;owner_line=0;owner_node=0;owner_txn=0;
        pending_read_tag=0;pending_read_line=0;held_result=0;held_fault=0;held_cas=0;held_replay=0;held_dirty=0;
        for(integer w=0;w<LINE_WORDS;w=w+1)begin model[w]=32'(10+w);expected[w]=model[w];held_line[w]=0;end
        repeat(3)tick();rst_n=1;tick();
        check(!epoch_advance_ready_o&&current_generation_o==0&&!busy_o,"held high is not fresh quiescence");
        mark("RESET_AND_CERTIFICATE");
        transact(1,2,0,64'd7,0,0,0,0,current_generation_o,1);
        mark("PENDING_REPLAY_RETURN_AND_RESULT_BACKPRESSURE");
        transact(1,2,0,64'd7,0,0,1,64'd10,current_generation_o,0);
        check(model[0]==17,"response-loss ADD executed twice");
        mark("RESPONSE_LOSS_COMMITTED_REPLAY");
        transact(1,2,0,64'd8,0,3,0,0,current_generation_o,0);
        mark("CHANGED_FINGERPRINT_REJECTED");
        req_source_i=1;
        transact(1,2,0,64'd1,0,0,0,0,current_generation_o,0);
        req_context_i=1;
        transact(1,2,0,64'd1,0,0,0,0,current_generation_o,0);
        req_source_i=0;req_context_i=0;
        transact(2,1,0,64'd100,64'd19,0,0,0,current_generation_o,0);
        check(model[0]==100&&table_full_o,"CAS winner/full table");
        mark("SOURCE_CONTEXT_SEPARATION_CAS_WINNER");
        req_valid_i=1;req_request_id_i=8'd99;repeat(3)begin tick();check(!req_ready_o,"full table accepted new identity");end
        req_valid_i=0;
        transact(1,2,0,64'd7,0,0,1,64'd10,current_generation_o,0);
        mark("FULL_TABLE_REPLAY_PROGRESS");
        transact(1,2,0,64'd7,0,3,0,0,current_generation_o,0,32'd1);
        transact(1,2,1,64'd7,0,3,0,0,current_generation_o,0);
        transact(1,3,0,64'd7,0,3,0,0,current_generation_o,0);
        transact(1,2,0,64'd7,64'd1,3,0,0,current_generation_o,0);
        check(table_full_o,"fingerprint rejection altered full ledger");
        mark("ADDRESS_WIDTH_OPERATION_COMPARE_FINGERPRINT_REJECTED");
        transact(99,15,0,0,0,1,0,0,current_generation_o,0);
        transact(99,2,1,64'd1,0,1,0,0,current_generation_o,0,32'd1);
        check(table_full_o,"invalid descriptor consumed or cleared ledger");
        mark("INVALID_OPCODE_AND_ODD_64_ADDRESS_REJECTED_WHILE_FULL");
        advance_epoch();
        transact(1,2,0,64'd7,0,2,0,0,GENERATION_W'(current_generation_o-1'b1),0);
        mark("STALE_EPOCH_REJECTED");
        for(integer wide=0;wide<2;wide=wide+1)begin
            for(integer op=0;op<11;op=op+1)begin
                if(table_full_o)advance_epoch();
                transact(next_id,4'(op),1'(wide),64'h8000_0000_8000_0001,64'hffff_ffff_ffff_fffe,
                    (wide!=0&&LINE_WORDS==1)?4'd1:4'd0,0,0,current_generation_o,0);
                next_id=next_id+1;
            end
        end
        mark("ALL_32_64_OPERATIONS_OR_EXPLICIT_SINGLEWORD_REJECTION");
        advance_epoch();
        fail_next_read=1;
        transact(90,2,0,64'd1,0,4,0,0,current_generation_o,0);
        transact(90,2,0,64'd1,0,4,1,0,current_generation_o,0);
        check(!fail_next_read,"faulted READ fixture was not consumed");
        mark("READ_FAULT_RETAINED_REPLAY_WITHOUT_OWNERSHIP");
        begin : missed_take
            integer reads_before,returns_before;
            reads_before=read_count;returns_before=returns;miss_next_probe=1;
            transact(91,2,0,64'd1,0,0,0,0,current_generation_o,0);
            check(read_count==reads_before+2&&returns==returns_before+1&&probe_misses==1&&!miss_next_probe,
                "TAKE miss did not retry READ exactly once before effect");
        end
        mark("TAKE_MISS_RETRIES_READ_WITH_ONE_FINAL_EFFECT");
        // Component fixture installs a fresh clean line only while fully idle.
        // This is not a production-cache reset or integration coverage claim.
        check(!owned&&!read_pending&&!probe_pending&&!busy_o,"clean-line fixture requires idle");
        dirty=0;
        for(integer w=0;w<LINE_WORDS;w=w+1)model[w]=32'(40+w);
        transact(92,1,0,64'd999,64'd39,0,0,0,current_generation_o,0);
        check(!dirty&&model[0]==40,"failed CAS dirtied or changed clean line");
        transact(92,1,0,64'd999,64'd39,0,1,64'd40,current_generation_o,0);
        check(!dirty,"failed CAS replay dirtied clean line");
        mark("CLEAN_FAILED_CAS_AND_REPLAY_PRESERVE_BYTES_AND_DIRTY");
        check(accepted==responses && returns==takes && epoch_events>0 && !dirty && probe_misses==1,"final handshake accounting");
        $display("P35_COMPONENT_PASS variant=%0d scenarios=%0d checks=%0d accepts=%0d responses=%0d effects=%0d reads=%0d epochs=%0d probe_misses=%0d",
            VARIANT,scenarios,checks,accepted,responses,returns,read_count,epoch_events,probe_misses);
        $finish;
    end
endmodule
