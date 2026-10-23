`timescale 1ns/1ps

module a0_backend_read_epoch_guard_tb;
    localparam integer CLUSTER_COUNT = 1;
    localparam integer CUS_PER_CLUSTER = 1;
    localparam integer STORE_LANES = 2;
    localparam integer L2_SLICE_COUNT = 2;
    localparam integer LINE_WORDS = 4;
    localparam integer NETWORK_TAG_W = 3;
    localparam integer READ_TRACK_COUNT = 2;
    localparam integer READ_EPOCH_W = 2;
    localparam integer WORD_SELECT_W = $clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W = 32 - WORD_SELECT_W;
    localparam integer LINE_PORT_ID_W = 1;
    localparam integer BASE_READ_TAG_W = LINE_PORT_ID_W + NETWORK_TAG_W;
    localparam integer EXT_READ_ID_W = BASE_READ_TAG_W + READ_EPOCH_W;
    localparam integer READ_OCC_W = 2;
    localparam integer SLICE_IDX_W = 1;

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
    logic read_duplicate;
    logic [READ_OCC_W-1:0] read_outstanding;
    logic read_capacity_full;
    logic epoch_wrap_block;
    logic [READ_EPOCH_W-1:0] next_generation;
    logic [READ_OCC_W-1:0] epoch_outstanding;

    logic backend_cmd_v;
    logic backend_cmd_r;
    logic backend_cmd_write;
    logic [EXT_READ_ID_W-1:0] backend_cmd_id;
    logic [31:0] backend_cmd_word_addr;
    logic [31:0] backend_cmd_wdata;
    logic [LINE_ADDR_W-1:0] backend_cmd_line_addr;

    logic backend_resp_v;
    logic [EXT_READ_ID_W-1:0] backend_resp_id;
    logic [LINE_ADDR_W-1:0] backend_resp_line_addr;
    logic backend_resp_fault;
    logic [31:0] backend_resp_data [0:LINE_WORDS-1];
    logic epoch_reuse_safe;

    integer line_accept_count [0:L2_SLICE_COUNT-1];
    integer line_resp_count [0:L2_SLICE_COUNT-1];
    integer backend_cmd_count;
    integer protocol_error_count;
    logic [EXT_READ_ID_W-1:0] captured_id [0:15];
    logic [NETWORK_TAG_W-1:0] last_resp_tag [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] last_resp_addr [0:L2_SLICE_COUNT-1];
    logic last_resp_fault [0:L2_SLICE_COUNT-1];
    logic [31:0] last_resp_word0 [0:L2_SLICE_COUNT-1];

    a0_production_store_backend_epoch_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT),
        .READ_EPOCH_W(READ_EPOCH_W)
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
        .read_duplicate_block_o(read_duplicate),
        .read_outstanding_o(read_outstanding),
        .read_capacity_full_o(read_capacity_full),
        .epoch_wrap_block_o(epoch_wrap_block),
        .next_generation_o(next_generation),
        .epoch_outstanding_o(epoch_outstanding),
        .backend_cmd_valid_o(backend_cmd_v),
        .backend_cmd_ready_i(backend_cmd_r),
        .backend_cmd_write_o(backend_cmd_write),
        .backend_cmd_read_id_o(backend_cmd_id),
        .backend_cmd_word_addr_o(backend_cmd_word_addr),
        .backend_cmd_wdata_o(backend_cmd_wdata),
        .backend_cmd_line_addr_o(backend_cmd_line_addr),
        .backend_resp_valid_i(backend_resp_v),
        .backend_resp_read_id_i(backend_resp_id),
        .backend_resp_line_addr_i(backend_resp_line_addr),
        .backend_resp_fault_i(backend_resp_fault),
        .backend_resp_data_i(backend_resp_data),
        .backend_epoch_reuse_safe_i(epoch_reuse_safe)
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
            for (integer c = 0; c < 16; c = c + 1) begin
                captured_id[c] <= '0;
            end
        end else begin
            if ($isunknown(commit_ready[0]))
                $fatal(1, "P10 commit-ready became unknown");
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
                if (backend_cmd_write || backend_cmd_word_addr != 32'd0
                    || backend_cmd_wdata != 32'd0)
                    $fatal(1, "P10 read-only TB observed backend write payload");
                if (backend_cmd_line_addr == '0)
                    $fatal(1, "P10 backend read lost line-address provenance");
                if (backend_cmd_count >= 16)
                    $fatal(1, "P10 command capture overflow");
                captured_id[backend_cmd_count] <= backend_cmd_id;
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
            while (guard < 100 && line_accept_count[port] == accept_before) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (line_accept_count[port] != accept_before + 1)
                $fatal(1, "P10 line request acceptance timeout");
            @(negedge clk);
            line_req_v[port] = 1'b0;
        end
    endtask

    task automatic wait_cmd_count(input integer want);
        integer guard;
        begin
            guard = 0;
            while (guard < 120 && backend_cmd_count < want) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (backend_cmd_count != want)
                $fatal(1, "P10 backend command count timeout");
        end
    endtask

    task automatic pulse_response(
        input logic [EXT_READ_ID_W-1:0] id,
        input logic [LINE_ADDR_W-1:0] addr,
        input logic fault,
        input logic [31:0] word0
    );
        begin
            @(negedge clk);
            backend_resp_v = 1'b1;
            backend_resp_id = id;
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
            @(posedge clk); #1;
        end
    endtask

    initial begin : test
        localparam logic [LINE_ADDR_W-1:0] A = LINE_ADDR_W'(30'h1010);
        localparam logic [LINE_ADDR_W-1:0] B = LINE_ADDR_W'(30'h2020);
        localparam logic [LINE_ADDR_W-1:0] C = LINE_ADDR_W'(30'h3030);
        localparam logic [LINE_ADDR_W-1:0] D = LINE_ADDR_W'(30'h4040);
        localparam logic [LINE_ADDR_W-1:0] E = LINE_ADDR_W'(30'h5050);
        integer err_before;
        integer resp_before;
        integer cmd_before;
        logic [EXT_READ_ID_W-1:0] id0;
        logic [EXT_READ_ID_W-1:0] id1;
        logic [EXT_READ_ID_W-1:0] id2;
        logic [EXT_READ_ID_W-1:0] id3;
        logic [EXT_READ_ID_W-1:0] id4;
        logic [EXT_READ_ID_W-1:0] id5;

        clk = 1'b0;
        rst_n = 1'b0;
        backend_cmd_r = 1'b1;
        backend_resp_v = 1'b0;
        backend_resp_id = '0;
        backend_resp_line_addr = '0;
        backend_resp_fault = 1'b0;
        epoch_reuse_safe = 1'b0;
        line_req_v = '0;
        for (integer p = 0; p < L2_SLICE_COUNT; p = p + 1) begin
            line_req_tag[p] = '0;
            line_req_addr[p] = '0;
        end
        for (integer w = 0; w < LINE_WORDS; w = w + 1)
            backend_resp_data[w] = '0;
        for (integer c = 0; c < CLUSTER_COUNT; c = c + 1) begin
            commit_valid[c] = '0;
            for (integer u = 0; u < CUS_PER_CLUSTER; u = u + 1) begin
                commit_mask[c][u] = '0;
                for (integer l = 0; l < STORE_LANES; l = l + 1) begin
                    commit_addr[c][u][l] = '0;
                    commit_wdata[c][u][l] = '0;
                end
            end
        end

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;

        issue_line(SLICE_IDX_W'(0), NETWORK_TAG_W'(1), A);
        wait_cmd_count(1);
        id0 = captured_id[0];
        if (id0[EXT_READ_ID_W-1:BASE_READ_TAG_W] != READ_EPOCH_W'(0))
            $fatal(1, "P10 first generation mismatch");
        pulse_response(id0, A, 1'b0, 32'h1000_0000);
        if (line_resp_count[0] != 1 || last_resp_tag[0] != NETWORK_TAG_W'(1)
            || last_resp_addr[0] != A || last_resp_fault[0]
            || last_resp_word0[0] != 32'h1000_0000)
            $fatal(1, "P10 first completion mismatch");
        $display("PROD_SEAM_P10_GENERATION_IDENTITY=PASS");

        issue_line(SLICE_IDX_W'(0), NETWORK_TAG_W'(1), A);
        wait_cmd_count(2);
        id1 = captured_id[1];
        if (id1[BASE_READ_TAG_W-1:0] != id0[BASE_READ_TAG_W-1:0]
            || id1[EXT_READ_ID_W-1:BASE_READ_TAG_W] != READ_EPOCH_W'(1))
            $fatal(1, "P10 same base tag did not advance generation");
        err_before = protocol_error_count;
        resp_before = line_resp_count[0];
        pulse_response(id0, A, 1'b0, 32'hdead_0000);
        if (protocol_error_count != err_before + 1
            || line_resp_count[0] != resp_before
            || epoch_outstanding != READ_OCC_W'(1)
            || read_outstanding != READ_OCC_W'(1))
            $fatal(1, "P10 late old-generation response was not rejected");
        $display("PROD_SEAM_P10_LATE_OLD_GENERATION_REJECT=PASS");

        pulse_response(id1, A, 1'b0, 32'h1100_0000);
        if (line_resp_count[0] != resp_before + 1
            || last_resp_word0[0] != 32'h1100_0000)
            $fatal(1, "P10 current generation did not complete");
        $display("PROD_SEAM_P10_CURRENT_GENERATION_RESTORE=PASS");

        issue_line(SLICE_IDX_W'(0), NETWORK_TAG_W'(2), B);
        wait_cmd_count(3);
        id2 = captured_id[2];
        issue_line(SLICE_IDX_W'(1), NETWORK_TAG_W'(3), C);
        wait_cmd_count(4);
        id3 = captured_id[3];
        if (id2[EXT_READ_ID_W-1:BASE_READ_TAG_W] != READ_EPOCH_W'(2)
            || id3[EXT_READ_ID_W-1:BASE_READ_TAG_W] != READ_EPOCH_W'(3)
            || !epoch_wrap_block || next_generation != READ_EPOCH_W'(0)
            || epoch_outstanding != READ_OCC_W'(2)
            || !read_capacity_full)
            $fatal(1, "P10 generation wrap/live capacity state mismatch");
        $display("PROD_SEAM_P10_BOUNDED_GENERATION_WRAP=PASS");

        resp_before = line_resp_count[1];
        pulse_response(id3, C, 1'b0, 32'h3300_0000);
        if (line_resp_count[1] != resp_before + 1
            || last_resp_tag[1] != NETWORK_TAG_W'(3)
            || last_resp_addr[1] != C || last_resp_fault[1])
            $fatal(1, "P10 OOO first completion restore mismatch");
        resp_before = line_resp_count[0];
        pulse_response(id2, B, 1'b1, 32'h2200_0000);
        if (line_resp_count[0] != resp_before + 1
            || last_resp_tag[0] != NETWORK_TAG_W'(2)
            || last_resp_addr[0] != B || !last_resp_fault[0])
            $fatal(1, "P10 OOO/fault restore mismatch");
        if (epoch_outstanding != '0 || read_outstanding != '0)
            $fatal(1, "P10 OOO completions did not drain trackers");
        $display("PROD_SEAM_P10_OOO_AND_FAULT_PROVENANCE=PASS");

        cmd_before = backend_cmd_count;
        issue_line(SLICE_IDX_W'(0), NETWORK_TAG_W'(4), D);
        repeat (8) @(posedge clk); #1;
        if (backend_cmd_count != cmd_before || !epoch_wrap_block)
            $fatal(1, "P10 wrap did not backpressure new read");
        $display("PROD_SEAM_P10_WRAP_BACKPRESSURE=PASS");

        err_before = protocol_error_count;
        resp_before = line_resp_count[0];
        pulse_response(id0, A, 1'b0, 32'hbad0_0000);
        if (protocol_error_count != err_before + 1
            || line_resp_count[0] != resp_before)
            $fatal(1, "P10 old response during wrap block escaped");
        $display("PROD_SEAM_P10_OLD_RESPONSE_DURING_WRAP_REJECT=PASS");

        @(negedge clk); epoch_reuse_safe = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); epoch_reuse_safe = 1'b0;
        wait_cmd_count(cmd_before + 1);
        id4 = captured_id[cmd_before];
        if (id4[EXT_READ_ID_W-1:BASE_READ_TAG_W] != READ_EPOCH_W'(0)
            || epoch_wrap_block)
            $fatal(1, "P10 explicit safe reuse did not release wrap");
        $display("PROD_SEAM_P10_EXPLICIT_SAFE_REUSE_RELEASE=PASS");

        pulse_response(id4, D, 1'b0, 32'h4400_0000);
        if (last_resp_tag[0] != NETWORK_TAG_W'(4)
            || last_resp_addr[0] != D || last_resp_fault[0]
            || last_resp_word0[0] != 32'h4400_0000)
            $fatal(1, "P10 post-wrap exact response mismatch");
        $display("PROD_SEAM_P10_POST_WRAP_EXACT_RESPONSE=PASS");

        issue_line(SLICE_IDX_W'(1), NETWORK_TAG_W'(5), E);
        wait_cmd_count(cmd_before + 2);
        id5 = captured_id[cmd_before + 1];
        err_before = protocol_error_count;
        resp_before = line_resp_count[1];
        pulse_response(id5, E + LINE_ADDR_W'(1), 1'b0, 32'h5500_0000);
        if (protocol_error_count != err_before + 1
            || line_resp_count[1] != resp_before
            || epoch_outstanding != READ_OCC_W'(1)
            || read_outstanding != READ_OCC_W'(1))
            $fatal(1, "P10 did not preserve P9 address mismatch contract");
        pulse_response(id5, E, 1'b0, 32'h5510_0000);
        if (line_resp_count[1] != resp_before + 1
            || last_resp_word0[1] != 32'h5510_0000)
            $fatal(1, "P10 exact response after mismatch failed");
        $display("PROD_SEAM_P10_P9_INTEGRITY_PRESERVED=PASS");

        err_before = protocol_error_count;
        resp_before = line_resp_count[1];
        pulse_response(id5, E, 1'b0, 32'h5520_0000);
        if (protocol_error_count != err_before + 1
            || line_resp_count[1] != resp_before)
            $fatal(1, "P10 duplicate completed incarnation escaped");
        $display("PROD_SEAM_P10_DUPLICATE_INCARCERATION_REJECT=PASS");

        if (read_duplicate || read_capacity_full || epoch_outstanding != '0
            || read_outstanding != '0)
            $fatal(1, "P10 final bounded state not clean");
        $display("PROD_SEAM_P10_BEHAVIOR=PASS");
        $finish;
    end
endmodule
