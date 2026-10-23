`timescale 1ns/1ps

module a0_store_read_resource_order_guard_tb;
    localparam integer CLIENT_COUNT = 2;
    localparam integer LOCAL_TAG_W = 2;
    localparam integer CLIENT_MAX_OUTSTANDING = 2;
    localparam integer COMMIT_PORT_COUNT = 2;
    localparam integer STORE_LANES = 2;
    localparam integer LINE_WORDS = 2;
    localparam integer SET_COUNT_PER_SLICE = 2;
    localparam integer SLICE_COUNT = 2;
    localparam integer LINE_ADDR_W = 31;
    localparam integer TAG_COUNT = 1 << LOCAL_TAG_W;

    logic clk;
    logic rst_n;
    logic [CLIENT_COUNT-1:0] client_req_valid, core_client_req_ready;
    logic [LOCAL_TAG_W-1:0] client_req_local_tag [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0] client_req_line_addr [0:CLIENT_COUNT-1];
    logic [CLIENT_COUNT-1:0] client_resp_valid;
    logic [LOCAL_TAG_W-1:0] client_resp_local_tag [0:CLIENT_COUNT-1];
    logic [LINE_ADDR_W-1:0] client_resp_line_addr [0:CLIENT_COUNT-1];
    logic [COMMIT_PORT_COUNT-1:0] commit_valid;
    logic [STORE_LANES-1:0] commit_lane_mask [0:COMMIT_PORT_COUNT-1];
    logic [31:0] commit_word_addr [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic [CLIENT_COUNT-1:0] core_client_req_valid, client_req_ready;
    logic [COMMIT_PORT_COUNT-1:0] core_commit_valid, commit_wait;
    logic [CLIENT_COUNT-1:0] request_conflict;
    logic protocol_error;

    // The public-interface reference ledger is indexed by requester/tag, not
    // by the DUT's private allocation slots. Only actual handshakes create work.
    logic expected_live [0:CLIENT_COUNT-1][0:TAG_COUNT-1];
    logic [LINE_ADDR_W-1:0] expected_line [0:CLIENT_COUNT-1][0:TAG_COUNT-1];
    integer accepted [0:CLIENT_COUNT-1];
    integer returned [0:CLIENT_COUNT-1];
    integer inflight [0:CLIENT_COUNT-1];
    integer bad_responses;
    integer lifetime_accepted;
    integer lifetime_returned;
    integer lifetime_bad_responses;
    integer checks;
    integer scenarios;

    a0_store_read_resource_order_guard #(
        .CLIENT_COUNT(CLIENT_COUNT), .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),
        .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT), .STORE_LANES(STORE_LANES),
        .LINE_WORDS(LINE_WORDS), .SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE),
        .SLICE_COUNT(SLICE_COUNT), .LINE_ADDR_W(LINE_ADDR_W), .SLICE_HASH_SHIFT(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .client_req_valid_i(client_req_valid),
        .client_req_local_tag_i(client_req_local_tag),
        .client_req_line_addr_i(client_req_line_addr),
        .core_client_req_ready_i(core_client_req_ready),
        .client_resp_valid_i(client_resp_valid),
        .client_resp_local_tag_i(client_resp_local_tag),
        .client_resp_line_addr_i(client_resp_line_addr),
        .commit_valid_i(commit_valid), .commit_lane_mask_i(commit_lane_mask),
        .commit_word_addr_i(commit_word_addr),
        .core_client_req_valid_o(core_client_req_valid),
        .client_req_ready_o(client_req_ready), .core_commit_valid_o(core_commit_valid),
        .request_conflict_o(request_conflict), .commit_wait_o(commit_wait),
        .protocol_error_o(protocol_error)
    );

    always #5 clk = !clk;
    initial begin
        #20000;
        $fatal(1, "P32_ORDER_GUARD_WATCHDOG");
    end

    // This fixed configuration has four cache resources. Line addresses
    // 0/4, 1/5, 2/6 and 3/7 are aliases; each pair has one home and one set.
    function automatic integer resource_id(input logic [LINE_ADDR_W-1:0] addr);
        resource_id = (((integer'(addr) % 2) ^ ((integer'(addr) / 2) % 2)) * 2)
            + (integer'(addr) % 2);
    endfunction

    task automatic check(input logic condition, input string label_text);
        if (!condition) $fatal(1, "P32_ORDER_GUARD_CHECK %s", label_text);
        checks = checks + 1;
    endtask

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_drives;
        client_req_valid = '0;
        client_resp_valid = '0;
        core_client_req_ready = '1;
        commit_valid = '0;
        for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
            client_req_local_tag[c] = '0;
            client_req_line_addr[c] = '0;
            client_resp_local_tag[c] = '0;
            client_resp_line_addr[c] = '0;
        end
        for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
            commit_lane_mask[p] = '0;
            for (integer lane = 0; lane < STORE_LANES; lane = lane + 1)
                commit_word_addr[p][lane] = '0;
        end
    endtask

    task automatic request(
        input integer client_id,
        input logic [LOCAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        if (client_id < 0 || client_id >= CLIENT_COUNT)
            $fatal(1, "P32_GUARD_REQUEST_CLIENT_RANGE client=%0d", client_id);
        client_req_valid[client_id] = 1'b1;
        client_req_local_tag[client_id] = tag;
        client_req_line_addr[client_id] = line_addr;
    endtask

    task automatic respond(
        input integer client_id,
        input logic [LOCAL_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        if (client_id < 0 || client_id >= CLIENT_COUNT)
            $fatal(1, "P32_GUARD_RESPONSE_CLIENT_RANGE client=%0d", client_id);
        client_resp_valid[client_id] = 1'b1;
        client_resp_local_tag[client_id] = tag;
        client_resp_line_addr[client_id] = line_addr;
    endtask

    task automatic commit_zero_resource;
        commit_valid[0] = 1'b1;
        commit_lane_mask[0] = 2'b01;
        commit_word_addr[0][0] = 32'd0;
    endtask

    always @(posedge clk) begin
        integer edge_accepts;
        integer edge_returns;
        integer edge_bad_responses;
        edge_accepts = 0;
        edge_returns = 0;
        edge_bad_responses = 0;
        if (!rst_n) begin
            bad_responses <= 0;
            for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
                accepted[c] <= 0;
                returned[c] <= 0;
                inflight[c] <= 0;
                for (integer tag = 0; tag < TAG_COUNT; tag = tag + 1) begin
                    expected_live[c][tag] <= 1'b0;
                    expected_line[c][tag] <= '0;
                end
            end
        end else begin
            // Check commit eligibility against the old ledger before retiring
            // this edge's responses. This is the ordering boundary under test.
            for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
                if (core_commit_valid[p]) begin
                    if (!commit_valid[p]) $fatal(1, "P32_GUARD_GHOST_COMMIT");
                    for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
                        for (integer tag = 0; tag < TAG_COUNT; tag = tag + 1) begin
                            for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                                if (expected_live[c][tag] && commit_lane_mask[p][lane]
                                    && resource_id(expected_line[c][tag])
                                        == resource_id(LINE_ADDR_W'(commit_word_addr[p][lane] >> 1)))
                                    $fatal(1, "P32_GUARD_COMMIT_PASSED_OLD_READ p=%0d c=%0d tag=%0d", p, c, tag);
                            end
                        end
                    end
                end
            end
            for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
                logic exact_retire;
                integer next_inflight;
                exact_retire = client_resp_valid[c]
                    && expected_live[c][integer'(client_resp_local_tag[c])]
                    && expected_line[c][integer'(client_resp_local_tag[c])]
                        == client_resp_line_addr[c];
                next_inflight = inflight[c];
                if ((client_req_valid[c] && client_req_ready[c])
                    != (core_client_req_valid[c] && core_client_req_ready[c]))
                    $fatal(1, "P32_GUARD_HANDSHAKE_DISAGREEMENT c=%0d", c);
                if (core_client_req_valid[c] && !client_req_valid[c])
                    $fatal(1, "P32_GUARD_GHOST_READ c=%0d", c);
                if (client_resp_valid[c]) begin
                    if (exact_retire) begin
                        expected_live[c][integer'(client_resp_local_tag[c])] <= 1'b0;
                        returned[c] <= returned[c] + 1;
                        next_inflight = next_inflight - 1;
                        edge_returns = edge_returns + 1;
                    end else begin
                        edge_bad_responses = edge_bad_responses + 1;
                    end
                end
                if (client_req_valid[c] && client_req_ready[c]) begin
                    if (expected_live[c][integer'(client_req_local_tag[c])]
                        && !(exact_retire && client_req_local_tag[c] == client_resp_local_tag[c]))
                        $fatal(1, "P32_GUARD_DUPLICATE_LIVE_TAG c=%0d tag=%0d", c, client_req_local_tag[c]);
                    for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
                        for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                            if (commit_valid[p] && commit_lane_mask[p][lane]
                                && resource_id(client_req_line_addr[c])
                                    == resource_id(LINE_ADDR_W'(commit_word_addr[p][lane] >> 1)))
                                $fatal(1, "P32_GUARD_CONFLICTING_READ_ACCEPTED c=%0d p=%0d lane=%0d", c, p, lane);
                        end
                    end
                    // Allocation follows retirement so same-edge exact tag
                    // reuse leaves the new transaction live after NBA updates.
                    expected_live[c][integer'(client_req_local_tag[c])] <= 1'b1;
                    expected_line[c][integer'(client_req_local_tag[c])] <= client_req_line_addr[c];
                    accepted[c] <= accepted[c] + 1;
                    next_inflight = next_inflight + 1;
                    edge_accepts = edge_accepts + 1;
                end
                if (next_inflight < 0 || next_inflight > CLIENT_MAX_OUTSTANDING)
                    $fatal(1, "P32_GUARD_REFERENCE_CAPACITY c=%0d inflight=%0d", c, next_inflight);
                inflight[c] <= next_inflight;
            end
            bad_responses <= bad_responses + edge_bad_responses;
            lifetime_accepted <= lifetime_accepted + edge_accepts;
            lifetime_returned <= lifetime_returned + edge_returns;
            lifetime_bad_responses <= lifetime_bad_responses + edge_bad_responses;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        lifetime_accepted = 0;
        lifetime_returned = 0;
        lifetime_bad_responses = 0;
        checks = 0;
        scenarios = 0;
        clear_drives();
        repeat (2) tick();
        @(negedge clk);
        rst_n = 1'b1;
        tick();
        check(!protocol_error, "reset clears sticky diagnostic");

        // A request offered while the core is not ready creates no ledger entry.
        @(negedge clk);
        clear_drives();
        core_client_req_ready[0] = 1'b0;
        request(0, 2'd0, 31'd0);
        #1;
        check(core_client_req_valid[0] && !client_req_ready[0], "ready-low offer stays unaccepted");
        tick();
        check(accepted[0] == 0 && inflight[0] == 0, "ready-low creates no reference transaction");
        @(negedge clk);
        clear_drives();
        commit_zero_resource();
        core_client_req_ready[0] = 1'b0;
        request(0, 2'd0, 31'd2);
        #1;
        check(core_commit_valid[0] && !commit_wait[0], "unaccepted offer cannot fence a commit");
        check(!request_conflict[0] && core_client_req_valid[0],
            "different home remains eligible even with the same local set");
        tick();
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_READY_ZERO_PASS");

        // Resource 0 is held by an old READ. Alias line 4 must wait, while line
        // 3 (same home, other set) may be accepted on the other client.
        @(negedge clk);
        clear_drives();
        request(0, 2'd0, 31'd0);
        #1;
        check(client_req_ready[0], "old READ admission");
        tick();
        @(negedge clk);
        clear_drives();
        commit_zero_resource();
        #1;
        check(commit_wait[0] && !core_commit_valid[0], "old READ blocks conflicting commit");
        tick();
        @(negedge clk);
        request(0, 2'd1, 31'd4);
        request(1, 2'd0, 31'd3);
        #1;
        check(request_conflict == 2'b01, "alias blocked and unrelated set eligible");
        check(!client_req_ready[0] && client_req_ready[1], "independent client handshake remains possible");
        tick();
        check(accepted[0] == 1 && accepted[1] == 1, "only unrelated READ was added");
        @(negedge clk);
        client_req_valid = '0;
        respond(0, 2'd0, 31'd0);
        #1;
        check(commit_wait[0] && !core_commit_valid[0], "response cycle cannot optimistically unmask commit");
        tick();
        check(!commit_wait[0] && core_commit_valid[0], "registered response retirement releases commit");
        @(negedge clk);
        clear_drives();
        respond(1, 2'd0, 31'd3);
        tick();
        check(returned[0] == 1 && returned[1] == 1 && inflight[0] == 0 && inflight[1] == 0,
            "exact old and unrelated READs drained");
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_OLD_READ_ALIAS_REGISTERED_RETIRE_PASS");

        // Both raw commit ports reserve every enabled lane. Disabled lanes
        // deliberately name the resources used by eligible requests.
        @(negedge clk);
        clear_drives();
        commit_valid = 2'b11;
        commit_lane_mask[0] = 2'b01;
        commit_word_addr[0][0] = 32'd0;
        commit_word_addr[0][1] = 32'd2;
        commit_lane_mask[1] = 2'b10;
        commit_word_addr[1][0] = 32'd6;
        commit_word_addr[1][1] = 32'd4;
        request(0, 2'd1, 31'd2);
        request(1, 2'd1, 31'd1);
        #1;
        check(core_commit_valid == 2'b11 && commit_wait == '0, "both pending ports initially eligible");
        check(request_conflict == 2'b01 && !client_req_ready[0] && client_req_ready[1],
            "port 1 lane 1 reserves; disabled port 0 lane does not");
        tick();
        @(negedge clk);
        client_req_valid = '0;
        respond(1, 2'd1, 31'd1);
        request(0, 2'd1, 31'd0);
        request(1, 2'd2, 31'd3);
        #1;
        check(request_conflict == 2'b01 && !client_req_ready[0] && client_req_ready[1],
            "port 0 lane 0 reserves; disabled port 1 lane does not");
        tick();
        @(negedge clk);
        clear_drives();
        respond(1, 2'd2, 31'd3);
        tick();
        check(accepted[0] == 1 && accepted[1] == 3 && returned[1] == 3,
            "enabled and disabled lane outcomes counted exactly");
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_ALL_RAW_PORTS_LANES_PASS");

        @(negedge clk);
        clear_drives();
        request(0, 2'd2, 31'd0);
        request(1, 2'd2, 31'd2);
        #1;
        check(client_req_ready == 2'b11, "same local tag on distinct clients is independent");
        tick();
        check(inflight[0] == 1 && inflight[1] == 1, "both same-tag transactions are live");
        @(negedge clk);
        clear_drives();
        respond(0, 2'd2, 31'd0);
        tick();
        check(inflight[0] == 0 && inflight[1] == 1, "client 0 response cannot retire client 1 tag");
        @(negedge clk);
        clear_drives();
        respond(1, 2'd2, 31'd2);
        tick();
        check(inflight[1] == 0 && returned[1] == 4, "client 1 exact response retires separately");
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_CLIENT_TAG_ISOLATION_PASS");

        @(negedge clk);
        clear_drives();
        request(0, 2'd0, 31'd0);
        tick();
        @(negedge clk);
        clear_drives();
        request(0, 2'd0, 31'd1);
        #1;
        check(!core_client_req_valid[0] && !client_req_ready[0], "busy tag cannot acquire another line");
        tick();
        check(accepted[0] == 3, "busy tag offer creates no transaction");
        @(negedge clk);
        clear_drives();
        request(0, 2'd1, 31'd1);
        #1;
        check(client_req_ready[0], "second independent tag fills second slot");
        tick();
        @(negedge clk);
        clear_drives();
        request(0, 2'd2, 31'd2);
        #1;
        check(!core_client_req_valid[0] && !client_req_ready[0], "full ledger blocks third tag");
        tick();
        check(accepted[0] == 4 && inflight[0] == 2, "capacity accounting excludes rejected offers");
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_BUSY_TAG_CAPACITY_PASS");

        @(negedge clk);
        clear_drives();
        respond(0, 2'd0, 31'd0);
        request(0, 2'd0, 31'd4);
        #1;
        check(core_client_req_valid[0] && client_req_ready[0], "full ledger allows exact same-edge retirement and tag reuse");
        tick();
        check(accepted[0] == 5 && returned[0] == 3 && inflight[0] == 2,
            "reuse adds and retires exactly once with occupancy unchanged");
        @(negedge clk);
        clear_drives();
        request(0, 2'd2, 31'd2);
        #1;
        check(!client_req_ready[0], "reused slot remains occupied");
        tick();
        @(negedge clk);
        clear_drives();
        respond(0, 2'd0, 31'd4);
        tick();
        check(inflight[0] == 1 && returned[0] == 4, "reused tag has its new exact line");
        @(negedge clk);
        clear_drives();
        respond(0, 2'd1, 31'd1);
        tick();
        check(accepted[0] == 5 && returned[0] == 5 && accepted[1] == 4 && returned[1] == 4
            && inflight[0] == 0 && inflight[1] == 0 && bad_responses == 0 && !protocol_error,
            "normal history drains with nine exact admissions and nine exact responses");
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_SAME_EDGE_SLOT_TAG_REUSE_PASS");

        // Diagnostic behavior is a final independent cold-reset case, after
        // the legal history has drained. Wrong identities must not free work.
        @(negedge clk);
        clear_drives();
        rst_n = 1'b0;
        repeat (2) tick();
        @(negedge clk);
        rst_n = 1'b1;
        tick();
        check(!protocol_error && accepted[0] == 0 && returned[0] == 0,
            "diagnostic case starts from separate cold reset");
        @(negedge clk);
        clear_drives();
        request(0, 2'd0, 31'd0);
        tick();
        @(negedge clk);
        clear_drives();
        commit_zero_resource();
        respond(0, 2'd0, 31'd4);
        #1;
        check(!protocol_error && commit_wait[0], "wrong line has no combinational diagnostic feedback or retirement");
        tick();
        check(protocol_error && commit_wait[0] && inflight[0] == 1 && returned[0] == 0 && bad_responses == 1,
            "wrong exact line latches error without freeing original READ");
        @(negedge clk);
        client_resp_valid = '0;
        respond(0, 2'd3, 31'd0);
        tick();
        check(protocol_error && commit_wait[0] && inflight[0] == 1 && bad_responses == 2,
            "unsolicited tag cannot free the original READ");
        @(negedge clk);
        client_resp_valid = '0;
        request(0, 2'd1, 31'd3);
        request(1, 2'd1, 31'd1);
        #1;
        check(core_client_req_valid == '0 && client_req_ready == '0 && core_commit_valid == '0,
            "sticky error closes new request and commit admission");
        tick();
        check(accepted[0] == 1 && accepted[1] == 0 && commit_wait[0], "error-state offers allocate nothing");
        @(negedge clk);
        client_req_valid = '0;
        respond(0, 2'd0, 31'd0);
        #1;
        check(commit_wait[0], "exact recovery response still obeys registered retirement boundary");
        tick();
        check(protocol_error && !commit_wait[0] && core_commit_valid == '0
            && returned[0] == 1 && inflight[0] == 0,
            "real response can drain retained work but cannot clear sticky error");
        scenarios = scenarios + 1;
        $display("P32_ORDER_GUARD_INVALID_RESPONSE_STICKY_PASS");
        check(scenarios == 7 && lifetime_accepted == 10 && lifetime_returned == 10
            && lifetime_bad_responses == 2,
            "all scenario and lifetime event totals match");
        $display("P32_ORDER_GUARD_PASS scenarios=%0d checks=%0d accepts=%0d responses=%0d rejected_responses=%0d",
            scenarios, checks, lifetime_accepted, lifetime_returned, lifetime_bad_responses);
        $finish;
    end
endmodule
