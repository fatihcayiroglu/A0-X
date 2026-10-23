`timescale 1ns/1ps

module a0_l2_line_cache_tb;

    localparam integer STORE_LANES = 4;
    localparam integer LINE_WORDS = 8;
    localparam integer SET_COUNT = 4;
    localparam integer GLOBAL_TAG_W = 4;
    localparam integer MISS_COUNT = 4;

    localparam integer WORD_SELECT_W =
        $clog2(LINE_WORDS);

    localparam integer LINE_ADDR_W =
        32 - WORD_SELECT_W;

    logic clk;
    logic rst_n;

    logic line_req_valid_i;
    logic line_req_ready_o;

    logic [GLOBAL_TAG_W-1:0]
        line_req_global_tag_i;

    logic [LINE_ADDR_W-1:0]
        line_req_line_addr_i;

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
        line_mem_resp_data_i [0:LINE_WORDS-1];

    logic line_resp_valid_o;

    logic [GLOBAL_TAG_W-1:0]
        line_resp_global_tag_o;

    logic [LINE_ADDR_W-1:0]
        line_resp_line_addr_o;

    logic line_resp_fault_o;

    logic [31:0]
        line_resp_data_o [0:LINE_WORDS-1];

    logic store_valid_i;

    logic [STORE_LANES-1:0]
        store_lane_mask_i;

    logic [31:0]
        store_word_addr_i [0:STORE_LANES-1];

    integer word_index;
    integer lane_index;
    integer miss_index;


    a0_l2_line_cache #(
        .STORE_LANES(STORE_LANES),
        .LINE_WORDS(LINE_WORDS),
        .SET_COUNT(SET_COUNT),
        .GLOBAL_TAG_W(GLOBAL_TAG_W),
        .MISS_COUNT(MISS_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .line_req_valid_i(line_req_valid_i),
        .line_req_ready_o(line_req_ready_o),
        .line_req_global_tag_i(
            line_req_global_tag_i
        ),
        .line_req_line_addr_i(
            line_req_line_addr_i
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

        .line_resp_valid_o(
            line_resp_valid_o
        ),
        .line_resp_global_tag_o(
            line_resp_global_tag_o
        ),
        .line_resp_line_addr_o(
            line_resp_line_addr_o
        ),
        .line_resp_fault_o(
            line_resp_fault_o
        ),
        .line_resp_data_o(
            line_resp_data_o
        ),

        .store_valid_i(store_valid_i),
        .store_lane_mask_i(
            store_lane_mask_i
        ),
        .store_word_addr_i(
            store_word_addr_i
        )
    );


    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;


    task automatic clear_inputs;
        begin
            line_req_valid_i = 1'b0;
            line_req_global_tag_i = '0;
            line_req_line_addr_i = '0;

            line_mem_req_ready_i = 1'b1;

            line_mem_resp_valid_i = 1'b0;
            line_mem_resp_global_tag_i = '0;
            line_mem_resp_line_addr_i = '0;
            line_mem_resp_fault_i = 1'b0;

            store_valid_i = 1'b0;
            store_lane_mask_i = '0;

            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                line_mem_resp_data_i[
                    word_index
                ] = '0;
            end

            for (
                lane_index = 0;
                lane_index < STORE_LANES;
                lane_index = lane_index + 1
            ) begin
                store_word_addr_i[
                    lane_index
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


    task automatic drive_request(
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line
    );
        begin
            @(negedge clk);

            line_req_global_tag_i = tag;
            line_req_line_addr_i = line;
            line_req_valid_i = 1'b1;

            #1;
        end
    endtask


    task automatic end_request;
        begin
            @(negedge clk);

            line_req_valid_i = 1'b0;

            #1;
        end
    endtask


    task automatic accept_miss(
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line
    );
        begin
            drive_request(
                tag,
                line
            );

            if (!line_req_ready_o) begin
                $fatal(
                    1,
                    "RTL9D2 expected miss request ready tag=%h line=%h",
                    tag,
                    line
                );
            end

            if (!line_mem_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9D2 expected downstream miss tag=%h line=%h",
                    tag,
                    line
                );
            end

            if (
                line_mem_req_global_tag_o
                != tag
            ) begin
                $fatal(
                    1,
                    "RTL9D2 downstream tag mismatch expected=%h actual=%h",
                    tag,
                    line_mem_req_global_tag_o
                );
            end

            if (
                line_mem_req_line_addr_o
                != line
            ) begin
                $fatal(
                    1,
                    "RTL9D2 downstream line mismatch expected=%h actual=%h",
                    line,
                    line_mem_req_line_addr_o
                );
            end

            @(posedge clk);

            end_request();
        end
    endtask


    task automatic begin_backend_response(
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line,
        input logic fault,
        input logic [31:0] data_base
    );
        begin
            @(negedge clk);

            line_mem_resp_global_tag_i = tag;
            line_mem_resp_line_addr_i = line;
            line_mem_resp_fault_i = fault;

            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                line_mem_resp_data_i[
                    word_index
                ] =
                    data_base
                    + 32'(word_index);
            end

            line_mem_resp_valid_i = 1'b1;

            #1;
        end
    endtask


    task automatic finish_backend_response;
        begin
            @(posedge clk);

            @(negedge clk);

            line_mem_resp_valid_i = 1'b0;
            line_mem_resp_fault_i = 1'b0;

            #1;
        end
    endtask


    task automatic respond_success(
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line,
        input logic [31:0] data_base
    );
        begin
            begin_backend_response(
                tag,
                line,
                1'b0,
                data_base
            );

            if (!line_resp_valid_o) begin
                $fatal(
                    1,
                    "RTL9D2 backend success was not forwarded"
                );
            end

            if (
                line_resp_global_tag_o
                != tag
                || line_resp_line_addr_o
                    != line
                || line_resp_fault_o
            ) begin
                $fatal(
                    1,
                    "RTL9D2 backend success metadata mismatch"
                );
            end

            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                if (
                    line_resp_data_o[
                        word_index
                    ]
                    != (
                        data_base
                        + 32'(word_index)
                    )
                ) begin
                    $fatal(
                        1,
                        "RTL9D2 backend success data mismatch word=%0d",
                        word_index
                    );
                end
            end

            finish_backend_response();
        end
    endtask


    task automatic expect_hit_accept(
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line
    );
        begin
            drive_request(
                tag,
                line
            );

            if (!line_req_ready_o) begin
                $fatal(
                    1,
                    "RTL9D2 expected hit ready tag=%h line=%h",
                    tag,
                    line
                );
            end

            if (line_mem_req_valid_o) begin
                $fatal(
                    1,
                    "RTL9D2 hit leaked to backend tag=%h line=%h",
                    tag,
                    line
                );
            end

            @(posedge clk);

            end_request();
        end
    endtask


    task automatic expect_buffered_hit_response(
        input logic [GLOBAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line,
        input logic [31:0] data_base
    );
        begin
            if (!line_resp_valid_o) begin
                $fatal(
                    1,
                    "RTL9D2 buffered hit response missing"
                );
            end

            if (
                line_resp_global_tag_o
                    != tag
                || line_resp_line_addr_o
                    != line
                || line_resp_fault_o
            ) begin
                $fatal(
                    1,
                    "RTL9D2 buffered hit metadata mismatch"
                );
            end

            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                if (
                    line_resp_data_o[
                        word_index
                    ]
                    != (
                        data_base
                        + 32'(word_index)
                    )
                ) begin
                    $fatal(
                        1,
                        "RTL9D2 buffered hit data mismatch word=%0d",
                        word_index
                    );
                end
            end

            @(posedge clk);

            @(negedge clk);

            #1;
        end
    endtask


    task automatic launch_store_one(
        input logic [31:0] word_addr
    );
        begin
            @(negedge clk);

            store_word_addr_i[0] =
                word_addr;

            store_lane_mask_i =
                {{(STORE_LANES-1){1'b0}}, 1'b1};

            store_valid_i = 1'b1;

            @(posedge clk);

            @(negedge clk);

            store_valid_i = 1'b0;
            store_lane_mask_i = '0;

            #1;
        end
    endtask


    initial begin
        rst_n = 1'b0;

        clear_inputs();


        /*
         * ====================================================
         * 01 — RESET INVALID
         * ====================================================
         */
        reset_dut();

        if (
            line_resp_valid_o
            || line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 reset/idle output mismatch"
            );
        end

        for (
            miss_index = 0;
            miss_index < MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.miss_valid_q[
                    miss_index
                ]
            ) begin
                $fatal(
                    1,
                    "RTL9D2 miss slot valid after reset slot=%0d",
                    miss_index
                );
            end
        end

        $display(
            "RTL9D2_RESET_INVALID=PASS"
        );


        /*
         * ====================================================
         * 02-09 — cold miss, refill, hit, shared-tag reuse.
         * ====================================================
         */
        accept_miss(
            4'h1,
            29'd8
        );

        $display(
            "RTL9D2_COLD_MISS_REACHES_BACKEND=PASS"
        );

        $display(
            "RTL9D2_REQUEST_GLOBAL_TAG_PRESERVED_TO_BACKEND=PASS"
        );

        begin_backend_response(
            4'h1,
            29'd8,
            1'b0,
            32'd1000
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h1
            || line_resp_line_addr_o
                != 29'd8
            || line_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9D2 successful refill forwarding mismatch"
            );
        end

        $display(
            "RTL9D2_SUCCESSFUL_REFILL_FORWARDED=PASS"
        );

        finish_backend_response();

        /*
         * A hit after the refill is the externally-visible proof that the
         * successful tracked refill installed.
         */
        expect_hit_accept(
            4'h2,
            29'd8
        );

        $display(
            "RTL9D2_SUCCESSFUL_REFILL_INSTALLS=PASS"
        );

        $display(
            "RTL9D2_SECOND_REQUEST_HITS_L2=PASS"
        );

        $display(
            "RTL9D2_L2_HIT_SUPPRESSES_BACKEND=PASS"
        );

        expect_buffered_hit_response(
            4'h2,
            29'd8,
            32'd1000
        );

        $display(
            "RTL9D2_HIT_GLOBAL_TAG_PRESERVED=PASS"
        );

        /*
         * Request tag differs from the fill tag, proving line reuse does not
         * depend on requester identity.
         */
        expect_hit_accept(
            4'h3,
            29'd8
        );

        expect_buffered_hit_response(
            4'h3,
            29'd8,
            32'd1000
        );

        $display(
            "RTL9D2_SHARED_LINE_REUSE_ACROSS_DIFFERENT_GLOBAL_TAGS=PASS"
        );


        /*
         * ====================================================
         * 10 — direct-mapped conflict replacement.
         *
         * SET_COUNT=4. Lines 1 and 5 map to the same set.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd1
        );

        respond_success(
            4'h1,
            29'd1,
            32'd1100
        );

        accept_miss(
            4'h2,
            29'd5
        );

        respond_success(
            4'h2,
            29'd5,
            32'd5500
        );

        drive_request(
            4'h3,
            29'd1
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 direct-mapped conflict did not evict old line"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_DIRECT_MAPPED_CONFLICT_REPLACEMENT=PASS"
        );


        /*
         * ====================================================
         * 11-13 — multiple outstanding and OoO response.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd10
        );

        accept_miss(
            4'h2,
            29'd11
        );

        accept_miss(
            4'h3,
            29'd12
        );

        if (
            !dut.miss_valid_q[0]
            || !dut.miss_valid_q[1]
            || !dut.miss_valid_q[2]
        ) begin
            $fatal(
                1,
                "RTL9D2 expected three outstanding misses"
            );
        end

        $display(
            "RTL9D2_MULTIPLE_OUTSTANDING_MISSES=PASS"
        );

        begin_backend_response(
            4'h3,
            29'd12,
            1'b0,
            32'd1200
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h3
            || line_resp_line_addr_o
                != 29'd12
        ) begin
            $fatal(
                1,
                "RTL9D2 first OoO response mismatch"
            );
        end

        finish_backend_response();

        begin_backend_response(
            4'h1,
            29'd10,
            1'b0,
            32'd1000
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h1
            || line_resp_line_addr_o
                != 29'd10
        ) begin
            $fatal(
                1,
                "RTL9D2 second OoO response mismatch"
            );
        end

        finish_backend_response();

        begin_backend_response(
            4'h2,
            29'd11,
            1'b0,
            32'd1100
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h2
            || line_resp_line_addr_o
                != 29'd11
        ) begin
            $fatal(
                1,
                "RTL9D2 third OoO response mismatch"
            );
        end

        finish_backend_response();

        $display(
            "RTL9D2_OUT_OF_ORDER_BACKEND_RESPONSES=PASS"
        );

        $display(
            "RTL9D2_OUT_OF_ORDER_TAG_PRESERVATION=PASS"
        );


        /*
         * ====================================================
         * 14-15 — tracker full / refill frees slot.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h0,
            29'd20
        );

        accept_miss(
            4'h1,
            29'd21
        );

        accept_miss(
            4'h2,
            29'd22
        );

        accept_miss(
            4'h3,
            29'd23
        );

        drive_request(
            4'h4,
            29'd24
        );

        if (line_req_ready_o) begin
            $fatal(
                1,
                "RTL9D2 full miss tracker accepted request"
            );
        end

        if (line_mem_req_valid_o) begin
            $fatal(
                1,
                "RTL9D2 full miss tracker leaked backend request"
            );
        end

        $display(
            "RTL9D2_MISS_SLOT_FULL_BACKPRESSURE=PASS"
        );

        /*
         * Keep tag4 request valid while response to tag0 frees a slot.
         */
        begin_backend_response(
            4'h0,
            29'd20,
            1'b0,
            32'd2000
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h0
        ) begin
            $fatal(
                1,
                "RTL9D2 full-tracker freeing response mismatch"
            );
        end

        finish_backend_response();

        /*
         * Request remained asserted throughout.
         */
        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
            || line_mem_req_global_tag_o
                != 4'h4
            || line_mem_req_line_addr_o
                != 29'd24
        ) begin
            $fatal(
                1,
                "RTL9D2 freed miss slot did not release pending request"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_REFILL_FREES_MISS_SLOT=PASS"
        );


        /*
         * ====================================================
         * 16 — same global tag cannot be reused while pending.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'hA,
            29'd30
        );

        drive_request(
            4'hA,
            29'd31
        );

        if (
            line_req_ready_o
            || line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 reused busy global tag"
            );
        end

        $display(
            "RTL9D2_SAME_GLOBAL_TAG_BUSY_BACKPRESSURE=PASS"
        );

        line_req_valid_i = 1'b0;

        respond_success(
            4'hA,
            29'd30,
            32'd3000
        );


        /*
         * ====================================================
         * 17-18 — backend response beats a simultaneously
         * accepted cache hit, and that hit remains buffered.
         *
         * The V2 TB accepted the hit first and did not assert
         * the backend response until a later cycle. With a
         * no-ready response interface, the hit was therefore
         * legitimately emitted and consumed before the supposed
         * collision existed.
         *
         * V3 presents both events before the same active edge.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd40
        );

        respond_success(
            4'h1,
            29'd40,
            32'd4000
        );

        accept_miss(
            4'h2,
            29'd41
        );

        /*
         * Present:
         *
         *   - a cached-line hit for tag3/line40; and
         *   - the outstanding tag2/line41 backend response
         *
         * in the same cycle before the same posedge.
         */
        @(negedge clk);

        line_req_global_tag_i =
            4'h3;

        line_req_line_addr_i =
            29'd40;

        line_req_valid_i =
            1'b1;

        line_mem_resp_global_tag_i =
            4'h2;

        line_mem_resp_line_addr_i =
            29'd41;

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
                32'd4100
                + 32'(word_index);
        end

        line_mem_resp_valid_i =
            1'b1;

        #1;

        /*
         * The cached request is accepted but must not leak to
         * the backend.
         */
        if (!line_req_ready_o) begin
            $fatal(
                1,
                "RTL9D2 simultaneous hit was not accepted"
            );
        end

        if (line_mem_req_valid_o) begin
            $fatal(
                1,
                "RTL9D2 simultaneous hit leaked to backend"
            );
        end

        /*
         * Backend response owns the no-ready response channel
         * during this exact collision cycle.
         */
        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h2
            || line_resp_line_addr_o
                != 29'd41
            || line_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9D2 backend did not beat simultaneous hit"
            );
        end

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            if (
                line_resp_data_o[
                    word_index
                ]
                != (
                    32'd4100
                    + 32'(word_index)
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D2 backend collision data mismatch word=%0d",
                    word_index
                );
            end
        end

        $display(
            "RTL9D2_BACKEND_RESPONSE_BEATS_BUFFERED_HIT=PASS"
        );

        /*
         * Same posedge:
         *
         *   - retires tag2 miss;
         *   - captures tag3 hit into the local hit buffer.
         *
         * Because the backend response occupies this cycle,
         * the newly captured hit cannot have been emitted yet.
         */
        @(posedge clk);

        @(negedge clk);

        line_req_valid_i =
            1'b0;

        line_mem_resp_valid_i =
            1'b0;

        line_mem_resp_fault_i =
            1'b0;

        #1;

        /*
         * Backend is now absent. The hit captured on the
         * collision edge must appear intact.
         */
        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h3
            || line_resp_line_addr_o
                != 29'd40
            || line_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9D2 buffered hit lost after true backend collision"
            );
        end

        for (
            word_index = 0;
            word_index < LINE_WORDS;
            word_index = word_index + 1
        ) begin
            if (
                line_resp_data_o[
                    word_index
                ]
                != (
                    32'd4000
                    + 32'(word_index)
                )
            ) begin
                $fatal(
                    1,
                    "RTL9D2 collision-surviving hit data mismatch word=%0d",
                    word_index
                );
            end
        end

        $display(
            "RTL9D2_BUFFERED_HIT_SURVIVES_BACKEND_COLLISION=PASS"
        );

        /*
         * One backend-free response cycle consumes the buffered
         * hit on the no-ready interface.
         */
        @(posedge clk);

        @(negedge clk);

        #1;

        if (line_resp_valid_o) begin
            $fatal(
                1,
                "RTL9D2 buffered hit duplicated after collision"
            );
        end


        /*
         * ====================================================
         * 19-20 — faulted refill forward / no install.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd50
        );

        begin_backend_response(
            4'h1,
            29'd50,
            1'b1,
            32'd5000
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h1
            || line_resp_line_addr_o
                != 29'd50
            || !line_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9D2 faulted refill forwarding mismatch"
            );
        end

        $display(
            "RTL9D2_FAULTED_REFILL_FORWARDED=PASS"
        );

        finish_backend_response();

        drive_request(
            4'h2,
            29'd50
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 faulted refill was incorrectly installed"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_FAULTED_REFILL_NOT_INSTALLED=PASS"
        );


        /*
         * ====================================================
         * 21 — matching store invalidates cached line.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd60
        );

        respond_success(
            4'h1,
            29'd60,
            32'd6000
        );

        launch_store_one(
            32'(
                (60 * LINE_WORDS)
                + 2
            )
        );

        drive_request(
            4'h2,
            29'd60
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 matching store did not invalidate cached line"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_STORE_INVALIDATES_MATCHING_CACHED_LINE=PASS"
        );


        /*
         * ====================================================
         * 22 — unrelated store preserves cached line.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd61
        );

        respond_success(
            4'h1,
            29'd61,
            32'd6100
        );

        launch_store_one(
            32'(
                (62 * LINE_WORDS)
                + 1
            )
        );

        expect_hit_accept(
            4'h2,
            29'd61
        );

        expect_buffered_hit_response(
            4'h2,
            29'd61,
            32'd6100
        );

        $display(
            "RTL9D2_STORE_OTHER_LINE_PRESERVES_CACHED_LINE=PASS"
        );


        /*
         * ====================================================
         * 23 — one store launch touches multiple cached lines.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd64
        );

        respond_success(
            4'h1,
            29'd64,
            32'd6400
        );

        accept_miss(
            4'h2,
            29'd65
        );

        respond_success(
            4'h2,
            29'd65,
            32'd6500
        );

        @(negedge clk);

        store_word_addr_i[0] =
            32'(
                (64 * LINE_WORDS)
                + 0
            );

        store_word_addr_i[1] =
            32'(
                (65 * LINE_WORDS)
                + 7
            );

        store_lane_mask_i =
            4'b0011;

        store_valid_i = 1'b1;

        @(posedge clk);

        @(negedge clk);

        store_valid_i = 1'b0;
        store_lane_mask_i = '0;

        drive_request(
            4'h3,
            29'd64
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 multi-lane store left first line cached"
            );
        end

        @(posedge clk);

        end_request();

        /*
         * Reset tracker only between the two externally-observable probes.
         * Cache state is reset too, so this alone would not prove line65.
         * Instead inspect both valid bits immediately after the original
         * store launch above.
         */
        if (
            dut.cache_valid_q[
                64 % SET_COUNT
            ]
            || dut.cache_valid_q[
                65 % SET_COUNT
            ]
        ) begin
            $fatal(
                1,
                "RTL9D2 multi-lane store did not invalidate both sets"
            );
        end

        $display(
            "RTL9D2_MULTI_LANE_STORE_INVALIDATES_MULTIPLE_LINES=PASS"
        );


        /*
         * ====================================================
         * 24-26 — store kills an outstanding refill.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd70
        );

        launch_store_one(
            32'(
                (70 * LINE_WORDS)
                + 3
            )
        );

        if (!dut.miss_kill_q[0]) begin
            $fatal(
                1,
                "RTL9D2 matching store did not kill outstanding miss"
            );
        end

        $display(
            "RTL9D2_STORE_KILLS_OUTSTANDING_REFILL=PASS"
        );

        begin_backend_response(
            4'h1,
            29'd70,
            1'b0,
            32'd7000
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h1
            || line_resp_line_addr_o
                != 29'd70
            || line_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9D2 killed refill was not forwarded"
            );
        end

        $display(
            "RTL9D2_KILLED_REFILL_STILL_FORWARDED=PASS"
        );

        finish_backend_response();

        drive_request(
            4'h2,
            29'd70
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 killed refill was incorrectly installed"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_KILLED_REFILL_NOT_INSTALLED=PASS"
        );


        /*
         * ====================================================
         * 27 — same-cycle store/refill.
         * ====================================================
         */
        reset_dut();

        accept_miss(
            4'h1,
            29'd80
        );

        @(negedge clk);

        line_mem_resp_global_tag_i =
            4'h1;

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

        store_word_addr_i[0] =
            32'(
                (80 * LINE_WORDS)
                + 4
            );

        store_lane_mask_i =
            4'b0001;

        store_valid_i =
            1'b1;

        #1;

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'h1
            || line_resp_line_addr_o
                != 29'd80
        ) begin
            $fatal(
                1,
                "RTL9D2 store/refill collision did not forward backend response"
            );
        end

        @(posedge clk);

        @(negedge clk);

        line_mem_resp_valid_i =
            1'b0;

        store_valid_i =
            1'b0;

        store_lane_mask_i =
            '0;

        #1;

        drive_request(
            4'h2,
            29'd80
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 same-cycle store/refill installed stale line"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_SAME_CYCLE_STORE_REFILL_INVALIDATE_WINS=PASS"
        );


        /*
         * ====================================================
         * 28-29 — untracked response forwards but never installs.
         * ====================================================
         */
        reset_dut();

        begin_backend_response(
            4'hE,
            29'd90,
            1'b0,
            32'd9000
        );

        if (
            !line_resp_valid_o
            || line_resp_global_tag_o
                != 4'hE
            || line_resp_line_addr_o
                != 29'd90
            || line_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9D2 untracked backend response not forwarded"
            );
        end

        $display(
            "RTL9D2_UNTRACKED_BACKEND_RESPONSE_FORWARDED=PASS"
        );

        finish_backend_response();

        drive_request(
            4'hF,
            29'd90
        );

        if (
            !line_req_ready_o
            || !line_mem_req_valid_o
        ) begin
            $fatal(
                1,
                "RTL9D2 untracked response incorrectly installed"
            );
        end

        @(posedge clk);

        end_request();

        $display(
            "RTL9D2_UNTRACKED_BACKEND_RESPONSE_NOT_INSTALLED=PASS"
        );


        /*
         * ====================================================
         * 30 — final miss tracker drain.
         * ====================================================
         */
        reset_dut();

        for (
            miss_index = 0;
            miss_index < MISS_COUNT;
            miss_index = miss_index + 1
        ) begin
            if (
                dut.miss_valid_q[
                    miss_index
                ]
            ) begin
                $fatal(
                    1,
                    "RTL9D2 miss tracker not drained slot=%0d",
                    miss_index
                );
            end
        end

        $display(
            "RTL9D2_FINAL_MISS_TRACKER_DRAIN=PASS"
        );


        /*
         * ====================================================
         * 31 — final marker.
         * ====================================================
         */
        $display(
            "RTL9D2_SHARED_L2_LINE_CACHE_TB=PASS"
        );

        $finish;
    end

endmodule
