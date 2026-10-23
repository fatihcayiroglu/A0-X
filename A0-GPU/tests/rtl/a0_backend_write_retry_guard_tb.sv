`timescale 1ns/1ps

module a0_backend_write_retry_guard_tb;
    localparam integer CLUSTER_COUNT = 1;
    localparam integer CUS_PER_CLUSTER = 1;
    localparam integer STORE_LANES = 2;
    localparam integer L2_SLICE_COUNT = 1;
    localparam integer LINE_WORDS = 4;
    localparam integer NETWORK_TAG_W = 2;
    localparam integer READ_TRACK_COUNT = 2;
    localparam integer READ_EPOCH_W = 4;
    localparam integer WRITE_ID_W = 2;
    localparam integer MAX_WRITE_RETRIES = 2;
    localparam integer RETRY_W = $clog2(MAX_WRITE_RETRIES + 1);
    localparam integer WORD_SELECT_W = $clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W = 32 - WORD_SELECT_W;
    localparam integer LINE_PORT_ID_W = 1;
    localparam integer BASE_READ_TAG_W = LINE_PORT_ID_W + NETWORK_TAG_W;
    localparam integer EXT_READ_ID_W = BASE_READ_TAG_W + READ_EPOCH_W;
    localparam integer EXT_WRITE_ATTEMPT_ID_W = WRITE_ID_W + RETRY_W;
    localparam integer READ_OCC_W = 2;

    logic clk;
    logic rst_n;
    always #5 clk = ~clk;

    logic [CUS_PER_CLUSTER-1:0] commit_valid [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] commit_ready [0:CLUSTER_COUNT-1];
    logic [STORE_LANES-1:0] commit_mask [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [31:0] commit_addr [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1];
    logic [31:0] commit_wdata [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1];
    logic [CUS_PER_CLUSTER-1:0] duplicate_collapse [0:CLUSTER_COUNT-1];

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
    logic read_wrap_block;
    logic [READ_EPOCH_W-1:0] next_read_generation;
    logic [READ_OCC_W-1:0] read_epoch_outstanding;
    logic write_ack_error;
    logic write_wrap_block;
    logic [WRITE_ID_W-1:0] next_write_id;
    logic write_pending;
    logic write_issued;
    logic status_error;
    logic retry_exhausted;
    logic terminal_failure;
    logic [RETRY_W-1:0] retry_count;
    logic retry_pending;

    logic issue_v;
    logic issue_r;
    logic issue_write;
    logic [EXT_READ_ID_W-1:0] issue_read_id;
    logic [EXT_WRITE_ATTEMPT_ID_W-1:0] issue_attempt_id;
    logic [31:0] issue_word_addr;
    logic [31:0] issue_wdata;
    logic [LINE_ADDR_W-1:0] issue_line_addr;

    logic read_resp_v;
    logic [EXT_READ_ID_W-1:0] read_resp_id;
    logic [LINE_ADDR_W-1:0] read_resp_line_addr;
    logic read_resp_fault;
    logic [31:0] read_resp_data [0:LINE_WORDS-1];
    logic read_reuse_safe;

    logic status_v;
    logic [EXT_WRITE_ATTEMPT_ID_W-1:0] status_attempt_id;
    logic status_success;
    logic status_retryable;
    logic write_reuse_safe;

    logic [31:0] memory [0:255];
    integer commit_accept_count;
    integer line_accept_count;
    integer line_resp_count;
    integer write_issue_count;
    integer read_issue_count;
    integer status_error_count;
    integer protocol_error_count;
    logic [EXT_WRITE_ATTEMPT_ID_W-1:0] attempt_seen [0:15];
    logic [31:0] write_addr_seen [0:15];
    logic [31:0] write_data_seen [0:15];
    logic [EXT_READ_ID_W-1:0] last_read_id;
    logic [LINE_ADDR_W-1:0] last_read_line;
    logic [31:0] last_resp_data [0:LINE_WORDS-1];
    logic last_resp_fault;

    a0_production_store_backend_retry_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT),
        .READ_EPOCH_W(READ_EPOCH_W),
        .WRITE_ID_W(WRITE_ID_W),
        .MAX_WRITE_RETRIES(MAX_WRITE_RETRIES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .store_commit_valid_i(commit_valid),
        .store_commit_ready_o(commit_ready),
        .store_commit_lane_mask_i(commit_mask),
        .store_commit_word_addr_i(commit_addr),
        .store_commit_wdata_i(commit_wdata),
        .store_duplicate_collapse_o(duplicate_collapse),
        .line_mem_req_valid_i(line_req_v),
        .line_mem_req_ready_o(line_req_r),
        .line_mem_req_network_tag_i(line_req_tag),
        .line_mem_req_line_addr_i(line_req_addr),
        .line_mem_resp_valid_o(line_resp_v),
        .line_mem_resp_network_tag_o(line_resp_tag),
        .line_mem_resp_line_addr_o(line_resp_addr),
        .line_mem_resp_fault_o(line_resp_fault),
        .line_mem_resp_data_o(line_resp_data),
        .backend_protocol_error_o(protocol_error),
        .read_duplicate_block_o(read_duplicate),
        .read_outstanding_o(read_outstanding),
        .read_capacity_full_o(read_capacity_full),
        .read_epoch_wrap_block_o(read_wrap_block),
        .next_read_generation_o(next_read_generation),
        .read_epoch_outstanding_o(read_epoch_outstanding),
        .write_ack_protocol_error_o(write_ack_error),
        .write_wrap_block_o(write_wrap_block),
        .next_write_id_o(next_write_id),
        .write_pending_o(write_pending),
        .write_issued_o(write_issued),
        .write_status_protocol_error_o(status_error),
        .write_retry_exhausted_o(retry_exhausted),
        .write_terminal_failure_o(terminal_failure),
        .write_retry_count_o(retry_count),
        .write_retry_pending_o(retry_pending),
        .backend_issue_valid_o(issue_v),
        .backend_issue_ready_i(issue_r),
        .backend_issue_write_o(issue_write),
        .backend_issue_read_id_o(issue_read_id),
        .backend_issue_write_attempt_id_o(issue_attempt_id),
        .backend_issue_word_addr_o(issue_word_addr),
        .backend_issue_wdata_o(issue_wdata),
        .backend_issue_line_addr_o(issue_line_addr),
        .backend_read_resp_valid_i(read_resp_v),
        .backend_read_resp_id_i(read_resp_id),
        .backend_read_resp_line_addr_i(read_resp_line_addr),
        .backend_read_resp_fault_i(read_resp_fault),
        .backend_read_resp_data_i(read_resp_data),
        .backend_read_epoch_reuse_safe_i(read_reuse_safe),
        .backend_write_status_valid_i(status_v),
        .backend_write_status_attempt_id_i(status_attempt_id),
        .backend_write_status_success_i(status_success),
        .backend_write_status_retryable_i(status_retryable),
        .backend_write_reuse_safe_i(write_reuse_safe)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            commit_accept_count <= 0;
            line_accept_count <= 0;
            line_resp_count <= 0;
            write_issue_count <= 0;
            read_issue_count <= 0;
            status_error_count <= 0;
            protocol_error_count <= 0;
            last_read_id <= '0;
            last_read_line <= '0;
            last_resp_fault <= 1'b0;
            for (integer i = 0; i < 16; i = i + 1) begin
                attempt_seen[i] <= '0;
                write_addr_seen[i] <= '0;
                write_data_seen[i] <= '0;
            end
            for (integer w = 0; w < LINE_WORDS; w = w + 1)
                last_resp_data[w] <= '0;
        end else begin
            if (commit_valid[0][0] && commit_ready[0][0])
                commit_accept_count <= commit_accept_count + 1;
            if (line_req_v[0] && line_req_r[0])
                line_accept_count <= line_accept_count + 1;
            if (status_error)
                status_error_count <= status_error_count + 1;
            if (protocol_error)
                protocol_error_count <= protocol_error_count + 1;
            if (issue_v && issue_r) begin
                if (issue_write) begin
                    attempt_seen[write_issue_count] <= issue_attempt_id;
                    write_addr_seen[write_issue_count] <= issue_word_addr;
                    write_data_seen[write_issue_count] <= issue_wdata;
                    write_issue_count <= write_issue_count + 1;
                end else begin
                    last_read_id <= issue_read_id;
                    last_read_line <= issue_line_addr;
                    read_issue_count <= read_issue_count + 1;
                end
            end
            if (line_resp_v[0]) begin
                line_resp_count <= line_resp_count + 1;
                last_resp_fault <= line_resp_fault[0];
                for (integer w = 0; w < LINE_WORDS; w = w + 1)
                    last_resp_data[w] <= line_resp_data[0][w];
            end
        end
    end

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            commit_valid[0] = '0;
            commit_mask[0][0] = '0;
            line_req_v = '0;
            status_v = 1'b0;
            status_success = 1'b0;
            status_retryable = 1'b0;
            read_resp_v = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            repeat (2) @(posedge clk); #1;
        end
    endtask

    task automatic start_commit(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(negedge clk);
            commit_addr[0][0][0] = addr;
            commit_wdata[0][0][0] = data;
            commit_addr[0][0][1] = addr + 32'd1;
            commit_wdata[0][0][1] = '0;
            commit_mask[0][0] = 2'b01;
            commit_valid[0][0] = 1'b1;
        end
    endtask

    task automatic finish_commit(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 160 && commit_accept_count < target) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (commit_accept_count != target)
                $fatal(1, "P13 commit completion timeout");
            commit_valid[0][0] = 1'b0;
            commit_mask[0][0] = '0;
        end
    endtask

    task automatic wait_write_issues(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 160 && write_issue_count < target) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (write_issue_count != target)
                $fatal(1, "P13 write issue timeout");
        end
    endtask

    task automatic pulse_status(
        input logic [EXT_WRITE_ATTEMPT_ID_W-1:0] id,
        input logic success,
        input logic retryable,
        input logic make_visible
    );
        integer idx;
        begin
            idx = write_issue_count - 1;
            @(negedge clk);
            if (make_visible && success && idx >= 0)
                memory[write_addr_seen[idx][7:0]] = write_data_seen[idx];
            status_attempt_id = id;
            status_success = success;
            status_retryable = retryable;
            status_v = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            status_v = 1'b0;
            status_success = 1'b0;
            status_retryable = 1'b0;
        end
    endtask

    task automatic issue_line(
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] addr
    );
        integer before_count;
        integer guard;
        begin
            before_count = line_accept_count;
            @(negedge clk);
            line_req_tag[0] = tag;
            line_req_addr[0] = addr;
            line_req_v[0] = 1'b1;
            guard = 0;
            while (guard < 120 && line_accept_count == before_count) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (line_accept_count != before_count + 1)
                $fatal(1, "P13 line acceptance timeout");
            @(negedge clk); line_req_v[0] = 1'b0;
        end
    endtask

    task automatic wait_read_issues(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 160 && read_issue_count < target) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (read_issue_count != target)
                $fatal(1, "P13 read issue timeout");
        end
    endtask

    task automatic respond_read(input logic fault);
        logic [7:0] base_word;
        begin
            base_word = 8'(last_read_line << WORD_SELECT_W);
            @(negedge clk);
            read_resp_v = 1'b1;
            read_resp_id = last_read_id;
            read_resp_line_addr = last_read_line;
            read_resp_fault = fault;
            for (integer w = 0; w < LINE_WORDS; w = w + 1)
                read_resp_data[w] = memory[integer'(base_word) + w];
            @(posedge clk); #1;
            @(negedge clk);
            read_resp_v = 1'b0;
            read_resp_fault = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    initial begin : test
        logic [EXT_WRITE_ATTEMPT_ID_W-1:0] attempt0;
        logic [EXT_WRITE_ATTEMPT_ID_W-1:0] attempt1;
        logic [31:0] first_addr;
        logic [31:0] first_data;
        integer err_before;
        integer issues_before;
        integer commits_before;
        integer resp_before;

        clk = 1'b0;
        rst_n = 1'b0;
        issue_r = 1'b1;
        read_resp_v = 1'b0;
        read_resp_id = '0;
        read_resp_line_addr = '0;
        read_resp_fault = 1'b0;
        read_reuse_safe = 1'b0;
        status_v = 1'b0;
        status_attempt_id = '0;
        status_success = 1'b0;
        status_retryable = 1'b0;
        write_reuse_safe = 1'b0;
        line_req_v = '0;
        line_req_tag[0] = '0;
        line_req_addr[0] = '0;
        commit_valid[0] = '0;
        commit_mask[0][0] = '0;
        for (integer l = 0; l < STORE_LANES; l = l + 1) begin
            commit_addr[0][0][l] = '0;
            commit_wdata[0][0][l] = '0;
        end
        for (integer w = 0; w < LINE_WORDS; w = w + 1)
            read_resp_data[w] = '0;
        for (integer m = 0; m < 256; m = m + 1)
            memory[m] = 32'hd100_0000 + 32'(m);

        reset_dut();

        /* Retry success path: first NACK must not release visibility. */
        start_commit(32'h20, 32'haaaa_0020);
        wait_write_issues(1);
        attempt0 = attempt_seen[0];
        first_addr = write_addr_seen[0];
        first_data = write_data_seen[0];
        commits_before = commit_accept_count;
        pulse_status(attempt0, 1'b0, 1'b1, 1'b0);
        repeat (3) @(posedge clk); #1;
        if (commit_accept_count != commits_before || memory[8'h20] == 32'haaaa_0020)
            $fatal(1, "P13 retryable failure released visibility");
        $display("PROD_SEAM_P13_FIRST_RETRYABLE_FAILURE_NO_VISIBILITY=PASS");

        wait_write_issues(2);
        attempt1 = attempt_seen[1];
        if (write_addr_seen[1] != first_addr || write_data_seen[1] != first_data)
            $fatal(1, "P13 retry changed payload");
        if (attempt1[WRITE_ID_W-1:0] != attempt0[WRITE_ID_W-1:0]
            || attempt1[EXT_WRITE_ATTEMPT_ID_W-1:WRITE_ID_W]
                == attempt0[EXT_WRITE_ATTEMPT_ID_W-1:WRITE_ID_W])
            $fatal(1, "P13 attempt/base identity contract broken");
        $display("PROD_SEAM_P13_RETRY_PAYLOAD_EXACT=PASS");
        $display("PROD_SEAM_P13_P12_WRITE_ID_PRESERVED=PASS");

        /* Conflicting refill may enter predecessor slot but must not issue. */
        issues_before = read_issue_count;
        issue_line(2'b01, LINE_ADDR_W'(32'h20 >> WORD_SELECT_W));
        repeat (4) @(posedge clk); #1;
        if (read_issue_count != issues_before)
            $fatal(1, "P13 conflicting refill escaped before retry success");
        $display("PROD_SEAM_P13_CONFLICTING_REFILL_HELD_DURING_RETRY=PASS");

        /* Old attempt status is stale and cannot release the current attempt. */
        err_before = status_error_count;
        pulse_status(attempt0, 1'b1, 1'b0, 1'b0);
        repeat (2) @(posedge clk); #1;
        if (status_error_count != err_before + 1 || commit_accept_count != commits_before)
            $fatal(1, "P13 stale attempt status not rejected");
        $display("PROD_SEAM_P13_STALE_ATTEMPT_STATUS_REJECT=PASS");

        /* Exact retry success updates backing memory and releases exactly once. */
        pulse_status(attempt1, 1'b1, 1'b0, 1'b1);
        finish_commit(commits_before + 1);
        if (memory[8'h20] != 32'haaaa_0020)
            $fatal(1, "P13 exact retry success did not become visible");
        repeat (4) @(posedge clk); #1;
        if (commit_accept_count != commits_before + 1)
            $fatal(1, "P13 success released commit more than once");
        $display("PROD_SEAM_P13_RETRY_SUCCESS_EXACT_ONCE_RELEASE=PASS");

        wait_read_issues(issues_before + 1);
        respond_read(1'b0);
        repeat (4) @(posedge clk); #1;
        if (line_resp_count != 1 || last_resp_fault || last_resp_data[0] != 32'haaaa_0020)
            $fatal(1, "P13 post-retry refill did not observe committed data");
        $display("PROD_SEAM_P13_POST_RETRY_REFILL_VISIBLE=PASS");

        /* Duplicate success after completion is stale/unknown. */
        err_before = status_error_count;
        pulse_status(attempt1, 1'b1, 1'b0, 1'b0);
        if (status_error_count != err_before + 1)
            $fatal(1, "P13 duplicate status not rejected");
        $display("PROD_SEAM_P13_DUPLICATE_STATUS_REJECT=PASS");

        /* Exhaustion: initial + two retries, then fail closed with no fourth issue. */
        start_commit(32'h24, 32'hbbbb_0024);
        wait_write_issues(3);
        pulse_status(attempt_seen[2], 1'b0, 1'b1, 1'b0);
        wait_write_issues(4);
        pulse_status(attempt_seen[3], 1'b0, 1'b1, 1'b0);
        wait_write_issues(5);
        commits_before = commit_accept_count;
        pulse_status(attempt_seen[4], 1'b0, 1'b1, 1'b0);
        repeat (5) @(posedge clk); #1;
        if (!retry_exhausted || retry_count != RETRY_W'(MAX_WRITE_RETRIES))
            $fatal(1, "P13 retry limit did not exhaust deterministically");
        if (write_issue_count != 5)
            $fatal(1, "P13 issued beyond retry limit");
        $display("PROD_SEAM_P13_RETRY_LIMIT_BOUNDED=PASS");
        if (commit_accept_count != commits_before || memory[8'h24] == 32'hbbbb_0024)
            $fatal(1, "P13 exhaustion faked visibility success");
        $display("PROD_SEAM_P13_EXHAUSTION_FAIL_CLOSED=PASS");

        err_before = status_error_count;
        pulse_status(attempt_seen[4], 1'b1, 1'b0, 1'b0);
        if (status_error_count != err_before + 1 || commit_accept_count != commits_before)
            $fatal(1, "P13 late status after exhaustion released write");
        $display("PROD_SEAM_P13_POST_EXHAUSTION_STATUS_REJECT=PASS");

        /* Reset fail-closed state, then prove terminal non-retryable failure. */
        reset_dut();
        start_commit(32'h28, 32'hcccc_0028);
        wait_write_issues(1);
        pulse_status(attempt_seen[0], 1'b0, 1'b0, 1'b0);
        repeat (4) @(posedge clk); #1;
        if (!terminal_failure || retry_exhausted || write_issue_count != 1
            || commit_accept_count != 0 || memory[8'h28] == 32'hcccc_0028)
            $fatal(1, "P13 terminal failure did not fail closed");
        $display("PROD_SEAM_P13_TERMINAL_FAILURE_FAIL_CLOSED=PASS");

        /* Reset again and prove predecessor read identity/fault behavior survives. */
        reset_dut();
        resp_before = line_resp_count;
        issue_line(2'b10, LINE_ADDR_W'(32'h30 >> WORD_SELECT_W));
        wait_read_issues(1);
        respond_read(1'b1);
        repeat (3) @(posedge clk); #1;
        if (line_resp_count != resp_before + 1 || !last_resp_fault)
            $fatal(1, "P13 read fault provenance broken");
        $display("PROD_SEAM_P13_READ_PATH_PRESERVED=PASS");

        if (write_ack_error)
            $fatal(1, "P13 predecessor P12 write-ack protocol error");
        if (read_duplicate || read_capacity_full || read_wrap_block || write_wrap_block)
            $fatal(1, "P13 unexpected predecessor wrap/read diagnostics");
        if (next_read_generation === 'x || read_outstanding === 'x
            || read_epoch_outstanding === 'x || next_write_id === 'x
            || write_pending === 1'bx || write_issued === 1'bx
            || retry_pending === 1'bx || duplicate_collapse[0][0] === 1'bx
            || line_resp_tag[0] === 'x || line_resp_addr[0] === 'x)
            $fatal(1, "P13 diagnostic/identity unknown");
        if (protocol_error_count < status_error_count)
            $fatal(1, "P13 combined protocol provenance lost status errors");

        $display("PROD_SEAM_P13_STATUS_PROVENANCE_PRESERVED=PASS");
        $display("PROD_SEAM_P13_BEHAVIOR=PASS");
        $finish;
    end
endmodule
