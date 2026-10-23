`timescale 1ns/1ps
module a0_atomic_response_retire_guard_tb #(parameter integer VARIANT=0);
    localparam integer SOURCE_W=2,CONTEXT_W=2,REQUEST_ID_W=8,GENERATION_W=VARIANT+1;
    localparam integer ENTRY_COUNT=2<<VARIANT,COUNT_W=$clog2(ENTRY_COUNT+1);
    logic clk,rst_n;
    logic issue_valid_i;
    logic issue_ready_o;
    logic [SOURCE_W-1:0] issue_source_i;
    logic [CONTEXT_W-1:0] issue_context_i;
    logic [REQUEST_ID_W-1:0] issue_request_id_i;
    logic [GENERATION_W-1:0] issue_generation_i;
    logic [31:0] issue_word_addr_i;
    logic issue_is64_i;
    logic [3:0] issue_op_i;
    logic [63:0] issue_operand_i,issue_compare_i;
    logic issue_new_o,issue_rejected_o;
    logic response_valid_i;
    logic response_ready_o;
    logic [SOURCE_W-1:0] response_source_i;
    logic [CONTEXT_W-1:0] response_context_i;
    logic [REQUEST_ID_W-1:0] response_request_id_i;
    logic [GENERATION_W-1:0] response_generation_i;
    logic [31:0] response_word_addr_i;
    logic response_is64_i;
    logic [3:0] response_op_i;
    logic [63:0] response_operand_i,response_compare_i,response_old_i;
    logic response_cas_success_i;
    logic [3:0] response_fault_i;
    logic response_duplicate_o,response_rejected_o;
    logic retire_valid_o;
    logic retire_ready_i;
    logic [SOURCE_W-1:0] retire_source_o;
    logic [CONTEXT_W-1:0] retire_context_o;
    logic [REQUEST_ID_W-1:0] retire_request_id_o;
    logic [GENERATION_W-1:0] retire_generation_o;
    logic [31:0] retire_word_addr_o;
    logic retire_is64_o;
    logic [3:0] retire_op_o;
    logic [63:0] retire_operand_o,retire_compare_o,retire_old_o;
    logic retire_cas_success_o;
    logic [3:0] retire_fault_o;
    logic namespace_advance_i;
    logic namespace_ready_o;
    logic [GENERATION_W-1:0] current_generation_o;
    logic [COUNT_W-1:0] outstanding_o;
    logic protocol_error_o;
    integer cycles,checks,scenarios,new_issues,retires,rejected,duplicates;
    logic [GENERATION_W-1:0] previous_generation;
    a0_atomic_response_retire_guard #(.SOURCE_W(SOURCE_W),.CONTEXT_W(CONTEXT_W),
        .REQUEST_ID_W(REQUEST_ID_W),.GENERATION_W(GENERATION_W),.ENTRY_COUNT(ENTRY_COUNT))dut(.*);
    initial begin clk=0;forever #5 clk=~clk;end
    task automatic check(input bit ok,input string detail);
        if(!ok)$fatal(1,"P35_RETIRE_CHECK_FAILED cycle=%0d %s",cycles,detail);
        checks=checks+1;
    endtask
    task automatic tick;@(negedge clk);#1;endtask
    task automatic mark(input string name);
        scenarios=scenarios+1;$display("P35_RETIRE_SCENARIO_PASS id=%0d name=%s",scenarios,name);
    endtask
    initial begin
        forever begin
            @(posedge clk);cycles=cycles+1;if(cycles>10000)$fatal(1,"P35 requester watchdog");
            if(rst_n)begin
                check(!protocol_error_o,"unexpected namespace protocol error");
                if(issue_new_o)new_issues=new_issues+1;
                if(response_rejected_o)rejected=rejected+1;
                if(response_duplicate_o)duplicates=duplicates+1;
                if(retire_valid_o&&retire_ready_i)retires=retires+1;
            end
        end
    end
    task automatic issue_fields(input integer id);
        begin
            check(id>=0&&id<256,"representable request ID");
            issue_source_i=0;issue_context_i=0;issue_request_id_i=REQUEST_ID_W'(id);
            issue_generation_i=current_generation_o;issue_word_addr_i=32'd4;issue_is64_i=0;
            issue_op_i=2;issue_operand_i=7;issue_compare_i=0;
        end
    endtask
    task automatic issue(input integer id,input bit fresh);
        begin
            issue_fields(id);issue_valid_i=1;#1;check(issue_ready_o,"admission");
            tick();issue_valid_i=0;check(issue_new_o==fresh&&!issue_rejected_o,"new vs duplicate request identity");
            tick();
        end
    endtask
    task automatic response_fields(input integer id,input logic[GENERATION_W-1:0] gen,input logic[63:0] value);
        begin
            check(id>=0&&id<256,"representable response ID");
            response_source_i=0;response_context_i=0;response_request_id_i=REQUEST_ID_W'(id);
            response_generation_i=gen;response_word_addr_i=4;response_is64_i=0;response_op_i=2;
            response_operand_i=7;response_compare_i=0;response_old_i=value;response_cas_success_i=0;response_fault_i=0;
        end
    endtask
    task automatic packet(input integer id,input logic[GENERATION_W-1:0] gen,input logic[63:0] value,
        input integer mutation,input bit reject,input bit duplicate);
        begin
            check(mutation>=0&&mutation<=9,"packet mutation selector");
            response_fields(id,gen,value);
            case(mutation)
                1:response_source_i=1;2:response_context_i=1;3:response_request_id_i=response_request_id_i^8'h80;
                4:response_generation_i=gen+1'b1;5:response_word_addr_i=8;6:response_is64_i=1;
                7:response_op_i=3;8:response_operand_i=8;9:response_compare_i=1;
                default:begin end
            endcase
            response_valid_i=1;#1;check(response_ready_o,"transport receive ready");
            tick();response_valid_i=0;
            check(response_rejected_o==reject&&response_duplicate_o==duplicate,"exact packet classification");
            tick();
        end
    endtask
    task automatic check_result(input integer id,input logic[63:0] value);
        begin
            check(id>=0&&id<256,"representable retire ID");
            check(retire_valid_o&&retire_source_o==0&&retire_context_o==0&&retire_request_id_o==REQUEST_ID_W'(id)
                &&retire_generation_o==current_generation_o&&retire_word_addr_o==4&&!retire_is64_o&&retire_op_o==2
                &&retire_operand_o==7&&retire_compare_o==0&&retire_old_o===value&&!retire_cas_success_o&&retire_fault_o==0,
                "exact architectural retirement descriptor/result");
        end
    endtask
    task automatic consume(input integer id,input logic[63:0] value);
        integer bound;
        begin
            bound=0;while(!retire_valid_o)begin tick();bound=bound+1;check(bound<20,"retirement availability");end
            check_result(id,value);retire_ready_i=1;tick();retire_ready_i=0;tick();
        end
    endtask
    task automatic advance;
        logic[GENERATION_W-1:0] old;
        begin
            old=current_generation_o;check(namespace_ready_o&&outstanding_o==0,"all architectural lifetimes retired before advance");
            namespace_advance_i=1;tick();namespace_advance_i=0;
            check(current_generation_o==GENERATION_W'(old+1'b1),"namespace counter");tick();
        end
    endtask
    initial begin
        cycles=0;checks=0;scenarios=0;new_issues=0;retires=0;rejected=0;duplicates=0;previous_generation=0;
        rst_n=0;issue_valid_i=0;response_valid_i=0;retire_ready_i=0;namespace_advance_i=0;
        issue_source_i=0;issue_context_i=0;issue_request_id_i=0;issue_generation_i=0;issue_word_addr_i=0;
        issue_is64_i=0;issue_op_i=0;issue_operand_i=0;issue_compare_i=0;
        response_source_i=0;response_context_i=0;response_request_id_i=0;response_generation_i=0;response_word_addr_i=0;
        response_is64_i=0;response_op_i=0;response_operand_i=0;response_compare_i=0;response_old_i=0;
        response_cas_success_i=0;response_fault_i=0;
        repeat(3)tick();rst_n=1;tick();
        packet(1,current_generation_o,10,0,1,0);check(!retire_valid_o&&outstanding_o==0,"unsolicited response fabricated retirement");
        mark("UNISSUED_RESPONSE_REJECTED");
        issue(1,1);
        for(integer m=1;m<=9;m=m+1)begin packet(1,current_generation_o,10,m,1,0);check(!retire_valid_o&&outstanding_o==1,"mismatched response completed request");end
        mark("ALL_KEY_AND_DESCRIPTOR_FIELDS_REQUIRED");
        packet(1,current_generation_o,10,0,0,0);repeat(5)begin tick();check_result(1,10);end
        issue(2,1);packet(2,current_generation_o,20,0,0,0);
        repeat(5)begin tick();check_result(1,10);end
        packet(1,current_generation_o,10,0,0,1);check_result(1,10);
        packet(1,current_generation_o,11,0,1,0);check_result(1,10);
        mark("HELD_RETIREMENT_STABLE_WITH_OTHER_RESPONSE_AND_DUPLICATE");
        consume(1,10);consume(2,20);check(retires==2&&outstanding_o==0,"two real architectural retirements");
        issue(1,0);packet(1,current_generation_o,10,0,0,1);repeat(3)tick();
        check(retires==2&&!retire_valid_o,"retired identity replay retired twice");
        mark("POST_RETIRE_TRANSPORT_REPLAY_NO_DOUBLE_RETIRE");
        for(integer id=3;id<=ENTRY_COUNT;id=id+1)begin issue(id,1);packet(id,current_generation_o,64'(id),0,0,0);consume(id,64'(id));end
        issue_fields(99);issue_valid_i=1;#1;check(!issue_ready_o,"full tombstone ledger reallocated");tick();issue_valid_i=0;tick();
        issue_fields(1);issue_operand_i=8;issue_valid_i=1;#1;check(!issue_ready_o,"descriptor collision accepted");
        tick();issue_valid_i=0;check(issue_rejected_o,"descriptor rejection notification");tick();
        mark("FINITE_RETIRED_TOMBSTONES_AND_COLLISION");
        for(integer epoch=0;epoch<(1<<GENERATION_W);epoch=epoch+1)begin
            previous_generation=current_generation_o;advance();
            // Old packet and new-generation issue arrive on the same edge.
            issue_fields(1);issue_valid_i=1;
            response_fields(1,previous_generation,64'd999);response_valid_i=1;
            #1;check(issue_ready_o&&response_ready_o,"same-edge new issue/old response admission");
            tick();issue_valid_i=0;response_valid_i=0;
            check(issue_new_o&&response_rejected_o&&outstanding_o==1&&!retire_valid_o,"late old packet completed fresh generation");
            tick();
            packet(1,current_generation_o,64'(100+epoch),0,0,0);consume(1,64'(100+epoch));
            packet(1,previous_generation,64'd999,0,1,0);
            check(outstanding_o==0&&!retire_valid_o,"late response fabricated extra retirement");
        end
        mark("GENERATION_REUSE_WRAP_AND_SAME_EDGE_STALE_RESPONSE");
        check(current_generation_o==0&&new_issues==retires&&duplicates==2&&rejected==11+2*(1<<GENERATION_W),
            "exact lifecycle/rejection accounting");
        $display("P35_RETIRE_PASS variant=%0d scenarios=%0d checks=%0d allocations=%0d retires=%0d rejects=%0d duplicates=%0d",
            VARIANT,scenarios,checks,new_issues,retires,rejected,duplicates);
        $finish;
    end
endmodule
