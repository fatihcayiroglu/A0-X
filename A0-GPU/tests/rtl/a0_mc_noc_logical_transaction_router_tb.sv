`timescale 1ns/1ps

module a0_mc_noc_logical_transaction_router_tb #(
    parameter integer CLUSTER_COUNT = 3,
    parameter integer CUS_PER_CLUSTER = 3,
    parameter integer MSHR_COUNT = 3,
    parameter integer LINE_WORDS = 8,
    parameter integer SLICE_COUNT = 4,
    parameter integer SLICE_HASH_SHIFT = 8,
    parameter integer FULL_SCENARIOS = 1
);

    localparam integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W = 32 - WORD_SELECT_W;
    localparam integer CLUSTER_ID_W =
        (CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT);
    localparam integer CU_ID_W =
        (CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER);
    localparam integer LOCAL_TAG_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT);
    localparam integer CLUSTER_LOCAL_TAG_W = CU_ID_W + LOCAL_TAG_W;
    localparam integer NETWORK_TAG_W =
        CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W;
    localparam integer SLICE_ID_W =
        (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT);
`ifdef MC_NOC_P2_FULL
    localparam integer CLUSTER_MAX_OUTSTANDING =
        CUS_PER_CLUSTER * MSHR_COUNT;
`endif

    logic clk;
    logic rst_n;

    logic [CLUSTER_COUNT-1:0] cluster_req_valid_i;
    logic [CLUSTER_COUNT-1:0] cluster_req_ready_o;
    logic [NETWORK_TAG_W-1:0]
        cluster_req_network_tag_i [0:CLUSTER_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        cluster_req_line_addr_i [0:CLUSTER_COUNT-1];
    logic [CLUSTER_COUNT-1:0] cluster_req_tag_error_o;

    logic [SLICE_COUNT-1:0] slice_req_valid_o;
    logic [SLICE_COUNT-1:0] slice_req_ready_i;
    logic [NETWORK_TAG_W-1:0]
        slice_req_network_tag_o [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        slice_req_line_addr_o [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0] slice_resp_valid_i;
    logic [NETWORK_TAG_W-1:0]
        slice_resp_network_tag_i [0:SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        slice_resp_line_addr_i [0:SLICE_COUNT-1];
    logic slice_resp_fault_i [0:SLICE_COUNT-1];
    logic [31:0] slice_resp_data_i
        [0:SLICE_COUNT-1]
        [0:LINE_WORDS-1];
    logic [SLICE_COUNT-1:0] slice_resp_protocol_error_o;

    logic [CLUSTER_COUNT-1:0] cluster_resp_valid_o;
    logic [CLUSTER_COUNT-1:0] cluster_resp_ready_i;
    logic [NETWORK_TAG_W-1:0]
        cluster_resp_network_tag_o [0:CLUSTER_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        cluster_resp_line_addr_o [0:CLUSTER_COUNT-1];
    logic cluster_resp_fault_o [0:CLUSTER_COUNT-1];
    logic [31:0] cluster_resp_data_o
        [0:CLUSTER_COUNT-1]
        [0:LINE_WORDS-1];

`ifdef MC_NOC_P2_FULL
    logic [NETWORK_TAG_W-1:0] final_tag [0:5];
    logic [LINE_ADDR_W-1:0] final_line [0:5];
    integer final_seed [0:5];
`endif


    a0_mc_noc_logical_transaction_router #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .SLICE_COUNT(SLICE_COUNT),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_req_valid_i(cluster_req_valid_i),
        .cluster_req_ready_o(cluster_req_ready_o),
        .cluster_req_network_tag_i(cluster_req_network_tag_i),
        .cluster_req_line_addr_i(cluster_req_line_addr_i),
        .cluster_req_tag_error_o(cluster_req_tag_error_o),
        .slice_req_valid_o(slice_req_valid_o),
        .slice_req_ready_i(slice_req_ready_i),
        .slice_req_network_tag_o(slice_req_network_tag_o),
        .slice_req_line_addr_o(slice_req_line_addr_o),
        .slice_resp_valid_i(slice_resp_valid_i),
        .slice_resp_network_tag_i(slice_resp_network_tag_i),
        .slice_resp_line_addr_i(slice_resp_line_addr_i),
        .slice_resp_fault_i(slice_resp_fault_i),
        .slice_resp_data_i(slice_resp_data_i),
        .slice_resp_protocol_error_o(slice_resp_protocol_error_o),
        .cluster_resp_valid_o(cluster_resp_valid_o),
        .cluster_resp_ready_i(cluster_resp_ready_i),
        .cluster_resp_network_tag_o(cluster_resp_network_tag_o),
        .cluster_resp_line_addr_o(cluster_resp_line_addr_o),
        .cluster_resp_fault_o(cluster_resp_fault_o),
        .cluster_resp_data_o(cluster_resp_data_o)
    );


    initial clk = 1'b0;
    always #5 clk = ~clk;


    function automatic logic [SLICE_ID_W-1:0] home_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic [SLICE_ID_W-1:0] low_bits;
        logic [SLICE_ID_W-1:0] high_bits;
        begin
            if (SLICE_COUNT <= 1) begin
                home_slice = '0;
            end else begin
                low_bits = SLICE_ID_W'(line_addr);
                high_bits = SLICE_ID_W'(
                    line_addr >> SLICE_HASH_SHIFT
                );
                home_slice = low_bits ^ high_bits;
            end
        end
    endfunction


    function automatic logic [LINE_ADDR_W-1:0] line_for_home(
        input integer target_home,
        input integer salt
    );
        line_for_home = LINE_ADDR_W'((salt * 4096) + target_home);
    endfunction


    function automatic logic [NETWORK_TAG_W-1:0] make_network_tag(
        input integer cluster_encoding,
        input integer cu_encoding,
        input integer local_tag_encoding
    );
        make_network_tag = NETWORK_TAG_W'(
            (cluster_encoding << CLUSTER_LOCAL_TAG_W)
            | (cu_encoding << LOCAL_TAG_W)
            | local_tag_encoding
        );
    endfunction


    function automatic logic [31:0] response_word(
        input integer seed,
        input integer word_index
    );
        response_word =
            32'hA5000000
            ^ (32'(seed) << 8)
            ^ 32'(word_index);
    endfunction


    task automatic clear_cluster_requests;
        integer cluster_index;
        begin
            cluster_req_valid_i = '0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] = '0;
                cluster_req_line_addr_i[cluster_index] = '0;
            end
        end
    endtask


    task automatic clear_slice_responses;
        integer slice_index;
        integer word_index;
        begin
            slice_resp_valid_i = '0;
            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                slice_resp_network_tag_i[slice_index] = '0;
                slice_resp_line_addr_i[slice_index] = '0;
                slice_resp_fault_i[slice_index] = 1'b0;
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    slice_resp_data_i[slice_index][word_index] = '0;
                end
            end
        end
    endtask


    task automatic clear_inputs;
        begin
            clear_cluster_requests();
            clear_slice_responses();
            slice_req_ready_i = '0;
            cluster_resp_ready_i = '0;
        end
    endtask


    task automatic reset_epoch;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            clear_inputs();
            repeat (3) begin
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask


    task automatic expect_no_request_output;
        begin
            if (slice_req_valid_o != '0) begin
                $fatal(1, "MC-NOC-P2 unexpected slice request output");
            end
        end
    endtask


    task automatic expect_no_cluster_output;
        begin
            if (cluster_resp_valid_o != '0) begin
                $fatal(1, "MC-NOC-P2 unexpected cluster response output");
            end
        end
    endtask


    task automatic expect_slice_request(
        input integer expected_slice,
        input logic [NETWORK_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line
    );
        integer slice_index;
        integer valid_count;
        begin
            valid_count = 0;
            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                if (slice_req_valid_o[slice_index]) begin
                    valid_count = valid_count + 1;
                    if (
                        slice_index != expected_slice
                        || slice_req_network_tag_o[slice_index]
                            !== expected_tag
                        || slice_req_line_addr_o[slice_index]
                            !== expected_line
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P2 slice request mismatch expected-slice=%0d actual=%0d",
                            expected_slice,
                            slice_index
                        );
                    end
                end
            end
            if (valid_count != 1) begin
                $fatal(
                    1,
                    "MC-NOC-P2 expected one slice request count=%0d",
                    valid_count
                );
            end
        end
    endtask


    task automatic accept_request(
        input integer cluster_index,
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);
            clear_cluster_requests();
            cluster_req_network_tag_i[cluster_index] = tag;
            cluster_req_line_addr_i[cluster_index] = line_addr;
            cluster_req_valid_i[cluster_index] = 1'b1;
            #1;
            if (
                !cluster_req_ready_o[cluster_index]
                || cluster_req_tag_error_o[cluster_index]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P2 legal request not accepted cluster=%0d",
                    cluster_index
                );
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_req_valid_i[cluster_index] = 1'b0;
            #1;
        end
    endtask


    task automatic issue_held_request(
        input integer expected_slice,
        input logic [NETWORK_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line
    );
        begin
            expect_slice_request(
                expected_slice,
                expected_tag,
                expected_line
            );
            slice_req_ready_i[expected_slice] = 1'b1;
            #1;
            @(posedge clk);
            #1;
            @(negedge clk);
            slice_req_ready_i[expected_slice] = 1'b0;
            #1;
        end
    endtask


    task automatic accept_and_issue(
        input integer cluster_index,
        input integer cu_encoding,
        input integer local_tag_encoding,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic [NETWORK_TAG_W-1:0] tag;
        integer target_slice;
        begin
            tag = make_network_tag(
                cluster_index,
                cu_encoding,
                local_tag_encoding
            );
            target_slice = integer'(home_slice(line_addr));
            slice_req_ready_i = '0;
            accept_request(cluster_index, tag, line_addr);
            issue_held_request(target_slice, tag, line_addr);
        end
    endtask


    task automatic set_response_lane(
        input integer slice_index,
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input integer seed
    );
        integer word_index;
        begin
            if (slice_index < 0 || slice_index >= SLICE_COUNT) begin
                $fatal(
                    1,
                    "MC-NOC-P2 response slice argument out of range=%0d",
                    slice_index
                );
            end
            slice_resp_valid_i[slice_index] = 1'b1;
            slice_resp_network_tag_i[slice_index] = tag;
            slice_resp_line_addr_i[slice_index] = line_addr;
            slice_resp_fault_i[slice_index] = fault;
            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                slice_resp_data_i[slice_index][word_index] =
                    response_word(seed, word_index);
            end
        end
    endtask


    task automatic capture_response(
        input integer slice_index,
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input integer seed
    );
        begin
            @(negedge clk);
            clear_slice_responses();
            set_response_lane(
                slice_index,
                tag,
                line_addr,
                fault,
                seed
            );
            #1;
            if (slice_resp_protocol_error_o[slice_index]) begin
                $fatal(
                    1,
                    "MC-NOC-P2 legal response rejected slice=%0d",
                    slice_index
                );
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            #1;
        end
    endtask


    task automatic reject_response(
        input integer slice_index,
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);
            clear_slice_responses();
            set_response_lane(
                slice_index,
                tag,
                line_addr,
                1'b0,
                99
            );
            #1;
            if (!slice_resp_protocol_error_o[slice_index]) begin
                $fatal(
                    1,
                    "MC-NOC-P2 malformed response not rejected slice=%0d",
                    slice_index
                );
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            #1;
        end
    endtask


    task automatic wait_cluster_response(
        input integer cluster_index
    );
        integer guard;
        begin
            guard = 0;
            while (!cluster_resp_valid_o[cluster_index]) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
                if (guard > 20) begin
                    $fatal(
                        1,
                        "MC-NOC-P2 response timeout cluster=%0d",
                        cluster_index
                    );
                end
            end
        end
    endtask


    task automatic expect_cluster_response(
        input integer cluster_index,
        input logic [NETWORK_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line,
        input logic expected_fault,
        input integer expected_seed
    );
        integer word_index;
        begin
            if (!cluster_resp_valid_o[cluster_index]) begin
                $fatal(
                    1,
                    "MC-NOC-P2 expected response absent cluster=%0d",
                    cluster_index
                );
            end
            if (
                cluster_resp_network_tag_o[cluster_index] !== expected_tag
                || cluster_resp_line_addr_o[cluster_index]
                    !== expected_line
                || cluster_resp_fault_o[cluster_index]
                    !== expected_fault
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P2 cluster response metadata mismatch cluster=%0d",
                    cluster_index
                );
            end
            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                if (
                    cluster_resp_data_o[cluster_index][word_index]
                        !== response_word(expected_seed, word_index)
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P2 response data mismatch cluster=%0d word=%0d",
                        cluster_index,
                        word_index
                    );
                end
            end
        end
    endtask


    task automatic retire_cluster_response(
        input integer cluster_index
    );
        begin
            if (!cluster_resp_valid_o[cluster_index]) begin
                $fatal(
                    1,
                    "MC-NOC-P2 cannot retire absent response cluster=%0d",
                    cluster_index
                );
            end
            @(negedge clk);
            cluster_resp_ready_i[cluster_index] = 1'b1;
            #1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_resp_ready_i[cluster_index] = 1'b0;
            #1;
        end
    endtask


    task automatic assert_quiet_cycles(
        input integer cycle_count
    );
        integer cycle_index;
        begin
            for (
                cycle_index = 0;
                cycle_index < cycle_count;
                cycle_index = cycle_index + 1
            ) begin
                @(posedge clk);
                #1;
                expect_no_cluster_output();
            end
        end
    endtask


    task automatic run_parameter_smoke;
        logic [NETWORK_TAG_W-1:0] tag;
        logic [LINE_ADDR_W-1:0] line_addr;
        integer target_slice;
        begin
            reset_epoch();
            tag = make_network_tag(0, 0, 0);
            line_addr = line_for_home(0, 1);
            target_slice = integer'(home_slice(line_addr));

            accept_and_issue(0, 0, 0, line_addr);
            capture_response(
                target_slice,
                tag,
                line_addr,
                1'b1,
                7
            );
            wait_cluster_response(0);
            expect_cluster_response(0, tag, line_addr, 1'b1, 7);
            retire_cluster_response(0);
            assert_quiet_cycles(2);

            $display("MC_NOC_P2_PARAMETER_SMOKE=PASS");
            $finish;
        end
    endtask


`ifdef MC_NOC_P2_FULL
    task automatic run_full_scenarios;
        logic [NETWORK_TAG_W-1:0] tag_a;
        logic [NETWORK_TAG_W-1:0] tag_b;
        logic [NETWORK_TAG_W-1:0] tag_c;
        logic [NETWORK_TAG_W-1:0] tag_d;
        logic [NETWORK_TAG_W-1:0] tag_x;
        logic [LINE_ADDR_W-1:0] line_a;
        logic [LINE_ADDR_W-1:0] line_b;
        logic [LINE_ADDR_W-1:0] line_c;
        logic [LINE_ADDR_W-1:0] line_d;
        logic [LINE_ADDR_W-1:0] line_x;
        logic [NETWORK_TAG_W-1:0] held_tag;
        logic [LINE_ADDR_W-1:0] held_line;
        logic held_fault;
        logic [31:0] held_word [0:LINE_WORDS-1];
        logic [3:0] seen_four;
        integer cluster_index;
        integer cu_index;
        integer local_index;
        integer slice_index;
        integer word_index;
        integer response_index;
        integer found_index;
        integer selected_cluster;
        integer seen_final;
        integer service_count;
        begin
            /*
             * Reset and basic request transport.
             */
            rst_n = 1'b0;
            clear_inputs();
            repeat (2) begin
                @(posedge clk);
                #1;
            end
            if (
                cluster_req_ready_o != '0
                || slice_req_valid_o != '0
                || slice_resp_protocol_error_o != '0
                || cluster_resp_valid_o != '0
            ) begin
                $fatal(1, "MC-NOC-P2 outputs not reset-gated");
            end
            $display("MC_NOC_P2_01_RESET_OUTPUTS_GATED=PASS");

            @(negedge clk);
            rst_n = 1'b1;
            #1;
            expect_no_request_output();
            expect_no_cluster_output();
            $display("MC_NOC_P2_02_RESET_RELEASE_EMPTY=PASS");

            tag_a = make_network_tag(0, 1, 3);
            line_a = line_for_home(2, 2);
            slice_req_ready_i = '0;
            @(negedge clk);
            cluster_req_network_tag_i[0] = tag_a;
            cluster_req_line_addr_i[0] = line_a;
            cluster_req_valid_i[0] = 1'b1;
            #1;
            expect_no_request_output();
            $display("MC_NOC_P2_03_REQUEST_REGISTERED_NO_BYPASS=PASS");
            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P2 first request unexpectedly stalled");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b0;
            #1;
            expect_slice_request(2, tag_a, line_a);
            if (integer'(home_slice(line_a)) != 2) begin
                $fatal(1, "MC-NOC-P2 home hash mismatch");
            end
            $display("MC_NOC_P2_04_REQUEST_HOME_HASH_PRESERVED=PASS");
            $display("MC_NOC_P2_05_REQUEST_TAG_LINE_EXACT=PASS");
            $display("MC_NOC_P2_06_OPAQUE_UNUSED_LOCAL_TAG=PASS");

            held_tag = slice_req_network_tag_o[2];
            held_line = slice_req_line_addr_o[2];
            repeat (3) begin
                @(posedge clk);
                #1;
                if (
                    !slice_req_valid_o[2]
                    || slice_req_network_tag_o[2] !== held_tag
                    || slice_req_line_addr_o[2] !== held_line
                ) begin
                    $fatal(1, "MC-NOC-P2 request changed under stall");
                end
            end
            $display("MC_NOC_P2_07_REQUEST_STALL_STABLE=PASS");

            /*
             * Bubble-free P1 turnover: issue cluster 0 while cluster 1
             * replaces the same home hold.
             */
            tag_b = make_network_tag(1, 0, 1);
            line_b = line_for_home(2, 3);
            @(negedge clk);
            cluster_req_network_tag_i[1] = tag_b;
            cluster_req_line_addr_i[1] = line_b;
            cluster_req_valid_i[1] = 1'b1;
            slice_req_ready_i[2] = 1'b1;
            #1;
            if (!cluster_req_ready_o[1]) begin
                $fatal(1, "MC-NOC-P2 turnover replacement not accepted");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_req_valid_i[1] = 1'b0;
            slice_req_ready_i[2] = 1'b0;
            #1;
            expect_slice_request(2, tag_b, line_b);
            $display("MC_NOC_P2_08_REQUEST_TURNOVER=PASS");
            issue_held_request(2, tag_b, line_b);

            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            tag_b = make_network_tag(1, 0, 0);
            line_a = line_for_home(0, 4);
            line_b = line_for_home(1, 4);
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[0] = tag_a;
            cluster_req_line_addr_i[0] = line_a;
            cluster_req_valid_i[1] = 1'b1;
            cluster_req_network_tag_i[1] = tag_b;
            cluster_req_line_addr_i[1] = line_b;
            #1;
            if (!cluster_req_ready_o[0] || !cluster_req_ready_o[1]) begin
                $fatal(1, "MC-NOC-P2 independent request accept failed");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_cluster_requests();
            #1;
            if (
                !slice_req_valid_o[0]
                || !slice_req_valid_o[1]
                || slice_req_network_tag_o[0] !== tag_a
                || slice_req_network_tag_o[1] !== tag_b
            ) begin
                $fatal(1, "MC-NOC-P2 different-slice concurrency failed");
            end
            $display("MC_NOC_P2_09_DIFFERENT_SLICE_CONCURRENT=PASS");

            /*
             * Request rejection and reservation semantics.
             */
            reset_epoch();
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[0] = make_network_tag(1, 0, 0);
            cluster_req_line_addr_i[0] = line_for_home(0, 5);
            #1;
            if (cluster_req_ready_o[0] || !cluster_req_tag_error_o[0]) begin
                $fatal(1, "MC-NOC-P2 wrong cluster request admitted");
            end
            $display("MC_NOC_P2_10_WRONG_CLUSTER_REQUEST_REJECT=PASS");

            cluster_req_network_tag_i[0] = make_network_tag(3, 0, 0);
            #1;
            if (cluster_req_ready_o[0] || !cluster_req_tag_error_o[0]) begin
                $fatal(1, "MC-NOC-P2 unused cluster request admitted");
            end
            $display("MC_NOC_P2_11_UNUSED_CLUSTER_REQUEST_REJECT=PASS");

            cluster_req_network_tag_i[0] = make_network_tag(0, 3, 0);
            #1;
            if (cluster_req_ready_o[0] || !cluster_req_tag_error_o[0]) begin
                $fatal(1, "MC-NOC-P2 unused CU request admitted");
            end
            $display("MC_NOC_P2_12_UNUSED_CU_REQUEST_REJECT=PASS");
            @(negedge clk);
            clear_cluster_requests();

            reset_epoch();
            tag_a = make_network_tag(0, 1, 1);
            line_a = line_for_home(0, 6);
            accept_request(0, tag_a, line_a);
            expect_slice_request(0, tag_a, line_a);
            $display("MC_NOC_P2_13_QUEUED_OWNER_RESERVED=PASS");

            @(negedge clk);
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[0] = tag_a;
            cluster_req_line_addr_i[0] = line_for_home(1, 6);
            #1;
            if (
                cluster_req_ready_o[0]
                || cluster_req_tag_error_o[0]
            ) begin
                $fatal(1, "MC-NOC-P2 duplicate request semantics wrong");
            end
            $display("MC_NOC_P2_14_DUPLICATE_REQUEST_BACKPRESSURE_NO_ERROR=PASS");
            @(negedge clk);
            clear_cluster_requests();
            issue_held_request(0, tag_a, line_a);
            $display("MC_NOC_P2_15_SLICE_ISSUE_TRANSITION=PASS");

            reset_epoch();
            for (
                cu_index = 0;
                cu_index < CUS_PER_CLUSTER;
                cu_index = cu_index + 1
            ) begin
                for (
                    local_index = 0;
                    local_index < MSHR_COUNT;
                    local_index = local_index + 1
                ) begin
                    accept_and_issue(
                        0,
                        cu_index,
                        local_index,
                        line_for_home(
                            (cu_index * MSHR_COUNT + local_index)
                                % SLICE_COUNT,
                            20 + cu_index * MSHR_COUNT + local_index
                        )
                    );
                end
            end
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[0] = make_network_tag(0, 0, 3);
            cluster_req_line_addr_i[0] = line_for_home(0, 40);
            #1;
            if (
                cluster_req_ready_o[0]
                || cluster_req_tag_error_o[0]
            ) begin
                $fatal(1, "MC-NOC-P2 full capacity semantics wrong");
            end
            $display("MC_NOC_P2_16_CAPACITY_FULL_BACKPRESSURE_NO_ERROR=PASS");
            @(negedge clk);
            clear_cluster_requests();

            /*
             * Basic response metadata/data, registration, stall, exactly once.
             */
            reset_epoch();
            tag_a = make_network_tag(1, 2, 3);
            line_a = line_for_home(2, 50);
            accept_and_issue(1, 2, 3, line_a);
            @(negedge clk);
            set_response_lane(2, tag_a, line_a, 1'b1, 11);
            #1;
            expect_no_cluster_output();
            $display("MC_NOC_P2_17_RESPONSE_REGISTERED_NO_BYPASS=PASS");
            if (slice_resp_protocol_error_o[2]) begin
                $fatal(1, "MC-NOC-P2 basic response rejected");
            end
            @(posedge clk);
            #1;
            expect_no_cluster_output();
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(1);
            expect_cluster_response(1, tag_a, line_a, 1'b1, 11);
            $display("MC_NOC_P2_18_BASIC_RESPONSE_ROUTE=PASS");
            $display("MC_NOC_P2_19_RESPONSE_FULL_TAG_EXACT=PASS");
            $display("MC_NOC_P2_20_RESPONSE_LINE_EXACT=PASS");
            $display("MC_NOC_P2_21_RESPONSE_FAULT_EXACT=PASS");
            $display("MC_NOC_P2_22_RESPONSE_ALL_WORDS_EXACT=PASS");

            held_tag = cluster_resp_network_tag_o[1];
            held_line = cluster_resp_line_addr_o[1];
            held_fault = cluster_resp_fault_o[1];
            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                held_word[word_index] = cluster_resp_data_o[1][word_index];
            end
            repeat (3) begin
                @(posedge clk);
                #1;
                if (
                    !cluster_resp_valid_o[1]
                    || cluster_resp_network_tag_o[1] !== held_tag
                    || cluster_resp_line_addr_o[1] !== held_line
                    || cluster_resp_fault_o[1] !== held_fault
                ) begin
                    $fatal(1, "MC-NOC-P2 response metadata changed stalled");
                end
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    if (
                        cluster_resp_data_o[1][word_index]
                            !== held_word[word_index]
                    ) begin
                        $fatal(1, "MC-NOC-P2 response data changed stalled");
                    end
                end
            end
            $display("MC_NOC_P2_23_RESPONSE_STALL_STABLE=PASS");
            retire_cluster_response(1);
            assert_quiet_cycles(3);
            $display("MC_NOC_P2_24_RESPONSE_EXACTLY_ONCE=PASS");

            /*
             * Reverse order and cross-cluster identity/concurrency.
             */
            reset_epoch();
            tag_a = make_network_tag(0, 1, 1);
            tag_b = make_network_tag(0, 1, 2);
            line_a = line_for_home(0, 60);
            line_b = line_for_home(1, 60);
            accept_and_issue(0, 1, 1, line_a);
            accept_and_issue(0, 1, 2, line_b);
            capture_response(1, tag_b, line_b, 1'b0, 22);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_b, line_b, 1'b0, 22);
            capture_response(0, tag_a, line_a, 1'b0, 21);
            retire_cluster_response(0);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 21);
            retire_cluster_response(0);
            $display("MC_NOC_P2_25_REVERSE_ORDER_COMPLETION=PASS");

            reset_epoch();
            tag_a = make_network_tag(0, 1, 1);
            tag_b = make_network_tag(1, 1, 1);
            line_a = line_for_home(0, 61);
            line_b = line_for_home(1, 61);
            accept_and_issue(0, 1, 1, line_a);
            accept_and_issue(1, 1, 1, line_b);
            @(negedge clk);
            set_response_lane(0, tag_a, line_a, 1'b0, 31);
            set_response_lane(1, tag_b, line_b, 1'b1, 32);
            #1;
            if (slice_resp_protocol_error_o != '0) begin
                $fatal(1, "MC-NOC-P2 cross-cluster response rejected");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(0);
            wait_cluster_response(1);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 31);
            expect_cluster_response(1, tag_b, line_b, 1'b1, 32);
            $display("MC_NOC_P2_26_SAME_SUFFIX_DIFFERENT_CLUSTERS=PASS");
            $display("MC_NOC_P2_27_DIFFERENT_CLUSTERS_CONCURRENT_OUTPUT=PASS");
            @(negedge clk);
            cluster_resp_ready_i[0] = 1'b1;
            cluster_resp_ready_i[1] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_resp_ready_i = '0;

            /*
             * Four no-ready responses to one cluster capture on one edge and
             * drain exactly once.
             */
            reset_epoch();
            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                accept_and_issue(
                    0,
                    slice_index % CUS_PER_CLUSTER,
                    slice_index,
                    line_for_home(slice_index, 70 + slice_index)
                );
            end
            @(negedge clk);
            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                set_response_lane(
                    slice_index,
                    make_network_tag(
                        0,
                        slice_index % CUS_PER_CLUSTER,
                        slice_index
                    ),
                    line_for_home(slice_index, 70 + slice_index),
                    (slice_index == 3),
                    40 + slice_index
                );
            end
            #1;
            if (slice_resp_protocol_error_o != '0) begin
                $fatal(1, "MC-NOC-P2 simultaneous responses rejected");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            $display("MC_NOC_P2_28_SAME_CLUSTER_SIMULTANEOUS_CAPTURE=PASS");

            seen_four = '0;
            for (
                response_index = 0;
                response_index < SLICE_COUNT;
                response_index = response_index + 1
            ) begin
                wait_cluster_response(0);
                found_index = -1;
                for (
                    slice_index = 0;
                    slice_index < SLICE_COUNT;
                    slice_index = slice_index + 1
                ) begin
                    if (
                        cluster_resp_network_tag_o[0]
                            == make_network_tag(
                                0,
                                slice_index % CUS_PER_CLUSTER,
                                slice_index
                            )
                    ) begin
                        found_index = slice_index;
                    end
                end
                if (
                    found_index < 0
                    || seen_four[found_index]
                ) begin
                    $fatal(1, "MC-NOC-P2 simultaneous response lost/duplicate");
                end
                expect_cluster_response(
                    0,
                    make_network_tag(
                        0,
                        found_index % CUS_PER_CLUSTER,
                        found_index
                    ),
                    line_for_home(found_index, 70 + found_index),
                    (found_index == 3),
                    40 + found_index
                );
                seen_four[found_index] = 1'b1;
                retire_cluster_response(0);
            end
            if (seen_four != 4'b1111) begin
                $fatal(1, "MC-NOC-P2 did not drain every simultaneous response");
            end
            $display("MC_NOC_P2_29_SAME_CLUSTER_NO_RESPONSE_LOSS=PASS");

            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            tag_b = make_network_tag(1, 0, 0);
            line_a = line_for_home(0, 80);
            line_b = line_for_home(1, 80);
            accept_and_issue(0, 0, 0, line_a);
            accept_and_issue(1, 0, 0, line_b);
            @(negedge clk);
            set_response_lane(0, tag_a, line_a, 1'b0, 51);
            set_response_lane(1, tag_b, line_b, 1'b0, 52);
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(0);
            wait_cluster_response(1);
            held_tag = cluster_resp_network_tag_o[0];
            cluster_resp_ready_i[1] = 1'b1;
            @(posedge clk);
            #1;
            if (
                !cluster_resp_valid_o[0]
                || cluster_resp_network_tag_o[0] !== held_tag
            ) begin
                $fatal(1, "MC-NOC-P2 stalled cluster disturbed");
            end
            @(negedge clk);
            cluster_resp_ready_i[1] = 1'b0;
            $display("MC_NOC_P2_30_BACKPRESSURE_ISOLATION=PASS");

            /*
             * Sparse RR, wrap, cursor-on-retire, and adversarial refill.
             */
            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            tag_b = make_network_tag(0, 0, 1);
            tag_c = make_network_tag(0, 0, 2);
            line_a = line_for_home(0, 90);
            line_b = line_for_home(1, 90);
            line_c = line_for_home(2, 90);
            accept_and_issue(0, 0, 0, line_a);
            accept_and_issue(0, 0, 1, line_b);
            accept_and_issue(0, 0, 2, line_c);
            @(negedge clk);
            set_response_lane(0, tag_a, line_a, 1'b0, 61);
            set_response_lane(1, tag_b, line_b, 1'b0, 62);
            set_response_lane(2, tag_c, line_c, 1'b0, 63);
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 61);
            repeat (3) begin
                @(posedge clk);
                #1;
                expect_cluster_response(0, tag_a, line_a, 1'b0, 61);
            end
            $display("MC_NOC_P2_31_RR_CURSOR_ONLY_RETIRE=PASS");
            retire_cluster_response(0);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_b, line_b, 1'b0, 62);
            $display("MC_NOC_P2_32_RR_SPARSE_COMPLETIONS=PASS");
            retire_cluster_response(0);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_c, line_c, 1'b0, 63);
            retire_cluster_response(0);

            tag_d = make_network_tag(0, 1, 0);
            line_d = line_for_home(3, 91);
            accept_and_issue(0, 1, 0, line_d);
            capture_response(3, tag_d, line_d, 1'b0, 64);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_d, line_d, 1'b0, 64);
            retire_cluster_response(0);
            tag_x = make_network_tag(0, 1, 1);
            line_x = line_for_home(0, 92);
            accept_and_issue(0, 1, 1, line_x);
            capture_response(0, tag_x, line_x, 1'b0, 65);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_x, line_x, 1'b0, 65);
            retire_cluster_response(0);
            $display("MC_NOC_P2_33_RR_WRAP=PASS");

            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            tag_b = make_network_tag(0, 0, 1);
            tag_c = make_network_tag(0, 0, 2);
            line_a = line_for_home(0, 100);
            line_b = line_for_home(1, 100);
            line_c = line_for_home(2, 100);
            accept_and_issue(0, 0, 0, line_a);
            accept_and_issue(0, 0, 1, line_b);
            accept_and_issue(0, 0, 2, line_c);
            @(negedge clk);
            set_response_lane(0, tag_a, line_a, 1'b0, 71);
            set_response_lane(1, tag_b, line_b, 1'b0, 72);
            set_response_lane(2, tag_c, line_c, 1'b0, 73);
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 71);

            line_d = line_for_home(3, 101);
            @(negedge clk);
            cluster_resp_ready_i[0] = 1'b1;
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[0] = tag_a;
            cluster_req_line_addr_i[0] = line_d;
            #1;
            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P2 retire/reuse did not admit");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_resp_ready_i[0] = 1'b0;
            clear_cluster_requests();
            wait_cluster_response(0);
            expect_cluster_response(0, tag_b, line_b, 1'b0, 72);

            /*
             * Refill the just-retired low owner while slot 1 is stalled.
             * Fixed-low service would choose that refill again after slot 1;
             * the handshake-driven RR cursor must choose older slot 2.
             */
            slice_req_ready_i[3] = 1'b1;
            set_response_lane(3, tag_a, line_d, 1'b0, 74);
            #1;
            if (slice_resp_protocol_error_o[3]) begin
                $fatal(1, "MC-NOC-P2 adversarial refill response rejected");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            slice_req_ready_i[3] = 1'b0;
            clear_slice_responses();
            retire_cluster_response(0);
            wait_cluster_response(0);
            service_count = 3;
            if (cluster_resp_network_tag_o[0] !== tag_c) begin
                $fatal(1, "MC-NOC-P2 older completed owner starved");
            end
            if (service_count > CLUSTER_MAX_OUTSTANDING) begin
                $fatal(1, "MC-NOC-P2 fairness bound exceeded");
            end
            $display("MC_NOC_P2_34_FAIRNESS_BOUND=PASS");
            $display("MC_NOC_P2_35_ADVERSARIAL_REFILL_NO_STARVATION=PASS");
            $display("MC_NOC_P2_36_SAME_CYCLE_RETIRE_REUSE=PASS");

            /*
             * Response rejection matrix; every owner-survival case is followed
             * by its legal completion.
             */
            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            line_a = line_for_home(0, 110);
            reject_response(0, tag_a, line_a);
            assert_quiet_cycles(2);
            $display("MC_NOC_P2_37_ORPHAN_REJECT=PASS");

            reset_epoch();
            accept_request(0, tag_a, line_a);
            reject_response(0, tag_a, line_a);
            expect_slice_request(0, tag_a, line_a);
            issue_held_request(0, tag_a, line_a);
            capture_response(0, tag_a, line_a, 1'b0, 81);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 81);
            $display("MC_NOC_P2_38_PREMATURE_REJECT=PASS");

            reset_epoch();
            accept_and_issue(0, 0, 0, line_a);
            @(negedge clk);
            set_response_lane(0, tag_a, line_a, 1'b0, 82);
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            set_response_lane(0, tag_a, line_a, 1'b0, 83);
            #1;
            if (!slice_resp_protocol_error_o[0]) begin
                $fatal(1, "MC-NOC-P2 duplicate complete not rejected");
            end
            $display("MC_NOC_P2_39_DUPLICATE_COMPLETE_REJECT=PASS");
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(0);
            set_response_lane(0, tag_a, line_a, 1'b0, 84);
            #1;
            if (!slice_resp_protocol_error_o[0]) begin
                $fatal(1, "MC-NOC-P2 duplicate emitting not rejected");
            end
            $display("MC_NOC_P2_40_DUPLICATE_EMITTING_REJECT=PASS");
            @(negedge clk);
            clear_slice_responses();
            retire_cluster_response(0);
            reject_response(0, tag_a, line_a);
            $display("MC_NOC_P2_41_POST_RETIRE_ORPHAN_REJECT=PASS");

            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            line_a = line_for_home(0, 120);
            accept_and_issue(0, 0, 0, line_a);
            reject_response(0, tag_a, line_for_home(0, 121));
            capture_response(0, tag_a, line_a, 1'b0, 85);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 85);
            retire_cluster_response(0);
            $display("MC_NOC_P2_42_WRONG_LINE_REJECT_OWNER_SURVIVES=PASS");

            reset_epoch();
            accept_and_issue(0, 0, 0, line_a);
            reject_response(1, tag_a, line_a);
            capture_response(0, tag_a, line_a, 1'b0, 86);
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 86);
            retire_cluster_response(0);
            $display("MC_NOC_P2_43_WRONG_HOME_REJECT_OWNER_SURVIVES=PASS");

            reset_epoch();
            reject_response(
                0,
                make_network_tag(3, 0, 0),
                line_for_home(0, 122)
            );
            $display("MC_NOC_P2_44_INVALID_RESPONSE_CLUSTER=PASS");
            reject_response(
                0,
                make_network_tag(0, 3, 0),
                line_for_home(0, 123)
            );
            $display("MC_NOC_P2_45_INVALID_RESPONSE_CU=PASS");

            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            line_a = line_for_home(0, 124);
            accept_and_issue(0, 0, 0, line_a);
            @(negedge clk);
            set_response_lane(0, tag_a, line_a, 1'b0, 87);
            set_response_lane(
                1,
                make_network_tag(3, 0, 0),
                line_for_home(1, 124),
                1'b0,
                88
            );
            #1;
            if (
                slice_resp_protocol_error_o[0]
                || !slice_resp_protocol_error_o[1]
            ) begin
                $fatal(1, "MC-NOC-P2 malformed peer isolation failed");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_slice_responses();
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b0, 87);
            retire_cluster_response(0);
            $display("MC_NOC_P2_46_MALFORMED_PEER_DOES_NOT_BLOCK=PASS");

            /*
             * Exact same-edge issue/response.
             */
            reset_epoch();
            tag_a = make_network_tag(0, 1, 3);
            line_a = line_for_home(2, 130);
            accept_request(0, tag_a, line_a);
            expect_slice_request(2, tag_a, line_a);
            @(negedge clk);
            slice_req_ready_i[2] = 1'b1;
            set_response_lane(2, tag_a, line_a, 1'b1, 91);
            #1;
            if (slice_resp_protocol_error_o[2]) begin
                $fatal(1, "MC-NOC-P2 same-edge issue/response rejected");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            slice_req_ready_i[2] = 1'b0;
            clear_slice_responses();
            wait_cluster_response(0);
            expect_cluster_response(0, tag_a, line_a, 1'b1, 91);
            retire_cluster_response(0);
            $display("MC_NOC_P2_47_SAME_CYCLE_ISSUE_RESPONSE=PASS");

            /*
             * Full table replacement by retirement with a new identity.
             */
            reset_epoch();
            for (
                cu_index = 0;
                cu_index < CUS_PER_CLUSTER;
                cu_index = cu_index + 1
            ) begin
                for (
                    local_index = 0;
                    local_index < MSHR_COUNT;
                    local_index = local_index + 1
                ) begin
                    accept_and_issue(
                        0,
                        cu_index,
                        local_index,
                        line_for_home(
                            (cu_index * MSHR_COUNT + local_index)
                                % SLICE_COUNT,
                            140 + cu_index * MSHR_COUNT + local_index
                        )
                    );
                end
            end
            tag_a = make_network_tag(0, 0, 0);
            line_a = line_for_home(0, 140);
            capture_response(0, tag_a, line_a, 1'b0, 101);
            wait_cluster_response(0);
            tag_x = make_network_tag(0, 0, 3);
            line_x = line_for_home(1, 160);
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[0] = tag_x;
            cluster_req_line_addr_i[0] = line_x;
            #1;
            if (
                cluster_req_ready_o[0]
                || cluster_req_tag_error_o[0]
            ) begin
                $fatal(1, "MC-NOC-P2 full table accepted before retire");
            end
            cluster_resp_ready_i[0] = 1'b1;
            #1;
            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P2 full-table retirement did not replace");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            cluster_resp_ready_i[0] = 1'b0;
            clear_cluster_requests();
            expect_slice_request(1, tag_x, line_x);
            $display("MC_NOC_P2_48_FULL_TABLE_RETIRE_REPLACEMENT=PASS");

            /*
             * Reset flushes QUEUED, AWAITING, COMPLETE, and EMITTING owners.
             */
            reset_epoch();
            tag_a = make_network_tag(0, 0, 0);
            tag_b = make_network_tag(0, 0, 1);
            tag_c = make_network_tag(0, 0, 2);
            tag_d = make_network_tag(0, 0, 3);
            line_a = line_for_home(0, 170);
            line_b = line_for_home(1, 170);
            line_c = line_for_home(2, 170);
            line_d = line_for_home(3, 170);
            accept_and_issue(0, 0, 0, line_a);
            accept_and_issue(0, 0, 1, line_b);
            capture_response(1, tag_b, line_b, 1'b0, 111);
            wait_cluster_response(0);
            accept_and_issue(0, 0, 2, line_c);
            capture_response(2, tag_c, line_c, 1'b0, 112);
            accept_request(0, tag_d, line_d);
            expect_slice_request(3, tag_d, line_d);
            reset_epoch();
            expect_no_request_output();
            expect_no_cluster_output();
            reject_response(0, tag_a, line_a);
            accept_request(0, tag_a, line_a);
            expect_slice_request(0, tag_a, line_a);
            $display("MC_NOC_P2_49_RESET_FLUSH_ALL_STATES=PASS");

            /*
             * Final six-transaction cross-cluster conservation drain.
             */
            reset_epoch();
            final_tag[0] = make_network_tag(0, 0, 0);
            final_tag[1] = make_network_tag(1, 0, 0);
            final_tag[2] = make_network_tag(2, 0, 0);
            final_tag[3] = make_network_tag(0, 1, 1);
            final_tag[4] = make_network_tag(1, 1, 1);
            final_tag[5] = make_network_tag(2, 1, 1);
            final_line[0] = line_for_home(0, 180);
            final_line[1] = line_for_home(1, 180);
            final_line[2] = line_for_home(2, 180);
            final_line[3] = line_for_home(3, 180);
            final_line[4] = line_for_home(0, 181);
            final_line[5] = line_for_home(1, 181);
            for (
                response_index = 0;
                response_index < 6;
                response_index = response_index + 1
            ) begin
                final_seed[response_index] = 120 + response_index;
            end

            accept_and_issue(0, 0, 0, final_line[0]);
            accept_and_issue(1, 0, 0, final_line[1]);
            accept_and_issue(2, 0, 0, final_line[2]);
            accept_and_issue(0, 1, 1, final_line[3]);
            accept_and_issue(1, 1, 1, final_line[4]);
            accept_and_issue(2, 1, 1, final_line[5]);

            capture_response(
                integer'(home_slice(final_line[5])),
                final_tag[5],
                final_line[5],
                1'b0,
                final_seed[5]
            );
            capture_response(
                integer'(home_slice(final_line[4])),
                final_tag[4],
                final_line[4],
                1'b1,
                final_seed[4]
            );
            capture_response(
                integer'(home_slice(final_line[3])),
                final_tag[3],
                final_line[3],
                1'b0,
                final_seed[3]
            );
            capture_response(
                integer'(home_slice(final_line[2])),
                final_tag[2],
                final_line[2],
                1'b1,
                final_seed[2]
            );
            capture_response(
                integer'(home_slice(final_line[1])),
                final_tag[1],
                final_line[1],
                1'b0,
                final_seed[1]
            );
            capture_response(
                integer'(home_slice(final_line[0])),
                final_tag[0],
                final_line[0],
                1'b1,
                final_seed[0]
            );

            seen_final = 0;
            for (
                response_index = 0;
                response_index < 6;
                response_index = response_index + 1
            ) begin
                selected_cluster = -1;
                while (selected_cluster < 0) begin
                    for (
                        cluster_index = 0;
                        cluster_index < CLUSTER_COUNT;
                        cluster_index = cluster_index + 1
                    ) begin
                        if (
                            selected_cluster < 0
                            && cluster_resp_valid_o[cluster_index]
                        ) begin
                            selected_cluster = cluster_index;
                        end
                    end
                    if (selected_cluster < 0) begin
                        @(posedge clk);
                        #1;
                    end
                end

                found_index = -1;
                for (
                    local_index = 0;
                    local_index < 6;
                    local_index = local_index + 1
                ) begin
                    if (
                        cluster_resp_network_tag_o[selected_cluster]
                            == final_tag[local_index]
                    ) begin
                        found_index = local_index;
                    end
                end
                if (
                    found_index < 0
                    || ((seen_final >> found_index) & 1) != 0
                ) begin
                    $fatal(1, "MC-NOC-P2 final drain duplicate/unknown");
                end
                expect_cluster_response(
                    selected_cluster,
                    final_tag[found_index],
                    final_line[found_index],
                    (found_index == 0
                        || found_index == 2
                        || found_index == 4),
                    final_seed[found_index]
                );
                seen_final = seen_final | (1 << found_index);
                retire_cluster_response(selected_cluster);
            end
            if (seen_final != 63) begin
                $fatal(1, "MC-NOC-P2 final conservation set incomplete");
            end
            assert_quiet_cycles(3);
            $display("MC_NOC_P2_50_FINAL_CONSERVATION_DRAIN=PASS");

            $finish;
        end
    endtask
`endif


    initial begin
        rst_n = 1'b0;
        clear_inputs();
`ifdef MC_NOC_P2_FULL
        if (FULL_SCENARIOS == 0) begin
            $fatal(1, "MC-NOC-P2 full TB define/parameter mismatch");
        end
        run_full_scenarios();
`else
        if (FULL_SCENARIOS != 0) begin
            $fatal(1, "MC-NOC-P2 smoke TB define/parameter mismatch");
        end
        run_parameter_smoke();
`endif
    end

endmodule
