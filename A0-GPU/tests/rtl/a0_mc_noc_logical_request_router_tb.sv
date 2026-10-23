`timescale 1ns/1ps

module a0_mc_noc_logical_request_router_tb #(
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

    localparam integer LINE_ADDR_W =
        32 - WORD_SELECT_W;

    localparam integer CLUSTER_ID_W =
        (CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT);

    localparam integer CU_ID_W =
        (CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER);

    localparam integer LOCAL_TAG_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT);

    localparam integer CLUSTER_LOCAL_TAG_W =
        CU_ID_W + LOCAL_TAG_W;

    localparam integer NETWORK_TAG_W =
        CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W;

    localparam integer SLICE_ID_W =
        (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT);

    localparam integer LOCAL_TAG_ENCODING_COUNT =
        (1 << LOCAL_TAG_W);

    logic clk;
    logic rst_n;

    logic [CLUSTER_COUNT-1:0]
        cluster_req_valid_i;

    logic [CLUSTER_COUNT-1:0]
        cluster_req_ready_o;

    logic [NETWORK_TAG_W-1:0]
        cluster_req_network_tag_i [0:CLUSTER_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        cluster_req_line_addr_i [0:CLUSTER_COUNT-1];

    logic [CLUSTER_COUNT-1:0]
        cluster_req_tag_error_o;

    logic [SLICE_COUNT-1:0]
        slice_req_valid_o;

    logic [SLICE_COUNT-1:0]
        slice_req_ready_i;

    logic [NETWORK_TAG_W-1:0]
        slice_req_network_tag_o [0:SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        slice_req_line_addr_o [0:SLICE_COUNT-1];

    logic [SLICE_COUNT-1:0]
        model_valid_q;

    logic [NETWORK_TAG_W-1:0]
        model_network_tag_q [0:SLICE_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        model_line_addr_q [0:SLICE_COUNT-1];

    integer unsigned accepted_total_q;
    integer unsigned emitted_total_q;

    integer unsigned
        accepted_by_cluster_q [0:CLUSTER_COUNT-1];

    integer unsigned
        emitted_by_cluster_q [0:CLUSTER_COUNT-1];

    a0_mc_noc_logical_request_router #(
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
        .slice_req_line_addr_o(slice_req_line_addr_o)
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


    function automatic logic transport_identity_valid_for_lane(
        input integer lane,
        input logic [CLUSTER_ID_W+CU_ID_W-1:0] encoded_identity
    );
        logic [CLUSTER_ID_W-1:0] encoded_cluster;
        logic [CU_ID_W-1:0] encoded_cu;
        begin
            encoded_cluster =
                encoded_identity[
                    CLUSTER_ID_W+CU_ID_W-1 -: CLUSTER_ID_W
                ];
            encoded_cu =
                encoded_identity[CU_ID_W-1:0];

            transport_identity_valid_for_lane =
                integer'(encoded_cluster) < CLUSTER_COUNT
                && integer'(encoded_cluster) == lane
                && integer'(encoded_cu) < CUS_PER_CLUSTER;
        end
    endfunction


    function automatic integer tag_cluster(
        input logic [CLUSTER_ID_W-1:0] encoded_cluster
    );
        tag_cluster = integer'(encoded_cluster);
    endfunction


    task automatic clear_requests;
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


    task automatic clear_inputs;
        begin
            clear_requests();
            slice_req_ready_i = '1;
        end
    endtask


    task automatic reset_epoch;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            clear_inputs();
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask


    task automatic assert_no_slice_output;
        integer slice_index;
        begin
            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                if (slice_req_valid_o[slice_index]) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 unexpected slice output slice=%0d",
                        slice_index
                    );
                end
            end
        end
    endtask


    task automatic expect_exact_hold(
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
                    if (slice_index != expected_slice) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 request appeared on wrong slice expected=%0d actual=%0d",
                            expected_slice,
                            slice_index
                        );
                    end
                    if (
                        slice_req_network_tag_o[slice_index]
                            !== expected_tag
                        || slice_req_line_addr_o[slice_index]
                            !== expected_line
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 held payload mismatch slice=%0d",
                            slice_index
                        );
                    end
                end
            end
            if (valid_count != 1) begin
                $fatal(
                    1,
                    "MC-NOC-P1 expected one held output count=%0d",
                    valid_count
                );
            end
        end
    endtask


    task automatic route_and_drain(
        input integer cluster_index,
        input integer cu_encoding,
        input integer local_tag_encoding,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer guard;
        integer target_slice;
        logic [NETWORK_TAG_W-1:0] expected_tag;
        begin
            target_slice = integer'(home_slice(line_addr));
            expected_tag = make_network_tag(
                cluster_index,
                cu_encoding,
                local_tag_encoding
            );

            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[cluster_index] = expected_tag;
            cluster_req_line_addr_i[cluster_index] = line_addr;
            cluster_req_valid_i[cluster_index] = 1'b1;
            #1;

            guard = 0;
            while (!cluster_req_ready_o[cluster_index]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 20) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 route accept timeout cluster=%0d slice=%0d",
                        cluster_index,
                        target_slice
                    );
                end
            end

            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[cluster_index] = 1'b0;
            #1;
            expect_exact_hold(
                target_slice,
                expected_tag,
                line_addr
            );

            slice_req_ready_i[target_slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();
            slice_req_ready_i = '1;
        end
    endtask


    task automatic drain_all_outputs;
        integer guard;
        begin
            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '1;
            #1;

            guard = 0;
            while (slice_req_valid_o != '0) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 20) begin
                    $fatal(1, "MC-NOC-P1 final drain timeout");
                end
            end
        end
    endtask


    always_ff @(posedge clk) begin : p_black_box_scoreboard
        integer cluster_index;
        integer slice_index;
        integer accepted_cluster;
        integer accepted_for_slice;
        integer accepted_this_cycle;
        integer emitted_this_cycle;
        integer emitted_source;
        integer emitted_for_cluster [0:CLUSTER_COUNT-1];

        accepted_this_cycle = 0;
        emitted_this_cycle = 0;
        for (
            cluster_index = 0;
            cluster_index < CLUSTER_COUNT;
            cluster_index = cluster_index + 1
        ) begin
            emitted_for_cluster[cluster_index] = 0;
        end

        if (!rst_n) begin
            model_valid_q <= '0;
            accepted_total_q <= 0;
            emitted_total_q <= 0;

            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                accepted_by_cluster_q[cluster_index] <= 0;
                emitted_by_cluster_q[cluster_index] <= 0;
            end

            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                model_network_tag_q[slice_index] <= '0;
                model_line_addr_q[slice_index] <= '0;
            end
        end else begin
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                if (
                    cluster_req_valid_i[cluster_index]
                    && cluster_req_ready_o[cluster_index]
                ) begin
                    if (
                        !transport_identity_valid_for_lane(
                            cluster_index,
                            cluster_req_network_tag_i[cluster_index][
                                NETWORK_TAG_W-1
                                -:
                                CLUSTER_ID_W+CU_ID_W
                            ]
                        )
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 malformed request handshook cluster=%0d",
                            cluster_index
                        );
                    end
                    accepted_this_cycle = accepted_this_cycle + 1;
                    accepted_by_cluster_q[cluster_index] <=
                        accepted_by_cluster_q[cluster_index] + 1;
                end
            end

            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                accepted_cluster = -1;
                accepted_for_slice = 0;

                for (
                    cluster_index = 0;
                    cluster_index < CLUSTER_COUNT;
                    cluster_index = cluster_index + 1
                ) begin
                    if (
                        cluster_req_valid_i[cluster_index]
                        && cluster_req_ready_o[cluster_index]
                        && integer'(
                            home_slice(
                                cluster_req_line_addr_i[cluster_index]
                            )
                        ) == slice_index
                    ) begin
                        accepted_cluster = cluster_index;
                        accepted_for_slice = accepted_for_slice + 1;
                    end
                end

                if (accepted_for_slice > 1) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 multiple requests accepted for one slice slice=%0d count=%0d",
                        slice_index,
                        accepted_for_slice
                    );
                end

                if (
                    slice_req_valid_o[slice_index]
                    && slice_req_ready_i[slice_index]
                ) begin
                    if (!model_valid_q[slice_index]) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 phantom output emission slice=%0d",
                            slice_index
                        );
                    end
                    if (
                        slice_req_network_tag_o[slice_index]
                            !== model_network_tag_q[slice_index]
                        || slice_req_line_addr_o[slice_index]
                            !== model_line_addr_q[slice_index]
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 output differs from black-box model slice=%0d",
                            slice_index
                        );
                    end

                    emitted_source = tag_cluster(
                        slice_req_network_tag_o[slice_index][
                            NETWORK_TAG_W-1 -: CLUSTER_ID_W
                        ]
                    );
                    if (
                        emitted_source < 0
                        || emitted_source >= CLUSTER_COUNT
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 emitted illegal source encoding slice=%0d",
                            slice_index
                        );
                    end

                    emitted_this_cycle = emitted_this_cycle + 1;
                    emitted_for_cluster[emitted_source] =
                        emitted_for_cluster[emitted_source] + 1;
                end

                if (accepted_cluster >= 0) begin
                    if (
                        model_valid_q[slice_index]
                        && !(
                            slice_req_valid_o[slice_index]
                            && slice_req_ready_i[slice_index]
                        )
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 accepted request overwrote occupied hold slice=%0d",
                            slice_index
                        );
                    end

                    model_valid_q[slice_index] <= 1'b1;
                    model_network_tag_q[slice_index] <=
                        cluster_req_network_tag_i[accepted_cluster];
                    model_line_addr_q[slice_index] <=
                        cluster_req_line_addr_i[accepted_cluster];
                end else if (
                    slice_req_valid_o[slice_index]
                    && slice_req_ready_i[slice_index]
                ) begin
                    model_valid_q[slice_index] <= 1'b0;
                end
            end

            accepted_total_q <=
                accepted_total_q + accepted_this_cycle;
            emitted_total_q <=
                emitted_total_q + emitted_this_cycle;

            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                if (emitted_for_cluster[cluster_index] != 0) begin
                    emitted_by_cluster_q[cluster_index] <=
                        emitted_by_cluster_q[cluster_index]
                        + emitted_for_cluster[cluster_index];
                end
            end
        end
    end


    always @(posedge clk) begin : p_settled_black_box_invariants
        integer cluster_index;
        integer slice_index;
        integer held_total;
        integer held_source;
        integer held_by_cluster [0:CLUSTER_COUNT-1];
        logic expected_error;

        #1;

        if (!rst_n) begin
            if (
                cluster_req_ready_o != '0
                || cluster_req_tag_error_o != '0
                || slice_req_valid_o != '0
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 reset did not gate public outputs"
                );
            end
        end else begin
            held_total = 0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                held_by_cluster[cluster_index] = 0;

                expected_error =
                    cluster_req_valid_i[cluster_index]
                    && !transport_identity_valid_for_lane(
                        cluster_index,
                        cluster_req_network_tag_i[cluster_index][
                            NETWORK_TAG_W-1
                            -:
                            CLUSTER_ID_W+CU_ID_W
                        ]
                    );

                if (
                    cluster_req_tag_error_o[cluster_index]
                        !== expected_error
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 tag-error mismatch cluster=%0d",
                        cluster_index
                    );
                end
                if (
                    expected_error
                    && cluster_req_ready_o[cluster_index]
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 malformed request was ready cluster=%0d",
                        cluster_index
                    );
                end
                if (
                    cluster_req_valid_i[cluster_index]
                    && cluster_req_ready_o[cluster_index]
                    && !transport_identity_valid_for_lane(
                        cluster_index,
                        cluster_req_network_tag_i[cluster_index][
                            NETWORK_TAG_W-1
                            -:
                            CLUSTER_ID_W+CU_ID_W
                        ]
                    )
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 illegal transport handshake cluster=%0d",
                        cluster_index
                    );
                end
            end

            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                if (slice_req_valid_o[slice_index] !== model_valid_q[slice_index]) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 valid/model occupancy mismatch slice=%0d",
                        slice_index
                    );
                end

                if (
                    ^slice_req_network_tag_o[slice_index] === 1'bx
                    || ^slice_req_line_addr_o[slice_index] === 1'bx
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 output contains unknown bits slice=%0d",
                        slice_index
                    );
                end

                if (model_valid_q[slice_index]) begin
                    held_total = held_total + 1;
                    if (
                        slice_req_network_tag_o[slice_index]
                            !== model_network_tag_q[slice_index]
                        || slice_req_line_addr_o[slice_index]
                            !== model_line_addr_q[slice_index]
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 settled payload/model mismatch slice=%0d",
                            slice_index
                        );
                    end
                    if (
                        integer'(
                            home_slice(
                                slice_req_line_addr_o[slice_index]
                            )
                        ) != slice_index
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 output home mismatch slice=%0d",
                            slice_index
                        );
                    end

                    held_source = tag_cluster(
                        model_network_tag_q[slice_index][
                            NETWORK_TAG_W-1 -: CLUSTER_ID_W
                        ]
                    );
                    if (
                        held_source < 0
                        || held_source >= CLUSTER_COUNT
                    ) begin
                        $fatal(
                            1,
                            "MC-NOC-P1 held request source invalid slice=%0d",
                            slice_index
                        );
                    end
                    held_by_cluster[held_source] =
                        held_by_cluster[held_source] + 1;
                end
            end

            if (
                accepted_total_q
                != emitted_total_q + held_total
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 total conservation mismatch accepted=%0d emitted=%0d held=%0d",
                    accepted_total_q,
                    emitted_total_q,
                    held_total
                );
            end

            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                if (
                    accepted_by_cluster_q[cluster_index]
                    != emitted_by_cluster_q[cluster_index]
                        + held_by_cluster[cluster_index]
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 per-cluster conservation mismatch cluster=%0d accepted=%0d emitted=%0d held=%0d",
                        cluster_index,
                        accepted_by_cluster_q[cluster_index],
                        emitted_by_cluster_q[cluster_index],
                        held_by_cluster[cluster_index]
                    );
                end
            end
        end
    end


    task automatic run_parameter_smoke;
        integer cluster_index;
        integer slice_index;
        integer concurrent_count;
        integer ready_count;
        integer round_index;
        integer expected_cluster;
        logic [SLICE_ID_W-1:0] target_slice;
        logic [LINE_ADDR_W-1:0] common_line;
        begin
            reset_epoch();

            concurrent_count =
                (CLUSTER_COUNT < SLICE_COUNT)
                    ? CLUSTER_COUNT
                    : SLICE_COUNT;

            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '0;
            for (
                cluster_index = 0;
                cluster_index < concurrent_count;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index % CUS_PER_CLUSTER,
                        LOCAL_TAG_ENCODING_COUNT - 1
                    );
                cluster_req_line_addr_i[cluster_index] =
                    LINE_ADDR_W'(cluster_index);
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;

            ready_count = 0;
            for (
                cluster_index = 0;
                cluster_index < concurrent_count;
                cluster_index = cluster_index + 1
            ) begin
                if (cluster_req_ready_o[cluster_index]) begin
                    ready_count = ready_count + 1;
                end
            end
            if (ready_count != concurrent_count) begin
                $fatal(
                    1,
                    "MC-NOC-P1 smoke distinct-slice concurrency failed expected=%0d actual=%0d",
                    concurrent_count,
                    ready_count
                );
            end

            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;

            for (
                slice_index = 0;
                slice_index < concurrent_count;
                slice_index = slice_index + 1
            ) begin
                if (!slice_req_valid_o[slice_index]) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 smoke missing distinct-slice hold slice=%0d",
                        slice_index
                    );
                end
            end

            slice_req_ready_i = '1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            common_line = '0;
            target_slice = home_slice(common_line);

            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '1;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index % CUS_PER_CLUSTER,
                        cluster_index % LOCAL_TAG_ENCODING_COUNT
                    );
                cluster_req_line_addr_i[cluster_index] = common_line;
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;

            for (
                round_index = 0;
                round_index < CLUSTER_COUNT;
                round_index = round_index + 1
            ) begin
                expected_cluster = round_index;
                ready_count = 0;
                for (
                    cluster_index = 0;
                    cluster_index < CLUSTER_COUNT;
                    cluster_index = cluster_index + 1
                ) begin
                    if (cluster_req_ready_o[cluster_index]) begin
                        ready_count = ready_count + 1;
                    end
                end
                if (
                    ready_count != 1
                    || !cluster_req_ready_o[expected_cluster]
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 smoke RR mismatch round=%0d expected=%0d",
                        round_index,
                        expected_cluster
                    );
                end
                @(posedge clk);
                @(negedge clk);
                #1;
            end

            clear_requests();
            slice_req_ready_i[target_slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            if (
                accepted_total_q != emitted_total_q
                || model_valid_q != '0
            ) begin
                $fatal(1, "MC-NOC-P1 smoke final conservation failed");
            end

            $display("MC_NOC_P1_PARAMETER_SMOKE=PASS");
        end
    endtask


    generate
        if (FULL_SCENARIOS != 0) begin : gen_full_scenarios
    task automatic run_full_scenarios;
        logic [LINE_ADDR_W-1:0] line_s0;
        logic [LINE_ADDR_W-1:0] line_s1;
        logic [LINE_ADDR_W-1:0] line_s2;
        logic [LINE_ADDR_W-1:0] line_s3;
        logic [LINE_ADDR_W-1:0] line_fold;
        logic [LINE_ADDR_W-1:0] line_max;
        logic [NETWORK_TAG_W-1:0] held_tag;
        logic [LINE_ADDR_W-1:0] held_line;
        integer cluster_index;
        integer slice_index;
        integer ready_count;
        integer winner;
        integer round_index;
        logic [SLICE_ID_W-1:0] target_slice;
        logic [SLICE_ID_W-1:0] other_slice;
        integer emitted_before;
        begin
            if (
                CLUSTER_COUNT != 3
                || CUS_PER_CLUSTER != 3
                || MSHR_COUNT != 3
                || SLICE_COUNT != 4
                || SLICE_HASH_SHIFT != 8
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 full scenarios require K3 U3 M3 S4 SHIFT8"
                );
            end

            line_s0 = LINE_ADDR_W'(0);
            line_s1 = LINE_ADDR_W'(1);
            line_s2 = LINE_ADDR_W'(2);
            line_s3 = LINE_ADDR_W'(3);
            line_fold = LINE_ADDR_W'((1 << SLICE_HASH_SHIFT) | 1);
            line_max = '1;

            rst_n = 1'b0;
            clear_inputs();
            @(negedge clk);
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_valid_i[cluster_index] = 1'b1;
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(cluster_index, 0, 0);
                cluster_req_line_addr_i[cluster_index] =
                    LINE_ADDR_W'(cluster_index);
            end
            repeat (2) @(posedge clk);
            #1;
            if (
                cluster_req_ready_o != '0
                || cluster_req_tag_error_o != '0
                || slice_req_valid_o != '0
            ) begin
                $fatal(1, "MC-NOC-P1 reset output gating failed");
            end
            $display("MC_NOC_P1_01_RESET_OUTPUTS_GATED=PASS");

            @(negedge clk);
            clear_requests();
            rst_n = 1'b1;
            #1;
            assert_no_slice_output();
            if (cluster_req_tag_error_o != '0) begin
                $fatal(1, "MC-NOC-P1 reset release exposed error");
            end
            $display("MC_NOC_P1_02_RESET_RELEASE_EMPTY=PASS");

            if (
                integer'(home_slice(line_s0)) != 0
                || integer'(home_slice(line_s1)) != 1
                || integer'(home_slice(line_s2)) != 2
                || integer'(home_slice(line_s3)) != 3
            ) begin
                $fatal(1, "MC-NOC-P1 fixed low-bit hash vectors wrong");
            end
            route_and_drain(0, 0, 0, line_s0);
            route_and_drain(0, 0, 1, line_s1);
            route_and_drain(0, 0, 2, line_s2);
            route_and_drain(0, 0, 3, line_s3);
            $display("MC_NOC_P1_03_HASH_LOW_BITS_ALL_SLICES=PASS");

            if (integer'(home_slice(line_fold)) != 0) begin
                $fatal(1, "MC-NOC-P1 fixed XOR-fold vector wrong");
            end
            route_and_drain(0, 0, 0, line_fold);
            $display("MC_NOC_P1_04_HASH_XOR_FOLD=PASS");

            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                route_and_drain(
                    cluster_index,
                    cluster_index,
                    cluster_index,
                    line_s3
                );
            end
            $display("MC_NOC_P1_05_SAME_LINE_ALL_CLUSTERS_SAME_HOME=PASS");

            route_and_drain(0, 0, 0, line_s0);
            $display("MC_NOC_P1_06_C0_TO_S0=PASS");

            route_and_drain(0, 0, 1, line_s1);
            $display("MC_NOC_P1_07_C0_TO_S1=PASS");

            route_and_drain(1, 1, 0, line_s0);
            $display("MC_NOC_P1_08_C1_TO_S0=PASS");

            route_and_drain(1, 1, 1, line_s1);
            $display("MC_NOC_P1_09_C1_TO_S1=PASS");

            route_and_drain(2, 2, 2, line_s2);
            $display("MC_NOC_P1_10_NETWORK_TAG_BIT_EXACT_PRESERVED=PASS");

            route_and_drain(2, 1, 1, line_max);
            $display("MC_NOC_P1_11_LINE_ADDRESS_BIT_EXACT_PRESERVED=PASS");

            if (LOCAL_TAG_ENCODING_COUNT <= MSHR_COUNT) begin
                $fatal(
                    1,
                    "MC-NOC-P1 full configuration lacks unused local-tag encoding"
                );
            end
            route_and_drain(
                1,
                2,
                LOCAL_TAG_ENCODING_COUNT - 1,
                line_s2
            );
            $display("MC_NOC_P1_12_LOCAL_TAG_UNUSED_ENCODING_OPAQUE=PASS");

            route_and_drain(2, 0, 1, line_s3);
            $display("MC_NOC_P1_13_SINGLE_REQUEST_EXACTLY_ONE_HOME_OUTPUT=PASS");

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(0, 0, 0);
            cluster_req_line_addr_i[0] = line_s0;
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[1] =
                make_network_tag(1, 1, 0);
            cluster_req_line_addr_i[1] = line_s1;
            cluster_req_valid_i[1] = 1'b1;
            #1;
            if (
                !cluster_req_ready_o[0]
                || !cluster_req_ready_o[1]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 different slices not accepted concurrently"
                );
            end
            $display("MC_NOC_P1_14_DIFFERENT_SLICE_DUAL_ACCEPT=PASS");

            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            if (
                !slice_req_valid_o[0]
                || !slice_req_valid_o[1]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 dual held outputs missing"
                );
            end
            slice_req_ready_i[0] = 1'b1;
            slice_req_ready_i[1] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();
            $display("MC_NOC_P1_15_DIFFERENT_SLICE_DUAL_EMIT=PASS");

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index,
                        cluster_index
                    );
                cluster_req_line_addr_i[cluster_index] =
                    LINE_ADDR_W'(cluster_index);
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;
            if (cluster_req_ready_o != '1) begin
                $fatal(
                    1,
                    "MC-NOC-P1 three independent slices did not all grant"
                );
            end
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            if (
                !slice_req_valid_o[0]
                || !slice_req_valid_o[1]
                || !slice_req_valid_o[2]
                || slice_req_valid_o[3]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 three-slice output concurrency failed"
                );
            end
            slice_req_ready_i = '1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();
            $display("MC_NOC_P1_16_THREE_SLICE_SIMULTANEOUS_PROGRESS=PASS");

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index,
                        cluster_index
                    );
                cluster_req_line_addr_i[cluster_index] = line_s2;
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;
            ready_count = 0;
            winner = -1;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                if (cluster_req_ready_o[cluster_index]) begin
                    ready_count = ready_count + 1;
                    winner = cluster_index;
                end
            end
            if (ready_count != 1 || winner != 0) begin
                $fatal(
                    1,
                    "MC-NOC-P1 same-slice initial grant wrong winner=%0d count=%0d",
                    winner,
                    ready_count
                );
            end
            $display("MC_NOC_P1_17_SAME_SLICE_SINGLE_GRANT=PASS");

            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b0;
            slice_req_ready_i[2] = 1'b1;
            #1;
            if (!cluster_req_ready_o[1]) begin
                $fatal(
                    1,
                    "MC-NOC-P1 same-slice waiter was not next"
                );
            end
            $display("MC_NOC_P1_18_SAME_SLICE_WAITER_NEXT=PASS");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '1;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index,
                        cluster_index
                    );
                cluster_req_line_addr_i[cluster_index] = line_s1;
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;
            for (
                round_index = 0;
                round_index < CLUSTER_COUNT;
                round_index = round_index + 1
            ) begin
                ready_count = 0;
                for (
                    cluster_index = 0;
                    cluster_index < CLUSTER_COUNT;
                    cluster_index = cluster_index + 1
                ) begin
                    if (cluster_req_ready_o[cluster_index]) begin
                        ready_count = ready_count + 1;
                    end
                end
                if (
                    ready_count != 1
                    || !cluster_req_ready_o[round_index]
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 full RR round mismatch round=%0d",
                        round_index
                    );
                end
                @(posedge clk);
                @(negedge clk);
                #1;
            end
            $display("MC_NOC_P1_19_ROUND_ROBIN_ALL_CLUSTERS_ONE_ROUND=PASS");

            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P1 RR did not wrap to cluster zero");
            end
            $display("MC_NOC_P1_20_ROUND_ROBIN_WRAP=PASS");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '1;
            cluster_req_network_tag_i[0] =
                make_network_tag(0, 0, 0);
            cluster_req_line_addr_i[0] = line_s0;
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[2] =
                make_network_tag(2, 2, 2);
            cluster_req_line_addr_i[2] = line_s0;
            cluster_req_valid_i[2] = 1'b1;
            #1;
            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P1 sparse RR first winner wrong");
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!cluster_req_ready_o[2]) begin
                $fatal(1, "MC-NOC-P1 sparse RR did not skip idle lane");
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P1 sparse RR did not wrap");
            end
            $display("MC_NOC_P1_21_ROUND_ROBIN_SPARSE_CONTENDERS=PASS");
            clear_requests();
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '1;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index,
                        cluster_index
                    );
                cluster_req_line_addr_i[cluster_index] = line_s3;
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;
            for (
                round_index = 0;
                round_index < 2 * CLUSTER_COUNT;
                round_index = round_index + 1
            ) begin
                if (
                    !cluster_req_ready_o[
                        round_index % CLUSTER_COUNT
                    ]
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 fairness bound/order failed opportunity=%0d",
                        round_index
                    );
                end
                @(posedge clk);
                @(negedge clk);
                #1;
            end
            $display("MC_NOC_P1_22_FAIRNESS_BOUND_K_SERVICE_OPPORTUNITIES=PASS");
            clear_requests();
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(0, 1, 2);
            cluster_req_line_addr_i[0] = line_s2;
            cluster_req_valid_i[0] = 1'b1;
            #1;
            if (
                !cluster_req_ready_o[0]
                || slice_req_valid_o != '0
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 request bypassed registered hold"
                );
            end
            $display("MC_NOC_P1_23_REGISTERED_HOLD_NO_COMBINATIONAL_BYPASS=PASS");

            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            target_slice = home_slice(line_s2);
            held_tag = slice_req_network_tag_o[target_slice];
            held_line = slice_req_line_addr_o[target_slice];
            if (!slice_req_valid_o[target_slice]) begin
                $fatal(1, "MC-NOC-P1 stalled hold not created");
            end
            $display("MC_NOC_P1_24_STALL_VALID_HELD=PASS");

            repeat (3) begin
                cluster_req_network_tag_i[0] =
                    make_network_tag(0, 2, 3);
                cluster_req_line_addr_i[0] = line_max;
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    !slice_req_valid_o[target_slice]
                    || slice_req_network_tag_o[target_slice]
                        !== held_tag
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 stalled network tag changed"
                    );
                end
            end
            $display("MC_NOC_P1_25_STALL_NETWORK_TAG_STABLE=PASS");

            if (slice_req_line_addr_o[target_slice] !== held_line) begin
                $fatal(1, "MC-NOC-P1 stalled line address changed");
            end
            $display("MC_NOC_P1_26_STALL_LINE_ADDRESS_STABLE=PASS");

            @(negedge clk);
            cluster_req_network_tag_i[1] =
                make_network_tag(1, 1, 1);
            cluster_req_line_addr_i[1] = line_s2;
            cluster_req_valid_i[1] = 1'b1;
            #1;
            if (cluster_req_ready_o[1]) begin
                $fatal(
                    1,
                    "MC-NOC-P1 stalled slice accepted overwrite"
                );
            end
            $display("MC_NOC_P1_27_STALLED_SLICE_REJECTS_OVERWRITE=PASS");

            other_slice =
                (target_slice == 0)
                    ? SLICE_ID_W'(1)
                    : SLICE_ID_W'(0);
            cluster_req_network_tag_i[2] =
                make_network_tag(2, 2, 2);
            cluster_req_line_addr_i[2] =
                LINE_ADDR_W'(other_slice);
            cluster_req_valid_i[2] = 1'b1;
            #1;
            if (!cluster_req_ready_o[2]) begin
                $fatal(
                    1,
                    "MC-NOC-P1 stalled slice blocked unrelated accept"
                );
            end
            $display("MC_NOC_P1_28_STALLED_SLICE_UNRELATED_ACCEPT=PASS");

            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[2] = 1'b0;
            #1;
            if (
                !slice_req_valid_o[other_slice]
                || !slice_req_valid_o[target_slice]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 unrelated slice output did not progress"
                );
            end
            $display("MC_NOC_P1_29_STALLED_SLICE_UNRELATED_EMIT=PASS");

            slice_req_ready_i[other_slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                slice_req_valid_o[other_slice]
                || !slice_req_valid_o[target_slice]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 unrelated drain disturbed stalled slice"
                );
            end

            cluster_req_valid_i[1] = 1'b0;
            emitted_before = emitted_total_q;
            slice_req_ready_i[target_slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                slice_req_valid_o[target_slice]
                || emitted_total_q != emitted_before + 1
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 stalled request did not drain exactly once"
                );
            end
            $display("MC_NOC_P1_30_STALL_RELEASE_EXACTLY_ONCE=PASS");

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(0, 0, 0);
            cluster_req_line_addr_i[0] = line_s1;
            cluster_req_valid_i[0] = 1'b1;
            #1;
            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b0;
            cluster_req_network_tag_i[1] =
                make_network_tag(1, 1, 1);
            cluster_req_line_addr_i[1] = line_s1;
            cluster_req_valid_i[1] = 1'b1;
            slice_req_ready_i[1] = 1'b1;
            #1;
            if (!cluster_req_ready_o[1]) begin
                $fatal(
                    1,
                    "MC-NOC-P1 turnover replacement was not accepted"
                );
            end
            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[1] = 1'b0;
            #1;
            if (!slice_req_valid_o[1]) begin
                $fatal(1, "MC-NOC-P1 turnover introduced a bubble");
            end
            $display("MC_NOC_P1_31_SAME_CYCLE_TURNOVER_NO_BUBBLE=PASS");

            if (
                slice_req_network_tag_o[1]
                    !== make_network_tag(1, 1, 1)
                || slice_req_line_addr_o[1] !== line_s1
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 turnover replacement payload wrong"
                );
            end
            $display("MC_NOC_P1_32_SAME_CYCLE_TURNOVER_REPLACEMENT_EXACT=PASS");
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index,
                        cluster_index
                    );
                cluster_req_line_addr_i[cluster_index] = line_s0;
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;
            if (!cluster_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P1 cursor initial winner wrong");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[0] = 1'b0;
            #1;
            if (cluster_req_ready_o != '0) begin
                $fatal(
                    1,
                    "MC-NOC-P1 cursor test accepted while stalled"
                );
            end
            @(posedge clk);
            @(negedge clk);
            slice_req_ready_i[0] = 1'b1;
            #1;
            if (!cluster_req_ready_o[1]) begin
                $fatal(
                    1,
                    "MC-NOC-P1 cursor changed without successful handshake"
                );
            end
            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[1] = 1'b0;
            slice_req_ready_i[0] = 1'b0;
            repeat (2) begin
                #1;
                if (cluster_req_ready_o != '0) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 cursor test accepted in second stall"
                    );
                end
                @(posedge clk);
                @(negedge clk);
            end
            slice_req_ready_i[0] = 1'b1;
            #1;
            if (!cluster_req_ready_o[2]) begin
                $fatal(
                    1,
                    "MC-NOC-P1 cursor changed across two stalled edges"
                );
            end
            $display("MC_NOC_P1_33_RR_CURSOR_ONLY_SUCCESSFUL_HANDSHAKE=PASS");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            @(posedge clk);
            @(negedge clk);
            #1;
            assert_no_slice_output();

            reset_epoch();
            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(3, 0, 0);
            cluster_req_line_addr_i[0] = line_s0;
            cluster_req_valid_i[0] = 1'b1;
            #1;
            if (
                !cluster_req_tag_error_o[0]
                || cluster_req_ready_o[0]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 unused cluster encoding not rejected"
                );
            end
            $display("MC_NOC_P1_34_UNUSED_CLUSTER_ENCODING_REJECTED=PASS");

            cluster_req_network_tag_i[0] =
                make_network_tag(1, 0, 0);
            #1;
            if (
                !cluster_req_tag_error_o[0]
                || cluster_req_ready_o[0]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 wrong legal cluster prefix not rejected"
                );
            end
            $display("MC_NOC_P1_35_WRONG_LEGAL_CLUSTER_PREFIX_REJECTED=PASS");

            cluster_req_network_tag_i[0] =
                make_network_tag(0, 3, 0);
            #1;
            if (
                !cluster_req_tag_error_o[0]
                || cluster_req_ready_o[0]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 unused CU encoding not rejected"
                );
            end
            $display("MC_NOC_P1_36_UNUSED_CU_ENCODING_REJECTED=PASS");

            cluster_req_network_tag_i[0] =
                make_network_tag(3, 0, 0);
            cluster_req_network_tag_i[1] =
                make_network_tag(0, 1, 0);
            cluster_req_line_addr_i[1] = line_s1;
            cluster_req_valid_i[1] = 1'b1;
            cluster_req_network_tag_i[2] =
                make_network_tag(2, 3, 0);
            cluster_req_line_addr_i[2] = line_s2;
            cluster_req_valid_i[2] = 1'b1;
            #1;
            if (
                cluster_req_tag_error_o != '1
                || cluster_req_ready_o != '0
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 malformed ready/error vector wrong"
                );
            end
            $display("MC_NOC_P1_37_MALFORMED_READY_LOW_ERROR_HIGH=PASS");

            repeat (2) @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            if (
                slice_req_valid_o != '0
                || accepted_total_q != 0
                || emitted_total_q != 0
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 malformed request created phantom traffic"
                );
            end
            $display("MC_NOC_P1_38_MALFORMED_NO_CAPTURE_NO_PHANTOM=PASS");

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(3, 0, 0);
            cluster_req_line_addr_i[0] = line_s0;
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[1] =
                make_network_tag(1, 1, 1);
            cluster_req_line_addr_i[1] = line_s0;
            cluster_req_valid_i[1] = 1'b1;
            #1;
            if (
                !cluster_req_tag_error_o[0]
                || !cluster_req_ready_o[1]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 malformed lane blocked legal same-slice peer"
                );
            end
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            expect_exact_hold(
                0,
                make_network_tag(1, 1, 1),
                line_s0
            );
            $display("MC_NOC_P1_39_MALFORMED_DOES_NOT_BLOCK_SAME_SLICE_LEGAL=PASS");
            slice_req_ready_i[0] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(3, 0, 0);
            cluster_req_line_addr_i[0] = line_s0;
            cluster_req_valid_i[0] = 1'b1;
            cluster_req_network_tag_i[1] =
                make_network_tag(1, 1, 1);
            cluster_req_line_addr_i[1] = line_s1;
            cluster_req_valid_i[1] = 1'b1;
            #1;
            if (
                !cluster_req_tag_error_o[0]
                || !cluster_req_ready_o[1]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 malformed lane blocked unrelated slice"
                );
            end
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            expect_exact_hold(
                1,
                make_network_tag(1, 1, 1),
                line_s1
            );
            $display("MC_NOC_P1_40_MALFORMED_DOES_NOT_BLOCK_OTHER_SLICE_LEGAL=PASS");
            slice_req_ready_i[1] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[0] =
                make_network_tag(3, 0, 0);
            cluster_req_line_addr_i[0] = line_s2;
            cluster_req_valid_i[0] = 1'b1;
            #1;
            if (!cluster_req_tag_error_o[0]) begin
                $fatal(1, "MC-NOC-P1 correction setup lacked error");
            end
            cluster_req_network_tag_i[0] =
                make_network_tag(0, 0, 0);
            #1;
            if (
                cluster_req_tag_error_o[0]
                || !cluster_req_ready_o[0]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 error did not clear after correction"
                );
            end
            $display("MC_NOC_P1_41_ERROR_CLEARS_AFTER_CORRECTION=PASS");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            #1;
            slice_req_ready_i[2] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            @(negedge clk);
            slice_req_ready_i = '0;
            cluster_req_network_tag_i[2] =
                make_network_tag(2, 2, 2);
            cluster_req_line_addr_i[2] = line_s3;
            cluster_req_valid_i[2] = 1'b1;
            #1;
            @(posedge clk);
            @(negedge clk);
            cluster_req_valid_i[2] = 1'b0;
            #1;
            if (!slice_req_valid_o[3]) begin
                $fatal(1, "MC-NOC-P1 reset-flush setup hold missing");
            end
            rst_n = 1'b0;
            @(posedge clk);
            #1;
            if (slice_req_valid_o != '0) begin
                $fatal(1, "MC-NOC-P1 reset did not flush stalled holds");
            end
            $display("MC_NOC_P1_42_RESET_FLUSHES_STALLED_HOLDS=PASS");

            @(negedge clk);
            clear_inputs();
            rst_n = 1'b1;
            slice_req_ready_i = '0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                cluster_req_network_tag_i[cluster_index] =
                    make_network_tag(
                        cluster_index,
                        cluster_index,
                        cluster_index
                    );
                cluster_req_line_addr_i[cluster_index] = line_s3;
                cluster_req_valid_i[cluster_index] = 1'b1;
            end
            #1;
            ready_count = 0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                if (cluster_req_ready_o[cluster_index]) begin
                    ready_count = ready_count + 1;
                end
            end
            if (
                ready_count != 1
                || !cluster_req_ready_o[0]
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 reset did not restart RR at cluster zero"
                );
            end
            $display("MC_NOC_P1_43_RESET_RESTARTS_RR=PASS");
            @(posedge clk);
            @(negedge clk);
            clear_requests();
            slice_req_ready_i = '1;
            #1;
            @(posedge clk);
            @(negedge clk);
            #1;

            assert_no_slice_output();
            if (
                model_valid_q != '0
                || accepted_total_q != emitted_total_q
            ) begin
                $fatal(
                    1,
                    "MC-NOC-P1 final conservation/drain failed"
                );
            end
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                if (
                    accepted_by_cluster_q[cluster_index]
                    != emitted_by_cluster_q[cluster_index]
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 final per-cluster drain failed cluster=%0d",
                        cluster_index
                    );
                end
            end
            for (
                slice_index = 0;
                slice_index < SLICE_COUNT;
                slice_index = slice_index + 1
            ) begin
                if (model_valid_q[slice_index]) begin
                    $fatal(
                        1,
                        "MC-NOC-P1 final slice not empty slice=%0d",
                        slice_index
                    );
                end
            end
            $display("MC_NOC_P1_44_FINAL_PER_SLICE_AND_PER_CLUSTER_CONSERVATION_DRAIN=PASS");
        end
    endtask


            initial begin : p_full_main
                rst_n = 1'b0;
                clear_inputs();

            run_full_scenarios();
                $finish;
            end
        end else begin : gen_parameter_smoke
            initial begin : p_smoke_main
                rst_n = 1'b0;
                clear_inputs();

                run_parameter_smoke();
                $finish;
            end
        end
    endgenerate


    initial begin : p_timeout
        #500000;
        $fatal(1, "MC-NOC-P1 TB timeout");
    end

endmodule
