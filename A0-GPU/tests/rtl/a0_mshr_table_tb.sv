`timescale 1ns/1ps

module a0_mshr_table_tb;

    localparam integer MSHR_COUNT = 4;
    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_SIZE = 8;
    localparam integer LINE_WORDS = 8;
    localparam integer LINE_ADDR_W = 12;
    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer ENTRY_W = 2;
    localparam integer WAVE_ID_W = 2;
    localparam integer WORD_SELECT_W = 3;
    localparam integer OCCUPANCY_W = 3;

    logic clk;
    logic rst_n;

    logic req_valid_i;
    logic req_ready_o;
    logic [LINE_ADDR_W-1:0] req_line_addr_i;
    logic [WAVE_ID_W-1:0] req_wave_i;
    logic [WAVE_ID_W-1:0] req_context_i;
    logic [5:0] req_dst_i;
    logic [WAVE_SIZE-1:0] req_lane_mask_i;
    logic [WORD_SELECT_W-1:0] req_lane_word_select_i [0:WAVE_SIZE-1];

    logic req_fire_o;
    logic req_allocated_o;
    logic req_merged_o;
    logic req_blocked_draining_o;
    logic req_duplicate_waiter_o;
    logic [ENTRY_W-1:0] req_entry_o;

    logic miss_req_valid_o;
    logic miss_req_ready_i;
    logic [ENTRY_W-1:0] miss_req_entry_o;
    logic [LINE_ADDR_W-1:0] miss_req_line_addr_o;

    logic resp_valid_i;
    logic [ENTRY_W-1:0] resp_entry_i;
    logic [LINE_ADDR_W-1:0] resp_line_addr_i;
    logic resp_fault_i;
    logic [31:0] resp_line_data_i [0:LINE_WORDS-1];
    logic resp_accept_o;
    logic resp_tag_error_o;

    logic complete_valid_o;
    logic complete_ready_i;
    logic [ENTRY_W-1:0] complete_entry_o;
    logic [WAVE_ID_W-1:0] complete_wave_o;
    logic [WAVE_ID_W-1:0] complete_context_o;
    logic [5:0] complete_dst_o;
    logic [WAVE_SIZE-1:0] complete_lane_mask_o;
    logic [WORD_SELECT_W-1:0] complete_lane_word_select_o [0:WAVE_SIZE-1];
    logic complete_fault_o;
    logic [31:0] complete_line_data_o [0:LINE_WORDS-1];

    logic [OCCUPANCY_W-1:0] occupancy_o;
    logic full_o;
    logic empty_o;
    logic [MSHR_COUNT-1:0] valid_mask_o;
    logic [MSHR_COUNT-1:0] issued_mask_o;
    logic [MSHR_COUNT-1:0] response_ready_mask_o;

    integer init_lane;
    integer init_word;


    a0_mshr_table #(
        .MSHR_COUNT(MSHR_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(LINE_WORDS),
        .LINE_ADDR_W(LINE_ADDR_W),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid_i(req_valid_i),
        .req_ready_o(req_ready_o),
        .req_line_addr_i(req_line_addr_i),
        .req_wave_i(req_wave_i),
        .req_context_i(req_context_i),
        .req_dst_i(req_dst_i),
        .req_lane_mask_i(req_lane_mask_i),
        .req_lane_word_select_i(req_lane_word_select_i),
        .req_fire_o(req_fire_o),
        .req_allocated_o(req_allocated_o),
        .req_merged_o(req_merged_o),
        .req_blocked_draining_o(req_blocked_draining_o),
        .req_duplicate_waiter_o(req_duplicate_waiter_o),
        .req_entry_o(req_entry_o),
        .miss_req_valid_o(miss_req_valid_o),
        .miss_req_ready_i(miss_req_ready_i),
        .miss_req_entry_o(miss_req_entry_o),
        .miss_req_line_addr_o(miss_req_line_addr_o),
        .resp_valid_i(resp_valid_i),
        .resp_entry_i(resp_entry_i),
        .resp_line_addr_i(resp_line_addr_i),
        .resp_fault_i(resp_fault_i),
        .resp_line_data_i(resp_line_data_i),
        .resp_accept_o(resp_accept_o),
        .resp_tag_error_o(resp_tag_error_o),
        .complete_valid_o(complete_valid_o),
        .complete_ready_i(complete_ready_i),
        .complete_entry_o(complete_entry_o),
        .complete_wave_o(complete_wave_o),
        .complete_context_o(complete_context_o),
        .complete_dst_o(complete_dst_o),
        .complete_lane_mask_o(complete_lane_mask_o),
        .complete_lane_word_select_o(complete_lane_word_select_o),
        .complete_fault_o(complete_fault_o),
        .complete_line_data_o(complete_line_data_o),
        .occupancy_o(occupancy_o),
        .full_o(full_o),
        .empty_o(empty_o),
        .valid_mask_o(valid_mask_o),
        .issued_mask_o(issued_mask_o),
        .response_ready_mask_o(response_ready_mask_o)
    );


    always #5 clk = ~clk;


    task automatic clear_inputs;
        begin
            req_valid_i = 1'b0;
            miss_req_ready_i = 1'b0;
            resp_valid_i = 1'b0;
            resp_fault_i = 1'b0;
            complete_ready_i = 1'b0;
        end
    endtask


    task automatic set_request_payload(
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [WAVE_ID_W-1:0] context_id,
        input logic [5:0] dst,
        input logic [WAVE_SIZE-1:0] lane_mask
    );
        integer task_lane;
        begin
            req_line_addr_i = line_addr;
            req_wave_i = wave_id;
            req_context_i = context_id;
            req_dst_i = dst;
            req_lane_mask_i = lane_mask;
            for (task_lane = 0; task_lane < WAVE_SIZE; task_lane = task_lane + 1) begin
                req_lane_word_select_i[task_lane] = WORD_SELECT_W'(task_lane % LINE_WORDS);
            end
        end
    endtask


    task automatic accept_request(
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [WAVE_ID_W-1:0] wave_id,
        input logic [WAVE_ID_W-1:0] context_id,
        input logic [5:0] dst,
        input logic [WAVE_SIZE-1:0] lane_mask,
        input logic expect_merge,
        input logic [ENTRY_W-1:0] expected_entry
    );
        begin
            @(negedge clk);
            clear_inputs();
            set_request_payload(line_addr, wave_id, context_id, dst, lane_mask);
            req_valid_i = 1'b1;
            #1;
            if (!req_ready_o || !req_fire_o) begin
                $fatal(1, "request unexpectedly blocked line=%0h wave=%0d", line_addr, wave_id);
            end
            if (req_merged_o != expect_merge) begin
                $fatal(1, "merge classification mismatch line=%0h", line_addr);
            end
            if (req_allocated_o != !expect_merge) begin
                $fatal(1, "allocation classification mismatch line=%0h", line_addr);
            end
            if (req_entry_o != expected_entry) begin
                $fatal(1, "entry mismatch expected=%0d actual=%0d", expected_entry, req_entry_o);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_inputs();
        end
    endtask


    task automatic issue_one_miss(
        input logic [ENTRY_W-1:0] expected_entry,
        input logic [LINE_ADDR_W-1:0] expected_line
    );
        begin
            @(negedge clk);
            clear_inputs();
            #1;
            if (!miss_req_valid_o) begin
                $fatal(1, "expected miss request not visible");
            end
            if (
                miss_req_entry_o != expected_entry
                || miss_req_line_addr_o != expected_line
            ) begin
                $fatal(1, "miss issue mismatch");
            end
            miss_req_ready_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_inputs();
        end
    endtask


    task automatic send_response(
        input logic [ENTRY_W-1:0] entry_id,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault_value,
        input logic expect_accept,
        input logic [31:0] base_data
    );
        integer task_word;
        begin
            @(negedge clk);
            clear_inputs();
            resp_entry_i = entry_id;
            resp_line_addr_i = line_addr;
            resp_fault_i = fault_value;
            for (task_word = 0; task_word < LINE_WORDS; task_word = task_word + 1) begin
                resp_line_data_i[task_word] = base_data + 32'(task_word);
            end
            resp_valid_i = 1'b1;
            #1;
            if (resp_accept_o != expect_accept) begin
                $fatal(1, "response accept mismatch entry=%0d line=%0h", entry_id, line_addr);
            end
            if (resp_tag_error_o == expect_accept) begin
                $fatal(1, "response tag-error mismatch entry=%0d", entry_id);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_inputs();
        end
    endtask


    task automatic consume_completion(
        input logic [ENTRY_W-1:0] expected_entry,
        input logic [WAVE_ID_W-1:0] expected_wave,
        input logic [WAVE_ID_W-1:0] expected_context,
        input logic [5:0] expected_dst,
        input logic [WAVE_SIZE-1:0] expected_mask,
        input logic expected_fault,
        input logic [31:0] expected_base_data
    );
        integer task_word;
        integer task_lane;
        begin
            @(negedge clk);
            clear_inputs();
            #1;
            if (!complete_valid_o) begin
                $fatal(1, "expected completion not visible");
            end
            if (
                complete_entry_o != expected_entry
                || complete_wave_o != expected_wave
                || complete_context_o != expected_context
                || complete_dst_o != expected_dst
                || complete_lane_mask_o != expected_mask
                || complete_fault_o != expected_fault
            ) begin
                $fatal(1, "completion metadata mismatch");
            end
            if (!expected_fault) begin
                for (task_word = 0; task_word < LINE_WORDS; task_word = task_word + 1) begin
                    if (complete_line_data_o[task_word] != expected_base_data + 32'(task_word)) begin
                        $fatal(1, "completion line data mismatch word=%0d", task_word);
                    end
                end
            end
            for (task_lane = 0; task_lane < WAVE_SIZE; task_lane = task_lane + 1) begin
                if (complete_lane_word_select_o[task_lane] != WORD_SELECT_W'(task_lane % LINE_WORDS)) begin
                    $fatal(1, "completion word-select mismatch lane=%0d", task_lane);
                end
            end
            complete_ready_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_inputs();
        end
    endtask


    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        req_line_addr_i = '0;
        req_wave_i = '0;
        req_context_i = '0;
        req_dst_i = '0;
        req_lane_mask_i = '0;
        resp_entry_i = '0;
        resp_line_addr_i = '0;
        for (init_lane = 0; init_lane < WAVE_SIZE; init_lane = init_lane + 1) begin
            req_lane_word_select_i[init_lane] = '0;
        end
        for (init_word = 0; init_word < LINE_WORDS; init_word = init_word + 1) begin
            resp_line_data_i[init_word] = '0;
        end
        clear_inputs();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (!empty_o || occupancy_o != 0 || valid_mask_o != 0) begin
            $fatal(1, "reset state not empty");
        end
        $display("RTL8A_MSHR_RESET=PASS");

        /* Entry 0: line 0x120, two merged waiters. */
        accept_request(12'h120, 2'd0, 2'd0, 6'd3, 8'h0F, 1'b0, 2'd0);
        if (occupancy_o != 1) $fatal(1, "occupancy after first allocation");
        accept_request(12'h120, 2'd1, 2'd1, 6'd7, 8'hF0, 1'b1, 2'd0);
        if (occupancy_o != 1) $fatal(1, "merge consumed extra MSHR");
        $display("RTL8A_MSHR_SAME_LINE_MERGE=PASS");

        /* Duplicate waiter from the same wave must not be inserted twice. */
        @(negedge clk);
        set_request_payload(12'h120, 2'd0, 2'd0, 6'd9, 8'hFF);
        req_valid_i = 1'b1;
        #1;
        if (req_ready_o || !req_duplicate_waiter_o) begin
            $fatal(1, "duplicate waiter was not rejected");
        end
        clear_inputs();
        $display("RTL8A_MSHR_DUPLICATE_WAITER_GUARD=PASS");

        /* Fill all four unique-line entries while downstream is backpressured. */
        accept_request(12'h220, 2'd2, 2'd2, 6'd11, 8'h33, 1'b0, 2'd1);
        accept_request(12'h320, 2'd3, 2'd3, 6'd13, 8'h55, 1'b0, 2'd2);
        accept_request(12'h420, 2'd0, 2'd0, 6'd15, 8'hAA, 1'b0, 2'd3);
        #1;
        if (!full_o || occupancy_o != 4 || valid_mask_o != 4'b1111) begin
            $fatal(1, "table did not report full");
        end

        @(negedge clk);
        set_request_payload(12'h520, 2'd1, 2'd1, 6'd17, 8'hFF);
        req_valid_i = 1'b1;
        #1;
        if (req_ready_o || req_fire_o) begin
            $fatal(1, "unique request accepted while full");
        end
        clear_inputs();
        $display("RTL8A_MSHR_FULL_BACKPRESSURE=PASS");

        /* Full table must still accept a merge into an open line. */
        accept_request(12'h220, 2'd1, 2'd1, 6'd19, 8'hC3, 1'b1, 2'd1);
        if (occupancy_o != 4) $fatal(1, "full-table merge changed occupancy");
        $display("RTL8A_MSHR_MERGE_WHILE_FULL=PASS");

        /* Issue all misses; one unique line -> one downstream request. */
        issue_one_miss(2'd0, 12'h120);
        issue_one_miss(2'd1, 12'h220);
        issue_one_miss(2'd2, 12'h320);
        issue_one_miss(2'd3, 12'h420);
        #1;
        if (issued_mask_o != 4'b1111 || miss_req_valid_o) begin
            $fatal(1, "miss issue accounting mismatch");
        end
        $display("RTL8A_MSHR_UNIQUE_MISS_ISSUE=PASS");

        /* Wrong line tag must not consume entry 2. */
        send_response(2'd2, 12'h321, 1'b0, 1'b0, 32'h9000_0000);
        if (response_ready_mask_o != 0) begin
            $fatal(1, "bad response changed response-ready state");
        end
        $display("RTL8A_MSHR_RESPONSE_TAG_GUARD=PASS");

        /* Out-of-order entry 2 response completes before older entries. */
        send_response(2'd2, 12'h320, 1'b0, 1'b1, 32'h3200_0000);
        consume_completion(2'd2, 2'd3, 2'd3, 6'd13, 8'h55, 1'b0, 32'h3200_0000);
        if (occupancy_o != 3 || valid_mask_o[2]) begin
            $fatal(1, "completed entry 2 not reclaimed");
        end
        $display("RTL8A_MSHR_OUT_OF_ORDER_RESPONSE=PASS");
        $display("RTL8A_MSHR_ENTRY_REUSE=PASS");

        /* Allocate the previously blocked unique line into the reclaimed slot. */
        accept_request(12'h520, 2'd3, 2'd3, 6'd21, 8'h3C, 1'b0, 2'd2);

        /* Response for merged entry 0 enters completion drain. */
        send_response(2'd0, 12'h120, 1'b0, 1'b1, 32'h1200_0000);

        @(negedge clk);
        set_request_payload(12'h120, 2'd2, 2'd2, 6'd23, 8'hFF);
        req_valid_i = 1'b1;
        #1;
        if (req_ready_o || !req_blocked_draining_o) begin
            $fatal(1, "draining line allowed duplicate live entry");
        end
        clear_inputs();
        $display("RTL8A_MSHR_DRAINING_LINE_GUARD=PASS");

        consume_completion(2'd0, 2'd0, 2'd0, 6'd3, 8'h0F, 1'b0, 32'h1200_0000);
        if (!valid_mask_o[0]) begin
            $fatal(1, "entry freed before merged waiter drained");
        end
        consume_completion(2'd0, 2'd1, 2'd1, 6'd7, 8'hF0, 1'b0, 32'h1200_0000);
        if (valid_mask_o[0]) begin
            $fatal(1, "entry not freed after final waiter");
        end
        $display("RTL8A_MSHR_WAITER_DRAIN=PASS");

        /* Fault response still routes and reclaims the correct waiter. */
        send_response(2'd1, 12'h220, 1'b1, 1'b1, 32'hDEAD_0000);
        consume_completion(2'd1, 2'd1, 2'd1, 6'd19, 8'hC3, 1'b1, 32'h0);
        consume_completion(2'd1, 2'd2, 2'd2, 6'd11, 8'h33, 1'b1, 32'h0);
        if (valid_mask_o[1]) begin
            $fatal(1, "faulted entry not reclaimed");
        end
        $display("RTL8A_MSHR_FAULT_FANOUT=PASS");

        /* Entry 2 was allocated but not issued yet; issue and return same cycle. */
        @(negedge clk);
        clear_inputs();
        #1;
        if (!miss_req_valid_o || miss_req_entry_o != 2'd2 || miss_req_line_addr_o != 12'h520) begin
            $fatal(1, "entry 2 same-cycle issue candidate missing");
        end
        miss_req_ready_i = 1'b1;
        resp_valid_i = 1'b1;
        resp_entry_i = 2'd2;
        resp_line_addr_i = 12'h520;
        resp_fault_i = 1'b0;
        for (init_word = 0; init_word < LINE_WORDS; init_word = init_word + 1) begin
            resp_line_data_i[init_word] = 32'h5200_0000 + 32'(init_word);
        end
        #1;
        if (!resp_accept_o || resp_tag_error_o) begin
            $fatal(1, "same-cycle issue/response not accepted");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_inputs();
        consume_completion(2'd2, 2'd3, 2'd3, 6'd21, 8'h3C, 1'b0, 32'h5200_0000);
        $display("RTL8A_MSHR_SAME_CYCLE_ISSUE_RESPONSE=PASS");

        $display("RTL8A_MSHR_TABLE_TB=PASS");
        $finish;
    end

endmodule
