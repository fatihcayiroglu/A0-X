`timescale 1ns/1ps

module a0_backend_write_completion_guard_tb;
    localparam integer CLUSTER_COUNT = 1;
    localparam integer CUS_PER_CLUSTER = 1;
    localparam integer STORE_LANES = 2;
    localparam integer L2_SLICE_COUNT = 1;
    localparam integer LINE_WORDS = 4;
    localparam integer NETWORK_TAG_W = 2;
    localparam integer READ_TRACK_COUNT = 2;
    localparam integer READ_EPOCH_W = 4;
    localparam integer WRITE_ID_W = 2;
    localparam integer WORD_SELECT_W = $clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W = 32 - WORD_SELECT_W;
    localparam integer LINE_PORT_ID_W = 1;
    localparam integer BASE_READ_TAG_W = LINE_PORT_ID_W + NETWORK_TAG_W;
    localparam integer EXT_READ_ID_W = BASE_READ_TAG_W + READ_EPOCH_W;
    localparam integer READ_OCC_W = 2;

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

    logic issue_v;
    logic issue_r;
    logic issue_write;
    logic [EXT_READ_ID_W-1:0] issue_read_id;
    logic [WRITE_ID_W-1:0] issue_write_id;
    logic [31:0] issue_word_addr;
    logic [31:0] issue_wdata;
    logic [LINE_ADDR_W-1:0] issue_line_addr;

    logic read_resp_v;
    logic [EXT_READ_ID_W-1:0] read_resp_id;
    logic [LINE_ADDR_W-1:0] read_resp_line_addr;
    logic read_resp_fault;
    logic [31:0] read_resp_data [0:LINE_WORDS-1];
    logic read_reuse_safe;
    logic write_ack_v;
    logic [WRITE_ID_W-1:0] write_ack_id;
    logic write_reuse_safe;

    logic [31:0] memory [0:255];
    integer commit_accept_count;
    integer line_accept_count;
    integer line_resp_count;
    integer write_issue_count;
    integer read_issue_count;
    integer protocol_error_count;
    integer write_ack_error_count;
    logic [WRITE_ID_W-1:0] write_id_seen [0:15];
    logic [31:0] write_addr_seen [0:15];
    logic [31:0] write_data_seen [0:15];
    logic [EXT_READ_ID_W-1:0] last_read_id;
    logic [LINE_ADDR_W-1:0] last_read_line;
    logic [NETWORK_TAG_W-1:0] last_resp_tag;
    logic [LINE_ADDR_W-1:0] last_resp_addr;
    logic last_resp_fault;
    logic [31:0] last_resp_data [0:LINE_WORDS-1];

    a0_production_store_backend_completion_seam #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .STORE_LANES(STORE_LANES),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .READ_TRACK_COUNT(READ_TRACK_COUNT),
        .READ_EPOCH_W(READ_EPOCH_W),
        .WRITE_ID_W(WRITE_ID_W)
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
        .backend_issue_valid_o(issue_v),
        .backend_issue_ready_i(issue_r),
        .backend_issue_write_o(issue_write),
        .backend_issue_read_id_o(issue_read_id),
        .backend_issue_write_id_o(issue_write_id),
        .backend_issue_word_addr_o(issue_word_addr),
        .backend_issue_wdata_o(issue_wdata),
        .backend_issue_line_addr_o(issue_line_addr),
        .backend_read_resp_valid_i(read_resp_v),
        .backend_read_resp_id_i(read_resp_id),
        .backend_read_resp_line_addr_i(read_resp_line_addr),
        .backend_read_resp_fault_i(read_resp_fault),
        .backend_read_resp_data_i(read_resp_data),
        .backend_read_epoch_reuse_safe_i(read_reuse_safe),
        .backend_write_ack_valid_i(write_ack_v),
        .backend_write_ack_id_i(write_ack_id),
        .backend_write_reuse_safe_i(write_reuse_safe)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            commit_accept_count <= 0;
            line_accept_count <= 0;
            line_resp_count <= 0;
            write_issue_count <= 0;
            read_issue_count <= 0;
            protocol_error_count <= 0;
            write_ack_error_count <= 0;
            last_read_id <= '0;
            last_read_line <= '0;
            last_resp_tag <= '0;
            last_resp_addr <= '0;
            last_resp_fault <= 1'b0;
            for (integer i = 0; i < 16; i = i + 1) begin
                write_id_seen[i] <= '0;
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
            if (protocol_error)
                protocol_error_count <= protocol_error_count + 1;
            if (write_ack_error)
                write_ack_error_count <= write_ack_error_count + 1;

            if (issue_v && issue_r) begin
                if (issue_write) begin
                    if (write_issue_count >= 16)
                        $fatal(1, "P12 write issue capture overflow");
                    write_id_seen[write_issue_count] <= issue_write_id;
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
                last_resp_tag <= line_resp_tag[0];
                last_resp_addr <= line_resp_addr[0];
                last_resp_fault <= line_resp_fault[0];
                for (integer w = 0; w < LINE_WORDS; w = w + 1)
                    last_resp_data[w] <= line_resp_data[0][w];
            end
        end
    end

    task automatic start_commit(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(negedge clk);
            commit_addr[0][0][0] = addr;
            commit_wdata[0][0][0] = data;
            commit_addr[0][0][1] = addr + 32'd1;
            commit_wdata[0][0][1] = 32'h0;
            commit_mask[0][0] = 2'b01;
            commit_valid[0][0] = 1'b1;
        end
    endtask

    task automatic finish_commit(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 120 && commit_accept_count < target) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (commit_accept_count != target)
                $fatal(1, "P12 commit completion timeout");
            commit_valid[0][0] = 1'b0;
            commit_mask[0][0] = '0;
        end
    endtask

    task automatic wait_write_issue(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 120 && write_issue_count < target) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (write_issue_count != target)
                $fatal(1, "P12 write issue timeout");
        end
    endtask

    task automatic pulse_ack(input logic [WRITE_ID_W-1:0] id, input logic make_visible);
        integer idx;
        begin
            idx = write_issue_count - 1;
            @(negedge clk);
            if (make_visible && idx >= 0)
                memory[write_addr_seen[idx][7:0]] = write_data_seen[idx];
            write_ack_id = id;
            write_ack_v = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            write_ack_v = 1'b0;
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
            while (guard < 100 && line_accept_count == before_count) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (line_accept_count != before_count + 1)
                $fatal(1, "P12 line acceptance timeout");
            @(negedge clk);
            line_req_v[0] = 1'b0;
        end
    endtask

    task automatic wait_read_issue(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 120 && read_issue_count < target) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (read_issue_count != target)
                $fatal(1, "P12 read issue timeout");
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
        logic [31:0] held_addr;
        logic [31:0] held_data;
        logic [WRITE_ID_W-1:0] held_id;
        integer err_before;
        integer issue_before;
        integer resp_before;
        integer commit_target;

        clk = 1'b0;
        rst_n = 1'b0;
        issue_r = 1'b0;
        read_resp_v = 1'b0;
        read_resp_id = '0;
        read_resp_line_addr = '0;
        read_resp_fault = 1'b0;
        read_reuse_safe = 1'b0;
        write_ack_v = 1'b0;
        write_ack_id = '0;
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
            memory[m] = 32'hd000_0000 + 32'(m);

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;

        /* First write: issue stalls, then issue occurs but visibility waits ACK. */
        start_commit(32'h20, 32'haaaa_0020);
        repeat (30) begin
            @(posedge clk); #1;
            if (issue_v && issue_write) break;
        end
        if (!(issue_v && issue_write))
            $fatal(1, "P12 write never reached issue boundary");
        held_addr = issue_word_addr;
        held_data = issue_wdata;
        held_id = issue_write_id;
        repeat (3) begin
            @(posedge clk); #1;
            if (!issue_v || !issue_write || issue_word_addr != held_addr
                || issue_wdata != held_data || issue_write_id != held_id)
                $fatal(1, "P12 write issue payload changed under backpressure");
            if (commit_ready[0][0] || write_issued)
                $fatal(1, "P12 predecessor released before external issue");
        end
        $display("PROD_SEAM_P12_WRITE_ISSUE_BACKPRESSURE=PASS");

        @(negedge clk); issue_r = 1'b1;
        wait_write_issue(1);
        if (write_id_seen[0] != WRITE_ID_W'(0) || !write_issued
            || commit_ready[0][0] || commit_accept_count != 0)
            $fatal(1, "P12 write issue incorrectly released visibility");
        $display("PROD_SEAM_P12_DELAYED_VISIBILITY_RELEASE=PASS");

        err_before = protocol_error_count;
        pulse_ack(WRITE_ID_W'(1), 1'b0);
        if (protocol_error_count != err_before + 1 || !write_issued
            || commit_accept_count != 0)
            $fatal(1, "P12 wrong ACK was not rejected");
        $display("PROD_SEAM_P12_UNKNOWN_ACK_REJECT=PASS");

        issue_line(NETWORK_TAG_W'(1), LINE_ADDR_W'(32'h20 >> WORD_SELECT_W));
        repeat (8) @(posedge clk); #1;
        if (read_issue_count != 0)
            $fatal(1, "P12 conflicting refill escaped before write completion");
        $display("PROD_SEAM_P12_CONFLICTING_REFILL_HELD_UNTIL_ACK=PASS");

        pulse_ack(write_id_seen[0], 1'b1);
        finish_commit(1);
        if (write_issued || write_pending)
            $fatal(1, "P12 exact ACK did not drain write state");
        $display("PROD_SEAM_P12_EXACT_ACK_RELEASE=PASS");

        wait_read_issue(1);
        resp_before = line_resp_count;
        respond_read(1'b0);
        if (line_resp_count != resp_before + 1 || last_resp_tag != NETWORK_TAG_W'(1)
            || last_resp_addr != LINE_ADDR_W'(32'h20 >> WORD_SELECT_W)
            || last_resp_fault || last_resp_data[0] != 32'haaaa_0020)
            $fatal(1, "P12 post-completion refill visibility mismatch");
        $display("PROD_SEAM_P12_POST_COMPLETION_REFILL_VISIBLE=PASS");

        err_before = protocol_error_count;
        pulse_ack(write_id_seen[0], 1'b0);
        if (protocol_error_count != err_before + 1)
            $fatal(1, "P12 duplicate ACK was not rejected");
        $display("PROD_SEAM_P12_DUPLICATE_ACK_REJECT=PASS");

        /* Consume IDs 1,2,3. Each completion is exact; ID 3 activates wrap block. */
        commit_target = 2;
        for (integer n = 1; n <= 3; n = n + 1) begin
            start_commit(32'(8'h30 + n), 32'hb000_0000 + 32'(n));
            wait_write_issue(n + 1);
            if (write_id_seen[n] != WRITE_ID_W'(n))
                $fatal(1, "P12 write ID sequence mismatch");
            pulse_ack(write_id_seen[n], 1'b1);
            finish_commit(commit_target);
            commit_target = commit_target + 1;
        end
        if (!write_wrap_block || next_write_id != '0)
            $fatal(1, "P12 write ID wrap did not block reuse");
        $display("PROD_SEAM_P12_WRITE_ID_SEQUENCE=PASS");
        $display("PROD_SEAM_P12_WRITE_ID_WRAP_BLOCK=PASS");

        issue_before = write_issue_count;
        start_commit(32'h40, 32'hcccc_0040);
        repeat (8) @(posedge clk); #1;
        if (write_issue_count != issue_before || !write_wrap_block)
            $fatal(1, "P12 wrap block allowed new write issue");

        err_before = protocol_error_count;
        pulse_ack(WRITE_ID_W'(0), 1'b0);
        if (protocol_error_count != err_before + 1
            || commit_accept_count != commit_target - 1)
            $fatal(1, "P12 stale ACK during wrap released predecessor");
        $display("PROD_SEAM_P12_STALE_ACK_DURING_WRAP_REJECT=PASS");

        @(negedge clk); write_reuse_safe = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); write_reuse_safe = 1'b0;
        wait_write_issue(issue_before + 1);
        if (write_id_seen[issue_before] != WRITE_ID_W'(0) || write_wrap_block)
            $fatal(1, "P12 safe reuse did not release ID zero");
        pulse_ack(write_id_seen[issue_before], 1'b1);
        finish_commit(commit_target);
        $display("PROD_SEAM_P12_EXPLICIT_SAFE_REUSE_RELEASE=PASS");

        /* Independent read still preserves P10 identity and backend fault provenance. */
        issue_line(NETWORK_TAG_W'(2), LINE_ADDR_W'(32'h50 >> WORD_SELECT_W));
        wait_read_issue(2);
        resp_before = line_resp_count;
        respond_read(1'b1);
        if (line_resp_count != resp_before + 1 || last_resp_tag != NETWORK_TAG_W'(2)
            || last_resp_addr != LINE_ADDR_W'(32'h50 >> WORD_SELECT_W)
            || !last_resp_fault)
            $fatal(1, "P12 read identity/fault path changed");
        $display("PROD_SEAM_P12_READ_PATH_PRESERVED=PASS");

        if (duplicate_collapse[0][0] || read_duplicate || read_capacity_full
            || read_wrap_block || read_outstanding != '0 || read_epoch_outstanding != '0
            || write_pending || write_issued || write_ack_error)
            $fatal(1, "P12 final bounded state not clean");
        if (next_read_generation != READ_EPOCH_W'(2))
            $fatal(1, "P12 read generation accounting mismatch");
        $display("PROD_SEAM_P12_BEHAVIOR=PASS");
        $finish;
    end
endmodule
