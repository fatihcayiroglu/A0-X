`timescale 1ns/1ps

// Requester-side architectural lifetime ledger. Transport replay may produce
// several packets; an allocated identity retires once, including after retry.
// Advance is an authoritative namespace handshake, not response-ready. Caller
// must enforce truthful quiescence and finite wrap before asserting it.
module a0_atomic_response_retire_guard #(
    parameter integer SOURCE_W=2,CONTEXT_W=2,REQUEST_ID_W=8,GENERATION_W=2,
    parameter integer ENTRY_COUNT=4,
    parameter integer COUNT_W=$clog2(ENTRY_COUNT+1)
) (
    input logic clk,rst_n,
    input logic issue_valid_i,
    output logic issue_ready_o,
    input logic [SOURCE_W-1:0] issue_source_i,
    input logic [CONTEXT_W-1:0] issue_context_i,
    input logic [REQUEST_ID_W-1:0] issue_request_id_i,
    input logic [GENERATION_W-1:0] issue_generation_i,
    input logic [31:0] issue_word_addr_i,
    input logic issue_is64_i,
    input logic [3:0] issue_op_i,
    input logic [63:0] issue_operand_i,issue_compare_i,
    output logic issue_new_o,issue_rejected_o,
    input logic response_valid_i,
    output logic response_ready_o,
    input logic [SOURCE_W-1:0] response_source_i,
    input logic [CONTEXT_W-1:0] response_context_i,
    input logic [REQUEST_ID_W-1:0] response_request_id_i,
    input logic [GENERATION_W-1:0] response_generation_i,
    input logic [31:0] response_word_addr_i,
    input logic response_is64_i,
    input logic [3:0] response_op_i,
    input logic [63:0] response_operand_i,response_compare_i,response_old_i,
    input logic response_cas_success_i,
    input logic [3:0] response_fault_i,
    output logic response_duplicate_o,response_rejected_o,
    output logic retire_valid_o,
    input logic retire_ready_i,
    output logic [SOURCE_W-1:0] retire_source_o,
    output logic [CONTEXT_W-1:0] retire_context_o,
    output logic [REQUEST_ID_W-1:0] retire_request_id_o,
    output logic [GENERATION_W-1:0] retire_generation_o,
    output logic [31:0] retire_word_addr_o,
    output logic retire_is64_o,
    output logic [3:0] retire_op_o,
    output logic [63:0] retire_operand_o,retire_compare_o,retire_old_o,
    output logic retire_cas_success_o,
    output logic [3:0] retire_fault_o,
    input logic namespace_advance_i,
    output logic namespace_ready_o,
    output logic [GENERATION_W-1:0] current_generation_o,
    output logic [COUNT_W-1:0] outstanding_o,
    output logic protocol_error_o
);
    localparam integer IW=(ENTRY_COUNT<=1)?1:$clog2(ENTRY_COUNT);
    typedef struct packed {
        logic [SOURCE_W-1:0] source;
        logic [CONTEXT_W-1:0] context_id;
        logic [REQUEST_ID_W-1:0] request_id;
        logic [GENERATION_W-1:0] generation;
    } key_t;
    typedef struct packed {
        logic [31:0] word_addr;
        logic is64;
        logic [3:0] op;
        logic [63:0] operand,compare_value;
    } descriptor_t;
    typedef enum logic [1:0] {FREE,ISSUED,RESULT_READY,RETIRED} state_t;
    key_t keys[0:ENTRY_COUNT-1],issue_key,response_key;
    descriptor_t descriptors[0:ENTRY_COUNT-1],issue_descriptor,response_descriptor;
    state_t states[0:ENTRY_COUNT-1];
    logic [63:0] results[0:ENTRY_COUNT-1];
    logic successes[0:ENTRY_COUNT-1];
    logic [3:0] faults[0:ENTRY_COUNT-1];
    logic held_q;
    logic [IW-1:0] selected_q;
    integer issue_match,response_match,free_entry,ready_entry,count;
    logic issue_exact,response_exact;
    initial begin
        if(ENTRY_COUNT<1||SOURCE_W<1||CONTEXT_W<1||REQUEST_ID_W<1||GENERATION_W<1
            ||COUNT_W<$clog2(ENTRY_COUNT+1))$fatal(1,"P35 requester ledger geometry");
    end
    always_comb begin
        issue_key={issue_source_i,issue_context_i,issue_request_id_i,issue_generation_i};
        response_key={response_source_i,response_context_i,response_request_id_i,response_generation_i};
        issue_descriptor={issue_word_addr_i,issue_is64_i,issue_op_i,issue_operand_i,issue_compare_i};
        response_descriptor={response_word_addr_i,response_is64_i,response_op_i,response_operand_i,response_compare_i};
        issue_match=-1;response_match=-1;free_entry=-1;ready_entry=-1;count=0;
        for(integer e=0;e<ENTRY_COUNT;e=e+1)begin
            if(states[e]==FREE&&free_entry<0)free_entry=e;
            if(states[e]!=FREE&&keys[e]==issue_key)issue_match=e;
            if(states[e]!=FREE&&keys[e]==response_key)response_match=e;
            if(states[e]==RESULT_READY&&ready_entry<0)ready_entry=e;
            if(states[e]==ISSUED||states[e]==RESULT_READY)count=count+1;
        end
        issue_exact=0;response_exact=0;
        if(issue_match>=0)issue_exact=descriptors[issue_match]==issue_descriptor;
        if(response_match>=0)response_exact=descriptors[response_match]==response_descriptor;
        issue_ready_o=rst_n&&!namespace_advance_i&&issue_generation_i==current_generation_o
            &&((issue_match>=0&&issue_exact)||(issue_match<0&&free_entry>=0));
        response_ready_o=rst_n&&!namespace_advance_i;
        retire_valid_o=rst_n&&held_q;
        {retire_source_o,retire_context_o,retire_request_id_o,retire_generation_o}=keys[selected_q];
        {retire_word_addr_o,retire_is64_o,retire_op_o,retire_operand_o,retire_compare_o}=descriptors[selected_q];
        retire_old_o=results[selected_q];retire_cas_success_o=successes[selected_q];retire_fault_o=faults[selected_q];
        outstanding_o=COUNT_W'(count);
        namespace_ready_o=rst_n&&count==0&&!held_q&&!issue_valid_i&&!response_valid_i;
    end
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            current_generation_o<='0;held_q<=0;selected_q<='0;protocol_error_o<=0;
            issue_new_o<=0;issue_rejected_o<=0;response_duplicate_o<=0;response_rejected_o<=0;
            for(integer e=0;e<ENTRY_COUNT;e=e+1)begin
                states[e]<=FREE;keys[e]<='0;descriptors[e]<='0;results[e]<='0;successes[e]<=0;faults[e]<='0;
            end
        end else begin
            issue_new_o<=0;issue_rejected_o<=0;response_duplicate_o<=0;response_rejected_o<=0;
            if(namespace_advance_i)begin
                if(namespace_ready_o)begin
                    current_generation_o<=current_generation_o+1'b1;
                    for(integer e=0;e<ENTRY_COUNT;e=e+1)states[e]<=FREE;
                end else protocol_error_o<=1;
            end else begin
                if(issue_valid_i)begin
                    if(issue_generation_i!=current_generation_o||(issue_match>=0&&!issue_exact))issue_rejected_o<=1;
                    if(issue_ready_o&&issue_match<0)begin
                        states[free_entry]<=ISSUED;keys[free_entry]<=issue_key;descriptors[free_entry]<=issue_descriptor;
                        issue_new_o<=1;
                    end
                end
                if(response_valid_i&&response_ready_o)begin
                    if(response_generation_i!=current_generation_o||response_match<0||!response_exact)response_rejected_o<=1;
                    else if(states[response_match]==ISSUED)begin
                        results[response_match]<=response_old_i;successes[response_match]<=response_cas_success_i;
                        faults[response_match]<=response_fault_i;states[response_match]<=RESULT_READY;
                    end else if(results[response_match]==response_old_i&&successes[response_match]==response_cas_success_i
                        &&faults[response_match]==response_fault_i)response_duplicate_o<=1;
                    else response_rejected_o<=1;
                end
                if(retire_valid_o&&retire_ready_i)begin states[selected_q]<=RETIRED;held_q<=0;end
                else if(!held_q&&ready_entry>=0)begin selected_q<=IW'(ready_entry);held_q<=1;end
            end
        end
    end
endmodule
