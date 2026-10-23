`timescale 1ns/1ps

// P35 bounded successor: one serializer, retained replay results, real cache
// TAKE/reclaim. A result commits only with the actual ownership-return edge.
// Epoch certificates are external promises, not inferred from response ready.
module a0_cache_backed_atomic_controller #(
    parameter integer LINE_WORDS=8,
    parameter integer LINE_ADDR_W=32-((LINE_WORDS<=1)?0:$clog2(LINE_WORDS)),
    parameter integer SLICE_COUNT=4,
    parameter integer SLICE_ID_W=(SLICE_COUNT<=1)?1:$clog2(SLICE_COUNT),
    parameter integer SLICE_HASH_SHIFT=6,
    parameter integer COHERENCE_NODE_W=4,
    parameter integer COHERENCE_TXN_W=4,
    parameter integer COHERENCE_GEN_W=2,
    parameter logic [COHERENCE_NODE_W-1:0] LOCAL_ATOMIC_NODE_ID=1,
    parameter integer SOURCE_W=4,
    parameter integer CONTEXT_W=4,
    parameter integer REQUEST_ID_W=8,
    parameter integer GENERATION_W=2,
    parameter integer ENTRY_COUNT=4,
    parameter integer READ_TAG_W=2
) (
    input logic clk,rst_n,
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [SOURCE_W-1:0] req_source_i,
    input logic [CONTEXT_W-1:0] req_context_i,
    input logic [REQUEST_ID_W-1:0] req_request_id_i,
    input logic [GENERATION_W-1:0] req_generation_i,
    input logic [31:0] req_word_addr_i,
    input logic req_is64_i,
    input logic [3:0] req_op_i,
    input logic [63:0] req_operand_i,req_compare_i,
    output logic resp_valid_o,
    input logic resp_ready_i,
    output logic [SOURCE_W-1:0] resp_source_o,
    output logic [CONTEXT_W-1:0] resp_context_o,
    output logic [REQUEST_ID_W-1:0] resp_request_id_o,
    output logic [GENERATION_W-1:0] resp_generation_o,
    output logic [31:0] resp_word_addr_o,
    output logic resp_is64_o,
    output logic [3:0] resp_op_o,
    output logic [63:0] resp_operand_o,resp_compare_o,resp_old_o,
    output logic resp_cas_success_o,
    output logic [3:0] resp_fault_o,
    output logic resp_replay_o,
    input logic epoch_advance_valid_i,
    output logic epoch_advance_ready_o,
    input logic epoch_quiescent_i,all_generations_quiescent_i,
    output logic [GENERATION_W-1:0] current_generation_o,
    output logic epoch_advance_pulse_o,table_full_o,busy_o,protocol_error_o,
    output logic read_req_valid_o,
    input logic read_req_ready_i,
    output logic [READ_TAG_W-1:0] read_req_tag_o,
    output logic [LINE_ADDR_W-1:0] read_req_line_addr_o,
    input logic read_resp_valid_i,
    input logic [READ_TAG_W-1:0] read_resp_tag_i,
    input logic [LINE_ADDR_W-1:0] read_resp_line_addr_i,
    input logic read_resp_fault_i,
    output logic probe_req_valid_o,
    input logic probe_req_ready_i,
    output logic probe_req_take_o,
    output logic [COHERENCE_NODE_W-1:0] probe_req_node_o,
    output logic [COHERENCE_TXN_W-1:0] probe_req_txn_o,
    output logic [SLICE_ID_W-1:0] probe_req_home_o,
    output logic [LINE_ADDR_W-1:0] probe_req_line_addr_o,
    input logic probe_resp_valid_i,
    output logic probe_resp_ready_o,
    input logic probe_resp_take_i,
    input logic [COHERENCE_NODE_W-1:0] probe_resp_node_i,
    input logic [COHERENCE_TXN_W-1:0] probe_resp_txn_i,
    input logic [SLICE_ID_W-1:0] probe_resp_home_i,
    input logic [LINE_ADDR_W-1:0] probe_resp_line_addr_i,
    input logic [COHERENCE_GEN_W-1:0] probe_resp_generation_i,
    input logic probe_resp_hit_i,probe_resp_dirty_i,
    input logic [31:0] probe_resp_data_i[0:LINE_WORDS-1],
    output logic reclaim_valid_o,
    input logic reclaim_ready_i,
    output logic [SLICE_ID_W-1:0] reclaim_home_o,
    output logic [COHERENCE_NODE_W-1:0] reclaim_node_o,
    output logic [COHERENCE_GEN_W-1:0] reclaim_generation_o,
    output logic [LINE_ADDR_W-1:0] reclaim_line_addr_o,
    output logic reclaim_dirty_o,
    output logic [31:0] reclaim_data_o[0:LINE_WORDS-1]
);
    localparam integer WSEL=(LINE_WORDS<=1)?0:$clog2(LINE_WORDS);
    localparam integer ENTRY_INDEX_W=(ENTRY_COUNT<=1)?1:$clog2(ENTRY_COUNT);
    typedef enum logic [2:0] {IDLE,READ_REQ,READ_WAIT,TAKE_REQ,TAKE_WAIT,RETURN_LINE,RESPONSE} state_t;
    state_t state_q;
    logic entry_valid_q[0:ENTRY_COUNT-1],entry_committed_q[0:ENTRY_COUNT-1];
    logic [SOURCE_W-1:0] entry_source_q[0:ENTRY_COUNT-1];
    logic [CONTEXT_W-1:0] entry_context_q[0:ENTRY_COUNT-1];
    logic [REQUEST_ID_W-1:0] entry_id_q[0:ENTRY_COUNT-1];
    logic [GENERATION_W-1:0] entry_generation_q[0:ENTRY_COUNT-1];
    logic [31:0] entry_addr_q[0:ENTRY_COUNT-1];
    logic entry_is64_q[0:ENTRY_COUNT-1],entry_cas_q[0:ENTRY_COUNT-1];
    logic [3:0] entry_op_q[0:ENTRY_COUNT-1],entry_fault_q[0:ENTRY_COUNT-1];
    logic [63:0] entry_operand_q[0:ENTRY_COUNT-1],entry_compare_q[0:ENTRY_COUNT-1],entry_old_q[0:ENTRY_COUNT-1];
    integer match_entry,free_entry,word_index;
    logic [ENTRY_INDEX_W-1:0] active_entry_q;
    logic fingerprint_match,invalid_request,probe_exact;
    logic epoch_low_q,all_low_q;
    logic [LINE_ADDR_W-1:0] line_q;
    logic [63:0] observed_old,next_value;
    logic [31:0] result32;
    logic compare_success;

    initial begin
        if(LINE_WORDS<1 || (LINE_WORDS&(LINE_WORDS-1))!=0 || LINE_ADDR_W!=32-WSEL)
            $fatal(1,"P35 power-of-two complete-line geometry");
        if(SLICE_COUNT<1 || (SLICE_COUNT&(SLICE_COUNT-1))!=0 || SLICE_HASH_SHIFT<0 || SLICE_HASH_SHIFT>31)
            $fatal(1,"P35 home geometry");
        if(ENTRY_COUNT<1 || SOURCE_W<1 || CONTEXT_W<1 || REQUEST_ID_W<1 || GENERATION_W<1 || READ_TAG_W<1)
            $fatal(1,"P35 positive namespace widths/capacity");
        if(COHERENCE_NODE_W<1 || COHERENCE_TXN_W<1 || COHERENCE_GEN_W<1)
            $fatal(1,"P35 positive coherence widths");
    end
    function automatic logic [SLICE_ID_W-1:0] home_of(input logic [LINE_ADDR_W-1:0] line);
        if(SLICE_COUNT<=1) home_of='0;
        else home_of=SLICE_ID_W'(line)^SLICE_ID_W'(line>>SLICE_HASH_SHIFT);
    endfunction
    always_comb begin
        match_entry=-1; free_entry=-1;
        for(integer e=0;e<ENTRY_COUNT;e=e+1) begin
            if(!entry_valid_q[e] && free_entry<0) free_entry=e;
            if(entry_valid_q[e] && entry_source_q[e]==req_source_i && entry_context_q[e]==req_context_i
                && entry_id_q[e]==req_request_id_i && entry_generation_q[e]==req_generation_i) match_entry=e;
        end
        fingerprint_match=0;
        if(match_entry>=0) fingerprint_match=entry_addr_q[match_entry]==req_word_addr_i
            && entry_is64_q[match_entry]==req_is64_i && entry_op_q[match_entry]==req_op_i
            && entry_operand_q[match_entry]==req_operand_i && entry_compare_q[match_entry]==req_compare_i;
        invalid_request=req_op_i>4'd10 || (req_is64_i && ((LINE_WORDS<2) || req_word_addr_i[0]));
        table_full_o=free_entry<0;
        req_ready_o=rst_n && state_q==IDLE
            && (req_generation_i!=current_generation_o || invalid_request || match_entry>=0 || free_entry>=0);
        busy_o=state_q!=IDLE;
        resp_valid_o=rst_n && state_q==RESPONSE;
        epoch_advance_ready_o=rst_n && state_q==IDLE && !req_valid_i && epoch_low_q && epoch_quiescent_i
            && ((current_generation_o!={GENERATION_W{1'b1}}) || (all_low_q && all_generations_quiescent_i));
        read_req_valid_o=rst_n && state_q==READ_REQ;
        read_req_tag_o='0; read_req_line_addr_o=line_q;
        probe_req_valid_o=rst_n && state_q==TAKE_REQ;
        probe_req_take_o=1; probe_req_node_o=LOCAL_ATOMIC_NODE_ID;
        probe_req_txn_o=COHERENCE_TXN_W'(resp_request_id_o);
        probe_req_home_o=home_of(line_q); probe_req_line_addr_o=line_q;
        probe_exact=probe_resp_take_i && probe_resp_node_i==LOCAL_ATOMIC_NODE_ID
            && probe_resp_txn_i==COHERENCE_TXN_W'(resp_request_id_o)
            && probe_resp_home_i==home_of(line_q) && probe_resp_line_addr_i==line_q;
        probe_resp_ready_o=rst_n && state_q==TAKE_WAIT && probe_exact;
        reclaim_valid_o=rst_n && state_q==RETURN_LINE;
        reclaim_home_o=home_of(line_q); reclaim_node_o=LOCAL_ATOMIC_NODE_ID; reclaim_line_addr_o=line_q;
    end
    always_comb begin
        word_index=integer'(resp_word_addr_o % LINE_WORDS);
        observed_old='0;
        for(integer w=0;w<LINE_WORDS;w=w+1) begin
            if(w==word_index) observed_old[31:0]=probe_resp_data_i[w];
            if(resp_is64_o && w==word_index+1) observed_old[63:32]=probe_resp_data_i[w];
        end
        compare_success=(resp_is64_o ? observed_old==resp_compare_o : observed_old[31:0]==resp_compare_o[31:0]);
        result32=observed_old[31:0]; next_value=observed_old;
        case(resp_op_o)
            0: begin result32=resp_operand_o[31:0]; next_value=resp_operand_o; end
            1: if(compare_success) begin result32=resp_operand_o[31:0]; next_value=resp_operand_o; end
            2: begin result32=observed_old[31:0]+resp_operand_o[31:0]; next_value=observed_old+resp_operand_o; end
            3: begin result32=observed_old[31:0]-resp_operand_o[31:0]; next_value=observed_old-resp_operand_o; end
            4: begin
                if($signed(observed_old[31:0])>$signed(resp_operand_o[31:0])) result32=resp_operand_o[31:0];
                if($signed(observed_old)>$signed(resp_operand_o)) next_value=resp_operand_o;
            end
            5: begin
                if($signed(observed_old[31:0])<$signed(resp_operand_o[31:0])) result32=resp_operand_o[31:0];
                if($signed(observed_old)<$signed(resp_operand_o)) next_value=resp_operand_o;
            end
            6: begin
                if(observed_old[31:0]>resp_operand_o[31:0]) result32=resp_operand_o[31:0];
                if(observed_old>resp_operand_o) next_value=resp_operand_o;
            end
            7: begin
                if(observed_old[31:0]<resp_operand_o[31:0]) result32=resp_operand_o[31:0];
                if(observed_old<resp_operand_o) next_value=resp_operand_o;
            end
            8: begin result32=observed_old[31:0]&resp_operand_o[31:0]; next_value=observed_old&resp_operand_o; end
            9: begin result32=observed_old[31:0]|resp_operand_o[31:0]; next_value=observed_old|resp_operand_o; end
            10: begin result32=observed_old[31:0]^resp_operand_o[31:0]; next_value=observed_old^resp_operand_o; end
            default: begin end
        endcase
        if(!resp_is64_o) next_value={32'b0,result32};
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state_q<=IDLE; active_entry_q<=0; current_generation_o<='0;
            epoch_low_q<=0; all_low_q<=0; epoch_advance_pulse_o<=0; protocol_error_o<=0;
            line_q<='0; resp_source_o<='0; resp_context_o<='0; resp_request_id_o<='0;
            resp_generation_o<='0; resp_word_addr_o<='0; resp_is64_o<=0; resp_op_o<='0;
            resp_operand_o<='0; resp_compare_o<='0; resp_old_o<='0; resp_cas_success_o<=0;
            resp_fault_o<='0; resp_replay_o<=0; reclaim_generation_o<='0; reclaim_dirty_o<=0;
            for(integer w=0;w<LINE_WORDS;w=w+1) reclaim_data_o[w]<='0;
            for(integer e=0;e<ENTRY_COUNT;e=e+1) begin
                entry_valid_q[e]<=0; entry_committed_q[e]<=0; entry_source_q[e]<='0; entry_context_q[e]<='0;
                entry_id_q[e]<='0; entry_generation_q[e]<='0; entry_addr_q[e]<='0; entry_is64_q[e]<=0;
                entry_op_q[e]<='0; entry_operand_q[e]<='0; entry_compare_q[e]<='0; entry_old_q[e]<='0;
                entry_cas_q[e]<=0; entry_fault_q[e]<='0;
            end
        end else begin
            epoch_advance_pulse_o<=0;
            if(!epoch_quiescent_i) epoch_low_q<=1;
            if(!all_generations_quiescent_i) all_low_q<=1;
            if(epoch_advance_valid_i && epoch_advance_ready_o) begin
                current_generation_o<=current_generation_o+1'b1;
                epoch_low_q<=0; all_low_q<=0; epoch_advance_pulse_o<=1;
                for(integer e=0;e<ENTRY_COUNT;e=e+1) begin entry_valid_q[e]<=0; entry_committed_q[e]<=0; end
            end
            if(read_resp_valid_i && (state_q!=READ_WAIT || read_resp_tag_i!='0 || read_resp_line_addr_i!=line_q))
                protocol_error_o<=1;
            if(probe_resp_valid_i && (state_q!=TAKE_WAIT || !probe_exact)) protocol_error_o<=1;
            case(state_q)
                IDLE: if(req_valid_i && req_ready_o) begin
                    resp_source_o<=req_source_i; resp_context_o<=req_context_i; resp_request_id_o<=req_request_id_i;
                    resp_generation_o<=req_generation_i; resp_word_addr_o<=req_word_addr_i; resp_is64_o<=req_is64_i;
                    resp_op_o<=req_op_i; resp_operand_o<=req_operand_i; resp_compare_o<=req_compare_i;
                    resp_old_o<='0; resp_fault_o<='0; resp_cas_success_o<=0; resp_replay_o<=0;
                    line_q<=LINE_ADDR_W'(req_word_addr_i>>WSEL);
                    if(req_generation_i!=current_generation_o) begin resp_fault_o<=4'd2; state_q<=RESPONSE; end
                    else if(match_entry>=0) begin
                        state_q<=RESPONSE;
                        if(!fingerprint_match) resp_fault_o<=4'd3;
                        else if(entry_committed_q[match_entry]) begin
                            resp_old_o<=entry_old_q[match_entry]; resp_cas_success_o<=entry_cas_q[match_entry];
                            resp_fault_o<=entry_fault_q[match_entry]; resp_replay_o<=1;
                        end else begin resp_fault_o<=4'd5; protocol_error_o<=1; end
                    end else if(invalid_request) begin resp_fault_o<=4'd1; state_q<=RESPONSE; end
                    else begin
                        active_entry_q<=ENTRY_INDEX_W'(free_entry);
                        entry_valid_q[free_entry]<=1; entry_committed_q[free_entry]<=0;
                        entry_source_q[free_entry]<=req_source_i; entry_context_q[free_entry]<=req_context_i;
                        entry_id_q[free_entry]<=req_request_id_i; entry_generation_q[free_entry]<=req_generation_i;
                        entry_addr_q[free_entry]<=req_word_addr_i; entry_is64_q[free_entry]<=req_is64_i;
                        entry_op_q[free_entry]<=req_op_i; entry_operand_q[free_entry]<=req_operand_i;
                        entry_compare_q[free_entry]<=req_compare_i;
                        state_q<=READ_REQ;
                    end
                end
                READ_REQ: if(read_req_valid_o && read_req_ready_i) state_q<=READ_WAIT;
                READ_WAIT: if(read_resp_valid_i && read_resp_tag_i=='0 && read_resp_line_addr_i==line_q) begin
                    if(read_resp_fault_i) begin
                        resp_fault_o<=4'd4; entry_fault_q[active_entry_q]<=4'd4;
                        entry_old_q[active_entry_q]<='0; entry_cas_q[active_entry_q]<=0;
                        entry_committed_q[active_entry_q]<=1; state_q<=RESPONSE;
                    end else state_q<=TAKE_REQ;
                end
                TAKE_REQ: if(probe_req_valid_o && probe_req_ready_i) state_q<=TAKE_WAIT;
                TAKE_WAIT: if(probe_resp_valid_i && probe_resp_ready_o) begin
                    if(!probe_resp_hit_i) state_q<=READ_REQ;
                    else begin
                        resp_old_o<=observed_old;
                        resp_cas_success_o<=(resp_op_o==4'd1) && compare_success;
                        reclaim_generation_o<=probe_resp_generation_i;
                        reclaim_dirty_o<=probe_resp_dirty_i || (observed_old!=next_value);
                        for(integer w=0;w<LINE_WORDS;w=w+1) begin
                            reclaim_data_o[w]<=probe_resp_data_i[w];
                            if(w==word_index) reclaim_data_o[w]<=next_value[31:0];
                            if(resp_is64_o && w==word_index+1) reclaim_data_o[w]<=next_value[63:32];
                        end
                        state_q<=RETURN_LINE;
                    end
                end
                RETURN_LINE: if(reclaim_valid_o && reclaim_ready_i) begin
                    entry_old_q[active_entry_q]<=resp_old_o;
                    entry_cas_q[active_entry_q]<=resp_cas_success_o;
                    entry_fault_q[active_entry_q]<='0; entry_committed_q[active_entry_q]<=1;
                    state_q<=RESPONSE;
                end
                RESPONSE: if(resp_valid_o && resp_ready_i) state_q<=IDLE;
                default: begin state_q<=IDLE; protocol_error_o<=1; end
            endcase
        end
    end
endmodule
