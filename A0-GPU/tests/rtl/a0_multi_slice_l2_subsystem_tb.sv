`timescale 1ns/1ps

module a0_multi_slice_l2_subsystem_tb;

    localparam integer CLIENT_COUNT = 2;
    localparam integer LOCAL_TAG_W = 2;
    localparam integer STORE_LANES_PER_CLIENT = 2;
    localparam integer LINE_WORDS = 4;
    localparam integer L2_SLICE_COUNT = 2;
    localparam integer L2_SET_COUNT_PER_SLICE = 4;
    localparam integer L2_MISS_COUNT_PER_SLICE = 2;
    localparam integer CLIENT_MAX_OUTSTANDING = 2;

    localparam integer CLIENT_ID_W = 1;
    localparam integer GLOBAL_TAG_W = CLIENT_ID_W + LOCAL_TAG_W;
    localparam integer WORD_SELECT_W = $clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W = 32 - WORD_SELECT_W;
    localparam integer SLICE_HASH_SHIFT = $clog2(L2_SET_COUNT_PER_SLICE);

    logic clk;
    logic rst_n;

    logic [CLIENT_COUNT-1:0] client_req_valid_i;
    logic [CLIENT_COUNT-1:0] client_req_ready_o;
    logic [LOCAL_TAG_W-1:0] client_req_local_tag_i [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0] client_req_line_addr_i [0:CLIENT_COUNT-1];

    logic [CLIENT_COUNT-1:0] client_resp_valid_o;
    logic [LOCAL_TAG_W-1:0] client_resp_local_tag_o [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0] client_resp_line_addr_o [0:CLIENT_COUNT-1];
    logic client_resp_fault_o [0:CLIENT_COUNT-1];
    logic [31:0] client_resp_data_o [0:CLIENT_COUNT-1][0:LINE_WORDS-1];

    logic [CLIENT_COUNT-1:0] client_store_valid_i;
    logic [STORE_LANES_PER_CLIENT-1:0] client_store_lane_mask_i [0:CLIENT_COUNT-1];
    logic [31:0] client_store_word_addr_i [0:CLIENT_COUNT-1][0:STORE_LANES_PER_CLIENT-1];

    logic [L2_SLICE_COUNT-1:0] line_mem_req_valid_o;
    logic [L2_SLICE_COUNT-1:0] line_mem_req_ready_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o [0:L2_SLICE_COUNT-1];

    logic [L2_SLICE_COUNT-1:0] line_mem_resp_valid_i;
    logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i [0:L2_SLICE_COUNT-1];
    logic line_mem_resp_fault_i [0:L2_SLICE_COUNT-1];
    logic [31:0] line_mem_resp_data_i [0:L2_SLICE_COUNT-1][0:LINE_WORDS-1];

    logic line_resp_tag_error_o;
    logic line_resp_overflow_o;

    integer c;
    integer s;
    integer w;


    a0_multi_slice_l2_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .STORE_LANES_PER_CLIENT(STORE_LANES_PER_CLIENT),
        .LINE_WORDS(LINE_WORDS),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .L2_SET_COUNT_PER_SLICE(L2_SET_COUNT_PER_SLICE),
        .L2_MISS_COUNT_PER_SLICE(L2_MISS_COUNT_PER_SLICE),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),
        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),
        .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .client_store_valid_i(client_store_valid_i),
        .client_store_lane_mask_i(client_store_lane_mask_i),
        .client_store_word_addr_i(client_store_word_addr_i),
        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_global_tag_o(line_mem_req_global_tag_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_global_tag_i(line_mem_resp_global_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i),
        .line_resp_tag_error_o(line_resp_tag_error_o),
        .line_resp_overflow_o(line_resp_overflow_o)
    );


    initial clk = 1'b0;
    always #5 clk = ~clk;


    function automatic integer home_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic low_bit;
        logic high_bit;
        begin
            low_bit = line_addr[0];
            high_bit = line_addr[SLICE_HASH_SHIFT];
            home_slice = integer'({31'b0, (low_bit ^ high_bit)});
        end
    endfunction


    task automatic clear_inputs;
        begin
            client_req_valid_i = '0;
            client_store_valid_i = '0;
            line_mem_req_ready_i = '1;
            line_mem_resp_valid_i = '0;

            for (c = 0; c < CLIENT_COUNT; c = c + 1) begin
                client_req_local_tag_i[c] = '0;
                client_req_line_addr_i[c] = '0;
                client_store_lane_mask_i[c] = '0;
                for (w = 0; w < STORE_LANES_PER_CLIENT; w = w + 1) begin
                    client_store_word_addr_i[c][w] = '0;
                end
            end

            for (s = 0; s < L2_SLICE_COUNT; s = s + 1) begin
                line_mem_resp_global_tag_i[s] = '0;
                line_mem_resp_line_addr_i[s] = '0;
                line_mem_resp_fault_i[s] = 1'b0;
                for (w = 0; w < LINE_WORDS; w = w + 1) begin
                    line_mem_resp_data_i[s][w] = '0;
                end
            end
        end
    endtask


    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            clear_inputs();
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask


    task automatic launch_request(
        input logic [CLIENT_ID_W-1:0] client,
        input logic [LOCAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer guard;
        begin
            @(negedge clk);
            client_req_local_tag_i[client] = tag;
            client_req_line_addr_i[client] = line_addr;
            client_req_valid_i[client] = 1'b1;
            guard = 0;
            #1;
            while (!client_req_ready_o[client]) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 30) begin
                    $fatal(1, "SLICED_L2_SUBSYSTEM client request timeout");
                end
            end
            @(posedge clk);
            @(negedge clk);
            client_req_valid_i[client] = 1'b0;
            #1;
        end
    endtask


    task automatic wait_mem_request(
        input integer expected_slice,
        input logic [LINE_ADDR_W-1:0] expected_line,
        output logic [GLOBAL_TAG_W-1:0] captured_tag
    );
        integer guard;
        begin
            guard = 0;
            while (!line_mem_req_valid_o[expected_slice]) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 30) begin
                    $fatal(1, "SLICED_L2_SUBSYSTEM memory request timeout slice=%0d", expected_slice);
                end
            end
            if (line_mem_req_line_addr_o[expected_slice] != expected_line) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM memory request line mismatch");
            end
            captured_tag = line_mem_req_global_tag_o[expected_slice];
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic memory_response(
        input logic slice,
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] seed
    );
        begin
            @(negedge clk);
            line_mem_resp_global_tag_i[slice] = tag;
            line_mem_resp_line_addr_i[slice] = line_addr;
            line_mem_resp_fault_i[slice] = fault;
            for (w = 0; w < LINE_WORDS; w = w + 1) begin
                line_mem_resp_data_i[slice][w] = seed + w;
            end
            line_mem_resp_valid_i[slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i[slice] = 1'b0;
            #1;
        end
    endtask


    task automatic consume_response(
        input logic [CLIENT_ID_W-1:0] client,
        input logic [LOCAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] seed
    );
        integer guard;
        begin
            guard = 0;
            while (!client_resp_valid_o[client]) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 30) begin
                    $fatal(1, "SLICED_L2_SUBSYSTEM client response timeout");
                end
            end
            if (
                client_resp_local_tag_o[client] != tag
                || client_resp_line_addr_o[client] != line_addr
                || client_resp_fault_o[client] != fault
            ) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM response metadata mismatch");
            end
            for (w = 0; w < LINE_WORDS; w = w + 1) begin
                if (client_resp_data_o[client][w] != seed + w) begin
                    $fatal(1, "SLICED_L2_SUBSYSTEM response data mismatch");
                end
            end
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic observe_store(
        input logic [CLIENT_ID_W-1:0] client,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer expected_slice;
        begin
            expected_slice = home_slice(line_addr);
            @(negedge clk);
            client_store_valid_i[client] = 1'b1;
            client_store_lane_mask_i[client] = '0;
            client_store_lane_mask_i[client][0] = 1'b1;
            client_store_word_addr_i[client][0] =
                32'(line_addr) << WORD_SELECT_W;
            #1;
            if (!dut.slice_store_valid[expected_slice]) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM home slice did not observe store");
            end
            if (dut.slice_store_valid[1-expected_slice]) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM unrelated slice observed store");
            end
            @(posedge clk);
            @(negedge clk);
            client_store_valid_i[client] = 1'b0;
            client_store_lane_mask_i[client] = '0;
            #1;
        end
    endtask


    initial begin
        logic [GLOBAL_TAG_W-1:0] t0;
        logic [GLOBAL_TAG_W-1:0] t1;
        logic [GLOBAL_TAG_W-1:0] t2;
        logic [GLOBAL_TAG_W-1:0] t3;
        logic [LINE_ADDR_W-1:0] line0;
        logic [LINE_ADDR_W-1:0] line1;
        logic [LINE_ADDR_W-1:0] line4;
        logic [LINE_ADDR_W-1:0] line5;
        integer guard;

        line0 = LINE_ADDR_W'(0);
        line1 = LINE_ADDR_W'(1);
        line4 = LINE_ADDR_W'(4);
        line5 = LINE_ADDR_W'(5);

        reset_dut();
        if (home_slice(line0) != 0 || home_slice(line1) != 1 || home_slice(line4) != 1 || home_slice(line5) != 0) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM hash expectation mismatch");
        end

        launch_request(0, 2'd0, line0);
        wait_mem_request(0, line0, t0);
        $display("SLICED_L2_29_COLD_MISS_SLICE0=PASS");
        memory_response(0, t0, line0, 1'b0, 32'h4000);
        consume_response(0, 2'd0, line0, 1'b0, 32'h4000);
        $display("SLICED_L2_30_REFILL_RESPONSE_RESTORED=PASS");

        launch_request(1, 2'd0, line1);
        wait_mem_request(1, line1, t1);
        $display("SLICED_L2_31_COLD_MISS_SLICE1=PASS");
        memory_response(1, t1, line1, 1'b0, 32'h4100);
        consume_response(1, 2'd0, line1, 1'b0, 32'h4100);

        launch_request(0, 2'd1, line0);
        guard = 0;
        while (!client_resp_valid_o[0]) begin
            if (line_mem_req_valid_o != '0) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM L2 hit unexpectedly reached backend");
            end
            @(negedge clk);
            guard = guard + 1;
            if (guard > 20) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM hit response timeout");
            end
        end
        if (client_resp_data_o[0][0] != 32'h4000) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM hit data mismatch");
        end
        $display("SLICED_L2_32_L2_HIT_SUPPRESSES_BACKEND=PASS");
        consume_response(0, 2'd1, line0, 1'b0, 32'h4000);

        fork
            launch_request(0, 2'd0, line5);
            launch_request(1, 2'd0, line4);
        join
        guard = 0;
        while (!(line_mem_req_valid_o[0] && line_mem_req_valid_o[1])) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 30) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM independent misses not concurrently visible");
            end
        end
        t2 = line_mem_req_global_tag_o[0];
        t3 = line_mem_req_global_tag_o[1];
        if (line_mem_req_line_addr_o[0] != line5 || line_mem_req_line_addr_o[1] != line4) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM concurrent miss routes wrong");
        end
        $display("SLICED_L2_33_DIFFERENT_SLICE_MISS_CONCURRENCY=PASS");
        @(posedge clk); @(negedge clk); #1;

        memory_response(1, t3, line4, 1'b0, 32'h4300);
        consume_response(1, 2'd0, line4, 1'b0, 32'h4300);
        memory_response(0, t2, line5, 1'b0, 32'h4200);
        consume_response(0, 2'd0, line5, 1'b0, 32'h4200);
        $display("SLICED_L2_34_OOO_RESPONSES_ACROSS_SLICES=PASS");
        $display("SLICED_L2_35_INDEPENDENT_BACKEND_PORTS=PASS");

        observe_store(0, line0);
        $display("SLICED_L2_36_STORE_ROUTED_TO_HOME_SLICE_ONLY=PASS");

        launch_request(0, 2'd0, line0);
        wait_mem_request(0, line0, t0);
        $display("SLICED_L2_37_STORE_INVALIDATES_RESIDENT_HOME_LINE=PASS");
        memory_response(0, t0, line0, 1'b0, 32'h4400);
        consume_response(0, 2'd0, line0, 1'b0, 32'h4400);

        launch_request(1, 2'd1, line4);
        guard = 0;
        while (!client_resp_valid_o[1]) begin
            if (line_mem_req_valid_o[1]) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM unrelated slice line was invalidated");
            end
            @(negedge clk);
            guard = guard + 1;
            if (guard > 20) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM unrelated cached hit timeout");
            end
        end
        if (client_resp_data_o[1][0] != 32'h4300) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM unrelated slice cached data changed");
        end
        $display("SLICED_L2_38_UNRELATED_SLICE_UNAFFECTED_BY_STORE=PASS");
        consume_response(1, 2'd1, line4, 1'b0, 32'h4300);

        launch_request(0, 2'd0, line5 + 2);
        wait_mem_request(home_slice(line5 + 2), line5 + 2, t0);
        observe_store(1, line5 + 2);
        memory_response(logic'(home_slice(line5 + 2)), t0, line5 + 2, 1'b0, 32'h4500);
        consume_response(0, 2'd0, line5 + 2, 1'b0, 32'h4500);
        launch_request(0, 2'd1, line5 + 2);
        wait_mem_request(home_slice(line5 + 2), line5 + 2, t1);
        $display("SLICED_L2_39_STORE_KILLS_MATCHING_REFILL_INSTALL=PASS");
        memory_response(logic'(home_slice(line5 + 2)), t1, line5 + 2, 1'b0, 32'h4510);
        consume_response(0, 2'd1, line5 + 2, 1'b0, 32'h4510);

        launch_request(0, 2'd0, line0 + 8);
        wait_mem_request(home_slice(line0 + 8), line0 + 8, t0);
        @(negedge clk);
        client_store_valid_i[0] = 1'b1;
        client_store_lane_mask_i[0][0] = 1'b1;
        client_store_word_addr_i[0][0] = 32'(line0 + 8) << WORD_SELECT_W;
        line_mem_resp_valid_i[home_slice(line0 + 8)] = 1'b1;
        line_mem_resp_global_tag_i[home_slice(line0 + 8)] = t0;
        line_mem_resp_line_addr_i[home_slice(line0 + 8)] = line0 + 8;
        line_mem_resp_fault_i[home_slice(line0 + 8)] = 1'b0;
        for (w = 0; w < LINE_WORDS; w = w + 1) begin
            line_mem_resp_data_i[home_slice(line0 + 8)][w] = 32'h4600 + w;
        end
        @(posedge clk); @(negedge clk);
        client_store_valid_i = '0;
        client_store_lane_mask_i[0] = '0;
        line_mem_resp_valid_i = '0;
        #1;
        consume_response(0, 2'd0, line0 + 8, 1'b0, 32'h4600);
        launch_request(0, 2'd1, line0 + 8);
        wait_mem_request(home_slice(line0 + 8), line0 + 8, t1);
        $display("SLICED_L2_40_SAME_CYCLE_STORE_REFILL_NOT_INSTALLED=PASS");
        memory_response(logic'(home_slice(line0 + 8)), t1, line0 + 8, 1'b0, 32'h4610);
        consume_response(0, 2'd1, line0 + 8, 1'b0, 32'h4610);

        launch_request(1, 2'd0, line1 + 8);
        wait_mem_request(home_slice(line1 + 8), line1 + 8, t0);
        memory_response(logic'(home_slice(line1 + 8)), t0, line1 + 8, 1'b1, 32'h4700);
        consume_response(1, 2'd0, line1 + 8, 1'b1, 32'h4700);
        launch_request(1, 2'd1, line1 + 8);
        wait_mem_request(home_slice(line1 + 8), line1 + 8, t1);
        $display("SLICED_L2_41_FAULTED_REFILL_NOT_INSTALLED=PASS");
        memory_response(logic'(home_slice(line1 + 8)), t1, line1 + 8, 1'b0, 32'h4710);
        consume_response(1, 2'd1, line1 + 8, 1'b0, 32'h4710);

        line_mem_req_ready_i[0] = 1'b0;
        launch_request(0, 2'd0, line0 + 16);
        launch_request(1, 2'd0, line1 + 16);
        guard = 0;
        while (!line_mem_req_valid_o[1]) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 30) begin
                $fatal(1, "SLICED_L2_SUBSYSTEM slice1 blocked by slice0 backend stall");
            end
        end
        t1 = line_mem_req_global_tag_o[1];
        $display("SLICED_L2_42_BACKEND_BACKPRESSURE_ISOLATED_PER_SLICE=PASS");
        @(posedge clk); @(negedge clk); #1;
        memory_response(1, t1, line1 + 16, 1'b0, 32'h4800);
        consume_response(1, 2'd0, line1 + 16, 1'b0, 32'h4800);
        line_mem_req_ready_i[0] = 1'b1;
        wait_mem_request(0, line0 + 16, t0);
        $display("SLICED_L2_43_STALLED_SLICE_EVENTUALLY_DRAINS=PASS");
        memory_response(0, t0, line0 + 16, 1'b0, 32'h4810);
        consume_response(0, 2'd0, line0 + 16, 1'b0, 32'h4810);

        repeat (6) @(posedge clk);
        @(negedge clk); #1;
        if (client_resp_valid_o != '0 || line_mem_req_valid_o != '0) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM final drain not idle");
        end
        if (line_resp_tag_error_o || line_resp_overflow_o) begin
            $fatal(1, "SLICED_L2_SUBSYSTEM unexpected response error");
        end
        $display("SLICED_L2_44_FINAL_DRAIN_NO_LOSS=PASS");
        $display("SLICED_L2_45_MULTI_SLICE_L2_SUBSYSTEM=PASS");
        $finish;
    end

endmodule
