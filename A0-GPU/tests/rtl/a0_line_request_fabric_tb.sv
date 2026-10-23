`timescale 1ns/1ps

module a0_line_request_fabric_tb;

    localparam integer CLIENT_COUNT = 3;
    localparam integer LOCAL_TAG_W = 2;
    localparam integer LINE_ADDR_W = 12;
    localparam integer LINE_WORDS = 4;

    localparam integer CLIENT_ID_W =
        (CLIENT_COUNT <= 1)
            ? 1
            : $clog2(CLIENT_COUNT);

    localparam integer GLOBAL_TAG_W =
        CLIENT_ID_W + LOCAL_TAG_W;

    logic clk;
    logic rst_n;

    logic [CLIENT_COUNT-1:0]
        client_req_valid_i;

    logic [CLIENT_COUNT-1:0]
        client_req_ready_o;

    logic [LOCAL_TAG_W-1:0]
        client_req_local_tag_i [0:CLIENT_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        client_req_line_addr_i [0:CLIENT_COUNT-1];

    logic line_req_valid_o;
    logic line_req_ready_i;

    logic [GLOBAL_TAG_W-1:0]
        line_req_global_tag_o;

    logic [LINE_ADDR_W-1:0]
        line_req_line_addr_o;

    logic line_resp_valid_i;

    logic [GLOBAL_TAG_W-1:0]
        line_resp_global_tag_i;

    logic [LINE_ADDR_W-1:0]
        line_resp_line_addr_i;

    logic line_resp_fault_i;

    logic [31:0]
        line_resp_data_i [0:LINE_WORDS-1];

    logic [CLIENT_COUNT-1:0]
        client_resp_valid_o;

    logic [LOCAL_TAG_W-1:0]
        client_resp_local_tag_o [0:CLIENT_COUNT-1];

    logic [LINE_ADDR_W-1:0]
        client_resp_line_addr_o [0:CLIENT_COUNT-1];

    logic
        client_resp_fault_o [0:CLIENT_COUNT-1];

    logic [31:0]
        client_resp_data_o
            [0:CLIENT_COUNT-1]
            [0:LINE_WORDS-1];

    logic line_resp_tag_error_o;

    integer client_index;
    integer word_index;
    integer expected_client;


    a0_line_request_fabric #(
        .CLIENT_COUNT(CLIENT_COUNT),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .LINE_WORDS(LINE_WORDS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .client_req_valid_i(client_req_valid_i),
        .client_req_ready_o(client_req_ready_o),
        .client_req_local_tag_i(client_req_local_tag_i),
        .client_req_line_addr_i(client_req_line_addr_i),

        .line_req_valid_o(line_req_valid_o),
        .line_req_ready_i(line_req_ready_i),
        .line_req_global_tag_o(line_req_global_tag_o),
        .line_req_line_addr_o(line_req_line_addr_o),

        .line_resp_valid_i(line_resp_valid_i),
        .line_resp_global_tag_i(line_resp_global_tag_i),
        .line_resp_line_addr_i(line_resp_line_addr_i),
        .line_resp_fault_i(line_resp_fault_i),
        .line_resp_data_i(line_resp_data_i),

        .client_resp_valid_o(client_resp_valid_o),
        .client_resp_local_tag_o(client_resp_local_tag_o),
        .client_resp_line_addr_o(client_resp_line_addr_o),
        .client_resp_fault_o(client_resp_fault_o),
        .client_resp_data_o(client_resp_data_o),

        .line_resp_tag_error_o(line_resp_tag_error_o)
    );


    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    function automatic logic [GLOBAL_TAG_W-1:0]
        make_global_tag(
            input integer requester,
            input logic [LOCAL_TAG_W-1:0] local_tag
        );
        /*
         * requester remains integer because callers also use it as an
         * unpacked-array index.
         *
         * Check representability in the integer domain before narrowing.
         * Do not cast the narrowed value back to integer here: a sized cast
         * may carry signedness and sign-extend values whose encoded top bit
         * is one (for example requester=2 with CLIENT_ID_W=2).
         *
         * CLIENT_COUNT=3 intentionally permits requester=3 here so the TB
         * can construct the unused encoded requester ID 2'b11 and prove
         * malformed-response rejection.
         */
        if (
            requester < 0
            || requester >= (1 << CLIENT_ID_W)
        ) begin
            $fatal(
                1,
                "RTL9D1 requester does not fit CLIENT_ID_W requester=%0d width=%0d",
                requester,
                CLIENT_ID_W
            );
        end

        make_global_tag = {
            CLIENT_ID_W'(requester),
            local_tag
        };
    endfunction


    task automatic clear_inputs;
        begin
            client_req_valid_i = '0;

            line_req_ready_i = 1'b0;

            line_resp_valid_i = 1'b0;
            line_resp_global_tag_i = '0;
            line_resp_line_addr_i = '0;
            line_resp_fault_i = 1'b0;

            for (
                client_index = 0;
                client_index < CLIENT_COUNT;
                client_index = client_index + 1
            ) begin
                client_req_local_tag_i[
                    client_index
                ] = '0;

                client_req_line_addr_i[
                    client_index
                ] = '0;
            end

            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                line_resp_data_i[
                    word_index
                ] = '0;
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


    task automatic expect_only_ready(
        input integer expected
    );
        integer ready_client;
        begin
            for (
                ready_client = 0;
                ready_client < CLIENT_COUNT;
                ready_client = ready_client + 1
            ) begin
                if (ready_client == expected) begin
                    if (
                        !client_req_ready_o[
                            ready_client
                        ]
                    ) begin
                        $fatal(
                            1,
                            "RTL9D1 expected client %0d ready",
                            expected
                        );
                    end
                end else begin
                    if (
                        client_req_ready_o[
                            ready_client
                        ]
                    ) begin
                        $fatal(
                            1,
                            "RTL9D1 unexpected client %0d ready while expected=%0d",
                            ready_client,
                            expected
                        );
                    end
                end
            end
        end
    endtask


    task automatic expect_no_client_ready;
        integer ready_client;
        begin
            for (
                ready_client = 0;
                ready_client < CLIENT_COUNT;
                ready_client = ready_client + 1
            ) begin
                if (
                    client_req_ready_o[
                        ready_client
                    ]
                ) begin
                    $fatal(
                        1,
                        "RTL9D1 unexpected client ready client=%0d",
                        ready_client
                    );
                end
            end
        end
    endtask


    task automatic issue_and_consume(
        input integer requester,
        input logic [LOCAL_TAG_W-1:0] local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            line_req_ready_i = 1'b1;

            @(negedge clk);

            client_req_local_tag_i[
                requester
            ] = local_tag;

            client_req_line_addr_i[
                requester
            ] = line_addr;

            client_req_valid_i[
                requester
            ] = 1'b1;

            #1;

            expect_only_ready(
                requester
            );

            @(posedge clk);

            @(negedge clk);

            client_req_valid_i[
                requester
            ] = 1'b0;

            #1;

            if (!line_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9D1 expected held downstream request requester=%0d",
                    requester
                );
            end

            if (
                line_req_global_tag_o
                != make_global_tag(
                    requester,
                    local_tag
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D1 global tag mismatch requester=%0d expected=%h actual=%h",
                    requester,
                    make_global_tag(
                        requester,
                        local_tag
                    ),
                    line_req_global_tag_o
                );
            end

            if (
                line_req_line_addr_o
                != line_addr
            ) begin
                $fatal(
                    1,
                    "RTL9D1 line mismatch requester=%0d expected=%h actual=%h",
                    requester,
                    line_addr,
                    line_req_line_addr_o
                );
            end

            @(posedge clk);

            @(negedge clk);

            #1;

            if (line_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9D1 request duplicated after consume requester=%0d",
                    requester
                );
            end
        end
    endtask


    initial begin
        rst_n = 1'b0;

        clear_inputs();

        /*
         * ----------------------------------------------------
         * Scenario 1 — reset / one request.
         * ----------------------------------------------------
         */
        reset_dut();

        if (
            line_req_valid_o
            || client_resp_valid_o != '0
            || line_resp_tag_error_o
        ) begin
            $fatal(
                1,
                "RTL9D1 reset/idle output mismatch"
            );
        end

        $display(
            "RTL9D1_RESET_IDLE=PASS"
        );

        line_req_ready_i = 1'b1;

        @(negedge clk);

        client_req_local_tag_i[0] =
            2'd1;

        client_req_line_addr_i[0] =
            12'h123;

        client_req_valid_i[0] =
            1'b1;

        #1;

        expect_only_ready(0);

        @(posedge clk);

        @(negedge clk);

        client_req_valid_i[0] =
            1'b0;

        #1;

        if (!line_req_valid_o) begin
            $fatal(
                1,
                "RTL9D1 single request not presented downstream"
            );
        end

        if (
            line_req_global_tag_o
            != make_global_tag(
                0,
                2'd1
            )
        ) begin
            $fatal(
                1,
                "RTL9D1 requester/local tag encode mismatch expected=%h actual=%h",
                make_global_tag(
                    0,
                    2'd1
                ),
                line_req_global_tag_o
            );
        end

        $display(
            "RTL9D1_GLOBAL_REQUESTER_TAG_ENCODE=PASS"
        );

        if (
            line_req_line_addr_o
            != 12'h123
        ) begin
            $fatal(
                1,
                "RTL9D1 single request line mismatch expected=123 actual=%h",
                line_req_line_addr_o
            );
        end

        $display(
            "RTL9D1_REQUEST_LINE_PRESERVED=PASS"
        );

        @(posedge clk);

        @(negedge clk);

        #1;

        if (line_req_valid_o) begin
            $fatal(
                1,
                "RTL9D1 consumed single request remained valid"
            );
        end


        /*
         * ----------------------------------------------------
         * Scenario 2 — held payload under backpressure.
         * ----------------------------------------------------
         */
        reset_dut();

        line_req_ready_i =
            1'b0;

        @(negedge clk);

        client_req_local_tag_i[1] =
            2'd2;

        client_req_line_addr_i[1] =
            12'h2A5;

        client_req_valid_i[1] =
            1'b1;

        #1;

        expect_only_ready(1);

        @(posedge clk);

        @(negedge clk);

        client_req_valid_i[1] =
            1'b0;

        /*
         * Change the original client payload after acceptance.
         * The downstream held request must not change.
         */
        client_req_local_tag_i[1] =
            2'd0;

        client_req_line_addr_i[1] =
            12'h000;

        /*
         * Another requester becomes pending while the held
         * request is stalled.
         */
        client_req_local_tag_i[2] =
            2'd3;

        client_req_line_addr_i[2] =
            12'h3C0;

        client_req_valid_i[2] =
            1'b1;

        #1;

        if (
            !line_req_valid_o
            || line_req_global_tag_o
                != make_global_tag(
                    1,
                    2'd2
                )
            || line_req_line_addr_o
                != 12'h2A5
        ) begin
            $fatal(
                1,
                "RTL9D1 held request changed immediately under backpressure"
            );
        end

        expect_no_client_ready();

        repeat (4) begin
            @(posedge clk);

            #1;

            if (
                !line_req_valid_o
                || line_req_global_tag_o
                    != make_global_tag(
                        1,
                        2'd2
                    )
                || line_req_line_addr_o
                    != 12'h2A5
            ) begin
                $fatal(
                    1,
                    "RTL9D1 held request changed under multi-cycle backpressure"
                );
            end

            expect_no_client_ready();
        end

        $display(
            "RTL9D1_BACKPRESSURE_PAYLOAD_STABLE=PASS"
        );

        $display(
            "RTL9D1_BACKPRESSURE_BLOCKS_SECOND_ACCEPT=PASS"
        );

        @(negedge clk);

        client_req_valid_i[2] =
            1'b0;

        line_req_ready_i =
            1'b1;

        @(posedge clk);

        @(negedge clk);

        #1;

        if (line_req_valid_o) begin
            $fatal(
                1,
                "RTL9D1 held request not retired"
            );
        end


        /*
         * ----------------------------------------------------
         * Scenario 3 — persistent simultaneous clients.
         *
         * Default behavioral CLIENT_COUNT is deliberately 3,
         * proving non-power-of-two arbitration.
         * ----------------------------------------------------
         */
        reset_dut();

        line_req_ready_i =
            1'b1;

        @(negedge clk);

        for (
            client_index = 0;
            client_index < CLIENT_COUNT;
            client_index = client_index + 1
        ) begin
            client_req_valid_i[
                client_index
            ] = 1'b1;

            client_req_local_tag_i[
                client_index
            ] = LOCAL_TAG_W'(
                client_index
            );

            client_req_line_addr_i[
                client_index
            ] = LINE_ADDR_W'(
                12'h300
                + client_index
            );
        end

        #1;

        expect_only_ready(0);

        for (
            expected_client = 0;
            expected_client < CLIENT_COUNT;
            expected_client =
                expected_client + 1
        ) begin
            expect_only_ready(
                expected_client
            );

            @(posedge clk);

            @(negedge clk);

            client_req_valid_i[
                expected_client
            ] = 1'b0;

            #1;

            if (!line_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9D1 RR request missing client=%0d",
                    expected_client
                );
            end

            if (
                line_req_global_tag_o
                != make_global_tag(
                    expected_client,
                    LOCAL_TAG_W'(
                        expected_client
                    )
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D1 RR tag mismatch client=%0d expected=%h actual=%h",
                    expected_client,
                    make_global_tag(
                        expected_client,
                        LOCAL_TAG_W'(
                            expected_client
                        )
                    ),
                    line_req_global_tag_o
                );
            end

            if (
                line_req_line_addr_o
                != LINE_ADDR_W'(
                    12'h300
                    + expected_client
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D1 RR line mismatch client=%0d expected=%h actual=%h",
                    expected_client,
                    LINE_ADDR_W'(
                        12'h300
                        + expected_client
                    ),
                    line_req_line_addr_o
                );
            end

            if (
                expected_client
                < CLIENT_COUNT - 1
            ) begin
                expect_only_ready(
                    expected_client + 1
                );
            end
        end

        $display(
            "RTL9D1_ROUND_ROBIN_FAIRNESS=PASS"
        );

        @(posedge clk);

        @(negedge clk);

        #1;

        if (line_req_valid_o) begin
            $fatal(
                1,
                "RTL9D1 RR sequence duplicated final request"
            );
        end

        if (client_req_ready_o != '0) begin
            $fatal(
                1,
                "RTL9D1 RR ready nonzero with no requests"
            );
        end

        $display(
            "RTL9D1_NO_REQUEST_LOSS_OR_DUPLICATION=PASS"
        );


        /*
         * ----------------------------------------------------
         * Scenario 4 — two outstanding requester identities,
         * responses returned in reverse order.
         * ----------------------------------------------------
         */
        reset_dut();

        issue_and_consume(
            0,
            2'd1,
            12'h410
        );

        issue_and_consume(
            2,
            2'd2,
            12'h520
        );

        /*
         * Client 2 responds first and faults.
         */
        @(negedge clk);

        line_resp_valid_i =
            1'b1;

        line_resp_global_tag_i =
            make_global_tag(
                2,
                2'd2
            );

        line_resp_line_addr_i =
            12'h520;

        line_resp_fault_i =
            1'b1;

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            line_resp_data_i[
                word_index
            ] =
                32'h2200_0000
                + 32'(word_index);
        end

        #1;

        if (
            client_resp_valid_o
            != 3'b100
        ) begin
            $fatal(
                1,
                "RTL9D1 reverse response wrong destination expected=100 actual=%b",
                client_resp_valid_o
            );
        end

        if (
            client_resp_local_tag_o[2]
            != 2'd2
            || client_resp_line_addr_o[2]
                != 12'h520
            || !client_resp_fault_o[2]
        ) begin
            $fatal(
                1,
                "RTL9D1 client2 response metadata mismatch"
            );
        end

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            if (
                client_resp_data_o[
                    2
                ][word_index]
                != (
                    32'h2200_0000
                    + 32'(word_index)
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D1 client2 response data mismatch word=%0d",
                    word_index
                );
            end
        end

        if (line_resp_tag_error_o) begin
            $fatal(
                1,
                "RTL9D1 valid client2 response raised tag error"
            );
        end

        /*
         * Client 0 responds second.
         */
        @(negedge clk);

        line_resp_global_tag_i =
            make_global_tag(
                0,
                2'd1
            );

        line_resp_line_addr_i =
            12'h410;

        line_resp_fault_i =
            1'b0;

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            line_resp_data_i[
                word_index
            ] =
                32'h1100_0000
                + 32'(word_index);
        end

        #1;

        if (
            client_resp_valid_o
            != 3'b001
        ) begin
            $fatal(
                1,
                "RTL9D1 second reverse response wrong destination expected=001 actual=%b",
                client_resp_valid_o
            );
        end

        if (
            client_resp_local_tag_o[0]
            != 2'd1
        ) begin
            $fatal(
                1,
                "RTL9D1 original local tag not restored expected=1 actual=%0d",
                client_resp_local_tag_o[0]
            );
        end

        if (
            client_resp_line_addr_o[0]
            != 12'h410
            || client_resp_fault_o[0]
        ) begin
            $fatal(
                1,
                "RTL9D1 client0 response metadata mismatch"
            );
        end

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            if (
                client_resp_data_o[
                    0
                ][word_index]
                != (
                    32'h1100_0000
                    + 32'(word_index)
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D1 client0 response data mismatch word=%0d",
                    word_index
                );
            end
        end

        if (line_resp_tag_error_o) begin
            $fatal(
                1,
                "RTL9D1 valid client0 response raised tag error"
            );
        end

        $display(
            "RTL9D1_OUT_OF_ORDER_RESPONSE_DEMUX=PASS"
        );

        $display(
            "RTL9D1_LOCAL_TAG_RESTORED=PASS"
        );

        $display(
            "RTL9D1_RESPONSE_PAYLOAD_PRESERVED=PASS"
        );

        @(negedge clk);

        line_resp_valid_i =
            1'b0;

        #1;

        if (client_resp_valid_o != '0) begin
            $fatal(
                1,
                "RTL9D1 response valid persisted after input deassertion"
            );
        end


        /*
         * ----------------------------------------------------
         * Scenario 5 — malformed requester ID.
         *
         * CLIENT_COUNT=3 -> CLIENT_ID_W=2, so encoded client 3
         * is intentionally invalid.
         * ----------------------------------------------------
         */
        @(negedge clk);

        line_resp_valid_i =
            1'b1;

        line_resp_global_tag_i =
            make_global_tag(
                3,
                2'd0
            );

        line_resp_line_addr_i =
            12'h6A0;

        line_resp_fault_i =
            1'b0;

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            line_resp_data_i[
                word_index
            ] =
                32'h3300_0000
                + 32'(word_index);
        end

        #1;

        if (!line_resp_tag_error_o) begin
            $fatal(
                1,
                "RTL9D1 malformed requester tag was not rejected"
            );
        end

        if (client_resp_valid_o != '0) begin
            $fatal(
                1,
                "RTL9D1 malformed response fanned out valid=%b",
                client_resp_valid_o
            );
        end

        $display(
            "RTL9D1_INVALID_REQUESTER_TAG_REJECTED=PASS"
        );

        $display(
            "RTL9D1_MALFORMED_RESPONSE_NO_FANOUT=PASS"
        );

        @(negedge clk);

        line_resp_valid_i =
            1'b0;

        #1;

        $display(
            "RTL9D1_LINE_REQUEST_FABRIC_TB=PASS"
        );

        $finish;
    end

endmodule
