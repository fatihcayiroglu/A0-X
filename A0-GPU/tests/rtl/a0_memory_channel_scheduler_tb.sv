`timescale 1ns/1ps
// P37 component proof. The ledger is built only from public handshakes; it
// deliberately does not inspect DUT slot state, queue pointers or arbitration.
module a0_memory_channel_scheduler_tb #(parameter integer VARIANT=0);
    localparam integer C=(VARIANT==0)?1:((VARIANT==1)?2:4);
    localparam integer D=(VARIANT==0)?1:((VARIANT==1)?2:3);
    localparam integer LW=(VARIANT==0)?1:((VARIANT==1)?2:4);
    localparam integer WS=(LW<=1)?0:$clog2(LW);
    localparam integer AW=32-WS, IW=16, GW=2;
    localparam integer SW=(D<=1)?1:$clog2(D), TOKW=SW+GW;
    localparam integer MAX_REQ=256, MEM_WORDS=4096;
    localparam logic [1:0] READ=2'b00, WB=2'b01, STORE=2'b10;
    logic clk, rst_n;
    initial begin
        clk=0;
        forever #5 clk=~clk;
    end

    logic cmd_valid_i,cmd_ready_o;
    logic [1:0] cmd_kind_i;
    logic [IW-1:0] cmd_read_tag_i,cmd_wb_attempt_id_i,cmd_store_attempt_id_i;
    logic [AW-1:0] cmd_line_addr_i;
    logic [31:0] cmd_data_i[0:LW-1];
    logic [31:0] cmd_store_word_addr_i,cmd_store_wdata_i;
    logic [C-1:0] channel_cmd_valid_o,channel_cmd_ready_i;
    logic [1:0] channel_cmd_kind_o[0:C-1];
    logic [TOKW-1:0] channel_cmd_token_o[0:C-1];
    logic [IW-1:0] channel_cmd_read_tag_o[0:C-1];
    logic [IW-1:0] channel_cmd_wb_attempt_id_o[0:C-1];
    logic [IW-1:0] channel_cmd_store_attempt_id_o[0:C-1];
    logic [AW-1:0] channel_cmd_line_addr_o[0:C-1];
    logic [31:0] channel_cmd_data_o[0:C-1][0:LW-1];
    logic [31:0] channel_cmd_store_word_addr_o[0:C-1];
    logic [31:0] channel_cmd_store_wdata_o[0:C-1];
    logic [C-1:0] channel_resp_valid_i,channel_resp_ready_o;
    logic [1:0] channel_resp_kind_i[0:C-1];
    logic [TOKW-1:0] channel_resp_token_i[0:C-1];
    logic [IW-1:0] channel_resp_read_tag_i[0:C-1];
    logic [IW-1:0] channel_resp_wb_attempt_id_i[0:C-1];
    logic [IW-1:0] channel_resp_store_attempt_id_i[0:C-1];
    logic [AW-1:0] channel_resp_line_addr_i[0:C-1];
    logic [31:0] channel_resp_store_word_addr_i[0:C-1];
    logic [31:0] channel_resp_data_i[0:C-1][0:LW-1];
    logic [C-1:0] channel_resp_success_i,channel_resp_retryable_i;
    logic read_resp_valid_o,read_resp_fault_o;
    logic [IW-1:0] read_resp_tag_o;
    logic [AW-1:0] read_resp_line_addr_o;
    logic [31:0] read_resp_data_o[0:LW-1];
    logic wb_status_valid_o,wb_status_success_o,wb_status_retryable_o;
    logic [IW-1:0] wb_status_attempt_id_o;
    logic store_status_valid_o,store_status_success_o;
    logic store_status_retryable_o;
    logic [IW-1:0] store_status_attempt_id_o;
    logic all_generations_quiescent_i,busy_o,quiescent_o;
    logic [C-1:0] generation_exhausted_o,response_rejected_o;
    logic [C-1:0] generation_rearm_pulse_o,channel_busy_o;
    logic protocol_error_o,read_busy_o,wb_busy_o,store_busy_o;

    a0_memory_channel_scheduler #(
        .CHANNEL_COUNT(C),.DEPTH_PER_CHANNEL(D),.LINE_WORDS(LW),
        .LINE_ADDR_W(AW),.READ_TAG_W(IW),.WB_ATTEMPT_ID_W(IW),
        .STORE_ATTEMPT_ID_W(IW),.TOKEN_GENERATION_W(GW)
    ) dut (.*);

    // States: accepted/queued=0, dispatched=1, return buffered=2, delivered=3.
    integer req_count,cycle_no,dispatched,returned,delivered;
    integer total_accepted,total_dispatched,total_returned,total_delivered;
    integer reject_count,stable_checks,full_checks,fair_checks;
    integer max_return_batch,max_dispatch_batch,mapping_checks;
    integer zero_latency_checks,rearm_denied_checks,early_return_checks;
    integer queue_hole_checks;
    integer r_state[0:MAX_REQ-1],r_channel[0:MAX_REQ-1];
    integer r_response_cycle[0:MAX_REQ-1];
    logic [1:0] r_kind[0:MAX_REQ-1];
    logic [IW-1:0] r_read[0:MAX_REQ-1],r_wb[0:MAX_REQ-1],r_store[0:MAX_REQ-1];
    logic [AW-1:0] r_line[0:MAX_REQ-1];
    logic [31:0] r_word[0:MAX_REQ-1],r_wdata[0:MAX_REQ-1];
    logic [31:0] r_data[0:MAX_REQ-1][0:LW-1];
    logic [31:0] r_expected_read[0:MAX_REQ-1][0:LW-1];
    logic [31:0] r_actual_read[0:MAX_REQ-1][0:LW-1];
    logic [TOKW-1:0] r_token[0:MAX_REQ-1];
    logic r_fault[0:MAX_REQ-1],r_success[0:MAX_REQ-1];
    logic r_retryable[0:MAX_REQ-1];
    logic [31:0] reference_memory[0:MEM_WORDS-1];
    logic [31:0] physical_memory[0:MEM_WORDS-1];
    logic token_seen[0:C-1][0:(1<<TOKW)-1];

    // A held offer is compared again on every edge, including its fire edge.
    logic held[0:C-1];
    logic [1:0] held_kind[0:C-1];
    logic [TOKW-1:0] held_token[0:C-1];
    logic [IW-1:0] held_read[0:C-1],held_wb[0:C-1],held_store[0:C-1];
    logic [AW-1:0] held_line[0:C-1];
    logic [31:0] held_word[0:C-1],held_wdata[0:C-1];
    logic [31:0] held_data[0:C-1][0:LW-1];
    integer expected_reject_mask;
    integer count_by_channel[0:C-1];

    function automatic logic[AW-1:0] canonical_line(input logic[1:0] kind,
        input logic[AW-1:0] line_addr,input logic[31:0] word_addr);
        canonical_line=(kind==STORE)?AW'(word_addr/LW):line_addr;
    endfunction

    function automatic integer find_issued(input integer ch);
        integer n;
        begin
            find_issued=-1;
            for(n=0;n<req_count;n=n+1)
                if(r_state[n]==1 && r_channel[n]==ch && find_issued<0) find_issued=n;
        end
    endfunction

    task automatic check_delivered(input integer n);
        integer w;
        begin
            if(n<0 || r_state[n]!=2) $fatal(1,"P37 unowned or duplicate upstream response");
            // A capture on edge N is serviceable starting on edge N+1.
            // The public contract allows at most one visit of all C*D slots.
            if(cycle_no-r_response_cycle[n]>C*D)
                $fatal(1,"P37 bounded return fairness violated req=%0d age=%0d",n,cycle_no-r_response_cycle[n]);
            fair_checks=fair_checks+1;
            if(r_kind[n]==READ) begin
                if(read_resp_line_addr_o!==r_line[n] || read_resp_fault_o!==r_fault[n])
                    $fatal(1,"P37 READ line/fault identity changed");
                for(w=0;w<LW;w=w+1)
                    if(read_resp_data_o[w]!==r_expected_read[n][w])
                        $fatal(1,"P37 READ data mismatch req=%0d word=%0d",n,w);
            end else if(r_kind[n]==WB) begin
                if(wb_status_success_o!==r_success[n] || wb_status_retryable_o!==r_retryable[n])
                    $fatal(1,"P37 WB result flags changed");
            end else begin
                if(store_status_success_o!==r_success[n] || store_status_retryable_o!==r_retryable[n])
                    $fatal(1,"P37 STORE result flags changed");
            end
            r_state[n]=3;delivered=delivered+1;total_delivered=total_delivered+1;
        end
    endtask

    // Public timing: deliver old buffered responses, accept ingress, dispatch,
    // then capture returns (including a return on the dispatch edge itself).
    task automatic sample_scoreboard;
        integer ch,n,w,found,head,ln,addr,expected_addr,batch_d,batch_r,outstanding;
        logic expected_busy,expected_read_busy,expected_wb_busy,expected_store_busy;
        logic [C-1:0] expected_channel_busy;
        begin
        if(!rst_n) begin
            req_count=0;cycle_no=0;dispatched=0;returned=0;delivered=0;
            expected_reject_mask=0;
            for(ch=0;ch<C;ch=ch+1) begin
                held[ch]=0;count_by_channel[ch]=0;
                for(n=0;n<(1<<TOKW);n=n+1) token_seen[ch][n]=0;
            end
        end else begin
            cycle_no=cycle_no+1;batch_d=0;batch_r=0;expected_reject_mask=0;
            if(integer'(read_resp_valid_o)+integer'(wb_status_valid_o)+integer'(store_status_valid_o)>1)
                $fatal(1,"P37 more than one upstream response in a cycle");
            if(read_resp_valid_o) begin
                found=-1;
                for(n=0;n<req_count;n=n+1) if(r_state[n]==2 && r_kind[n]==READ && r_read[n]==read_resp_tag_o) found=n;
                check_delivered(found);
            end
            if(wb_status_valid_o) begin
                found=-1;
                for(n=0;n<req_count;n=n+1) if(r_state[n]==2 && r_kind[n]==WB && r_wb[n]==wb_status_attempt_id_o) found=n;
                check_delivered(found);
            end
            if(store_status_valid_o) begin
                found=-1;
                for(n=0;n<req_count;n=n+1) if(r_state[n]==2 && r_kind[n]==STORE && r_store[n]==store_status_attempt_id_o) found=n;
                check_delivered(found);
            end
            if(cmd_valid_i && cmd_ready_o) begin
                if(req_count>=MAX_REQ) $fatal(1,"P37 test ledger capacity exceeded");
                n=req_count;r_state[n]=0;r_kind[n]=cmd_kind_i;
                r_read[n]=cmd_read_tag_i;r_wb[n]=cmd_wb_attempt_id_i;r_store[n]=cmd_store_attempt_id_i;
                r_line[n]=canonical_line(cmd_kind_i,cmd_line_addr_i,cmd_store_word_addr_i);r_word[n]=cmd_store_word_addr_i;r_wdata[n]=cmd_store_wdata_i;
                r_channel[n]=32'(canonical_line(cmd_kind_i,cmd_line_addr_i,cmd_store_word_addr_i))%C;
                for(w=0;w<LW;w=w+1) r_data[n][w]=cmd_data_i[w];
                req_count=req_count+1;total_accepted=total_accepted+1;
            end
            for(ch=0;ch<C;ch=ch+1) begin
                if(held[ch]) begin
                    if(!channel_cmd_valid_o[ch] || channel_cmd_kind_o[ch]!==held_kind[ch]
                        || channel_cmd_token_o[ch]!==held_token[ch] || channel_cmd_read_tag_o[ch]!==held_read[ch]
                        || channel_cmd_wb_attempt_id_o[ch]!==held_wb[ch] || channel_cmd_store_attempt_id_o[ch]!==held_store[ch]
                        || channel_cmd_line_addr_o[ch]!==held_line[ch] || channel_cmd_store_word_addr_o[ch]!==held_word[ch]
                        || channel_cmd_store_wdata_o[ch]!==held_wdata[ch]) $fatal(1,"P37 stalled command identity changed");
                    for(w=0;w<LW;w=w+1) if(channel_cmd_data_o[ch][w]!==held_data[ch][w]) $fatal(1,"P37 stalled command byte changed");
                    stable_checks=stable_checks+1;
                end
                held[ch]=channel_cmd_valid_o[ch]&&!channel_cmd_ready_i[ch];
                if(held[ch]) begin
                    held_kind[ch]=channel_cmd_kind_o[ch];held_token[ch]=channel_cmd_token_o[ch];
                    held_read[ch]=channel_cmd_read_tag_o[ch];held_wb[ch]=channel_cmd_wb_attempt_id_o[ch];
                    held_store[ch]=channel_cmd_store_attempt_id_o[ch];held_line[ch]=channel_cmd_line_addr_o[ch];
                    held_word[ch]=channel_cmd_store_word_addr_o[ch];held_wdata[ch]=channel_cmd_store_wdata_o[ch];
                    for(w=0;w<LW;w=w+1) held_data[ch][w]=channel_cmd_data_o[ch][w];
                end
                if(channel_cmd_valid_o[ch]&&channel_cmd_ready_i[ch]) begin
                    head=-1;
                    for(n=0;n<req_count;n=n+1) if(r_channel[n]==ch && r_state[n]==0 && head<0) head=n;
                    if(head<0) $fatal(1,"P37 unaccepted or duplicate physical dispatch");
                    if(channel_cmd_kind_o[ch]!==r_kind[head] || channel_cmd_read_tag_o[ch]!==r_read[head]
                        || channel_cmd_wb_attempt_id_o[ch]!==r_wb[head] || channel_cmd_store_attempt_id_o[ch]!==r_store[head]
                        || channel_cmd_line_addr_o[ch]!==r_line[head] || channel_cmd_store_word_addr_o[ch]!==r_word[head]
                        || channel_cmd_store_wdata_o[ch]!==r_wdata[head]) $fatal(1,"P37 exact FIFO/routing identity mismatch ch=%0d req=%0d",ch,head);
                    for(w=0;w<LW;w=w+1) if(channel_cmd_data_o[ch][w]!==r_data[head][w]) $fatal(1,"P37 command payload mismatch");
                    ln=integer'(32'(canonical_line(channel_cmd_kind_o[ch],channel_cmd_line_addr_o[ch],channel_cmd_store_word_addr_o[ch]))% (MEM_WORDS/LW));
                    if(integer'(32'(canonical_line(channel_cmd_kind_o[ch],channel_cmd_line_addr_o[ch],channel_cmd_store_word_addr_o[ch]))%C)!=ch) $fatal(1,"P37 physical channel/address mapping mismatch");
                    if(token_seen[ch][channel_cmd_token_o[ch]]) $fatal(1,"P37 live generation token reused without certificate");
                    token_seen[ch][channel_cmd_token_o[ch]]=1;r_token[head]=channel_cmd_token_o[ch];
                    r_state[head]=1;dispatched=dispatched+1;total_dispatched=total_dispatched+1;batch_d=batch_d+1;mapping_checks=mapping_checks+1;
                    expected_addr=integer'(32'(canonical_line(r_kind[head],r_line[head],r_word[head]))%(MEM_WORDS/LW))*LW;
                    if(r_kind[head]==WB) begin
                        for(w=0;w<LW;w=w+1) begin
                            reference_memory[expected_addr+w]=r_data[head][w];
                            physical_memory[ln*LW+w]=channel_cmd_data_o[ch][w];
                        end
                    end else if(r_kind[head]==STORE) begin
                        reference_memory[r_word[head]%MEM_WORDS]=r_wdata[head];
                        physical_memory[channel_cmd_store_word_addr_o[ch]%MEM_WORDS]=channel_cmd_store_wdata_o[ch];
                    end else begin
                        for(w=0;w<LW;w=w+1) begin
                            r_expected_read[head][w]=reference_memory[expected_addr+w];
                            r_actual_read[head][w]=physical_memory[ln*LW+w];
                        end
                    end
                    for(addr=0;addr<MEM_WORDS;addr=addr+1)
                        if(reference_memory[addr]!==physical_memory[addr]) $fatal(1,"P37 backing-memory effect mismatch address=%0d",addr);
                end
            end
            for(ch=0;ch<C;ch=ch+1) begin
                if(channel_resp_valid_i[ch]) begin
                    found=-1;
                    for(n=0;n<req_count;n=n+1)
                        if(r_state[n]==1 && r_channel[n]==ch && r_token[n]==channel_resp_token_i[ch]
                            && r_kind[n]==channel_resp_kind_i[ch] && r_read[n]==channel_resp_read_tag_i[ch]
                            && r_wb[n]==channel_resp_wb_attempt_id_i[ch] && r_store[n]==channel_resp_store_attempt_id_i[ch]
                            && r_line[n]==channel_resp_line_addr_i[ch] && r_word[n]==channel_resp_store_word_addr_i[ch]) found=n;
                    if(found<0) begin
                        expected_reject_mask=expected_reject_mask|(1<<ch);reject_count=reject_count+1;
                    end else begin
                        if(!channel_resp_ready_o[ch]) $fatal(1,"P37 valid owned return unexpectedly blocked");
                        r_state[found]=2;r_response_cycle[found]=cycle_no;
                        r_fault[found]=!channel_resp_success_i[ch];r_success[found]=channel_resp_success_i[ch];
                        r_retryable[found]=channel_resp_retryable_i[ch];
                        returned=returned+1;total_returned=total_returned+1;batch_r=batch_r+1;
                    end
                end
            end
            if(batch_d>max_dispatch_batch) max_dispatch_batch=batch_d;
            if(batch_r>max_return_batch) max_return_batch=batch_r;
            outstanding=0;
            for(ch=0;ch<C;ch=ch+1) begin
                count_by_channel[ch]=0;
                for(n=0;n<req_count;n=n+1) if(r_channel[n]==ch && r_state[n]!=3) count_by_channel[ch]=count_by_channel[ch]+1;
                if(count_by_channel[ch]>D) $fatal(1,"P37 accepted beyond finite capacity");
                outstanding=outstanding+count_by_channel[ch];
            end
            #1;
            expected_busy=(outstanding!=0)||cmd_valid_i||(|channel_resp_valid_i);
            expected_read_busy=cmd_valid_i&&(cmd_kind_i==READ);
            expected_wb_busy=cmd_valid_i&&(cmd_kind_i==WB);
            expected_store_busy=cmd_valid_i&&(cmd_kind_i==STORE);
            expected_channel_busy=channel_resp_valid_i;
            if(cmd_valid_i) expected_channel_busy[32'(canonical_line(cmd_kind_i,cmd_line_addr_i,cmd_store_word_addr_i))%C]=1;
            for(ch=0;ch<C;ch=ch+1) begin
                if(count_by_channel[ch]!=0) expected_channel_busy[ch]=1;
                if(channel_resp_valid_i[ch]) begin
                    expected_read_busy=expected_read_busy||(channel_resp_kind_i[ch]==READ);
                    expected_wb_busy=expected_wb_busy||(channel_resp_kind_i[ch]==WB);
                    expected_store_busy=expected_store_busy||(channel_resp_kind_i[ch]==STORE);
                end
            end
            for(n=0;n<req_count;n=n+1) if(r_state[n]!=3) begin
                expected_read_busy=expected_read_busy||(r_kind[n]==READ);
                expected_wb_busy=expected_wb_busy||(r_kind[n]==WB);
                expected_store_busy=expected_store_busy||(r_kind[n]==STORE);
            end
            if(busy_o!==expected_busy || quiescent_o!==!expected_busy
               || read_busy_o!==expected_read_busy || wb_busy_o!==expected_wb_busy
               || store_busy_o!==expected_store_busy || channel_busy_o!==expected_channel_busy)
                $fatal(1,"P37 public busy/quiescence accounting mismatch");
            if(response_rejected_o!==C'(expected_reject_mask)) $fatal(1,"P37 response rejection witness mismatch expected=%0h got=%0h",expected_reject_mask,response_rejected_o);
            if(|generation_rearm_pulse_o) begin
                if(outstanding!=0 || channel_resp_valid_i!='0 || !all_generations_quiescent_i)
                    $fatal(1,"P37 dishonest generation rearm");
                for(ch=0;ch<C;ch=ch+1) for(n=0;n<(1<<TOKW);n=n+1) token_seen[ch][n]=0;
            end
        end
        end
    endtask

    // This is an ordered testbench ledger, not a bank of sequential RTL
    // registers. Blocking updates deliberately expose earlier handshakes to
    // later checks on this same edge; the task retains the post-NBA #1 check.
    initial begin : scoreboard
        total_accepted=0;total_dispatched=0;total_returned=0;total_delivered=0;
        reject_count=0;stable_checks=0;full_checks=0;fair_checks=0;
        max_return_batch=0;max_dispatch_batch=0;mapping_checks=0;
        zero_latency_checks=0;rearm_denied_checks=0;early_return_checks=0;
        queue_hole_checks=0;
        forever begin
            @(posedge clk);
            sample_scoreboard();
        end
    end

    task automatic tick;
        begin @(posedge clk);@(negedge clk);#1;end
    endtask

    task automatic reset_scenario;
        integer ch,w;
        begin
            if(rst_n && req_count!=delivered) $fatal(1,"P37 test may not reset away a live obligation");
            @(negedge clk);rst_n=0;cmd_valid_i=0;cmd_kind_i=READ;
            cmd_read_tag_i=0;cmd_wb_attempt_id_i=0;cmd_store_attempt_id_i=0;
            cmd_line_addr_i=0;cmd_store_word_addr_i=0;cmd_store_wdata_i=0;
            channel_cmd_ready_i='0;channel_resp_valid_i='0;all_generations_quiescent_i=0;
            channel_resp_success_i='0;channel_resp_retryable_i='0;
            for(w=0;w<LW;w=w+1) cmd_data_i[w]=0;
            for(ch=0;ch<C;ch=ch+1) begin
                channel_resp_kind_i[ch]=READ;channel_resp_token_i[ch]=0;
                channel_resp_read_tag_i[ch]=0;channel_resp_wb_attempt_id_i[ch]=0;channel_resp_store_attempt_id_i[ch]=0;
                channel_resp_line_addr_i[ch]=0;channel_resp_store_word_addr_i[ch]=0;
                for(w=0;w<LW;w=w+1) channel_resp_data_i[ch][w]=0;
            end
            for(w=0;w<MEM_WORDS;w=w+1) begin
                reference_memory[w]=32'h1D000000^32'(w*257);
                physical_memory[w]=reference_memory[w];
            end
            repeat(3) tick();rst_n=1;tick();
            if(!quiescent_o || busy_o) $fatal(1,"P37 reset is not empty");
        end
    endtask

    task automatic offer(input logic[1:0] kind,input integer line_no,input integer word_no);
        integer w,id;
        begin
            id=req_count+1;cmd_valid_i=1;cmd_kind_i=kind;
            cmd_read_tag_i=16'hA000|IW'(id);cmd_wb_attempt_id_i=16'hB000|IW'(id+512);cmd_store_attempt_id_i=16'hD000|IW'(id+1024);
            // This deliberately matches the production seam's STORE line=0.
            cmd_line_addr_i=(kind==STORE)?'0:AW'(line_no);
            cmd_store_word_addr_i=(kind==STORE)?32'(line_no*LW+word_no):32'(3000+id);
            cmd_store_wdata_i=32'hA5000000^32'(line_no*17+word_no+id);
            for(w=0;w<LW;w=w+1) cmd_data_i[w]=32'hB7000000^32'(id*4096+w*19+line_no);
            #1;
        end
    endtask

    task automatic submit(input logic[1:0] kind,input integer line_no,input integer word_no);
        integer guard,before_count;
        begin
            before_count=req_count;offer(kind,line_no,word_no);guard=0;
            while(!cmd_ready_o) begin tick();guard=guard+1;if(guard>80) $fatal(1,"P37 submit bounded wait failed");end
            tick();cmd_valid_i=0;#1;
            if(req_count!=before_count+1) $fatal(1,"P37 expected exactly one ingress acceptance");
        end
    endtask

    task automatic wait_dispatched(input integer target);
        integer guard;
        begin
            guard=0;
            while(dispatched<target) begin tick();guard=guard+1;if(guard>80) $fatal(1,"P37 dispatch bounded wait failed");end
        end
    endtask

    task automatic prepare_response(input integer request_no,input integer ch);
        integer w;
        begin
            if(ch<0 || ch>=C) $fatal(1,"P37 response driver channel out of range");
            channel_resp_valid_i[ch]=1;channel_resp_kind_i[ch]=r_kind[request_no];
            channel_resp_token_i[ch]=r_token[request_no];channel_resp_read_tag_i[ch]=r_read[request_no];
            channel_resp_wb_attempt_id_i[ch]=r_wb[request_no];channel_resp_store_attempt_id_i[ch]=r_store[request_no];
            channel_resp_line_addr_i[ch]=r_line[request_no];channel_resp_store_word_addr_i[ch]=r_word[request_no];
            channel_resp_success_i[ch]=(request_no%3!=1);
            channel_resp_retryable_i[ch]=(request_no%3==1);
            for(w=0;w<LW;w=w+1) channel_resp_data_i[ch][w]=r_actual_read[request_no][w];
            // Prepare every lane without advancing time. A per-lane delay can
            // cross the next sample edge when four responses form one batch.
        end
    endtask

    task automatic return_one(input integer request_no);
        begin
            prepare_response(request_no,r_channel[request_no]);tick();channel_resp_valid_i='0;#1;
        end
    endtask

    // Echo a public queued offer, so this also models a zero-cycle channel.
    // No private slot state is used to obtain its token or payload.
    task automatic prepare_dispatch_response(input integer ch);
        integer w,base_addr;
        begin
            if(ch<0 || ch>=C) $fatal(1,"P37 dispatch response channel out of range");
            if(!channel_cmd_valid_o[ch]) $fatal(1,"P37 zero-latency model needs a public offer");
            channel_resp_valid_i[ch]=1;channel_resp_kind_i[ch]=channel_cmd_kind_o[ch];
            channel_resp_token_i[ch]=channel_cmd_token_o[ch];
            channel_resp_read_tag_i[ch]=channel_cmd_read_tag_o[ch];
            channel_resp_wb_attempt_id_i[ch]=channel_cmd_wb_attempt_id_o[ch];
            channel_resp_store_attempt_id_i[ch]=channel_cmd_store_attempt_id_o[ch];
            channel_resp_line_addr_i[ch]=channel_cmd_line_addr_o[ch];
            channel_resp_store_word_addr_i[ch]=channel_cmd_store_word_addr_o[ch];
            channel_resp_success_i[ch]=1;channel_resp_retryable_i[ch]=0;
            base_addr=integer'(32'(channel_cmd_line_addr_o[ch])%(MEM_WORDS/LW))*LW;
            for(w=0;w<LW;w=w+1) channel_resp_data_i[ch][w]=physical_memory[base_addr+w];
            // The caller's tick supplies the common sampling edge.
        end
    endtask

    task automatic drain;
        integer ch,n,guard;
        begin
            guard=0;
            while(delivered<req_count) begin
                channel_resp_valid_i='0;
                for(ch=0;ch<C;ch=ch+1) begin n=find_issued(ch);if(n>=0) prepare_response(n,ch);end
                tick();channel_resp_valid_i='0;guard=guard+1;
                if(guard>80) $fatal(1,"P37 lossless drain failed");
            end
            tick();
            if(!quiescent_o || busy_o || dispatched!=req_count || returned!=req_count)
                $fatal(1,"P37 accepted/dispatched/returned/delivered conservation failed");
        end
    endtask

    task automatic reject_then_correct(input integer request_no,input integer mutation);
        integer ch,before_returns,before_rejects;
        begin
            ch=r_channel[request_no];if(mutation==1 && C>1) ch=(ch+1)%C;
            before_returns=returned;before_rejects=reject_count;
            prepare_response(request_no,ch);
            case(mutation)
                0: channel_resp_token_i[ch]=channel_resp_token_i[ch]^(TOKW'(1)<<SW);
                1: if(C==1) channel_resp_token_i[ch]=channel_resp_token_i[ch]^(TOKW'(1)<<SW);
                2: channel_resp_kind_i[ch]=(r_kind[request_no]==READ)?STORE:READ;
                3: channel_resp_read_tag_i[ch]=channel_resp_read_tag_i[ch]^(IW'(1)<<(IW-1));
                4: channel_resp_wb_attempt_id_i[ch]=channel_resp_wb_attempt_id_i[ch]^(IW'(1)<<(IW-1));
                5: channel_resp_store_attempt_id_i[ch]=channel_resp_store_attempt_id_i[ch]^(IW'(1)<<(IW-1));
                6: channel_resp_line_addr_i[ch]=channel_resp_line_addr_i[ch]^(AW'(1)<<(AW-1));
                7: channel_resp_store_word_addr_i[ch]=channel_resp_store_word_addr_i[ch]^32'h80000000;
            endcase
            #1;tick();channel_resp_valid_i='0;#1;
            if(returned!=before_returns || reject_count!=before_rejects+1 || r_state[request_no]!=1)
                $fatal(1,"P37 malformed response consumed live ownership mutation=%0d",mutation);
        end
    endtask

    initial begin : scenarios
        integer ch,j,n,before_count,before_returns,before_deliveries,guard,old_request,new_request;
        logic[TOKW-1:0] old_token;
        rst_n=0;req_count=0;delivered=0;

        // Isolate STORE's canonical line before filling any queue. A broken
        // raw-line route must fail the public identity/accounting assertions;
        // it must not be hidden behind a later full-channel submit timeout.
        reset_scenario();channel_cmd_ready_i='1;
        submit(STORE,C*3+(C-1),LW-1);wait_dispatched(1);
        // P36 uses a synchronous active-low reset. A pulse wholly between
        // rising edges must not discard this issued owner or its token.
        @(negedge clk);rst_n=0;#2;rst_n=1;#1;
        if(dispatched!=1 || returned!=0 || !busy_o || quiescent_o)
            $fatal(1,"P37 off-edge reset pulse discarded live ownership");
        $display("PROD_SEAM_P37_SYNC_RESET_OFF_EDGE_RETENTION=PASS variant=%0d",VARIANT);
        drain();
        $display("PROD_SEAM_P37_INITIAL_STORE_CANONICAL_ROUTE=PASS variant=%0d",VARIANT);

        // Hold every channel, fill its finite capacity, then let independently
        // ready channels dispatch while channel zero remains blocked/full.
        reset_scenario();
        for(ch=0;ch<C;ch=ch+1) for(j=0;j<D;j=j+1)
            submit(2'((ch+j)%3),ch+C*(j+4),j%LW);
        if(req_count-delivered!=C*D) $fatal(1,"P37 capacity not reached");
        channel_cmd_ready_i='1;channel_cmd_ready_i[0]=0;
        offer(STORE,C*20,LW-1);before_count=req_count;
        repeat(5) begin
            if(cmd_ready_o) $fatal(1,"P37 full destination accepted another request");
            full_checks=full_checks+1;tick();
        end
        if(req_count!=before_count || dispatched!=(C-1)*D)
            $fatal(1,"P37 accepted independent channels did not bypass blocked dispatch");
        channel_cmd_ready_i[0]=1;wait_dispatched(C*D);
        n=find_issued(0);if(n<0) $fatal(1,"P37 missing oldest channel zero request");
        return_one(n);guard=0;
        while(req_count==before_count) begin tick();guard=guard+1;if(guard>20) $fatal(1,"P37 full queue did not resume");end
        cmd_valid_i=0;wait_dispatched(req_count);drain();
        $display("PROD_SEAM_P37_MAPPING_FIFO_FULL_STABLE=PASS variant=%0d stable_checks=%0d full_checks=%0d",VARIANT,stable_checks,full_checks);
        $display("PROD_SEAM_P37_INDEPENDENT_CHANNEL_DISPATCH=PASS variant=%0d channels=%0d max_parallel_dispatch=%0d",VARIANT,C,max_dispatch_batch);

        // Recycle the first physical slot while older commands remain queued.
        // Accept the new owner on the same edge as the next older dispatch;
        // physical slot order must never replace per-channel FIFO order.
        if(D>1) begin
            reset_scenario();
            for(j=0;j<D;j=j+1) submit(READ,C*(5+j),0);
            channel_cmd_ready_i[0]=1;tick();channel_cmd_ready_i[0]=0;
            if(dispatched!=1) $fatal(1,"P37 queue-hole scenario did not isolate first dispatch");
            return_one(0);guard=0;
            while(delivered!=1) begin tick();guard=guard+1;if(guard>10) $fatal(1,"P37 queue-hole release did not deliver");end
            channel_cmd_ready_i[0]=1;submit(READ,C*19,0);
            wait_dispatched(req_count);return_one(req_count-1);drain();
            queue_hole_checks=queue_hole_checks+1;
            $display("PROD_SEAM_P37_RECYCLED_SLOT_FIFO_AND_OUT_OF_ORDER_RETURN=PASS variant=%0d depth=%0d",VARIANT,D);
        end

        // Actual WB and every STORE word affect a backing memory. A later READ
        // observes the independent reference, including STORE's zero line field.
        reset_scenario();channel_cmd_ready_i='1;
        submit(WB,C*9+(C-1),0);wait_dispatched(req_count);drain();
        for(j=0;j<LW;j=j+1) begin
            submit(STORE,C*9+(C-1),j);wait_dispatched(req_count);drain();
        end
        submit(READ,C*9+(C-1),0);wait_dispatched(req_count);drain();
        $display("PROD_SEAM_P37_BACKING_MEMORY_STORE_WORD_MAPPING=PASS variant=%0d line_words=%0d",VARIANT,LW);

        // Same-type responses accepted concurrently are each delivered exactly
        // once. Mixed types above and below share one fair upstream serializer.
        reset_scenario();
        for(ch=0;ch<C;ch=ch+1) submit(READ,ch+C*12,0);
        channel_cmd_ready_i='1;wait_dispatched(C);
        for(ch=0;ch<C;ch=ch+1) prepare_response(ch,ch);
        before_returns=returned;before_deliveries=delivered;tick();channel_resp_valid_i='0;
        if(returned-before_returns!=C) $fatal(1,"P37 same-type concurrent returns lost");
        if(delivered!=before_deliveries) $fatal(1,"P37 unbuffered return unexpectedly bypassed accounting");
        drain();
        $display("PROD_SEAM_P37_CONCURRENT_RETURNS_BOUNDED_FAIR=PASS variant=%0d max_parallel_returns=%0d fair_checks=%0d",VARIANT,max_return_batch,fair_checks);

        // A queued owner cannot return before dispatch. The same exact echo is
        // legal on the dispatch edge, including concurrent channels. Certificate
        // requests must not erase either queued or newly returned ownership.
        reset_scenario();
        for(ch=0;ch<C;ch=ch+1) submit(READ,ch+C*14,0);
        for(ch=0;ch<C;ch=ch+1) prepare_dispatch_response(ch);
        all_generations_quiescent_i=1;before_returns=returned;tick();
        if(returned!=before_returns || (|generation_rearm_pulse_o))
            $fatal(1,"P37 early response/certificate erased queued ownership");
        early_return_checks=early_return_checks+C;rearm_denied_checks=rearm_denied_checks+1;
        channel_cmd_ready_i='1;tick();channel_resp_valid_i='0;
        if(returned-before_returns!=C || dispatched!=C || (|generation_rearm_pulse_o))
            $fatal(1,"P37 same-cycle dispatch/return was lost");
        zero_latency_checks=zero_latency_checks+C;rearm_denied_checks=rearm_denied_checks+1;
        all_generations_quiescent_i=0;drain();
        if(!protocol_error_o || !quiescent_o) $fatal(1,"P37 sticky diagnostic poisoned preserved-owner recovery");
        $display("PROD_SEAM_P37_ZERO_LATENCY_AND_EARLY_RETURN=PASS variant=%0d same_cycle=%0d early_rejected=%0d",VARIANT,zero_latency_checks,early_return_checks);

        // Full-width line/word identities include the top address bit. The
        // finite backing model projects addresses into its own 4096-word store;
        // routing and transported identity are still checked at full width.
        reset_scenario();channel_cmd_ready_i='1;
        submit(WB,(1<<(AW-1))+C*3+(C-1),0);wait_dispatched(req_count);drain();
        submit(STORE,(1<<(AW-1))+C*3+(C-1),LW-1);wait_dispatched(req_count);drain();
        submit(READ,(1<<(AW-1))+C*3+(C-1),0);wait_dispatched(req_count);drain();
        $display("PROD_SEAM_P37_FULL_WIDTH_ADDRESS_AND_IDENTITY=PASS variant=%0d address_width=%0d id_width=%0d",VARIANT,AW,IW);

        // Corrupt every transported identity component without resetting away
        // the owner, then deliver the correct response and a duplicate.
        reset_scenario();channel_cmd_ready_i='1;
        submit(READ,C*16,0);wait_dispatched(1);
        for(j=0;j<8;j=j+1) reject_then_correct(0,j);
        return_one(0);drain();before_returns=returned;prepare_response(0,0);tick();channel_resp_valid_i='0;
        if(returned!=before_returns) $fatal(1,"P37 duplicate returned twice");
        // Slot reuse carries a new transport generation; the old exact token
        // must still be rejected even while a new same-kind owner is issued.
        old_request=0;old_token=r_token[0];offer(READ,C*16,0);
        cmd_read_tag_i=r_read[0];cmd_wb_attempt_id_i=r_wb[0];cmd_store_attempt_id_i=r_store[0];
        cmd_store_word_addr_i=r_word[0];
        if(!cmd_ready_o) $fatal(1,"P37 slot reuse scenario unexpectedly blocked");
        tick();cmd_valid_i=0;new_request=1;wait_dispatched(2);
        if(r_token[new_request]==old_token) $fatal(1,"P37 token failed to change on slot reuse");
        before_returns=returned;prepare_response(old_request,0);tick();channel_resp_valid_i='0;
        if(returned!=before_returns || r_state[new_request]!=1) $fatal(1,"P37 stale duplicate captured new owner");
        return_one(new_request);drain();
        $display("PROD_SEAM_P37_EXACT_RESPONSE_IDENTITY_AND_STALE_REJECTION=PASS variant=%0d rejected=%0d",VARIANT,reject_count);

        reset_scenario();offer(2'b11,C*21,0);before_count=req_count;
        repeat(3) begin
            if(cmd_ready_o || !busy_o || quiescent_o) $fatal(1,"P37 invalid ingress accepted or hidden");
            tick();
        end
        cmd_valid_i=0;tick();
        if(req_count!=before_count || !protocol_error_o || !quiescent_o)
            $fatal(1,"P37 invalid ingress diagnostic/accounting mismatch");
        $display("PROD_SEAM_P37_INVALID_INGRESS=PASS variant=%0d",VARIANT);

        // Consume every finite per-slot generation. A held producer must resume
        // only after the explicit all-generation external drainage certificate.
        reset_scenario();channel_cmd_ready_i='1;
        for(j=0;j<D*(1<<GW);j=j+1) begin
            submit(READ,C*(25+j),0);wait_dispatched(req_count);
            if(j==D*(1<<GW)-1) begin
                // Exercise the owned-work exclusion with a genuinely exhausted
                // generation pool, so denial cannot be vacuous.
                if(generation_exhausted_o!=C'(1)) $fatal(1,"P37 final live token did not exhaust only channel zero");
                all_generations_quiescent_i=1;before_deliveries=delivered;tick();
                if((|generation_rearm_pulse_o) || delivered!=before_deliveries
                    || r_state[req_count-1]!=1 || generation_exhausted_o!=C'(1))
                    $fatal(1,"P37 false certificate erased exhausted live owner");
                rearm_denied_checks=rearm_denied_checks+1;
                all_generations_quiescent_i=0;
            end
            drain();
        end
        if(generation_exhausted_o!=C'(1)) $fatal(1,"P37 expected finite generation exhaustion only on channel zero");
        offer(READ,C*60,0);before_count=req_count;
        repeat(4) begin
            if(cmd_ready_o || quiescent_o) $fatal(1,"P37 exhausted ingress admitted or hid raw offer");
            tick();
        end
        // Even with no local owner, a raw old token response blocks reuse.
        all_generations_quiescent_i=1;prepare_response(0,0);tick();
        if((|generation_rearm_pulse_o) || req_count!=before_count || generation_exhausted_o!=C'(1))
            $fatal(1,"P37 raw return did not block exhausted-token rearm");
        rearm_denied_checks=rearm_denied_checks+1;channel_resp_valid_i='0;tick();
        if(generation_rearm_pulse_o!=C'(1) || req_count!=before_count) $fatal(1,"P37 certified rearm must be a bubble");
        all_generations_quiescent_i=0;guard=0;
        while(req_count==before_count) begin tick();guard=guard+1;if(guard>10) $fatal(1,"P37 held request stranded after rearm");end
        cmd_valid_i=0;wait_dispatched(req_count);drain();
        $display("PROD_SEAM_P37_FINITE_GENERATION_AND_HELD_REQUEST_REARM=PASS variant=%0d exhausted_tokens=%0d",VARIANT,D*(1<<GW));

        if(total_accepted!=total_dispatched || total_accepted!=total_returned || total_accepted!=total_delivered)
            $fatal(1,"P37 final conservation mismatch");
        if(stable_checks==0 || full_checks==0 || fair_checks==0 || mapping_checks==0 || reject_count<10
            || zero_latency_checks!=C || early_return_checks!=C || rearm_denied_checks<3)
            $fatal(1,"P37 vacuous proof counters");
        if(C>1 && (max_dispatch_batch<C-1 || max_return_batch<C)) $fatal(1,"P37 concurrency witness absent");
        if(D>1 && queue_hole_checks==0) $fatal(1,"P37 recycled-slot FIFO witness absent");
        $display("PROD_SEAM_P37_SCHEDULER_BEHAVIOR=PASS variant=%0d accepted=%0d dispatched=%0d returned=%0d delivered=%0d",VARIANT,total_accepted,total_dispatched,total_returned,total_delivered);
        $finish;
    end
    initial begin #200000;$fatal(1,"P37 component global timeout");end
endmodule
