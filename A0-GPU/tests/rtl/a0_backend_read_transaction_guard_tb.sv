`timescale 1ns/1ps

module a0_backend_read_transaction_guard_tb;
    localparam integer CLUSTER_COUNT = 1;
    localparam integer CUS_PER_CLUSTER = 1;
    localparam integer STORE_LANES = 2;
    localparam integer L2_SLICE_COUNT = 2;
    localparam integer LINE_WORDS = 4;
    localparam integer NETWORK_TAG_W = 3;
    localparam integer LINE_ADDR_W = 30;
    localparam integer BACKEND_TAG_W = 4;
    localparam integer READ_TRACK_COUNT = 2;
    localparam integer READ_OCC_W = 2;
    localparam integer SLICE_IDX_W = (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT);

    logic clk;
    logic rst_n;
    always #5 clk = ~clk;

    logic [CUS_PER_CLUSTER-1:0] commit_valid [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] commit_ready [0:CLUSTER_COUNT-1];
    logic [STORE_LANES-1:0]
        commit_mask [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [31:0]
        commit_addr [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1];
    logic [31:0]
        commit_wdata [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1];

    logic [L2_SLICE_COUNT-1:0] line_req_v;
    logic [L2_SLICE_COUNT-1:0] line_req_r;
    logic [NETWORK_TAG_W-1:0] line_req_tag [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_req_addr [0:L2_SLICE_COUNT-1];

    logic [L2_SLICE_COUNT-1:0] line_resp_v;
    logic [NETWORK_TAG_W-1:0] line_resp_tag [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_resp_addr [0:L2_SLICE_COUNT-1];
    logic line_resp_fault [0:L2_SLICE_COUNT-1];
    logic [31:0] line_resp_data [0:L2_SLICE_COUNT-1][0:LINE_WORDS-1];

    logic protocol_error;
    logic duplicate_block;
    logic [READ_OCC_W-1:0] outstanding;
    logic capacity_full;

    logic backend_cmd_v;
    logic backend_cmd_r;
    logic backend_cmd_write;
    logic [BACKEND_TAG_W-1:0] backend_cmd_tag;
    logic [31:0] backend_cmd_word_addr;
    logic [31:0] backend_cmd_wdata;
    logic [LINE_ADDR_W-1:0] backend_cmd_line_addr;

    logic backend_resp_v;
    logic [BACKEND_TAG_W-1:0] backend_resp_tag;
    logic [LINE_ADDR_W-1:0] backend_resp_line_addr;
    logic backend_resp_fault;
    logic [31:0] backend_resp_data [0:LINE_WORDS-1];

    integer line_accept_count [0:L2_SLICE_COUNT-1];
    integer backend_cmd_count;
    integer protocol_error_count;
    integer line_resp_count [0:L2_SLICE_COUNT-1];
    logic [BACKEND_TAG_W-1:0] captured_tag [0:7];
    logic [LINE_ADDR_W-1:0] captured_addr [0:7];
    logic [NETWORK_TAG_W-1:0] last_resp_tag [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] last_resp_addr [0:L2_SLICE_COUNT-1];
    logic last_resp_fault [0:L2_SLICE_COUNT-1];
    logic [31:0] last_resp_word0 [0:L2_SLICE_COUNT-1];

    a0_production_store_backend_transaction_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .store_commit_valid_i(commit_valid),
        .store_commit_ready_o(commit_ready),
        .store_commit_lane_mask_i(commit_mask),
        .store_commit_word_addr_i(commit_addr),
        .store_commit_wdata_i(commit_wdata),
        .line_mem_req_valid_i(line_req_v),
        .line_mem_req_ready_o(line_req_r),
        .line_mem_req_network_tag_i(line_req_tag),
        .line_mem_req_line_addr_i(line_req_addr),
        .line_mem_resp_valid_o(line_resp_v),
        .line_mem_resp_network_tag_o(line_resp_tag),
        .line_mem_resp_line_addr_o(line_resp_addr),
        .line_mem_resp_fault_o(line_resp_fault),
        .line_mem_resp_data_o(line_resp_data),
        .backend_resp_protocol_error_o(protocol_error),
        .read_duplicate_block_o(duplicate_block),
        .read_outstanding_o(outstanding),
        .read_capacity_full_o(capacity_full),
        .backend_cmd_valid_o(backend_cmd_v),
        .backend_cmd_ready_i(backend_cmd_r),
        .backend_cmd_write_o(backend_cmd_write),
        .backend_cmd_read_tag_o(backend_cmd_tag),
        .backend_cmd_word_addr_o(backend_cmd_word_addr),
        .backend_cmd_wdata_o(backend_cmd_wdata),
        .backend_cmd_line_addr_o(backend_cmd_line_addr),
        .backend_resp_valid_i(backend_resp_v),
        .backend_resp_read_tag_i(backend_resp_tag),
        .backend_resp_line_addr_i(backend_resp_line_addr),
        .backend_resp_fault_i(backend_resp_fault),
        .backend_resp_data_i(backend_resp_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            backend_cmd_count <= 0;
            protocol_error_count <= 0;
            for (integer p = 0; p < L2_SLICE_COUNT; p = p + 1) begin
                line_accept_count[p] <= 0;
                line_resp_count[p] <= 0;
                last_resp_tag[p] <= '0;
                last_resp_addr[p] <= '0;
                last_resp_fault[p] <= 1'b0;
                last_resp_word0[p] <= '0;
            end
            for (integer c = 0; c < 8; c = c + 1) begin
                captured_tag[c] <= '0;
                captured_addr[c] <= '0;
            end
        end else begin
            for (integer p = 0; p < L2_SLICE_COUNT; p = p + 1) begin
                if (line_req_v[p] && line_req_r[p])
                    line_accept_count[p] <= line_accept_count[p] + 1;
                if (line_resp_v[p]) begin
                    line_resp_count[p] <= line_resp_count[p] + 1;
                    last_resp_tag[p] <= line_resp_tag[p];
                    last_resp_addr[p] <= line_resp_addr[p];
                    last_resp_fault[p] <= line_resp_fault[p];
                    last_resp_word0[p] <= line_resp_data[p][0];
                end
            end
            if (backend_cmd_v && backend_cmd_r) begin
                if (backend_cmd_write
                    || backend_cmd_word_addr != 32'd0
                    || backend_cmd_wdata != 32'd0)
                    $fatal(1, "P9 read-only TB observed unexpected backend write payload");
                if (backend_cmd_count >= 8)
                    $fatal(1, "P9 TB command capture overflow");
                captured_tag[backend_cmd_count] <= backend_cmd_tag;
                captured_addr[backend_cmd_count] <= backend_cmd_line_addr;
                backend_cmd_count <= backend_cmd_count + 1;
            end
            if (protocol_error)
                protocol_error_count <= protocol_error_count + 1;
        end
    end

    task automatic issue_line(
        input logic [SLICE_IDX_W-1:0] port,
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] addr
    );
        integer accept_before;
        integer guard;
        begin
            accept_before = line_accept_count[port];
            @(negedge clk);
            line_req_tag[port] = tag;
            line_req_addr[port] = addr;
            line_req_v[port] = 1'b1;
            guard = 0;
            while (guard < 80 && line_accept_count[port] == accept_before) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (line_accept_count[port] != accept_before + 1)
                $fatal(1, "P9 line request acceptance timeout");
            @(negedge clk);
            line_req_v[port] = 1'b0;
        end
    endtask

    task automatic pulse_response(
        input logic [BACKEND_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] addr,
        input logic fault,
        input logic [31:0] word0
    );
        begin
            @(negedge clk);
            backend_resp_v = 1'b1;
            backend_resp_tag = tag;
            backend_resp_line_addr = addr;
            backend_resp_fault = fault;
            backend_resp_data[0] = word0;
            backend_resp_data[1] = word0 + 32'd1;
            backend_resp_data[2] = word0 + 32'd2;
            backend_resp_data[3] = word0 + 32'd3;
            @(posedge clk); #1;
            @(negedge clk);
            backend_resp_v = 1'b0;
            backend_resp_fault = 1'b0;
        end
    endtask

    task automatic wait_cmd_count(input integer want);
        integer guard;
        begin
            guard = 0;
            while (guard < 100 && backend_cmd_count < want) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (backend_cmd_count != want)
                $fatal(1, "P9 backend command count timeout");
        end
    endtask

    initial begin : test
        integer err_before;
        integer resp0_before;
        integer resp1_before;
        integer cmd_before;
        logic saw_duplicate_block;

        clk = 1'b0;
        rst_n = 1'b0;
        commit_valid[0] = '0;
        commit_mask[0][0] = '0;
        line_req_v = '0;
        line_req_tag[0] = '0;
        line_req_tag[1] = '0;
        line_req_addr[0] = '0;
        line_req_addr[1] = '0;
        backend_cmd_r = 1'b1;
        backend_resp_v = 1'b0;
        backend_resp_tag = '0;
        backend_resp_line_addr = '0;
        backend_resp_fault = 1'b0;
        for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
            commit_addr[0][0][lane] = '0;
            commit_wdata[0][0][lane] = '0;
        end
        for (integer word = 0; word < LINE_WORDS; word = word + 1)
            backend_resp_data[word] = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        /* Fill the bounded scoreboard with two independent slice requests. */
        issue_line(0, 3'd1, 30'd4);
        wait_cmd_count(1);
        issue_line(1, 3'd2, 30'd8);
        wait_cmd_count(2);
        repeat (2) @(posedge clk); #1;
        if (outstanding != READ_OCC_W'(2) || !capacity_full)
            $fatal(1, "P9 read scoreboard did not reach finite full state");
        $display("PROD_SEAM_P9_BOUNDED_READ_CAPACITY=PASS");

        /* A third read may sit in P8/P9 staging but cannot reach backend full. */
        issue_line(0, 3'd3, 30'd12);
        cmd_before = backend_cmd_count;
        repeat (4) @(posedge clk); #1;
        if (backend_cmd_count != cmd_before || !capacity_full)
            $fatal(1, "P9 full scoreboard leaked a third backend read");
        $display("PROD_SEAM_P9_CAPACITY_BACKPRESSURE=PASS");

        /* Complete command #1 before command #0: valid OOO restore. */
        resp0_before = line_resp_count[0];
        resp1_before = line_resp_count[1];
        pulse_response(captured_tag[1], captured_addr[1], 1'b0, 32'h22220000);
        repeat (1) @(posedge clk); #1;
        if (captured_tag[1][BACKEND_TAG_W-1] != 1'b1
            || line_resp_count[1] != resp1_before + 1
            || line_resp_count[0] != resp0_before
            || last_resp_tag[1] != 3'd2
            || last_resp_addr[1] != 30'd8
            || last_resp_fault[1]
            || last_resp_word0[1] != 32'h22220000)
            $fatal(1, "P9 out-of-order response restored to wrong slice/tag/address");
        $display("PROD_SEAM_P9_OUT_OF_ORDER_IDENTITY_RESTORE=PASS");

        /* Freed capacity must permit the staged third request. */
        wait_cmd_count(3);
        if (captured_tag[2][NETWORK_TAG_W-1:0] != 3'd3
            || captured_addr[2] != 30'd12)
            $fatal(1, "P9 staged read identity changed after capacity release");
        $display("PROD_SEAM_P9_CAPACITY_RELEASE_PROGRESS=PASS");

        /* Duplicate response after entry free is diagnostic-only. */
        err_before = protocol_error_count;
        resp1_before = line_resp_count[1];
        pulse_response(captured_tag[1], captured_addr[1], 1'b0, 32'hDEAD0000);
        repeat (1) @(posedge clk); #1;
        if (protocol_error_count != err_before + 1
            || line_resp_count[1] != resp1_before)
            $fatal(1, "P9 duplicate response escaped or lacked diagnostic");
        $display("PROD_SEAM_P9_DUPLICATE_RESPONSE_REJECT=PASS");

        /* Address mismatch for a live tag is suppressed without freeing it. */
        err_before = protocol_error_count;
        resp0_before = line_resp_count[0];
        pulse_response(captured_tag[0], captured_addr[0] + LINE_ADDR_W'(1),
                       1'b0, 32'hBAD00000);
        repeat (1) @(posedge clk); #1;
        if (protocol_error_count != err_before + 1
            || line_resp_count[0] != resp0_before
            || outstanding != READ_OCC_W'(2))
            $fatal(1, "P9 address-mismatch response corrupted live transaction");
        $display("PROD_SEAM_P9_ADDRESS_MISMATCH_REJECT=PASS");

        /* Correct completion still succeeds after the rejected mismatch. */
        pulse_response(captured_tag[0], captured_addr[0], 1'b0, 32'h11110000);
        repeat (1) @(posedge clk); #1;
        if (line_resp_count[0] != resp0_before + 1
            || last_resp_tag[0] != 3'd1
            || last_resp_addr[0] != 30'd4
            || last_resp_word0[0] != 32'h11110000)
            $fatal(1, "P9 live transaction did not survive mismatch diagnostic");
        $display("PROD_SEAM_P9_EXACT_LIVE_RESPONSE_ONLY=PASS");

        /* The staged third request returns a genuine backend fault distinctly. */
        resp0_before = line_resp_count[0];
        pulse_response(captured_tag[2], captured_addr[2], 1'b1, 32'h33330000);
        repeat (1) @(posedge clk); #1;
        if (line_resp_count[0] != resp0_before + 1
            || last_resp_tag[0] != 3'd3
            || last_resp_addr[0] != 30'd12
            || !last_resp_fault[0]
            || last_resp_word0[0] != 32'h33330000
            || outstanding != READ_OCC_W'(0))
            $fatal(1, "P9 backend fault provenance or final free mismatch");
        $display("PROD_SEAM_P9_FAULT_PROVENANCE_DISTINCT=PASS");

        /* Unknown/invalid response cannot become a refill. */
        err_before = protocol_error_count;
        resp0_before = line_resp_count[0];
        resp1_before = line_resp_count[1];
        pulse_response(4'hF, 30'd31, 1'b0, 32'hFFFF0000);
        repeat (1) @(posedge clk); #1;
        if (protocol_error_count != err_before + 1
            || line_resp_count[0] != resp0_before
            || line_resp_count[1] != resp1_before)
            $fatal(1, "P9 unknown response escaped transaction guard");
        $display("PROD_SEAM_P9_UNKNOWN_RESPONSE_REJECT=PASS");

        /* Reusing the same live backend tag is held until old completion. */
        issue_line(0, 3'd4, 30'd16);
        wait_cmd_count(4);
        issue_line(0, 3'd4, 30'd20);
        cmd_before = backend_cmd_count;
        saw_duplicate_block = 1'b0;
        repeat (4) begin
            @(posedge clk); #1;
            if (duplicate_block)
                saw_duplicate_block = 1'b1;
        end
        if (!saw_duplicate_block || backend_cmd_count != cmd_before)
            $fatal(1, "P9 duplicate live tag was not backpressured");
        $display("PROD_SEAM_P9_DUPLICATE_LIVE_TAG_BACKPRESSURE=PASS");

        pulse_response(captured_tag[3], captured_addr[3], 1'b0, 32'h44440000);
        wait_cmd_count(5);
        if (captured_tag[4] != captured_tag[3]
            || captured_addr[4] != 30'd20)
            $fatal(1, "P9 tag reuse did not wait for prior completion");
        pulse_response(captured_tag[4], captured_addr[4], 1'b0, 32'h55550000);
        repeat (2) @(posedge clk); #1;
        if (outstanding != READ_OCC_W'(0) || capacity_full || commit_ready[0][0])
            $fatal(1, "P9 final transaction state not clean");
        $display("PROD_SEAM_P9_SAFE_TAG_REUSE_AFTER_COMPLETION=PASS");

        $display("PROD_SEAM_P9_BEHAVIOR=PASS");
        $finish;
    end
endmodule
