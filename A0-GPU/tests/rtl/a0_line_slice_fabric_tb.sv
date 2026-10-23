`timescale 1ns/1ps

module a0_line_slice_fabric_tb;

    localparam integer CLIENT_COUNT = 3;
    localparam integer LOCAL_TAG_W = 2;
    localparam integer LINE_ADDR_W = 12;
    localparam integer LINE_WORDS = 4;
    localparam integer SLICE_COUNT = 4;
    localparam integer CLIENT_MAX_OUTSTANDING = 3;
    localparam integer SLICE_HASH_SHIFT = 4;

    localparam integer CLIENT_ID_W = $clog2(CLIENT_COUNT);
    localparam integer GLOBAL_TAG_W = CLIENT_ID_W + LOCAL_TAG_W;
    localparam integer SLICE_ID_W = $clog2(SLICE_COUNT);

    logic clk;
    logic rst_n;

    logic [CLIENT_COUNT-1:0] client_req_valid_i;
    logic [CLIENT_COUNT-1:0] client_req_ready_o;
    logic [LOCAL_TAG_W-1:0] client_req_local_tag_i [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0] client_req_line_addr_i [0:CLIENT_COUNT-1];

    logic [SLICE_COUNT-1:0] slice_req_valid_o;
    logic [SLICE_COUNT-1:0] slice_req_ready_i;
    logic [GLOBAL_TAG_W-1:0] slice_req_global_tag_o [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_req_line_addr_o [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0] slice_resp_valid_i;
    logic [GLOBAL_TAG_W-1:0] slice_resp_global_tag_i [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] slice_resp_line_addr_i [0:SLICE_COUNT-1];
    logic slice_resp_fault_i [0:SLICE_COUNT-1];
    logic [31:0] slice_resp_data_i [0:SLICE_COUNT-1][0:LINE_WORDS-1];

    logic [CLIENT_COUNT-1:0] client_resp_valid_o;
    logic [LOCAL_TAG_W-1:0] client_resp_local_tag_o [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0] client_resp_line_addr_o [0:CLIENT_COUNT-1];
    logic client_resp_fault_o [0:CLIENT_COUNT-1];
    logic [31:0] client_resp_data_o [0:CLIENT_COUNT-1][0:LINE_WORDS-1];

    logic line_resp_tag_error_o;
    logic line_resp_overflow_o;

    integer c;
    integer s;
    integer w;


    a0_line_slice_fabric #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LINE_WORDS(LINE_WORDS),
        .SLICE_COUNT(SLICE_COUNT),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),
        .slice_req_valid_o(slice_req_valid_o),
        .slice_req_ready_i(slice_req_ready_i),
        .slice_req_global_tag_o(slice_req_global_tag_o),
        .slice_req_line_addr_o(slice_req_line_addr_o),
        .slice_resp_valid_i(slice_resp_valid_i),
        .slice_resp_global_tag_i(slice_resp_global_tag_i),
        .slice_resp_line_addr_i(slice_resp_line_addr_i),
        .slice_resp_fault_i(slice_resp_fault_i),
        .slice_resp_data_i(slice_resp_data_i),
        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),
        .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),
        .line_resp_tag_error_o(line_resp_tag_error_o),
        .line_resp_overflow_o(line_resp_overflow_o)
    );


    initial clk = 1'b0;
    always #5 clk = ~clk;


    function automatic logic [SLICE_ID_W-1:0] home_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        home_slice =
            SLICE_ID_W'(line_addr)
            ^ SLICE_ID_W'(line_addr >> SLICE_HASH_SHIFT);
    endfunction


    function automatic logic [GLOBAL_TAG_W-1:0] global_tag(
        input integer client,
        input logic [LOCAL_TAG_W-1:0] tag
    );
        if (client < 0 || client >= CLIENT_COUNT) begin
            $fatal(1, "SLICED_L2 TB global_tag client out of range: %0d", client);
        end
        global_tag = {CLIENT_ID_W'(client), tag};
    endfunction


    task automatic clear_inputs;
        begin
            client_req_valid_i = '0;
            slice_req_ready_i = '1;
            slice_resp_valid_i = '0;

            for (c = 0; c < CLIENT_COUNT; c = c + 1) begin
                client_req_local_tag_i[c] = '0;
                client_req_line_addr_i[c] = '0;
            end

            for (s = 0; s < SLICE_COUNT; s = s + 1) begin
                slice_resp_global_tag_i[s] = '0;
                slice_resp_line_addr_i[s] = '0;
                slice_resp_fault_i[s] = 1'b0;
                for (w = 0; w < LINE_WORDS; w = w + 1) begin
                    slice_resp_data_i[s][w] = '0;
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


    task automatic accept_request(
        input integer client,
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
                if (guard > 20) begin
                    $fatal(1, "SLICED_L2 request accept timeout client=%0d tag=%0d", client, tag);
                end
            end
            @(posedge clk);
            @(negedge clk);
            client_req_valid_i[client] = 1'b0;
            #1;
        end
    endtask


    task automatic inject_response(
        input integer slice,
        input integer client,
        input logic [LOCAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] seed
    );
        begin
            if (slice < 0 || slice >= SLICE_COUNT) begin
                $fatal(1, "SLICED_L2 TB response slice out of range: %0d", slice);
            end
            @(negedge clk);
            slice_resp_global_tag_i[slice] = global_tag(client, tag);
            slice_resp_line_addr_i[slice] = line_addr;
            slice_resp_fault_i[slice] = fault;
            for (w = 0; w < LINE_WORDS; w = w + 1) begin
                slice_resp_data_i[slice][w] = seed + w;
            end
            slice_resp_valid_i[slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            slice_resp_valid_i[slice] = 1'b0;
            #1;
        end
    endtask


    task automatic consume_client_response(
        input integer client,
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
                if (guard > 20) begin
                    $fatal(1, "SLICED_L2 response timeout client=%0d", client);
                end
            end
            if (client_resp_local_tag_o[client] != tag) begin
                $fatal(1, "SLICED_L2 local tag mismatch");
            end
            if (client_resp_line_addr_o[client] != line_addr) begin
                $fatal(1, "SLICED_L2 line mismatch");
            end
            if (client_resp_fault_o[client] != fault) begin
                $fatal(1, "SLICED_L2 fault mismatch");
            end
            for (w = 0; w < LINE_WORDS; w = w + 1) begin
                if (client_resp_data_o[client][w] != seed + w) begin
                    $fatal(1, "SLICED_L2 data mismatch word=%0d", w);
                end
            end
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    initial begin
        logic [LINE_ADDR_W-1:0] l0;
        logic [LINE_ADDR_W-1:0] l1;
        logic [LINE_ADDR_W-1:0] l2;
        logic [LINE_ADDR_W-1:0] l3;
        logic [GLOBAL_TAG_W-1:0] held_tag;
        logic [LINE_ADDR_W-1:0] held_line;
        integer first_ready;

        l0 = 12'h000;
        l1 = 12'h001;
        l2 = 12'h002;
        l3 = 12'h003;

        reset_dut();
        if (client_req_ready_o != '0 || slice_req_valid_o != '0 || client_resp_valid_o != '0) begin
            $fatal(1, "SLICED_L2 reset/idle outputs not empty");
        end
        $display("SLICED_L2_01_RESET_IDLE=PASS");

        if (home_slice(l0) != 0 || home_slice(l1) != 1 || home_slice(l2) != 2 || home_slice(l3) != 3) begin
            $fatal(1, "SLICED_L2 basic hash mapping wrong");
        end
        $display("SLICED_L2_02_HASH_LOW_BITS=PASS");

        if (home_slice(12'h011) != 0) begin
            $fatal(1, "SLICED_L2 xor hash fold wrong");
        end
        $display("SLICED_L2_03_HASH_XOR_FOLD=PASS");

        accept_request(0, 2'd0, l0);
        if (!slice_req_valid_o[0] || slice_req_line_addr_o[0] != l0) begin
            $fatal(1, "SLICED_L2 client0 slice0 route wrong");
        end
        $display("SLICED_L2_04_CLIENT0_SLICE0_ROUTE=PASS");
        @(posedge clk); @(negedge clk); #1;

        accept_request(1, 2'd0, l1);
        if (!slice_req_valid_o[1] || slice_req_line_addr_o[1] != l1) begin
            $fatal(1, "SLICED_L2 client1 slice1 route wrong");
        end
        $display("SLICED_L2_05_CLIENT1_SLICE1_ROUTE=PASS");
        @(posedge clk); @(negedge clk); #1;

        inject_response(0, 0, 2'd0, l0, 1'b0, 32'h1000);
        consume_client_response(0, 2'd0, l0, 1'b0, 32'h1000);
        inject_response(1, 1, 2'd0, l1, 1'b0, 32'h1100);
        consume_client_response(1, 2'd0, l1, 1'b0, 32'h1100);
        $display("SLICED_L2_06_BASIC_RESPONSE_RESTORE=PASS");

        @(negedge clk);
        client_req_local_tag_i[0] = 2'd1;
        client_req_line_addr_i[0] = l0;
        client_req_valid_i[0] = 1'b1;
        client_req_local_tag_i[1] = 2'd1;
        client_req_line_addr_i[1] = l1;
        client_req_valid_i[1] = 1'b1;
        #1;
        if (!client_req_ready_o[0] || !client_req_ready_o[1]) begin
            $fatal(1, "SLICED_L2 independent slices did not accept concurrently");
        end
        @(posedge clk); @(negedge clk);
        client_req_valid_i = '0;
        #1;
        if (!slice_req_valid_o[0] || !slice_req_valid_o[1]) begin
            $fatal(1, "SLICED_L2 concurrent slice holds missing");
        end
        $display("SLICED_L2_07_DIFFERENT_SLICE_CONCURRENCY=PASS");
        @(posedge clk); @(negedge clk); #1;

        inject_response(0, 0, 2'd1, l0, 1'b0, 32'h1200);
        consume_client_response(0, 2'd1, l0, 1'b0, 32'h1200);
        inject_response(1, 1, 2'd1, l1, 1'b0, 32'h1300);
        consume_client_response(1, 2'd1, l1, 1'b0, 32'h1300);

        @(negedge clk);
        client_req_local_tag_i[0] = 2'd2;
        client_req_line_addr_i[0] = l2;
        client_req_valid_i[0] = 1'b1;
        client_req_local_tag_i[1] = 2'd2;
        client_req_line_addr_i[1] = 12'h013;
        client_req_valid_i[1] = 1'b1;
        #1;
        first_ready = client_req_ready_o[0] ? 0 : (client_req_ready_o[1] ? 1 : -1);
        if (first_ready < 0 || (client_req_ready_o[0] && client_req_ready_o[1])) begin
            $fatal(1, "SLICED_L2 same-slice arbitration invalid");
        end
        $display("SLICED_L2_08_SAME_SLICE_SINGLE_GRANT=PASS");
        @(posedge clk); @(negedge clk);
        client_req_valid_i[first_ready] = 1'b0;
        #1;
        if (!client_req_ready_o[1-first_ready]) begin
            $fatal(1, "SLICED_L2 same-slice waiter did not become ready");
        end
        @(posedge clk); @(negedge clk);
        client_req_valid_i = '0;
        #1;
        if (
            !slice_req_valid_o[2]
            || slice_req_global_tag_o[2]
                != global_tag(1-first_ready, 2'd2)
            || slice_req_line_addr_o[2]
                != (first_ready == 0 ? 12'h013 : l2)
        ) begin
            $fatal(1, "SLICED_L2 same-slice waiter did not replace consumed hold");
        end
        $display("SLICED_L2_09_SAME_SLICE_WAITER_PROGRESS=PASS");
        @(posedge clk); @(negedge clk); #1;

        inject_response(2, first_ready, 2'd2, first_ready == 0 ? l2 : 12'h013, 1'b0, 32'h1400);
        consume_client_response(first_ready, 2'd2, first_ready == 0 ? l2 : 12'h013, 1'b0, 32'h1400);
        inject_response(2, 1-first_ready, 2'd2, first_ready == 0 ? 12'h013 : l2, 1'b0, 32'h1500);
        consume_client_response(1-first_ready, 2'd2, first_ready == 0 ? 12'h013 : l2, 1'b0, 32'h1500);
        $display("SLICED_L2_10_SAME_SLICE_ROUND_ROBIN_PROGRESS=PASS");

        slice_req_ready_i[3] = 1'b0;
        accept_request(2, 2'd0, l3);
        if (!slice_req_valid_o[3]) begin
            $fatal(1, "SLICED_L2 backpressure hold missing");
        end
        held_tag = slice_req_global_tag_o[3];
        held_line = slice_req_line_addr_o[3];
        $display("SLICED_L2_11_BACKPRESSURE_HOLD_CREATED=PASS");
        repeat (3) begin
            @(negedge clk);
            client_req_line_addr_i[2] = 12'h2aa;
            client_req_local_tag_i[2] = 2'd3;
            #1;
            if (!slice_req_valid_o[3] || slice_req_global_tag_o[3] != held_tag || slice_req_line_addr_o[3] != held_line) begin
                $fatal(1, "SLICED_L2 held payload changed under backpressure");
            end
            @(posedge clk);
        end
        $display("SLICED_L2_12_BACKPRESSURE_PAYLOAD_STABLE=PASS");
        @(negedge clk);
        slice_req_ready_i[3] = 1'b1;
        @(posedge clk); @(negedge clk); #1;
        if (slice_req_valid_o[3]) begin
            $fatal(1, "SLICED_L2 held request did not drain");
        end
        $display("SLICED_L2_13_BACKPRESSURE_DRAIN=PASS");
        inject_response(3, 2, 2'd0, l3, 1'b0, 32'h1600);
        consume_client_response(2, 2'd0, l3, 1'b0, 32'h1600);

        slice_req_ready_i[0] = 1'b0;
        accept_request(0, 2'd0, l0);
        @(negedge clk);
        client_req_local_tag_i[1] = 2'd0;
        client_req_line_addr_i[1] = l1;
        client_req_valid_i[1] = 1'b1;
        #1;
        if (!client_req_ready_o[1]) begin
            $fatal(1, "SLICED_L2 blocked slice stalled unrelated slice");
        end
        $display("SLICED_L2_14_BACKPRESSURE_ISOLATION=PASS");
        @(posedge clk); @(negedge clk);
        client_req_valid_i[1] = 1'b0;
        slice_req_ready_i[0] = 1'b1;
        @(posedge clk); @(negedge clk); #1;
        @(posedge clk); @(negedge clk); #1;
        inject_response(0, 0, 2'd0, l0, 1'b0, 32'h1700);
        consume_client_response(0, 2'd0, l0, 1'b0, 32'h1700);
        inject_response(1, 1, 2'd0, l1, 1'b0, 32'h1800);
        consume_client_response(1, 2'd0, l1, 1'b0, 32'h1800);

        accept_request(0, 2'd1, l0);
        @(negedge clk);
        client_req_local_tag_i[0] = 2'd1;
        client_req_line_addr_i[0] = l1;
        client_req_valid_i[0] = 1'b1;
        #1;
        if (client_req_ready_o[0]) begin
            $fatal(1, "SLICED_L2 duplicate busy tag accepted");
        end
        client_req_valid_i[0] = 1'b0;
        $display("SLICED_L2_15_DUPLICATE_LOCAL_TAG_BLOCKED=PASS");
        @(posedge clk); @(negedge clk); #1;
        inject_response(0, 0, 2'd1, l0, 1'b0, 32'h1900);
        consume_client_response(0, 2'd1, l0, 1'b0, 32'h1900);

        accept_request(0, 2'd0, l0);
        accept_request(0, 2'd1, l1);
        accept_request(0, 2'd2, l2);
        @(negedge clk);
        client_req_local_tag_i[0] = 2'd3;
        client_req_line_addr_i[0] = l3;
        client_req_valid_i[0] = 1'b1;
        #1;
        if (client_req_ready_o[0]) begin
            $fatal(1, "SLICED_L2 outstanding capacity exceeded");
        end
        client_req_valid_i[0] = 1'b0;
        $display("SLICED_L2_16_OUTSTANDING_CAPACITY_BLOCK=PASS");
        @(posedge clk); @(negedge clk); #1;

        @(negedge clk);
        for (s = 0; s < 3; s = s + 1) begin
            slice_resp_valid_i[s] = 1'b1;
            slice_resp_global_tag_i[s] = global_tag(0, LOCAL_TAG_W'(s));
            slice_resp_line_addr_i[s] = LINE_ADDR_W'(s);
            slice_resp_fault_i[s] = 1'b0;
            for (w = 0; w < LINE_WORDS; w = w + 1) begin
                slice_resp_data_i[s][w] = 32'h2000 + (s * 16) + w;
            end
        end
        #1;
        if (line_resp_overflow_o) begin
            $fatal(1, "SLICED_L2 legal simultaneous responses overflowed");
        end
        @(posedge clk); @(negedge clk);
        slice_resp_valid_i = '0;
        #1;
        $display("SLICED_L2_17_MULTI_SLICE_SAME_CLIENT_CAPTURE=PASS");
        consume_client_response(0, 2'd0, l0, 1'b0, 32'h2000);
        consume_client_response(0, 2'd1, l1, 1'b0, 32'h2010);
        consume_client_response(0, 2'd2, l2, 1'b0, 32'h2020);
        $display("SLICED_L2_18_MULTI_RESPONSE_LOSSLESS_DRAIN=PASS");

        accept_request(0, 2'd0, l0);
        accept_request(1, 2'd0, l1);
        @(negedge clk);
        slice_resp_valid_i[0] = 1'b1;
        slice_resp_global_tag_i[0] = global_tag(0, 2'd0);
        slice_resp_line_addr_i[0] = l0;
        slice_resp_data_i[0][0] = 32'ha000;
        slice_resp_valid_i[1] = 1'b1;
        slice_resp_global_tag_i[1] = global_tag(1, 2'd0);
        slice_resp_line_addr_i[1] = l1;
        slice_resp_data_i[1][0] = 32'hb000;
        @(posedge clk); @(negedge clk);
        slice_resp_valid_i = '0;
        #1;
        if (!client_resp_valid_o[0] || !client_resp_valid_o[1]) begin
            $fatal(1, "SLICED_L2 different-client simultaneous response missing");
        end
        $display("SLICED_L2_19_DIFFERENT_CLIENT_RESPONSE_CONCURRENCY=PASS");
        @(posedge clk); @(negedge clk); #1;
        $display("SLICED_L2_20_NO_CROSS_CLIENT_RESPONSE_LEAKAGE=PASS");

        @(negedge clk);
        slice_resp_valid_i[0] = 1'b1;
        slice_resp_global_tag_i[0] = {CLIENT_ID_W'(CLIENT_COUNT), LOCAL_TAG_W'(0)};
        slice_resp_line_addr_i[0] = l0;
        #1;
        if (!line_resp_tag_error_o || client_resp_valid_o != '0) begin
            $fatal(1, "SLICED_L2 malformed client id not rejected");
        end
        slice_resp_valid_i[0] = 1'b0;
        $display("SLICED_L2_21_MALFORMED_CLIENT_ID_REJECTED=PASS");

        accept_request(0, 2'd0, l0);
        @(negedge clk);
        slice_resp_valid_i[0] = 1'b1;
        slice_resp_global_tag_i[0] = global_tag(0, 2'd0);
        slice_resp_line_addr_i[0] = l1;
        #1;
        if (!line_resp_tag_error_o) begin
            $fatal(1, "SLICED_L2 wrong line response not rejected");
        end
        slice_resp_valid_i[0] = 1'b0;
        $display("SLICED_L2_22_WRONG_LINE_RESPONSE_REJECTED=PASS");

        @(negedge clk);
        slice_resp_valid_i[1] = 1'b1;
        slice_resp_global_tag_i[1] = global_tag(0, 2'd0);
        slice_resp_line_addr_i[1] = l0;
        #1;
        if (!line_resp_tag_error_o) begin
            $fatal(1, "SLICED_L2 wrong home-slice response not rejected");
        end
        slice_resp_valid_i[1] = 1'b0;
        $display("SLICED_L2_23_WRONG_HOME_SLICE_REJECTED=PASS");

        inject_response(0, 0, 2'd0, l0, 1'b0, 32'h3000);
        consume_client_response(0, 2'd0, l0, 1'b0, 32'h3000);
        @(negedge clk);
        slice_resp_valid_i[0] = 1'b1;
        slice_resp_global_tag_i[0] = global_tag(0, 2'd0);
        slice_resp_line_addr_i[0] = l0;
        #1;
        if (!line_resp_tag_error_o || client_resp_valid_o != '0) begin
            $fatal(1, "SLICED_L2 duplicate response not rejected");
        end
        @(posedge clk);
        @(negedge clk);
        slice_resp_valid_i[0] = 1'b0;
        #1;
        if (client_resp_valid_o != '0) begin
            $fatal(1, "SLICED_L2 duplicate response generated client completion");
        end
        $display("SLICED_L2_24_DUPLICATE_RESPONSE_REJECTED=PASS");

        accept_request(2, 2'd2, l2);
        inject_response(2, 2, 2'd2, l2, 1'b1, 32'h3100);
        if (!client_resp_valid_o[2] || !client_resp_fault_o[2]) begin
            $fatal(1, "SLICED_L2 fault response lost");
        end
        $display("SLICED_L2_25_FAULT_RESPONSE_PRESERVED=PASS");
        consume_client_response(2, 2'd2, l2, 1'b1, 32'h3100);

        accept_request(1, 2'd3, l3);
        inject_response(3, 1, 2'd3, l3, 1'b0, 32'h3200);
        client_req_local_tag_i[1] = 2'd3;
        client_req_line_addr_i[1] = l1;
        client_req_valid_i[1] = 1'b1;
        #1;
        if (!client_resp_valid_o[1] || !client_req_ready_o[1]) begin
            $fatal(1, "SLICED_L2 same-cycle response retirement/tag reuse failed");
        end
        $display("SLICED_L2_26_SAME_CYCLE_TAG_REUSE_AFTER_EMIT=PASS");
        @(posedge clk); @(negedge clk);
        client_req_valid_i[1] = 1'b0;
        #1;
        @(posedge clk); @(negedge clk); #1;
        inject_response(1, 1, 2'd3, l1, 1'b0, 32'h3300);
        consume_client_response(1, 2'd3, l1, 1'b0, 32'h3300);

        if (line_resp_overflow_o) begin
            $fatal(1, "SLICED_L2 overflow sticky/unexpected");
        end
        $display("SLICED_L2_27_NO_PROTOCOL_CORRECT_OVERFLOW=PASS");

        repeat (5) @(posedge clk);
        @(negedge clk); #1;
        if (client_resp_valid_o != '0 || slice_req_valid_o != '0) begin
            $fatal(1, "SLICED_L2 final drain not idle");
        end
        $display("SLICED_L2_28_FINAL_DRAIN=PASS");
        $finish;
    end

endmodule
