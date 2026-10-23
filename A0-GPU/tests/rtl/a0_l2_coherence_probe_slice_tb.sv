`timescale 1ns/1ps

// P34 unit foundation only. One startup reset; all ownership and payload changes
// use public ports. Parameter matrix: (words,sets,gen)=(1,1,1),(4,4,2),(8,8,3).
// Expected scenario count: 23 for one set, 24 otherwise. The receiver acquires
// bytes only at a response handshake and returns its own modified full payload.
module a0_l2_coherence_probe_slice_tb #(
    parameter integer LINE_WORDS=4,
    parameter integer SET_COUNT=4,
    parameter integer GEN_W=2
);
    localparam integer STORE_LANES=4, GLOBAL_TAG_W=4;
    localparam integer COHERENCE_NODE_W=4, COHERENCE_TXN_W=4;
    localparam integer WORD_SELECT_W=(LINE_WORDS<=1)?0:$clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W=32-WORD_SELECT_W;
    localparam integer GENERATION_COUNT=(1<<GEN_W);
    localparam logic [LINE_ADDR_W-1:0] A=LINE_ADDR_W'(SET_COUNT);
    localparam logic [LINE_ADDR_W-1:0] B=LINE_ADDR_W'(2*SET_COUNT);
    localparam logic [LINE_ADDR_W-1:0] C=LINE_ADDR_W'(SET_COUNT+1);

    logic clk, rst_n;
    logic line_req_valid_i,line_req_ready_o;
    logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i;
    logic [LINE_ADDR_W-1:0] line_req_line_addr_i;
    logic line_mem_req_valid_o,line_mem_req_ready_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o;
    logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o;
    logic line_mem_resp_valid_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i;
    logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i;
    logic line_mem_resp_fault_i;
    logic [31:0] line_mem_resp_data_i[0:LINE_WORDS-1];
    logic line_resp_valid_o;
    logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o;
    logic [LINE_ADDR_W-1:0] line_resp_line_addr_o;
    logic line_resp_fault_o;
    logic [31:0] line_resp_data_o[0:LINE_WORDS-1];
    logic store_valid_i,store_ready_o;
    logic [STORE_LANES-1:0] store_lane_mask_i;
    logic [31:0] store_word_addr_i[0:STORE_LANES-1];
    logic [31:0] store_wdata_i[0:STORE_LANES-1];
    logic [STORE_LANES-1:0] store_hit_mask_o,store_miss_mask_o;
    logic wb_valid_o,wb_ready_i;
    logic [LINE_ADDR_W-1:0] wb_line_addr_o;
    logic [31:0] wb_data_o[0:LINE_WORDS-1];
    logic dirty_present_o,protocol_error_o;

    logic probe_req_valid_i,probe_req_ready_o,probe_req_take_i;
    logic [COHERENCE_NODE_W-1:0] probe_req_node_i;
    logic [COHERENCE_TXN_W-1:0] probe_req_txn_i;
    logic [LINE_ADDR_W-1:0] probe_req_line_addr_i;
    logic probe_resp_valid_o,probe_resp_ready_i,probe_resp_take_o;
    logic [COHERENCE_NODE_W-1:0] probe_resp_node_o;
    logic [COHERENCE_TXN_W-1:0] probe_resp_txn_o;
    logic [LINE_ADDR_W-1:0] probe_resp_line_addr_o;
    logic [GEN_W-1:0] probe_resp_generation_o;
    logic probe_resp_hit_o,probe_resp_dirty_o;
    logic [31:0] probe_resp_data_o[0:LINE_WORDS-1];
    logic reclaim_valid_i,reclaim_ready_o;
    logic [COHERENCE_NODE_W-1:0] reclaim_node_i;
    logic [GEN_W-1:0] reclaim_generation_i;
    logic [LINE_ADDR_W-1:0] reclaim_line_addr_i;
    logic reclaim_dirty_i;
    logic [31:0] reclaim_data_i[0:LINE_WORDS-1];
    logic probe_reuse_safe_i,probe_block_i;
    logic [SET_COUNT-1:0] coherence_block_set_o;
    logic remote_owned_present_o,probe_generation_exhausted_o;
    logic coherence_protocol_error_o;

    integer checks,scenarios,cycles;
    integer probe_accepts,probe_responses,transfers,reclaims;
    integer reclaim_rejects,read_accepts,read_responses;
    integer stores,memory_reads,wb_count,error_pulses;
    integer next_generation;
    logic [31:0] expected[0:LINE_WORDS-1],other_expected[0:LINE_WORDS-1];
    logic read_pending[0:15];
    logic [LINE_ADDR_W-1:0] read_expected_line[0:15];
    logic [31:0] read_expected_data[0:15][0:LINE_WORDS-1];
    bit pending_probe,receiver_owned,expect_error;
    logic [LINE_ADDR_W-1:0] pending_line,receiver_line;
    logic [COHERENCE_NODE_W-1:0] pending_node,receiver_node;
    logic [COHERENCE_TXN_W-1:0] pending_txn;
    logic [GEN_W-1:0] pending_generation,receiver_generation;
    bit pending_take,pending_hit,pending_dirty,receiver_dirty;
    logic [31:0] pending_data[0:LINE_WORDS-1],receiver_data[0:LINE_WORDS-1];
    bit planned_hit,planned_dirty;
    logic [31:0] planned_data[0:LINE_WORDS-1];
    logic [SET_COUNT-1:0] expected_blocks;
    integer mw;
    logic [GLOBAL_TAG_W-1:0] mt;

    a0_l2_coherence_probe_slice #(
        .STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),
        .SET_COUNT(SET_COUNT),.GLOBAL_TAG_W(GLOBAL_TAG_W),
        .COHERENCE_NODE_W(COHERENCE_NODE_W),.COHERENCE_TXN_W(COHERENCE_TXN_W),
        .COHERENCE_GEN_W(GEN_W)
    ) dut(.*);
    initial begin : clock_driver
        clk=0;
        forever #5 clk=~clk;
    end

    task automatic check(input bit condition,input string detail);
        begin
            if(!condition) $fatal(1,"P34_CHECK_FAILED cycle=%0d detail=%s",cycles,detail);
            checks=checks+1;
        end
    endtask
    task automatic mark(input string name);
        begin
            scenarios=scenarios+1;
            $display("P34_PROBE_SCENARIO_PASS id=%0d name=%s",scenarios,name);
        end
    endtask
    function automatic logic [31:0] word_addr(input logic [LINE_ADDR_W-1:0] line,input integer off);
        word_addr=(32'(line)<<WORD_SELECT_W)+32'(off);
    endfunction

    // All counters count actual sampling-edge events. In particular an offered
    // TAKE response has no effect on receiver_owned until ready AND valid.
    // This procedural reference model samples pre-NBA handshakes, immediately
    // updates its dependent bookkeeping, then observes registered DUT state.
    // It is not a bank of flops: delaying these model updates would change the
    // expected ownership/bitmap for the same edge. Stimulus is driven at negedge.
    initial begin : sampling_monitor
      forever begin
        @(posedge clk);
        cycles=cycles+1;
        if(cycles>12000) $fatal(1,"P34_WATCHDOG cycle=%0d",cycles);
        if(rst_n) begin
            check(!protocol_error_o,"unexpected read-response protocol error");
            if(line_req_valid_i && line_req_ready_o) begin
                mt=line_req_global_tag_i;
                check(!read_pending[mt],"reused outstanding local read tag");
                check(read_expected_line[mt]===line_req_line_addr_i,"local read acceptance identity");
                read_pending[mt]=1;
                read_accepts=read_accepts+1;
            end
            if(line_resp_valid_o) begin
                mt=line_resp_global_tag_o;
                check(read_pending[mt],"lost or duplicate local read response");
                check(line_resp_line_addr_o===read_expected_line[mt] && !line_resp_fault_o,"local response route/fault");
                for(mw=0;mw<LINE_WORDS;mw=mw+1)
                    check(line_resp_data_o[mw]===read_expected_data[mt][mw],"local response full payload");
                read_pending[mt]=0;
                read_responses=read_responses+1;
            end
            if(line_mem_req_valid_o && line_mem_req_ready_i) memory_reads=memory_reads+1;
            if(store_valid_i && store_ready_o) stores=stores+1;
            if(wb_valid_o && wb_ready_i) wb_count=wb_count+1;
            if(probe_req_valid_i && probe_req_ready_o) begin
                check(!pending_probe,"more than one pending probe");
                pending_probe=1;
                pending_line=probe_req_line_addr_i;
                pending_node=probe_req_node_i;
                pending_txn=probe_req_txn_i;
                pending_take=probe_req_take_i;
                pending_hit=planned_hit;
                pending_dirty=planned_dirty;
                pending_generation=(pending_take && pending_hit)?GEN_W'(next_generation):'0;
                for(mw=0;mw<LINE_WORDS;mw=mw+1) pending_data[mw]=planned_data[mw];
                if(pending_take && pending_hit) begin
                    check(next_generation<GENERATION_COUNT,"generation allocation wrapped");
                    next_generation=next_generation+1;
                end
                probe_accepts=probe_accepts+1;
            end
            if(probe_resp_valid_o) begin
                check(pending_probe,"untracked probe response");
                check(probe_resp_line_addr_o===pending_line && probe_resp_node_o===pending_node
                    && probe_resp_txn_o===pending_txn && probe_resp_take_o===pending_take,
                    "probe response full route identity / held stability");
                check(probe_resp_generation_o===pending_generation && probe_resp_hit_o===pending_hit
                    && probe_resp_dirty_o===pending_dirty,"probe response generation/hit/dirty");
                for(mw=0;mw<LINE_WORDS;mw=mw+1)
                    check(probe_resp_data_o[mw]===pending_data[mw],"probe response full bytes / held stability");
                if(probe_resp_ready_i) begin
                    if(pending_take && pending_hit) begin
                        check(!receiver_owned,"receiver already owns a transfer");
                        receiver_owned=1;
                        receiver_line=probe_resp_line_addr_o;
                        receiver_node=probe_resp_node_o;
                        receiver_generation=probe_resp_generation_o;
                        receiver_dirty=probe_resp_dirty_o;
                        for(mw=0;mw<LINE_WORDS;mw=mw+1) receiver_data[mw]=probe_resp_data_o[mw];
                        transfers=transfers+1;
                    end
                    pending_probe=0;
                    probe_responses=probe_responses+1;
                end
            end
            if(reclaim_valid_i) begin
                if(reclaim_ready_o) begin
                    check(receiver_owned,"reclaim accepted without receiver ownership");
                    check(reclaim_line_addr_i===receiver_line && reclaim_node_i===receiver_node
                        && reclaim_generation_i===receiver_generation,"accepted reclaim tuple");
                    check(reclaim_dirty_i===receiver_dirty,"accepted reclaim dirty metadata");
                    for(mw=0;mw<LINE_WORDS;mw=mw+1)
                        check(reclaim_data_i[mw]===receiver_data[mw],"accepted reclaim actual receiver bytes");
                    receiver_owned=0;
                    reclaims=reclaims+1;
                end else if(expect_error) reclaim_rejects=reclaim_rejects+1;
            end
            expected_blocks='0;
            if(pending_probe) expected_blocks[integer'(pending_line)%SET_COUNT]=1;
            if(receiver_owned) expected_blocks[integer'(receiver_line)%SET_COUNT]=1;
            #1;
            check(coherence_block_set_o===expected_blocks,"registered pending-or-remote block bitmap");
            check(remote_owned_present_o===receiver_owned,"remote ownership must follow accepting receiver");
            check(coherence_protocol_error_o===expect_error,"coherence protocol-error pulse");
            if(coherence_protocol_error_o) error_pulses=error_pulses+1;
        end
      end
    end

    task automatic seed_read(input logic [3:0] tag,input logic [LINE_ADDR_W-1:0] line);
        integer w;
        begin
            read_expected_line[integer'(tag)]=line;
            for(w=0;w<LINE_WORDS;w=w+1) read_expected_data[integer'(tag)][w]=expected[w];
        end
    endtask
    task automatic fill_expected(input logic [31:0] base);
        integer w;
        begin for(w=0;w<LINE_WORDS;w=w+1) expected[w]=base+32'(w); end
    endtask
    task automatic miss(input logic [3:0] tag,input logic [LINE_ADDR_W-1:0] line);
        begin
            @(negedge clk); seed_read(tag,line);
            line_req_valid_i=1;line_req_global_tag_i=tag;line_req_line_addr_i=line;#1;
            check(line_req_ready_o && line_mem_req_valid_o,"cold/clean miss acceptance");
            check(line_mem_req_line_addr_o===line && line_mem_req_global_tag_o===tag,"memory request route");
            @(posedge clk);@(negedge clk);line_req_valid_i=0;#1;
        end
    endtask
    task automatic refill(input logic [3:0] tag,input logic [LINE_ADDR_W-1:0] line,input bit probe_waits);
        integer w;
        begin
            @(negedge clk);
            line_mem_resp_valid_i=1;line_mem_resp_global_tag_i=tag;line_mem_resp_line_addr_i=line;
            for(w=0;w<LINE_WORDS;w=w+1) line_mem_resp_data_i[w]=expected[w];
            #1;
            check(line_resp_valid_o && line_resp_global_tag_o===tag && line_resp_line_addr_o===line,"combinational refill response before sampling edge");
            if(probe_waits) check(!probe_req_ready_o,"probe accepted optimistically on matching refill edge");
            @(posedge clk);@(negedge clk);line_mem_resp_valid_i=0;#1;
        end
    endtask
    task automatic hit(input logic [3:0] tag,input logic [LINE_ADDR_W-1:0] line);
        integer before_mem;
        begin
            before_mem=memory_reads;
            @(negedge clk);seed_read(tag,line);
            line_req_valid_i=1;line_req_global_tag_i=tag;line_req_line_addr_i=line;#1;
            check(line_req_ready_o && !line_mem_req_valid_o,"resident read must hit actual cache");
            @(posedge clk);@(negedge clk);line_req_valid_i=0;#1;
            check(line_resp_valid_o,"resident read response missing");
            @(posedge clk);@(negedge clk);#1;
            check(memory_reads==before_mem,"resident read emitted stale memory access");
        end
    endtask
    task automatic dirty_store(input logic [LINE_ADDR_W-1:0] line);
        logic [STORE_LANES-1:0] mask;
        begin
            @(negedge clk);
            store_valid_i=1;mask='0;mask[0]=1;
            store_word_addr_i[0]=word_addr(line,0);store_wdata_i[0]=32'hf135_79bd;
            expected[0]=32'hf135_79bd;
            if(LINE_WORDS>1) begin
                mask[1]=1;store_word_addr_i[1]=word_addr(line,LINE_WORDS-1);
                store_wdata_i[1]=32'h2468_ace0;expected[LINE_WORDS-1]=32'h2468_ace0;
            end
            store_lane_mask_i=mask;#1;
            check(store_ready_o && store_hit_mask_o===mask && store_miss_mask_o=='0,"real resident STORE lane hits");
            @(posedge clk);@(negedge clk);store_valid_i=0;store_lane_mask_i='0;#1;
            check(dirty_present_o,"real STORE did not make cache dirty");
        end
    endtask
    task automatic drive_probe(input logic [LINE_ADDR_W-1:0] line,input bit take,input bit hit_value,input bit dirty_value,input logic [3:0] txn);
        integer w;
        begin
            @(negedge clk);
            planned_hit=hit_value;planned_dirty=dirty_value;
            for(w=0;w<LINE_WORDS;w=w+1) planned_data[w]=hit_value?expected[w]:32'b0;
            probe_req_valid_i=1;probe_req_line_addr_i=line;probe_req_take_i=take;
            probe_req_node_i=4'h1;probe_req_txn_i=txn;#1;
        end
    endtask
    task automatic capture_probe;
        integer waited;
        begin
            waited=0;
            while(!probe_req_ready_o) begin
                @(negedge clk);#1;waited=waited+1;
                check(waited<40,"probe capture timed out");
            end
            @(posedge clk);@(negedge clk);probe_req_valid_i=0;#1;
            check(probe_resp_valid_o,"accepted probe has no held response");
        end
    endtask
    task automatic consume_probe;
        begin
            @(negedge clk);probe_resp_ready_i=1;#1;
            check(probe_resp_valid_o,"receiver ready without expected offered response");
            @(posedge clk);@(negedge clk);probe_resp_ready_i=0;#1;
            check(!probe_resp_valid_o,"consumed probe response did not drain");
        end
    endtask
    task automatic query(input logic [LINE_ADDR_W-1:0] line,input bit hit_value,input bit dirty_value,input logic [3:0] txn);
        begin drive_probe(line,0,hit_value,dirty_value,txn);capture_probe();consume_probe();end
    endtask
    task automatic take_a;
        begin drive_probe(A,1,1,1,4'ha);capture_probe();consume_probe();end
    endtask
    task automatic blocked_aliases(input integer repetitions);
        integer j;
        begin
            for(j=0;j<repetitions;j=j+1) begin
                @(negedge clk);line_req_valid_i=1;line_req_global_tag_i=4'hf;
                line_req_line_addr_i=(j%2==0)?A:B;
                store_valid_i=1;store_lane_mask_i=4'b0001;
                store_word_addr_i[0]=word_addr((j%2==0)?B:A,0);store_wdata_i[0]=32'hbad0_d00d;#1;
                check(!line_req_ready_o && !store_ready_o,"pending/remote set allowed READ or STORE alias");
                check(!line_mem_req_valid_o,"pending/remote set emitted stale memory request");
            end
            @(negedge clk);line_req_valid_i=0;store_valid_i=0;store_lane_mask_i='0;#1;
        end
    endtask
    task automatic bad_reclaim(input logic [LINE_ADDR_W-1:0] line,input logic [3:0] node,input logic [GEN_W-1:0] generation);
        integer w;
        begin
            @(negedge clk);expect_error=1;reclaim_valid_i=1;
            reclaim_line_addr_i=line;reclaim_node_i=node;reclaim_generation_i=generation;reclaim_dirty_i=0;
            for(w=0;w<LINE_WORDS;w=w+1) reclaim_data_i[w]=32'hbadf_0000+32'(w);
            #1;check(receiver_owned && !reclaim_ready_o,"wrong reclaim tuple accepted");
            @(posedge clk);@(negedge clk);reclaim_valid_i=0;expect_error=0;#1;
            check(receiver_owned && remote_owned_present_o,"rejected reclaim mutated ownership");
            @(posedge clk);@(negedge clk);#1;
            check(!coherence_protocol_error_o,"reclaim error failed to pulse");
        end
    endtask
    task automatic return_receiver(input logic [31:0] salt,input bit test_local_collision);
        integer w;
        begin
            @(negedge clk);
            check(receiver_owned,"cannot manufacture reclaim without accepting receiver");
            receiver_dirty=1;
            for(w=0;w<LINE_WORDS;w=w+1) begin
                receiver_data[w]=receiver_data[w]^salt^(32'(w)<<8);
                expected[w]=receiver_data[w];reclaim_data_i[w]=receiver_data[w];
            end
            reclaim_line_addr_i=receiver_line;reclaim_node_i=receiver_node;
            reclaim_generation_i=receiver_generation;reclaim_dirty_i=receiver_dirty;reclaim_valid_i=1;
            if(test_local_collision) begin
                line_req_valid_i=1;line_req_line_addr_i=A;line_req_global_tag_i=4'hf;
                store_valid_i=1;store_lane_mask_i=4'b0001;store_word_addr_i[0]=word_addr(B,0);
            end
            #1;check(reclaim_ready_o,"exact reclaim tuple was not accepted");
            if(test_local_collision) check(!line_req_ready_o && !store_ready_o && !line_mem_req_valid_o,
                "local request accepted optimistically on reclaim edge");
            @(posedge clk);@(negedge clk);
            reclaim_valid_i=0;line_req_valid_i=0;store_valid_i=0;store_lane_mask_i='0;#1;
            check(!receiver_owned && !remote_owned_present_o && coherence_block_set_o=='0,"reclaim did not release registered hold");
            check(dirty_present_o,"reclaim payload dirty metadata not installed");
        end
    endtask

    // Exercise the public local ports on the exact edge that used to allow an
    // alias READ to snapshot/invalidate a resident line while accepting its STORE.
    task automatic alias_store_read(
        input logic [LINE_ADDR_W-1:0] resident_line,
        input logic [LINE_ADDR_W-1:0] replacement_line,
        input logic [3:0] tag,
        input logic [31:0] new_word,
        input logic [31:0] refill_base
    );
        integer w;
        logic [31:0] victim[0:LINE_WORDS-1];
        begin
            for(w=0;w<LINE_WORDS;w=w+1) victim[w]=expected[w];
            victim[0]=new_word;
            @(negedge clk);
            fill_expected(refill_base);seed_read(tag,replacement_line);
            line_req_valid_i=1;line_req_line_addr_i=replacement_line;line_req_global_tag_i=tag;
            store_valid_i=1;store_lane_mask_i=4'b0001;
            store_word_addr_i[0]=word_addr(resident_line,0);store_wdata_i[0]=new_word;
            #1;
            check(store_ready_o && store_hit_mask_o===4'b0001 && store_miss_mask_o=='0,
                "same-set race must accept the resident STORE");
            check(!line_req_ready_o && !line_mem_req_valid_o && !wb_valid_o,
                "same-set race must defer alias READ before victim capture");
            @(posedge clk);@(negedge clk);store_valid_i=0;store_lane_mask_i='0;#1;
            check(line_req_ready_o && !line_mem_req_valid_o && dirty_present_o,
                "deferred READ must see updated dirty resident after STORE withdrawal");
            @(posedge clk);@(negedge clk);line_req_valid_i=0;#1;
            repeat(2) begin
                check(wb_valid_o && wb_line_addr_o===resident_line,
                    "deferred alias READ must write back the correct resident");
                for(w=0;w<LINE_WORDS;w=w+1)
                    check(wb_data_o[w]===victim[w],"alias race WB must include every accepted STORE byte");
                @(negedge clk);#1;
            end
            wb_ready_i=1;#1;
            @(posedge clk);@(negedge clk);wb_ready_i=0;#1;
            check(line_mem_req_valid_o && line_mem_req_line_addr_o===replacement_line
                && line_mem_req_global_tag_o===tag,"alias race replacement READ identity");
            @(posedge clk);@(negedge clk);#1;
            refill(tag,replacement_line,0);
            hit(tag,replacement_line);
        end
    endtask

    initial begin : stimulus
        integer w,t,j,before_count;
        logic [GEN_W-1:0] old_generation;
        logic [31:0] saved_a[0:LINE_WORDS-1];
        checks=0;scenarios=0;cycles=0;
        probe_accepts=0;probe_responses=0;transfers=0;reclaims=0;
        reclaim_rejects=0;read_accepts=0;read_responses=0;
        stores=0;memory_reads=0;wb_count=0;error_pulses=0;
        next_generation=0;pending_probe=0;receiver_owned=0;expect_error=0;
        rst_n=0;line_req_valid_i=0;line_req_global_tag_i=0;line_req_line_addr_i=0;
        line_mem_req_ready_i=1;line_mem_resp_valid_i=0;line_mem_resp_global_tag_i=0;
        line_mem_resp_line_addr_i=0;line_mem_resp_fault_i=0;
        store_valid_i=0;store_lane_mask_i=0;wb_ready_i=0;
        probe_req_valid_i=0;probe_req_take_i=0;probe_req_node_i=1;probe_req_txn_i=0;probe_req_line_addr_i=0;
        probe_resp_ready_i=0;reclaim_valid_i=0;reclaim_node_i=0;reclaim_generation_i=0;
        reclaim_line_addr_i=0;reclaim_dirty_i=0;probe_reuse_safe_i=1;probe_block_i=0;
        for(w=0;w<LINE_WORDS;w=w+1) begin
            line_mem_resp_data_i[w]=0;reclaim_data_i[w]=0;expected[w]=0;other_expected[w]=0;
        end
        for(w=0;w<STORE_LANES;w=w+1) begin store_word_addr_i[w]=0;store_wdata_i[w]=0;end
        for(t=0;t<16;t=t+1) begin
            read_pending[t]=0;read_expected_line[t]=0;
            for(w=0;w<LINE_WORDS;w=w+1) read_expected_data[t][w]=0;
        end
        repeat(3) @(posedge clk);
        @(negedge clk);rst_n=1;#1;
        check(!dirty_present_o && !remote_owned_present_o && !probe_generation_exhausted_o
            && coherence_block_set_o=='0,"startup must be empty");
        mark("RESET_EMPTY");

        query(A,0,0,4'h3);
        check(next_generation==0 && !receiver_owned,"cold QUERY allocated ownership");
        mark("COLD_QUERY_MISS");
        drive_probe(B,1,0,0,4'he);capture_probe();consume_probe();
        check(next_generation==0 && !receiver_owned && !probe_generation_exhausted_o,"TAKE miss consumed generation/ownership");
        mark("TAKE_MISS_NO_ALLOCATION");

        @(negedge clk);probe_req_valid_i=1;probe_req_take_i=1;probe_req_node_i=0;
        probe_req_line_addr_i=A;expect_error=1;#1;
        check(!probe_req_ready_o,"local node accepted as remote transfer target");
        @(posedge clk);@(negedge clk);probe_req_valid_i=0;probe_req_node_i=1;expect_error=0;
        @(posedge clk);@(negedge clk);#1;
        check(!coherence_protocol_error_o && next_generation==0,"local-node rejection mutated allocator/error sticky");
        mark("LOCAL_NODE_REJECTED");

        fill_expected(32'h1020_3040);miss(4'h1,A);
        drive_probe(A,0,1,0,4'h5);
        check(!probe_req_ready_o && coherence_block_set_o=='0,"active READ must drain before probe capture");
        refill(4'h1,A,1);capture_probe();consume_probe();
        check(!dirty_present_o && !receiver_owned,"clean refill QUERY changed ownership/dirty");
        mark("REFILL_DRAINS_BEFORE_QUERY");

        @(negedge clk);seed_read(4'h2,A);line_req_valid_i=1;line_req_global_tag_i=2;line_req_line_addr_i=A;#1;
        check(line_req_ready_o && !line_mem_req_valid_o,"hit-buffer setup READ");
        @(posedge clk);@(negedge clk);line_req_valid_i=0;
        planned_hit=1;planned_dirty=0;
        for(w=0;w<LINE_WORDS;w=w+1) planned_data[w]=expected[w];
        probe_req_valid_i=1;probe_req_take_i=0;probe_req_node_i=1;probe_req_txn_i=6;probe_req_line_addr_i=A;#1;
        check(line_resp_valid_o && !probe_req_ready_o,"probe must wait through old hit-buffer response edge");
        capture_probe();consume_probe();mark("HIT_BUFFER_DRAINS");

        dirty_store(A);drive_probe(A,0,1,1,4'h7);capture_probe();
        repeat(3) begin @(negedge clk);#1;check(probe_resp_valid_o && dirty_present_o && !receiver_owned,"held dirty QUERY snapshot");end
        consume_probe();hit(4'h3,A);
        mark("RESIDENT_STORE_DIRTY_QUERY");

        drive_probe(A,0,1,1,4'h8);
        line_req_valid_i=1;line_req_global_tag_i=4'hf;line_req_line_addr_i=B;
        store_valid_i=1;store_lane_mask_i=1;store_word_addr_i[0]=word_addr(A,0);store_wdata_i[0]=32'hbad0_0001;#1;
        check(probe_req_ready_o && !line_req_ready_o && !store_ready_o && !line_mem_req_valid_o,"raw probe reservation must win new READ/STORE");
        check(coherence_block_set_o=='0,"raw reservation must not masquerade as registered pending");
        capture_probe();line_req_valid_i=0;store_valid_i=0;store_lane_mask_i=0;
        consume_probe();mark("RAW_PROBE_PRIORITY");

        @(negedge clk);probe_block_i=1;
        drive_probe(A,0,1,1,4'h9);
        line_req_valid_i=1;line_req_global_tag_i=4'hf;line_req_line_addr_i=B;
        store_valid_i=1;store_lane_mask_i=1;store_word_addr_i[0]=word_addr(A,0);#1;
        repeat(3) begin
            check(!probe_req_ready_o && !line_req_ready_o && !store_ready_o && !line_mem_req_valid_o
                && coherence_block_set_o=='0,"external quarantine must stop capture but retain raw reservation");
            @(negedge clk);#1;
        end
        probe_block_i=0;#1;capture_probe();line_req_valid_i=0;store_valid_i=0;store_lane_mask_i=0;
        consume_probe();mark("EXTERNAL_QUARANTINE");

        drive_probe(A,1,1,1,4'hb);capture_probe();
        check(!receiver_owned && dirty_present_o,"TAKE offer prematurely moved dirty ownership");
        blocked_aliases(3);
        check(!receiver_owned && dirty_present_o && probe_resp_valid_o,"held TAKE invalidated source before receiver handshake");
        consume_probe();old_generation=receiver_generation;
        check(receiver_owned && !dirty_present_o && remote_owned_present_o,"receiver acceptance must remove local dirty residency");
        mark("DIRTY_TAKE_STABLE_UNTIL_RECEIVER");
        before_count=memory_reads;blocked_aliases(4);
        check(memory_reads==before_count && receiver_owned,"remote hold allowed alias memory read");
        mark("REMOTE_HOLD_BLOCKS_ALIASES");

        if(SET_COUNT>1) begin
            for(w=0;w<LINE_WORDS;w=w+1) saved_a[w]=expected[w];
            fill_expected(32'hc001_2000);miss(4'h4,C);refill(4'h4,C,0);dirty_store(C);hit(4'h5,C);
            for(w=0;w<LINE_WORDS;w=w+1) begin other_expected[w]=expected[w];expected[w]=saved_a[w];end
            check(receiver_owned && coherence_block_set_o[integer'(A)%SET_COUNT],"disjoint traffic disturbed remote hold");
            mark("DISJOINT_PROGRESS");
        end

        bad_reclaim(B,receiver_node,receiver_generation);
        bad_reclaim(A,4'h2,receiver_generation);
        bad_reclaim(A,receiver_node,receiver_generation^GEN_W'(1));
        check(reclaim_rejects==3 && reclaims==0,"bad reclaim accounting");
        mark("RECLAIM_TUPLE_REJECTIONS");
        return_receiver(32'h9696_5a5a,1);hit(4'h6,A);
        mark("RECLAIM_REAL_CACHE_INSTALL");

        take_a();check(receiver_generation!==old_generation,"fresh transfer reused old generation");
        bad_reclaim(A,receiver_node,old_generation);
        return_receiver(32'h0102_0304,0);
        check(reclaim_rejects==4,"stale replay must be a rejected reclaim event");
        mark("STALE_GENERATION_REPLAY");
        while(next_generation<GENERATION_COUNT) begin take_a();return_receiver(32'h0001_1001,0);end
        repeat(3) begin @(negedge clk);#1;check(probe_generation_exhausted_o,"already-high certificate silently rearmed exhausted namespace");end
        query(A,1,1,4'hc);
        drive_probe(A,1,1,1,4'hd);
        repeat(3) begin
            check(!probe_req_ready_o && probe_generation_exhausted_o,"exhausted TAKE was accepted");
            @(negedge clk);#1;
        end
        probe_req_valid_i=0;#1;
        check(next_generation==GENERATION_COUNT && !receiver_owned,"exhaustion changed ownership/allocation");
        mark("EXHAUSTION_BLOCKS_TAKE_QUERY_ALLOWED");

        @(negedge clk);probe_reuse_safe_i=0;
        @(posedge clk);@(negedge clk);seed_read(4'h7,A);
        line_req_valid_i=1;line_req_line_addr_i=A;line_req_global_tag_i=7;#1;
        check(line_req_ready_o && !line_mem_req_valid_o,"namespace rearm cache-preservation READ setup");
        @(posedge clk);@(negedge clk);line_req_valid_i=0;probe_reuse_safe_i=1;#1;
        check(line_resp_valid_o && probe_generation_exhausted_o,"rearm requires old buffered READ to drain");
        @(posedge clk);@(negedge clk);#1;
        check(probe_generation_exhausted_o,"namespace rearmed optimistically on old hit-buffer drain edge");
        @(posedge clk);@(negedge clk);#1;
        check(!probe_generation_exhausted_o && dirty_present_o,"idle LOW/HIGH certificate failed or reset cache");
        next_generation=0;hit(4'h8,A);
        if(SET_COUNT>1) begin
            for(w=0;w<LINE_WORDS;w=w+1) begin saved_a[w]=expected[w];expected[w]=other_expected[w];end
            hit(4'h9,C);
            for(w=0;w<LINE_WORDS;w=w+1) expected[w]=saved_a[w];
        end
        mark("LOW_HIGH_IDLE_REARM_PRESERVES_CACHE");

        for(j=0;j<GENERATION_COUNT;j=j+1) begin
            take_a();
            if(j<GENERATION_COUNT-1) return_receiver(32'h0033_00cc,0);
        end
        check(probe_generation_exhausted_o && receiver_owned,"second epoch failed to exhaust into real remote ownership");
        @(negedge clk);probe_reuse_safe_i=0;
        @(posedge clk);@(negedge clk);probe_reuse_safe_i=1;
        repeat(3) begin @(negedge clk);#1;check(probe_generation_exhausted_o && receiver_owned,"LOW/HIGH certificate bypassed remote hold");end
        return_receiver(32'h88aa_55ff,1);
        check(probe_generation_exhausted_o,"rearm occurred optimistically on reclaim edge");
        @(posedge clk);@(negedge clk);#1;
        check(!probe_generation_exhausted_o,"namespace did not rearm after final remote hold and idle edge");
        next_generation=0;hit(4'ha,A);mark("REMOTE_HOLD_PREVENTS_REARM");
        take_a();check(receiver_generation=='0,"certified namespace did not restart at generation zero");
        return_receiver(32'h5c5c_a3a3,0);mark("CERTIFIED_GENERATION_ZERO_REUSE");

        // An old dirty eviction owns its set until successful WB and replacement
        // refill. A waiting probe cannot steal the victim or starve that READ.
        for(w=0;w<LINE_WORDS;w=w+1) saved_a[w]=expected[w];
        fill_expected(32'hb005_6000);
        @(negedge clk);seed_read(4'hb,B);line_mem_req_ready_i=0;wb_ready_i=0;
        line_req_valid_i=1;line_req_line_addr_i=B;line_req_global_tag_i=4'hb;#1;
        check(line_req_ready_o && !line_mem_req_valid_o,"dirty replacement request must retain victim");
        @(posedge clk);@(negedge clk);line_req_valid_i=0;#1;
        drive_probe(B,0,1,0,4'hf);
        repeat(3) begin
            check(wb_valid_o && wb_line_addr_o===A && !probe_req_ready_o && !line_mem_req_valid_o,"probe stole or bypassed pending dirty victim");
            for(w=0;w<LINE_WORDS;w=w+1) check(wb_data_o[w]===saved_a[w],"held WB full payload changed");
            check(dirty_present_o,"victim became clean before WB success handshake");
            @(negedge clk);#1;
        end
        store_valid_i=1;store_lane_mask_i=1;store_word_addr_i[0]=word_addr(A,0);store_wdata_i[0]=32'hbadb_adbb;#1;
        check(!store_ready_o,"victim STORE accepted during held writeback");
        @(negedge clk);store_valid_i=0;store_lane_mask_i=0;wb_ready_i=1;#1;
        check(!probe_req_ready_o && wb_valid_o,"probe accepted on WB success edge");
        @(posedge clk);@(negedge clk);wb_ready_i=0;#1;
        check(wb_count==1 && !wb_valid_o && !probe_req_ready_o,"WB handoff failed or probe stole replacement window");
        check(line_mem_req_valid_o && line_mem_req_line_addr_o===B && line_mem_req_global_tag_o===4'hb,"old replacement READ blocked by waiting raw probe");
        repeat(2) begin @(negedge clk);#1;check(!probe_req_ready_o && line_mem_req_valid_o,"probe bypassed retained READ backpressure");end
        mark("EVICTION_WB_STABLE_PROBE_WAITS");
        line_mem_req_ready_i=1;#1;
        @(posedge clk);@(negedge clk);#1;
        check(!probe_req_ready_o,"probe accepted before replacement refill");
        refill(4'hb,B,1);capture_probe();consume_probe();hit(4'hc,B);
        mark("REPLACEMENT_REFILL_THEN_PROBE");

        // B is clean from the checked replacement refill. Accept its STORE
        // while simultaneously offering alias A; the READ must wait one edge.
        alias_store_read(B,A,4'hd,32'hc1ea_0001,32'ha0a0_1000);
        mark("CLEAN_ALIAS_STORE_PRIORITY");
        // A is then dirtied through its STORE port before another same-set race.
        dirty_store(A);
        alias_store_read(A,B,4'he,32'hd17a_0002,32'hb0b0_2000);
        mark("DIRTY_ALIAS_STORE_PRIORITY");

        repeat(3) @(negedge clk);
        check(!pending_probe && !receiver_owned && !probe_resp_valid_o && coherence_block_set_o=='0,"final undrained coherence transaction");
        for(t=0;t<16;t=t+1) check(!read_pending[t],"final undrained local read");
        check(read_accepts==read_responses,"local read acceptance/response conservation");
        check(probe_accepts==probe_responses && probe_accepts==2*GENERATION_COUNT+10,"probe acceptance/response cardinality");
        check(transfers==2*GENERATION_COUNT+1 && reclaims==transfers,"real transfer/reclaim cardinality");
        check(reclaim_rejects==4 && error_pulses==5 && wb_count==3,"rejection/error/WB cardinality");
        check(read_accepts==((SET_COUNT>1)?16:13),"exact local READ event cardinality");
        check(stores==((SET_COUNT>1)?5:4) && memory_reads==((SET_COUNT>1)?5:4),"STORE/backend READ event cardinality");
        mark("HANDSHAKE_ACCOUNTING");
        check(scenarios==((SET_COUNT>1)?24:23),"scenario marker cardinality");
        $display("P34_PROBE_DEVELOPMENT_PASS={\"line_words\":%0d,\"sets\":%0d,\"gen_w\":%0d,\"scenarios\":%0d,\"checks\":%0d,\"probe_accepts\":%0d,\"probe_responses\":%0d,\"transfers\":%0d,\"reclaims\":%0d,\"reclaim_rejects\":%0d,\"read_accepts\":%0d,\"read_responses\":%0d,\"stores\":%0d,\"memory_reads\":%0d,\"wb\":%0d}",
            LINE_WORDS,SET_COUNT,GEN_W,scenarios,checks,probe_accepts,probe_responses,transfers,reclaims,reclaim_rejects,read_accepts,read_responses,stores,memory_reads,wb_count);
        $finish;
    end
endmodule
