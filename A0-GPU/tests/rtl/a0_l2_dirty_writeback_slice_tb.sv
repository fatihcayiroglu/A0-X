`timescale 1ns/1ps
module a0_l2_dirty_writeback_slice_tb;
    localparam integer STORE_LANES=2;
    localparam integer LINE_WORDS=4;
    localparam integer SET_COUNT=4;
    localparam integer GLOBAL_TAG_W=4;
    localparam integer WORD_SELECT_W=$clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W=32-WORD_SELECT_W;

    logic clk, rst_n;
    logic line_req_valid_i, line_req_ready_o;
    logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i;
    logic [LINE_ADDR_W-1:0] line_req_line_addr_i;
    logic line_mem_req_valid_o, line_mem_req_ready_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o;
    logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o;
    logic line_mem_resp_valid_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i;
    logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i;
    logic line_mem_resp_fault_i;
    logic [31:0] line_mem_resp_data_i [0:LINE_WORDS-1];
    logic line_resp_valid_o;
    logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o;
    logic [LINE_ADDR_W-1:0] line_resp_line_addr_o;
    logic line_resp_fault_o;
    logic [31:0] line_resp_data_o [0:LINE_WORDS-1];
    logic store_valid_i, store_ready_o;
    logic [STORE_LANES-1:0] store_lane_mask_i;
    logic [31:0] store_word_addr_i [0:STORE_LANES-1];
    logic [31:0] store_wdata_i [0:STORE_LANES-1];
    logic [STORE_LANES-1:0] store_hit_mask_o, store_miss_mask_o;
    logic wb_valid_o, wb_ready_i;
    logic [LINE_ADDR_W-1:0] wb_line_addr_o;
    logic [31:0] wb_data_o [0:LINE_WORDS-1];
    logic dirty_present_o, protocol_error_o;

    localparam logic [LINE_ADDR_W-1:0] LINE_A = LINE_ADDR_W'(1);
    localparam logic [LINE_ADDR_W-1:0] LINE_B = LINE_ADDR_W'(5); // same set, other tag
    localparam logic [LINE_ADDR_W-1:0] LINE_C = LINE_ADDR_W'(2); // other set

    integer i;
    integer mem_req_fire_count;
    integer wb_fire_count;

    a0_l2_dirty_writeback_slice #(
        .STORE_LANES(STORE_LANES), .LINE_WORDS(LINE_WORDS), .SET_COUNT(SET_COUNT), .GLOBAL_TAG_W(GLOBAL_TAG_W)
    ) dut (.*);

    initial clk=1'b0;
    always #5 clk=~clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_req_fire_count <= 0;
            wb_fire_count <= 0;
        end else begin
            if (line_mem_req_valid_o && line_mem_req_ready_i) mem_req_fire_count <= mem_req_fire_count + 1;
            if (wb_valid_o && wb_ready_i) wb_fire_count <= wb_fire_count + 1;
        end
    end

    function automatic logic [31:0] word_addr(input logic [LINE_ADDR_W-1:0] line, input integer off);
        word_addr = (32'(line) << WORD_SELECT_W) + 32'(off);
    endfunction

    task automatic clear_inputs;
        begin
            line_req_valid_i=0; line_req_global_tag_i='0; line_req_line_addr_i='0;
            line_mem_req_ready_i=1;
            line_mem_resp_valid_i=0; line_mem_resp_global_tag_i='0; line_mem_resp_line_addr_i='0; line_mem_resp_fault_i=0;
            store_valid_i=0; store_lane_mask_i='0;
            wb_ready_i=1;
            for (i=0;i<LINE_WORDS;i=i+1) line_mem_resp_data_i[i]='0;
            for (i=0;i<STORE_LANES;i=i+1) begin store_word_addr_i[i]='0; store_wdata_i[i]='0; end
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n=0; clear_inputs(); repeat(3) @(posedge clk); @(negedge clk); rst_n=1; #1;
        end
    endtask

    task automatic issue_miss(input logic [GLOBAL_TAG_W-1:0] tag, input logic [LINE_ADDR_W-1:0] line);
        begin
            @(negedge clk); line_req_global_tag_i=tag; line_req_line_addr_i=line; line_req_valid_i=1; #1;
            if (!line_req_ready_o || !line_mem_req_valid_o) $fatal(1,"P17 expected clean miss acceptance");
            if (line_mem_req_global_tag_o!=tag || line_mem_req_line_addr_o!=line) $fatal(1,"P17 miss identity mismatch");
            @(posedge clk); @(negedge clk); line_req_valid_i=0; #1;
        end
    endtask

    task automatic respond(input logic [GLOBAL_TAG_W-1:0] tag, input logic [LINE_ADDR_W-1:0] line, input logic fault, input logic [31:0] base);
        begin
            @(negedge clk); line_mem_resp_global_tag_i=tag; line_mem_resp_line_addr_i=line; line_mem_resp_fault_i=fault;
            for(i=0;i<LINE_WORDS;i=i+1) line_mem_resp_data_i[i]=base+32'(i);
            line_mem_resp_valid_i=1; #1;
            if (!line_resp_valid_o || line_resp_global_tag_o!=tag || line_resp_line_addr_o!=line || line_resp_fault_o!=fault)
                $fatal(1,"P17 response forwarding mismatch");
            @(posedge clk); @(negedge clk); line_mem_resp_valid_i=0; line_mem_resp_fault_i=0; #1;
        end
    endtask

    task automatic expect_hit(input logic [GLOBAL_TAG_W-1:0] tag, input logic [LINE_ADDR_W-1:0] line, input logic [31:0] word2);
        integer before_req;
        begin
            before_req=mem_req_fire_count;
            @(negedge clk); line_req_global_tag_i=tag; line_req_line_addr_i=line; line_req_valid_i=1; #1;
            if(!line_req_ready_o || line_mem_req_valid_o) $fatal(1,"P17 expected hit");
            @(posedge clk); #1;
            if(!line_resp_valid_o || line_resp_global_tag_o!=tag || line_resp_line_addr_o!=line || line_resp_data_o[2]!=word2)
                $fatal(1,"P17 hit data/identity mismatch got=%h", line_resp_data_o[2]);
            if(mem_req_fire_count!=before_req) $fatal(1,"P17 hit leaked backend read");
            @(negedge clk); line_req_valid_i=0; #1; @(posedge clk); #1;
        end
    endtask

    initial begin
        reset_dut();
        if(dirty_present_o) $fatal(1,"P17 dirty after reset");
        $display("PROD_SEAM_P17_RESET_CLEAN=PASS");

        issue_miss(4'h1,LINE_A);
        respond(4'h1,LINE_A,0,32'h1000);
        if(dirty_present_o) $fatal(1,"P17 refill must install clean");
        $display("PROD_SEAM_P17_REFILL_INSTALLS_CLEAN=PASS");
        expect_hit(4'h2,LINE_A,32'h1002);

        @(negedge clk);
        store_word_addr_i[0]=word_addr(LINE_A,2); store_wdata_i[0]=32'hDEAD_BEEF;
        store_lane_mask_i=2'b01; store_valid_i=1; #1;
        if(!store_ready_o || store_hit_mask_o!=2'b01 || store_miss_mask_o!=0) $fatal(1,"P17 resident store hit mismatch");
        @(posedge clk); #1;
        if(!dirty_present_o) $fatal(1,"P17 store hit did not dirty line");
        @(negedge clk); store_valid_i=0; store_lane_mask_i=0; #1;
        $display("PROD_SEAM_P17_STORE_HIT_MARKS_DIRTY=PASS");
        expect_hit(4'h3,LINE_A,32'hDEAD_BEEF);
        $display("PROD_SEAM_P17_DIRTY_HIT_RETURNS_UPDATED_DATA=PASS");

        // Store miss is explicit no-write-allocate in P17.
        @(negedge clk); store_word_addr_i[0]=word_addr(LINE_C,0); store_wdata_i[0]=32'hCAFE_0001;
        store_lane_mask_i=2'b01; store_valid_i=1; #1;
        if(!store_ready_o || store_miss_mask_o!=2'b01 || store_hit_mask_o!=0) $fatal(1,"P17 store miss classification");
        @(posedge clk); @(negedge clk); store_valid_i=0; store_lane_mask_i=0; #1;
        if(!dirty_present_o) $fatal(1,"P17 unrelated store miss cleared dirty victim");
        $display("PROD_SEAM_P17_STORE_MISS_NO_WRITE_ALLOCATE=PASS");

        // Same-set miss captures dirty victim; read must not issue before writeback acceptance.
        wb_ready_i=0;
        @(negedge clk); line_req_global_tag_i=4'h4; line_req_line_addr_i=LINE_B; line_req_valid_i=1; #1;
        if(!line_req_ready_o) $fatal(1,"P17 dirty eviction request not accepted");
        if(line_mem_req_valid_o) $fatal(1,"P17 read issued before dirty victim capture");
        @(posedge clk); @(negedge clk); line_req_valid_i=0; #1;
        if(!wb_valid_o || wb_line_addr_o!=LINE_A) $fatal(1,"P17 writeback not presented");
        if(wb_data_o[2]!=32'hDEAD_BEEF || wb_data_o[0]!=32'h1000) $fatal(1,"P17 writeback payload mismatch");
        if(line_mem_req_valid_o) $fatal(1,"P17 backend read escaped while wb blocked");
        if(!dirty_present_o) $fatal(1,"P17 synthetic clean before wb acceptance");
        $display("PROD_SEAM_P17_DIRTY_EVICTION_REQUIRES_WRITEBACK=PASS");
        $display("PROD_SEAM_P17_NO_SYNTHETIC_CLEAN_BEFORE_WB_ACCEPT=PASS");

        // Victim store is backpressured and writeback payload remains stable.
        store_valid_i=1; store_lane_mask_i=2'b01; store_word_addr_i[0]=word_addr(LINE_A,1); store_wdata_i[0]=32'hBAD0_BAD0; #1;
        if(store_ready_o) $fatal(1,"P17 victim mutation accepted during writeback");
        if(wb_data_o[2]!=32'hDEAD_BEEF) $fatal(1,"P17 wb payload changed under backpressure");
        store_valid_i=0; store_lane_mask_i=0; #1;
        $display("PROD_SEAM_P17_WRITEBACK_PAYLOAD_STABLE=PASS");
        $display("PROD_SEAM_P17_VICTIM_STORE_BACKPRESSURED=PASS");

        // Accept writeback. Only afterward may the retained read issue.
        @(negedge clk); wb_ready_i=1; #1;
        if(!wb_valid_o) $fatal(1,"P17 wb disappeared before handshake");
        @(posedge clk); #1;
        if(wb_fire_count!=1) $fatal(1,"P17 wb handshake count");
        if(dirty_present_o) $fatal(1,"P17 dirty not cleared by accepted wb");
        if(!line_mem_req_valid_o || line_mem_req_global_tag_o!=4'h4 || line_mem_req_line_addr_o!=LINE_B)
            $fatal(1,"P17 retained miss not released after wb");
        $display("PROD_SEAM_P17_WB_ACCEPT_RELEASES_RETAINED_MISS=PASS");
        @(posedge clk); #1;
        respond(4'h4,LINE_B,0,32'h2000);
        if(dirty_present_o) $fatal(1,"P17 new refill dirty");
        expect_hit(4'h5,LINE_B,32'h2002);
        $display("PROD_SEAM_P17_POST_WB_REFILL_HIT=PASS");

        // Clean conflict must not emit writeback.
        issue_miss(4'h6,LINE_A);
        if(wb_valid_o) $fatal(1,"P17 clean conflict emitted wb");
        respond(4'h6,LINE_A,0,32'h3000);
        $display("PROD_SEAM_P17_CLEAN_EVICTION_NO_WRITEBACK=PASS");

        // Faulted refill is forwarded but never installed.
        issue_miss(4'h7,LINE_C);
        respond(4'h7,LINE_C,1,32'h4000);
        if(dirty_present_o) $fatal(1,"P17 fault created dirty state");
        $display("PROD_SEAM_P17_FAULTED_REFILL_NOT_INSTALLED=PASS");

        // Unknown response is contained as protocol error, never architectural response.
        @(negedge clk); line_mem_resp_valid_i=1; line_mem_resp_global_tag_i=4'hF; line_mem_resp_line_addr_i=LINE_C; #1;
        if(!protocol_error_o || line_resp_valid_o) $fatal(1,"P17 untracked response containment");
        @(negedge clk); line_mem_resp_valid_i=0; #1;
        $display("PROD_SEAM_P17_UNTRACKED_RESPONSE_CONTAINED=PASS");

        $display("PROD_SEAM_P17_BEHAVIOR=PASS");
        $finish;
    end
endmodule
