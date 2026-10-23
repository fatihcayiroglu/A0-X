`timescale 1ns/1ps

module a0_shared_l2_subsystem_tb;

    localparam integer CLIENT_COUNT = 3;
    localparam integer LOCAL_TAG_W = 2;

    localparam integer STORE_LANES_PER_CLIENT = 2;

    localparam integer LINE_WORDS = 8;
    localparam integer L2_SET_COUNT = 4;
    localparam integer L2_MISS_COUNT = 2;

    localparam integer CLIENT_ID_W =
        $clog2(CLIENT_COUNT);

    localparam integer GLOBAL_TAG_W =
        CLIENT_ID_W
        + LOCAL_TAG_W;

    localparam integer WORD_SELECT_W =
        $clog2(LINE_WORDS);

    localparam integer LINE_ADDR_W =
        32 - WORD_SELECT_W;


    logic clk;
    logic rst_n;


    logic [CLIENT_COUNT-1:0]
        client_req_valid_i;

    logic [CLIENT_COUNT-1:0]
        client_req_ready_o;

    logic [LOCAL_TAG_W-1:0]
        client_req_local_tag_i
            [0:CLIENT_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        client_req_line_addr_i
            [0:CLIENT_COUNT-1];


    logic [CLIENT_COUNT-1:0]
        client_resp_valid_o;

    logic [LOCAL_TAG_W-1:0]
        client_resp_local_tag_o
            [0:CLIENT_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        client_resp_line_addr_o
            [0:CLIENT_COUNT-1];

    logic
        client_resp_fault_o
            [0:CLIENT_COUNT-1];

    logic [31:0]
        client_resp_data_o
            [0:CLIENT_COUNT-1]
            [0:LINE_WORDS-1];


    logic [CLIENT_COUNT-1:0]
        client_store_valid_i;

    logic [STORE_LANES_PER_CLIENT-1:0]
        client_store_lane_mask_i
            [0:CLIENT_COUNT-1];

    logic [31:0]
        client_store_word_addr_i
            [0:CLIENT_COUNT-1]
            [0:STORE_LANES_PER_CLIENT-1];


    logic line_mem_req_valid_o;
    logic line_mem_req_ready_i;

    logic [GLOBAL_TAG_W-1:0]
        line_mem_req_global_tag_o;

    logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o;


    logic line_mem_resp_valid_i;

    logic [GLOBAL_TAG_W-1:0]
        line_mem_resp_global_tag_i;

    logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i;

    logic line_mem_resp_fault_i;

    logic [31:0]
        line_mem_resp_data_i
            [0:LINE_WORDS-1];


    logic line_resp_tag_error_o;


    logic [GLOBAL_TAG_W-1:0] tag_a;
    logic [GLOBAL_TAG_W-1:0] tag_b;
    logic [GLOBAL_TAG_W-1:0] tag_c;

    logic [GLOBAL_TAG_W-1:0] stable_tag;
    logic [LINE_ADDR_W-1:0] stable_line;

    integer word_index;
    integer miss_index;
    integer valid_miss_count;
    integer killed_match_count;


    a0_shared_l2_subsystem #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .STORE_LANES_PER_CLIENT(
            STORE_LANES_PER_CLIENT
        ),
        .LINE_WORDS(LINE_WORDS),
        .L2_SET_COUNT(L2_SET_COUNT),
        .L2_MISS_COUNT(L2_MISS_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .client_req_valid_i(
            client_req_valid_i
        ),
        .client_req_ready_o(
            client_req_ready_o
        ),
        .client_req_local_tag_i(
            client_req_local_tag_i
        ),
        .client_req_line_addr_i(
            client_req_line_addr_i
        ),

        .client_resp_valid_o(
            client_resp_valid_o
        ),
        .client_resp_local_tag_o(
            client_resp_local_tag_o
        ),
        .client_resp_line_addr_o(
            client_resp_line_addr_o
        ),
        .client_resp_fault_o(
            client_resp_fault_o
        ),
        .client_resp_data_o(
            client_resp_data_o
        ),

        .client_store_valid_i(
            client_store_valid_i
        ),
        .client_store_lane_mask_i(
            client_store_lane_mask_i
        ),
        .client_store_word_addr_i(
            client_store_word_addr_i
        ),

        .line_mem_req_valid_o(
            line_mem_req_valid_o
        ),
        .line_mem_req_ready_i(
            line_mem_req_ready_i
        ),
        .line_mem_req_global_tag_o(
            line_mem_req_global_tag_o
        ),
        .line_mem_req_line_addr_o(
            line_mem_req_line_addr_o
        ),

        .line_mem_resp_valid_i(
            line_mem_resp_valid_i
        ),
        .line_mem_resp_global_tag_i(
            line_mem_resp_global_tag_i
        ),
        .line_mem_resp_line_addr_i(
            line_mem_resp_line_addr_i
        ),
        .line_mem_resp_fault_i(
            line_mem_resp_fault_i
        ),
        .line_mem_resp_data_i(
            line_mem_resp_data_i
        ),

        .line_resp_tag_error_o(
            line_resp_tag_error_o
        )
    );


    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    function automatic logic [GLOBAL_TAG_W-1:0]
        make_global_tag(
            input logic [CLIENT_ID_W-1:0] client_id,
            input logic [LOCAL_TAG_W-1:0] local_tag
        );
        begin
            make_global_tag = {
                client_id,
                local_tag
            };
        end
    endfunction


    function automatic logic [31:0]
        make_word_addr(
            input logic [LINE_ADDR_W-1:0] line_addr,
            input integer word_offset
        );
        begin
            make_word_addr =
                {
                    line_addr,
                    {WORD_SELECT_W{1'b0}}
                }
                + 32'(word_offset);
        end
    endfunction


    task automatic clear_inputs;
        integer c;
        integer l;
        integer w;
        begin
            client_req_valid_i = '0;
            client_store_valid_i = '0;

            line_mem_req_ready_i = 1'b1;

            line_mem_resp_valid_i = 1'b0;
            line_mem_resp_global_tag_i = '0;
            line_mem_resp_line_addr_i = '0;
            line_mem_resp_fault_i = 1'b0;

            for (
                c = 0;
                c < CLIENT_COUNT;
                c = c + 1
            ) begin
                client_req_local_tag_i[c] = '0;
                client_req_line_addr_i[c] = '0;

                client_store_lane_mask_i[c] = '0;

                for (
                    l = 0;
                    l < STORE_LANES_PER_CLIENT;
                    l = l + 1
                ) begin
                    client_store_word_addr_i[c][l] = '0;
                end
            end

            for (
                w = 0;
                w < LINE_WORDS;
                w = w + 1
            ) begin
                line_mem_resp_data_i[w] = '0;
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


    task automatic pulse_client_request(
        input integer client,
        input logic [LOCAL_TAG_W-1:0] local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer wait_count;
        begin
            @(negedge clk);

            client_req_valid_i = '0;

            client_req_local_tag_i[
                client
            ] = local_tag;

            client_req_line_addr_i[
                client
            ] = line_addr;

            client_req_valid_i[
                client
            ] = 1'b1;

            #1;

            wait_count = 0;

            while (
                !client_req_ready_o[
                    client
                ]
            ) begin
                if (wait_count >= 40) begin
                    $fatal(
                        1,
                        "RTL9D3 client request timeout client=%0d",
                        client
                    );
                end

                @(posedge clk);
                @(negedge clk);
                #1;

                wait_count =
                    wait_count + 1;
            end

            @(posedge clk);

            @(negedge clk);

            client_req_valid_i[
                client
            ] = 1'b0;

            #1;
        end
    endtask


    task automatic wait_backend_request(
        input logic [GLOBAL_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line,
        output logic [GLOBAL_TAG_W-1:0] observed_tag
    );
        integer wait_count;
        begin
            wait_count = 0;

            while (!line_mem_req_valid_o) begin
                if (wait_count >= 40) begin
                    $fatal(
                        1,
                        "RTL9D3 external backend request timeout"
                    );
                end

                @(negedge clk);
                #1;

                wait_count =
                    wait_count + 1;
            end

            observed_tag =
                line_mem_req_global_tag_o;

            if (
                line_mem_req_global_tag_o
                != expected_tag
            ) begin
                $fatal(
                    1,
                    "RTL9D3 backend global tag mismatch expected=%h actual=%h",
                    expected_tag,
                    line_mem_req_global_tag_o
                );
            end

            if (
                line_mem_req_line_addr_o
                != expected_line
            ) begin
                $fatal(
                    1,
                    "RTL9D3 backend line mismatch expected=%h actual=%h",
                    expected_line,
                    line_mem_req_line_addr_o
                );
            end

            /*
             * Seeing downstream valid combinationally is not yet proof that
             * the shared L2 has committed the miss into a tracker slot.
             *
             * The external backend is ready in this focused TB, so cross the
             * accepting clock edge and allow nonblocking state updates to
             * settle before returning to any test that inspects miss_valid_q.
             */
            if (!line_mem_req_ready_i) begin
                $fatal(
                    1,
                    "RTL9D3 backend request observed while backend not ready"
                );
            end

            @(posedge clk);
            #1;
        end
    endtask


    task automatic send_miss(
        input integer client,
        input logic [LOCAL_TAG_W-1:0] local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        output logic [GLOBAL_TAG_W-1:0] observed_tag
    );
        logic [GLOBAL_TAG_W-1:0] expected_tag;
        begin
            expected_tag =
                make_global_tag(
                    CLIENT_ID_W'(client),
                    local_tag
                );

            pulse_client_request(
                client,
                local_tag,
                line_addr
            );

            wait_backend_request(
                expected_tag,
                line_addr,
                observed_tag
            );
        end
    endtask


    task automatic respond_to_client(
        input logic [GLOBAL_TAG_W-1:0] global_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] data_base,
        input integer expected_client,
        input logic [LOCAL_TAG_W-1:0] expected_local_tag
    );
        integer c;
        integer w;
        begin
            @(negedge clk);

            line_mem_resp_global_tag_i =
                global_tag;

            line_mem_resp_line_addr_i =
                line_addr;

            line_mem_resp_fault_i =
                fault;

            for (
                w = 0;
                w < LINE_WORDS;
                w = w + 1
            ) begin
                line_mem_resp_data_i[w] =
                    data_base
                    + 32'(w);
            end

            line_mem_resp_valid_i =
                1'b1;

            #1;

            for (
                c = 0;
                c < CLIENT_COUNT;
                c = c + 1
            ) begin
                if (c == expected_client) begin
                    if (!client_resp_valid_o[c]) begin
                        $fatal(
                            1,
                            "RTL9D3 expected client response missing client=%0d",
                            expected_client
                        );
                    end

                    if (
                        client_resp_local_tag_o[c]
                        != expected_local_tag
                    ) begin
                        $fatal(
                            1,
                            "RTL9D3 restored local tag mismatch client=%0d",
                            expected_client
                        );
                    end

                    if (
                        client_resp_line_addr_o[c]
                        != line_addr
                    ) begin
                        $fatal(
                            1,
                            "RTL9D3 restored line mismatch client=%0d",
                            expected_client
                        );
                    end

                    if (
                        client_resp_fault_o[c]
                        != fault
                    ) begin
                        $fatal(
                            1,
                            "RTL9D3 restored fault mismatch client=%0d",
                            expected_client
                        );
                    end

                    for (
                        w = 0;
                        w < LINE_WORDS;
                        w = w + 1
                    ) begin
                        if (
                            client_resp_data_o[c][w]
                            != (
                                data_base
                                + 32'(w)
                            )
                        ) begin
                            $fatal(
                                1,
                                "RTL9D3 response data mismatch client=%0d word=%0d",
                                expected_client,
                                w
                            );
                        end
                    end
                end else begin
                    if (client_resp_valid_o[c]) begin
                        $fatal(
                            1,
                            "RTL9D3 response fanned out to wrong client=%0d",
                            c
                        );
                    end
                end
            end

            @(posedge clk);

            @(negedge clk);

            line_mem_resp_valid_i = 1'b0;
            line_mem_resp_fault_i = 1'b0;

            #1;
        end
    endtask


    task automatic wait_hit_response(
        input integer expected_client,
        input logic [LOCAL_TAG_W-1:0] expected_local_tag,
        input logic [LINE_ADDR_W-1:0] expected_line,
        input logic [31:0] expected_data_base
    );
        integer wait_count;
        integer c;
        integer w;
        begin
            wait_count = 0;

            while (
                !client_resp_valid_o[
                    expected_client
                ]
            ) begin
                if (line_mem_req_valid_o) begin
                    $fatal(
                        1,
                        "RTL9D3 expected shared-L2 hit leaked to backend"
                    );
                end

                if (wait_count >= 40) begin
                    $fatal(
                        1,
                        "RTL9D3 hit response timeout client=%0d",
                        expected_client
                    );
                end

                @(negedge clk);
                #1;

                wait_count =
                    wait_count + 1;
            end

            if (line_mem_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9D3 shared-L2 hit issued backend request"
                );
            end

            for (
                c = 0;
                c < CLIENT_COUNT;
                c = c + 1
            ) begin
                if (c == expected_client) begin
                    if (
                        client_resp_local_tag_o[c]
                        != expected_local_tag
                    ) begin
                        $fatal(
                            1,
                            "RTL9D3 hit local tag mismatch"
                        );
                    end

                    if (
                        client_resp_line_addr_o[c]
                        != expected_line
                    ) begin
                        $fatal(
                            1,
                            "RTL9D3 hit line mismatch"
                        );
                    end

                    if (client_resp_fault_o[c]) begin
                        $fatal(
                            1,
                            "RTL9D3 hit unexpectedly faulted"
                        );
                    end

                    for (
                        w = 0;
                        w < LINE_WORDS;
                        w = w + 1
                    ) begin
                        if (
                            client_resp_data_o[c][w]
                            != (
                                expected_data_base
                                + 32'(w)
                            )
                        ) begin
                            $fatal(
                                1,
                                "RTL9D3 hit data mismatch word=%0d",
                                w
                            );
                        end
                    end
                end else begin
                    if (client_resp_valid_o[c]) begin
                        $fatal(
                            1,
                            "RTL9D3 hit response wrong-client fanout"
                        );
                    end
                end
            end

            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic send_hit(
        input integer client,
        input logic [LOCAL_TAG_W-1:0] local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] data_base
    );
        begin
            pulse_client_request(
                client,
                local_tag,
                line_addr
            );

            wait_hit_response(
                client,
                local_tag,
                line_addr,
                data_base
            );
        end
    endtask


    task automatic fill_line(
        input integer client,
        input logic [LOCAL_TAG_W-1:0] local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] data_base,
        output logic [GLOBAL_TAG_W-1:0] global_tag
    );
        begin
            send_miss(
                client,
                local_tag,
                line_addr,
                global_tag
            );

            respond_to_client(
                global_tag,
                line_addr,
                1'b0,
                data_base,
                client,
                local_tag
            );
        end
    endtask


    task automatic issue_single_store(
        input integer client,
        input integer lane,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input integer word_offset
    );
        integer c;
        begin
            /*
             * Use the complete integer arguments, not only their low index
             * bits. Besides guarding the TB against invalid calls, this
             * avoids hiding accidental out-of-range client/lane values.
             */
            if (
                client < 0
                || client >= CLIENT_COUNT
            ) begin
                $fatal(
                    1,
                    "RTL9D3 store client index out of range client=%0d",
                    client
                );
            end

            if (
                lane < 0
                || lane >= STORE_LANES_PER_CLIENT
            ) begin
                $fatal(
                    1,
                    "RTL9D3 store lane index out of range lane=%0d",
                    lane
                );
            end

            @(negedge clk);

            client_store_valid_i = '0;

            for (
                c = 0;
                c < CLIENT_COUNT;
                c = c + 1
            ) begin
                client_store_lane_mask_i[c] = '0;
            end

            client_store_valid_i[
                client
            ] = 1'b1;

            client_store_lane_mask_i[
                client
            ][
                lane
            ] = 1'b1;

            client_store_word_addr_i[
                client
            ][
                lane
            ] =
                make_word_addr(
                    line_addr,
                    word_offset
                );

            @(posedge clk);

            @(negedge clk);

            client_store_valid_i = '0;

            for (
                c = 0;
                c < CLIENT_COUNT;
                c = c + 1
            ) begin
                client_store_lane_mask_i[c] = '0;
            end

            #1;
        end
    endtask


    task automatic cleanup_miss(
        input logic [GLOBAL_TAG_W-1:0] global_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input integer client,
        input logic [LOCAL_TAG_W-1:0] local_tag,
        input logic [31:0] data_base
    );
        begin
            respond_to_client(
                global_tag,
                line_addr,
                1'b0,
                data_base,
                client,
                local_tag
            );
        end
    endtask


    initial begin
        rst_n = 1'b0;
        clear_inputs();


        /*
         * ====================================================
         * 01 — RESET_IDLE
         * ====================================================
         */
        reset_dut();

        if (
            line_mem_req_valid_o
            || (client_resp_valid_o != '0)
            || line_resp_tag_error_o
        ) begin
            $fatal(
                1,
                "RTL9D3 reset idle mismatch"
            );
        end

        if (
            dut.line_fabric.hold_valid_q
        ) begin
            $fatal(
                1,
                "RTL9D3 fabric hold valid after reset"
            );
        end

        for (
            miss_index = 0;
            miss_index < L2_MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.l2_line_cache.miss_valid_q[
                    miss_index
                ]
            ) begin
                $fatal(
                    1,
                    "RTL9D3 L2 miss valid after reset"
                );
            end
        end

        $display(
            "RTL9D3_RESET_IDLE=PASS"
        );


        /*
         * ====================================================
         * 02-06 — client0 cold miss through fabric and L2.
         * ====================================================
         */
        send_miss(
            0,
            2'd1,
            29'd8,
            tag_a
        );

        $display(
            "RTL9D3_CLIENT0_COLD_MISS_REACHES_EXTERNAL_BACKEND=PASS"
        );

        if (
            dut.fabric_line_req_global_tag
            != tag_a
        ) begin
            $fatal(
                1,
                "RTL9D3 fabric global tag changed before L2"
            );
        end

        if (
            dut.l2_line_cache.line_req_global_tag_i
            != tag_a
        ) begin
            $fatal(
                1,
                "RTL9D3 L2 did not receive opaque fabric tag"
            );
        end

        $display(
            "RTL9D3_FABRIC_GLOBAL_TAG_REACHES_L2_OPAQUELY=PASS"
        );

        if (
            line_mem_req_global_tag_o
            != tag_a
        ) begin
            $fatal(
                1,
                "RTL9D3 L2 changed global tag to backend"
            );
        end

        $display(
            "RTL9D3_L2_GLOBAL_TAG_REACHES_BACKEND_UNCHANGED=PASS"
        );

        respond_to_client(
            tag_a,
            29'd8,
            1'b0,
            32'd8000,
            0,
            2'd1
        );

        $display(
            "RTL9D3_BACKEND_REFILL_ROUTES_TO_CLIENT0=PASS"
        );

        $display(
            "RTL9D3_CLIENT0_LOCAL_TAG_RESTORED=PASS"
        );


        /*
         * ====================================================
         * 07-09 — client1 reuses client0-filled shared line.
         * ====================================================
         */
        send_hit(
            1,
            2'd2,
            29'd8,
            32'd8000
        );

        $display(
            "RTL9D3_CLIENT1_SAME_LINE_HITS_SHARED_L2=PASS"
        );

        $display(
            "RTL9D3_CROSS_CLIENT_L2_HIT_SUPPRESSES_BACKEND=PASS"
        );

        $display(
            "RTL9D3_CLIENT1_LOCAL_TAG_RESTORED=PASS"
        );


        /*
         * ====================================================
         * 10-11 — same local tag, different requester identity.
         * ====================================================
         */
        reset_dut();

        send_miss(
            0,
            2'd1,
            29'd20,
            tag_a
        );

        send_miss(
            1,
            2'd1,
            29'd21,
            tag_b
        );

        if (tag_a == tag_b) begin
            $fatal(
                1,
                "RTL9D3 same local tag collided across clients"
            );
        end

        if (
            tag_a
            != make_global_tag(
                CLIENT_ID_W'(0),
                2'd1
            )
            || tag_b
            != make_global_tag(
                CLIENT_ID_W'(1),
                2'd1
            )
        ) begin
            $fatal(
                1,
                "RTL9D3 global requester encoding mismatch"
            );
        end

        $display(
            "RTL9D3_SAME_LOCAL_TAG_DIFFERENT_CLIENT_GLOBAL_TAG_UNIQUE=PASS"
        );

        valid_miss_count = 0;

        for (
            miss_index = 0;
            miss_index < L2_MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.l2_line_cache.miss_valid_q[
                    miss_index
                ]
            ) begin
                valid_miss_count =
                    valid_miss_count + 1;
            end
        end

        if (valid_miss_count != 2) begin
            $fatal(
                1,
                "RTL9D3 expected two same-local-tag cross-client misses"
            );
        end

        $display(
            "RTL9D3_SAME_LOCAL_TAG_DIFFERENT_CLIENT_CONCURRENT_MISSES=PASS"
        );

        cleanup_miss(
            tag_a,
            29'd20,
            0,
            2'd1,
            32'd2000
        );

        cleanup_miss(
            tag_b,
            29'd21,
            1,
            2'd1,
            32'd2100
        );


        /*
         * ====================================================
         * 12-15 — multiple client misses and OoO responses.
         * ====================================================
         */
        reset_dut();

        send_miss(
            0,
            2'd0,
            29'd30,
            tag_a
        );

        send_miss(
            2,
            2'd3,
            29'd31,
            tag_b
        );

        valid_miss_count = 0;

        for (
            miss_index = 0;
            miss_index < L2_MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.l2_line_cache.miss_valid_q[
                    miss_index
                ]
            ) begin
                valid_miss_count =
                    valid_miss_count + 1;
            end
        end

        if (valid_miss_count != 2) begin
            $fatal(
                1,
                "RTL9D3 multiple outstanding miss count mismatch"
            );
        end

        $display(
            "RTL9D3_MULTI_CLIENT_MULTIPLE_OUTSTANDING_MISSES=PASS"
        );

        respond_to_client(
            tag_b,
            29'd31,
            1'b0,
            32'd3100,
            2,
            2'd3
        );

        respond_to_client(
            tag_a,
            29'd30,
            1'b0,
            32'd3000,
            0,
            2'd0
        );

        $display(
            "RTL9D3_EXTERNAL_BACKEND_OOO_RESPONSES=PASS"
        );

        $display(
            "RTL9D3_OOO_RESPONSES_ROUTE_TO_CORRECT_CLIENTS=PASS"
        );

        $display(
            "RTL9D3_OOO_LOCAL_TAGS_RESTORED=PASS"
        );


        /*
         * ====================================================
         * 16-17 — L2 tracker-full backpressure into fabric.
         * ====================================================
         */
        reset_dut();

        send_miss(
            0,
            2'd0,
            29'd40,
            tag_a
        );

        send_miss(
            1,
            2'd1,
            29'd41,
            tag_b
        );

        tag_c =
            make_global_tag(
                CLIENT_ID_W'(2),
                2'd2
            );

        /*
         * The fabric still has its one-entry hold slot and may accept the
         * third client request even while the L2 tracker itself is full.
         */
        pulse_client_request(
            2,
            2'd2,
            29'd42
        );

        if (
            !dut.fabric_line_req_valid
            || dut.l2_line_req_ready
            || line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D3 tracker-full backpressure did not hold fabric request"
            );
        end

        if (client_req_ready_o != '0) begin
            $fatal(
                1,
                "RTL9D3 fabric accepted another request while held"
            );
        end

        $display(
            "RTL9D3_L2_MISS_TRACKER_FULL_BACKPRESSURES_FABRIC=PASS"
        );

        stable_tag =
            dut.fabric_line_req_global_tag;

        stable_line =
            dut.fabric_line_req_line_addr;

        repeat (3) begin
            @(posedge clk);
            @(negedge clk);
            #1;

            if (
                !dut.fabric_line_req_valid
                || dut.fabric_line_req_global_tag
                    != stable_tag
                || dut.fabric_line_req_line_addr
                    != stable_line
            ) begin
                $fatal(
                    1,
                    "RTL9D3 fabric held payload changed under L2 backpressure"
                );
            end
        end

        if (
            stable_tag != tag_c
            || stable_line != 29'd42
        ) begin
            $fatal(
                1,
                "RTL9D3 held payload identity mismatch"
            );
        end

        $display(
            "RTL9D3_FABRIC_BACKPRESSURE_PAYLOAD_STABLE=PASS"
        );

        respond_to_client(
            tag_a,
            29'd40,
            1'b0,
            32'd4000,
            0,
            2'd0
        );

        wait_backend_request(
            tag_c,
            29'd42,
            tag_c
        );

        respond_to_client(
            tag_b,
            29'd41,
            1'b0,
            32'd4100,
            1,
            2'd1
        );

        respond_to_client(
            tag_c,
            29'd42,
            1'b0,
            32'd4200,
            2,
            2'd2
        );


        /*
         * ====================================================
         * 18 — round-robin fairness remains visible with L2.
         * ====================================================
         */
        reset_dut();

        @(negedge clk);

        client_req_local_tag_i[0] = 2'd0;
        client_req_local_tag_i[1] = 2'd1;
        client_req_local_tag_i[2] = 2'd2;

        client_req_line_addr_i[0] = 29'd50;
        client_req_line_addr_i[1] = 29'd51;
        client_req_line_addr_i[2] = 29'd52;

        client_req_valid_i = 3'b111;

        #1;

        if (client_req_ready_o != 3'b001) begin
            $fatal(
                1,
                "RTL9D3 fairness first grant expected client0"
            );
        end

        @(posedge clk);
        @(negedge clk);
        #1;

        if (client_req_ready_o != 3'b010) begin
            $fatal(
                1,
                "RTL9D3 fairness second grant expected client1"
            );
        end

        @(posedge clk);
        @(negedge clk);
        #1;

        if (client_req_ready_o != 3'b100) begin
            $fatal(
                1,
                "RTL9D3 fairness third grant expected client2"
            );
        end

        @(posedge clk);
        @(negedge clk);

        client_req_valid_i = '0;

        #1;

        $display(
            "RTL9D3_FABRIC_ROUND_ROBIN_FAIRNESS_WITH_L2=PASS"
        );

        tag_a =
            make_global_tag(
                CLIENT_ID_W'(0),
                2'd0
            );

        tag_b =
            make_global_tag(
                CLIENT_ID_W'(1),
                2'd1
            );

        tag_c =
            make_global_tag(
                CLIENT_ID_W'(2),
                2'd2
            );

        respond_to_client(
            tag_a,
            29'd50,
            1'b0,
            32'd5000,
            0,
            2'd0
        );

        wait_backend_request(
            tag_c,
            29'd52,
            tag_c
        );

        respond_to_client(
            tag_b,
            29'd51,
            1'b0,
            32'd5100,
            1,
            2'd1
        );

        respond_to_client(
            tag_c,
            29'd52,
            1'b0,
            32'd5200,
            2,
            2'd2
        );


        /*
         * ====================================================
         * 19-20 — cross-client store invalidation.
         * ====================================================
         */
        reset_dut();

        fill_line(
            0,
            2'd0,
            29'd60,
            32'd6000,
            tag_a
        );

        issue_single_store(
            1,
            0,
            29'd60,
            2
        );

        $display(
            "RTL9D3_CLIENT1_STORE_INVALIDATES_CLIENT0_SHARED_LINE=PASS"
        );

        send_miss(
            0,
            2'd1,
            29'd60,
            tag_a
        );

        $display(
            "RTL9D3_CROSS_CLIENT_LOAD_AFTER_STORE_MISSES=PASS"
        );

        cleanup_miss(
            tag_a,
            29'd60,
            0,
            2'd1,
            32'd6010
        );


        /*
         * ====================================================
         * 21-23 — cross-client store kills outstanding refill.
         * ====================================================
         */
        reset_dut();

        send_miss(
            0,
            2'd0,
            29'd70,
            tag_a
        );

        issue_single_store(
            2,
            1,
            29'd70,
            3
        );

        killed_match_count = 0;

        for (
            miss_index = 0;
            miss_index < L2_MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.l2_line_cache.miss_valid_q[
                    miss_index
                ]
                && dut.l2_line_cache.miss_line_q[
                    miss_index
                ] == 29'd70
                && dut.l2_line_cache.miss_kill_q[
                    miss_index
                ]
            ) begin
                killed_match_count =
                    killed_match_count + 1;
            end
        end

        if (killed_match_count != 1) begin
            $fatal(
                1,
                "RTL9D3 cross-client store did not kill matching refill"
            );
        end

        $display(
            "RTL9D3_CLIENT2_STORE_KILLS_CLIENT0_OUTSTANDING_REFILL=PASS"
        );

        respond_to_client(
            tag_a,
            29'd70,
            1'b0,
            32'd7000,
            0,
            2'd0
        );

        $display(
            "RTL9D3_CROSS_CLIENT_KILLED_REFILL_STILL_ROUTED=PASS"
        );

        send_miss(
            1,
            2'd1,
            29'd70,
            tag_b
        );

        $display(
            "RTL9D3_CROSS_CLIENT_KILLED_REFILL_NOT_INSTALLED=PASS"
        );

        cleanup_miss(
            tag_b,
            29'd70,
            1,
            2'd1,
            32'd7010
        );


        /*
         * ====================================================
         * 24 — same-cycle cross-client store/refill.
         * ====================================================
         */
        reset_dut();

        send_miss(
            0,
            2'd0,
            29'd80,
            tag_a
        );

        @(negedge clk);

        line_mem_resp_global_tag_i =
            tag_a;

        line_mem_resp_line_addr_i =
            29'd80;

        line_mem_resp_fault_i =
            1'b0;

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            line_mem_resp_data_i[
                word_index
            ] =
                32'd8000
                + 32'(word_index);
        end

        line_mem_resp_valid_i =
            1'b1;

        client_store_valid_i =
            3'b010;

        client_store_lane_mask_i[0] = '0;
        client_store_lane_mask_i[1] = 2'b01;
        client_store_lane_mask_i[2] = '0;

        client_store_word_addr_i[1][0] =
            make_word_addr(
                29'd80,
                4
            );

        #1;

        if (
            !client_resp_valid_o[0]
            || client_resp_local_tag_o[0]
                != 2'd0
        ) begin
            $fatal(
                1,
                "RTL9D3 same-cycle store/refill response not routed"
            );
        end

        @(posedge clk);

        @(negedge clk);

        line_mem_resp_valid_i = 1'b0;
        client_store_valid_i = '0;
        client_store_lane_mask_i[1] = '0;

        #1;

        send_miss(
            2,
            2'd2,
            29'd80,
            tag_b
        );

        $display(
            "RTL9D3_CROSS_CLIENT_SAME_CYCLE_STORE_REFILL_STORE_WINS=PASS"
        );

        cleanup_miss(
            tag_b,
            29'd80,
            2,
            2'd2,
            32'd8010
        );


        /*
         * ====================================================
         * 25-26 — simultaneous store fan-in.
         * ====================================================
         */
        reset_dut();

        fill_line(
            0,
            2'd0,
            29'd90,
            32'd9000,
            tag_a
        );

        fill_line(
            1,
            2'd1,
            29'd91,
            32'd9100,
            tag_b
        );

        @(negedge clk);

        client_store_valid_i =
            3'b101;

        client_store_lane_mask_i[0] =
            2'b01;

        client_store_lane_mask_i[1] =
            '0;

        client_store_lane_mask_i[2] =
            2'b10;

        client_store_word_addr_i[0][0] =
            make_word_addr(
                29'd90,
                0
            );

        client_store_word_addr_i[2][1] =
            make_word_addr(
                29'd91,
                7
            );

        #1;

        if (!dut.l2_store_valid) begin
            $fatal(
                1,
                "RTL9D3 flattened store valid missing"
            );
        end

        if (
            !dut.l2_store_lane_mask[0]
            || !dut.l2_store_lane_mask[5]
        ) begin
            $fatal(
                1,
                "RTL9D3 simultaneous store lanes not flattened"
            );
        end

        if (
            dut.l2_store_word_addr[0]
                != make_word_addr(
                    29'd90,
                    0
                )
            || dut.l2_store_word_addr[5]
                != make_word_addr(
                    29'd91,
                    7
                )
        ) begin
            $fatal(
                1,
                "RTL9D3 flattened store addresses changed"
            );
        end

        $display(
            "RTL9D3_MULTI_CLIENT_SIMULTANEOUS_STORE_FANIN=PASS"
        );

        @(posedge clk);

        @(negedge clk);

        client_store_valid_i = '0;
        client_store_lane_mask_i[0] = '0;
        client_store_lane_mask_i[2] = '0;

        #1;

        send_miss(
            1,
            2'd2,
            29'd90,
            tag_a
        );

        cleanup_miss(
            tag_a,
            29'd90,
            1,
            2'd2,
            32'd9010
        );

        send_miss(
            1,
            2'd3,
            29'd91,
            tag_b
        );

        cleanup_miss(
            tag_b,
            29'd91,
            1,
            2'd3,
            32'd9110
        );

        $display(
            "RTL9D3_MULTI_CLIENT_STORE_INVALIDATES_MULTIPLE_LINES=PASS"
        );


        /*
         * ====================================================
         * 27-28 — faulted refill.
         * ====================================================
         */
        reset_dut();

        send_miss(
            2,
            2'd2,
            29'd100,
            tag_a
        );

        respond_to_client(
            tag_a,
            29'd100,
            1'b1,
            32'd10000,
            2,
            2'd2
        );

        $display(
            "RTL9D3_FAULTED_BACKEND_REFILL_ROUTES_TO_ORIGIN=PASS"
        );

        send_miss(
            0,
            2'd0,
            29'd100,
            tag_b
        );

        $display(
            "RTL9D3_FAULTED_BACKEND_REFILL_NOT_INSTALLED=PASS"
        );

        cleanup_miss(
            tag_b,
            29'd100,
            0,
            2'd0,
            32'd10010
        );


        /*
         * ====================================================
         * 29-31 — malformed global requester tag.
         *
         * CLIENT_COUNT=3 and CLIENT_ID_W=2, so requester id 3 is invalid.
         * ====================================================
         */
        reset_dut();

        tag_a =
            make_global_tag(
                CLIENT_ID_W'(3),
                2'd1
            );

        @(negedge clk);

        line_mem_resp_global_tag_i =
            tag_a;

        line_mem_resp_line_addr_i =
            29'd110;

        line_mem_resp_fault_i =
            1'b0;

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            line_mem_resp_data_i[
                word_index
            ] =
                32'd11000
                + 32'(word_index);
        end

        line_mem_resp_valid_i =
            1'b1;

        #1;

        if (!line_resp_tag_error_o) begin
            $fatal(
                1,
                "RTL9D3 malformed requester was not rejected"
            );
        end

        $display(
            "RTL9D3_MALFORMED_GLOBAL_REQUESTER_TAG_REJECTED=PASS"
        );

        if (client_resp_valid_o != '0) begin
            $fatal(
                1,
                "RTL9D3 malformed requester fanned out to client"
            );
        end

        $display(
            "RTL9D3_MALFORMED_GLOBAL_REQUESTER_TAG_NO_CLIENT_FANOUT=PASS"
        );

        if (!line_resp_tag_error_o) begin
            $fatal(
                1,
                "RTL9D3 malformed requester tag error missing"
            );
        end

        $display(
            "RTL9D3_MALFORMED_GLOBAL_REQUESTER_TAG_ERROR_ASSERTED=PASS"
        );

        @(posedge clk);

        @(negedge clk);

        line_mem_resp_valid_i =
            1'b0;

        #1;

        /*
         * Also verify that the untracked malformed response did not install.
         */
        send_miss(
            0,
            2'd0,
            29'd110,
            tag_b
        );

        cleanup_miss(
            tag_b,
            29'd110,
            0,
            2'd0,
            32'd11010
        );


        /*
         * ====================================================
         * 32 — final natural miss-tracker drain.
         * ====================================================
         */
        repeat (2) begin
            @(posedge clk);
            @(negedge clk);
            #1;
        end

        valid_miss_count = 0;

        for (
            miss_index = 0;
            miss_index < L2_MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.l2_line_cache.miss_valid_q[
                    miss_index
                ]
            ) begin
                valid_miss_count =
                    valid_miss_count + 1;
            end
        end

        if (valid_miss_count != 0) begin
            $fatal(
                1,
                "RTL9D3 final L2 miss tracker not drained"
            );
        end

        $display(
            "RTL9D3_FINAL_L2_MISS_TRACKER_DRAIN=PASS"
        );


        /*
         * ====================================================
         * 33 — final fabric idle.
         * ====================================================
         */
        if (
            dut.line_fabric.hold_valid_q
            || dut.fabric_line_req_valid
        ) begin
            $fatal(
                1,
                "RTL9D3 final fabric not idle"
            );
        end

        $display(
            "RTL9D3_FINAL_FABRIC_IDLE=PASS"
        );


        /*
         * ====================================================
         * 34 — final marker.
         * ====================================================
         */
        $display(
            "RTL9D3_SHARED_L2_INTEGRATION_TB=PASS"
        );

        $finish;
    end

endmodule
