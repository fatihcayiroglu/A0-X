`timescale 1ns/1ps

module a0_mc_noc_sliced_l2_store_liveness_subsystem_tb;
    localparam integer C = 2;
    localparam integer U = 1;
    localparam integer M = 4;
    localparam integer W = 4;
    localparam integer S = 2;
    localparam integer SETS = 8;
    localparam integer MISSES = 4;
    localparam integer LANES = 4;
    localparam integer CLTW = 3;
    localparam integer NTW = 4;
    localparam integer LAW = 30;

    logic clk;
    logic rst_n;
    always #5 clk = ~clk;

    logic [C-1:0] req_v;
    logic [C-1:0] req_r;
    logic [C-1:0] req_err;
    logic [CLTW-1:0] req_tag [0:C-1];
    logic [LAW-1:0] req_addr [0:C-1];

    logic [C-1:0] resp_v;
    logic [C-1:0] resp_r;
    logic [CLTW-1:0] resp_tag [0:C-1];
    logic [LAW-1:0] resp_addr [0:C-1];
    logic resp_fault [0:C-1];
    logic [31:0] resp_data [0:C-1][0:W-1];

    logic store_v;
    logic [LANES-1:0] store_mask;
    logic [31:0] store_word_addr [0:LANES-1];

    logic [C-1:0] noc_req_err;
    logic [S-1:0] slice_resp_err;
    logic [C-1:0] noc_resp_err;

    logic [S-1:0] mem_req_v;
    logic [S-1:0] mem_req_r;
    logic [NTW-1:0] mem_req_tag [0:S-1];
    logic [LAW-1:0] mem_req_addr [0:S-1];

    logic [S-1:0] mem_resp_v;
    logic [NTW-1:0] mem_resp_tag [0:S-1];
    logic [LAW-1:0] mem_resp_addr [0:S-1];
    logic mem_resp_fault [0:S-1];
    logic [31:0] mem_resp_data [0:S-1][0:W-1];

    logic [7:0] arb_pending;
    logic [2:0] arb_cursor;
    logic arb_found;
    logic [2:0] arb_tag;

    integer response_count;
    integer response_count_c [0:C-1];
    integer backend_count;
    integer backend_count_s [0:S-1];
    logic [NTW-1:0] last_backend_tag_s [0:S-1];
    logic [LAW-1:0] last_backend_addr_s [0:S-1];
    integer retry_inject_count [0:C-1];
    integer i;
    integer j;

    a0_retry_round_robin_arbiter #(
        .TAG_W(3), .SLOT_COUNT(8)
    ) arb_probe (
        .pending_i(arb_pending), .cursor_i(arb_cursor),
        .found_o(arb_found), .tag_o(arb_tag)
    );

    a0_mc_noc_sliced_l2_store_liveness_subsystem #(
        .CLUSTER_COUNT(C), .CUS_PER_CLUSTER(U), .MSHR_COUNT(M),
        .LINE_WORDS(W), .L2_SLICE_COUNT(S),
        .L2_SET_COUNT_PER_SLICE(SETS),
        .L2_MISS_COUNT_PER_SLICE(MISSES), .STORE_LANES(LANES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cluster_local_req_valid_i(req_v),
        .cluster_local_req_ready_o(req_r),
        .cluster_local_req_tag_i(req_tag),
        .cluster_local_req_line_addr_i(req_addr),
        .cluster_local_req_tag_error_o(req_err),
        .cluster_local_resp_valid_o(resp_v),
        .cluster_local_resp_ready_i(resp_r),
        .cluster_local_resp_tag_o(resp_tag),
        .cluster_local_resp_line_addr_o(resp_addr),
        .cluster_local_resp_fault_o(resp_fault),
        .cluster_local_resp_data_o(resp_data),
        .global_store_valid_i(store_v),
        .global_store_lane_mask_i(store_mask),
        .global_store_word_addr_i(store_word_addr),
        .noc_req_tag_error_o(noc_req_err),
        .slice_resp_protocol_error_o(slice_resp_err),
        .noc_resp_tag_error_o(noc_resp_err),
        .line_mem_req_valid_o(mem_req_v),
        .line_mem_req_ready_i(mem_req_r),
        .line_mem_req_network_tag_o(mem_req_tag),
        .line_mem_req_line_addr_o(mem_req_addr),
        .line_mem_resp_valid_i(mem_resp_v),
        .line_mem_resp_network_tag_i(mem_resp_tag),
        .line_mem_resp_line_addr_i(mem_resp_addr),
        .line_mem_resp_fault_i(mem_resp_fault),
        .line_mem_resp_data_i(mem_resp_data)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            response_count <= 0;
            backend_count <= 0;
            response_count_c[0] <= 0;
            response_count_c[1] <= 0;
            retry_inject_count[0] <= 0;
            retry_inject_count[1] <= 0;
            backend_count_s[0] <= 0;
            backend_count_s[1] <= 0;
            last_backend_tag_s[0] <= '0;
            last_backend_tag_s[1] <= '0;
            last_backend_addr_s[0] <= '0;
            last_backend_addr_s[1] <= '0;
        end else begin
            response_count <= response_count
                + integer'(resp_v[0] && resp_r[0])
                + integer'(resp_v[1] && resp_r[1]);
            if (resp_v[0] && resp_r[0]) begin
                response_count_c[0] <= response_count_c[0] + 1;
                if (resp_data[0][0] == 32'hDEAD0000
                    || resp_data[0][0] == 32'hDEAD1000
                    || resp_data[0][0] == 32'hDEAD2000
                    || resp_data[0][0] == 32'hDEAD3000)
                    $fatal(1, "P5 stale data escaped architecturally");
            end
            if (resp_v[1] && resp_r[1]) begin
                response_count_c[1] <= response_count_c[1] + 1;
                if (resp_data[1][0] == 32'hDEAD0000
                    || resp_data[1][0] == 32'hDEAD1000
                    || resp_data[1][0] == 32'hDEAD2000
                    || resp_data[1][0] == 32'hDEAD3000)
                    $fatal(1, "P5 stale data escaped architecturally");
            end
            if (dut.retry_found[0]
                && dut.p3_req_valid[0]
                && dut.p3_req_ready[0])
                retry_inject_count[0] <= retry_inject_count[0] + 1;
            if (dut.retry_found[1]
                && dut.p3_req_valid[1]
                && dut.p3_req_ready[1])
                retry_inject_count[1] <= retry_inject_count[1] + 1;

            backend_count <= backend_count
                + integer'(mem_req_v[0] && mem_req_r[0])
                + integer'(mem_req_v[1] && mem_req_r[1]);
            if (mem_req_v[0] && mem_req_r[0]) begin
                backend_count_s[0] <= backend_count_s[0] + 1;
                last_backend_tag_s[0] <= mem_req_tag[0];
                last_backend_addr_s[0] <= mem_req_addr[0];
            end
            if (mem_req_v[1] && mem_req_r[1]) begin
                backend_count_s[1] <= backend_count_s[1] + 1;
                last_backend_tag_s[1] <= mem_req_tag[1];
                last_backend_addr_s[1] <= mem_req_addr[1];
            end
        end
    end

    task automatic issue_req(
        input logic cluster,
        input logic [CLTW-1:0] tag,
        input logic [LAW-1:0] addr
    );
        integer guard;
        begin
            @(negedge clk);
            req_v[cluster] = 1'b1;
            req_tag[cluster] = tag;
            req_addr[cluster] = addr;
            guard = 0;
            while (guard < 160) begin
                @(posedge clk);
                if (req_r[cluster]) begin
                    @(negedge clk);
                    req_v[cluster] = 1'b0;
                    guard = 1000;
                end else begin
                    guard = guard + 1;
                end
            end
            if (guard != 1000)
                $fatal(1, "P5 cluster request timeout");
        end
    endtask

    task automatic wait_backend_after(
        input integer snapshot,
        input logic [LAW-1:0] wanted_addr,
        output logic slice,
        output logic [NTW-1:0] tag
    );
        integer guard;
        integer sidx;
        logic found;
        begin
            slice = 0;
            tag = '0;
            found = 1'b0;
            guard = 0;
            while (guard < 200 && !found) begin
                @(posedge clk); #1;
                if (backend_count > snapshot) begin
                    for (sidx = 0; sidx < S; sidx = sidx + 1) begin
                        if (backend_count_s[sidx] > 0
                            && last_backend_addr_s[sidx] == wanted_addr) begin
                            slice = 1'(sidx);
                            tag = last_backend_tag_s[sidx];
                            found = 1'b1;
                        end
                    end
                end
                guard = guard + 1;
            end
            if (!found)
                $fatal(1, "P5 backend request timeout addr=%0d", wanted_addr);
        end
    endtask

    task automatic issue_capture(
        input logic cluster,
        input logic [CLTW-1:0] tag_in,
        input logic [LAW-1:0] addr,
        output logic slice,
        output logic [NTW-1:0] tag_out
    );
        integer snap;
        begin
            snap = backend_count;
            issue_req(cluster, tag_in, addr);
            wait_backend_after(snap, addr, slice, tag_out);
        end
    endtask

    task automatic pulse_store_one(input logic [LAW-1:0] addr);
        begin
            @(negedge clk);
            store_v = 1'b1;
            store_mask = '0;
            store_mask[0] = 1'b1;
            store_word_addr[0] = {addr, 2'b00};
            @(posedge clk); #1;
            store_v = 1'b0;
            store_mask = '0;
        end
    endtask

    task automatic pulse_store_two(
        input logic [LAW-1:0] addr0,
        input logic [LAW-1:0] addr1
    );
        begin
            @(negedge clk);
            store_v = 1'b1;
            store_mask = '0;
            store_mask[0] = 1'b1;
            store_mask[1] = 1'b1;
            store_word_addr[0] = {addr0, 2'b00};
            store_word_addr[1] = {addr1, 2'b00};
            @(posedge clk); #1;
            store_v = 1'b0;
            store_mask = '0;
        end
    endtask

    task automatic send_resp(
        input logic slice,
        input logic [NTW-1:0] tag,
        input logic [LAW-1:0] addr,
        input logic fault,
        input logic [31:0] base
    );
        integer w;
        begin
            @(negedge clk);
            mem_resp_v[slice] = 1'b1;
            mem_resp_tag[slice] = tag;
            mem_resp_addr[slice] = addr;
            mem_resp_fault[slice] = fault;
            for (w = 0; w < W; w = w + 1)
                mem_resp_data[slice][w] = base + 32'(w);
            @(posedge clk); #1;
            mem_resp_v[slice] = 1'b0;
        end
    endtask

    task automatic send_two_resp(
        input logic slice0,
        input logic [NTW-1:0] tag0,
        input logic [LAW-1:0] addr0,
        input logic [31:0] base0,
        input logic slice1,
        input logic [NTW-1:0] tag1,
        input logic [LAW-1:0] addr1,
        input logic [31:0] base1
    );
        integer w;
        begin
            if (slice0 == slice1)
                $fatal(1, "P5 two-response helper requires distinct slices");
            @(negedge clk);
            mem_resp_v[slice0] = 1'b1;
            mem_resp_v[slice1] = 1'b1;
            mem_resp_tag[slice0] = tag0;
            mem_resp_tag[slice1] = tag1;
            mem_resp_addr[slice0] = addr0;
            mem_resp_addr[slice1] = addr1;
            mem_resp_fault[slice0] = 1'b0;
            mem_resp_fault[slice1] = 1'b0;
            for (w = 0; w < W; w = w + 1) begin
                mem_resp_data[slice0][w] = base0 + 32'(w);
                mem_resp_data[slice1][w] = base1 + 32'(w);
            end
            @(posedge clk); #1;
            mem_resp_v[slice0] = 1'b0;
            mem_resp_v[slice1] = 1'b0;
        end
    endtask

    task automatic wait_resp(
        input logic cluster,
        input logic [CLTW-1:0] tag,
        input logic [LAW-1:0] addr,
        input logic fault,
        input logic [31:0] data0
    );
        integer guard;
        logic found;
        begin
            guard = 0;
            found = 1'b0;
            while (guard < 200 && !found) begin
                @(posedge clk);
                if (resp_v[cluster] && resp_r[cluster]) begin
                    if (resp_tag[cluster] != tag
                        || resp_addr[cluster] != addr
                        || resp_fault[cluster] != fault
                        || resp_data[cluster][0] != data0)
                        $fatal(1, "P5 architectural response mismatch");
                    #1;
                    found = 1'b1;
                end
                guard = guard + 1;
            end
            if (!found)
                $fatal(1, "P5 architectural response timeout");
        end
    endtask

    initial begin
        logic sl0;
        logic sl1;
        logic sl2;
        integer snap_backend;
        integer snap_response;
        logic [NTW-1:0] net0;
        logic [NTW-1:0] net1;
        logic [NTW-1:0] net2;

        clk = 1'b0;
        rst_n = 1'b0;
        req_v = '0;
        resp_r = '1;
        store_v = 1'b0;
        store_mask = '0;
        mem_req_r = '1;
        mem_resp_v = '0;
        arb_pending = '0;
        arb_cursor = '0;
        for (i = 0; i < C; i = i + 1) begin
            req_tag[i] = '0;
            req_addr[i] = '0;
        end
        for (i = 0; i < LANES; i = i + 1)
            store_word_addr[i] = '0;
        for (i = 0; i < S; i = i + 1) begin
            mem_resp_tag[i] = '0;
            mem_resp_addr[i] = '0;
            mem_resp_fault[i] = 1'b0;
            for (j = 0; j < W; j = j + 1)
                mem_resp_data[i][j] = '0;
        end

        /* Direct proof that the exact arbiter used by P5 wraps and rotates. */
        #1;
        arb_pending = 8'b0000_1101;
        arb_cursor = 3'd2; #1;
        if (!arb_found || arb_tag != 3'd2)
            $fatal(1, "P5 RR cursor did not select tag2");
        arb_cursor = 3'd3; #1;
        if (!arb_found || arb_tag != 3'd3)
            $fatal(1, "P5 RR cursor did not select tag3");
        arb_cursor = 3'd4; #1;
        if (!arb_found || arb_tag != 3'd0)
            $fatal(1, "P5 RR wrap did not select tag0");
        $display("PROD_SEAM_P5_ROUND_ROBIN_FAIRNESS=PASS");

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        /* Repeated same-line conflict: two squashes, then quiescent progress. */
        snap_response = response_count_c[0];
        issue_capture(0, 3'd0, 30'd4, sl0, net0);
        pulse_store_one(30'd4);
        snap_backend = backend_count;
        send_resp(sl0, net0, 30'd4, 1'b0, 32'hDEAD0000);
        wait_backend_after(snap_backend, 30'd4, sl1, net1);
        if (net1 != net0)
            $fatal(1, "P5 first replay requester identity changed");

        /* Retry state owns the tag until its final architectural completion. */
        @(negedge clk);
        req_v[0] = 1'b1;
        req_tag[0] = 3'd0;
        req_addr[0] = 30'd7;
        repeat (3) begin
            @(posedge clk); #1;
            if (req_r[0])
                $fatal(1, "P5 same requester tag aliased retry state");
        end
        @(negedge clk);
        req_v[0] = 1'b0;
        $display("PROD_SEAM_P5_RETRY_CAPACITY_BACKPRESSURE=PASS");

        pulse_store_one(30'd4);
        snap_backend = backend_count;
        send_resp(sl1, net1, 30'd4, 1'b0, 32'hDEAD1000);
        wait_backend_after(snap_backend, 30'd4, sl2, net2);
        if (net2 != net0)
            $fatal(1, "P5 second replay requester identity changed");
        send_resp(sl2, net2, 30'd4, 1'b0, 32'hBEEF0000);
        wait_resp(0, 3'd0, 30'd4, 1'b0, 32'hBEEF0000);
        repeat (8) @(posedge clk);
        if (response_count_c[0] != snap_response + 1)
            $fatal(1, "P5 repeated conflict double-retired");
        $display("PROD_SEAM_P5_REPEATED_CONFLICT_LIVENESS=PASS");
        $display("PROD_SEAM_P5_REQUESTER_IDENTITY_PRESERVED=PASS");
        $display("PROD_SEAM_P5_NO_DOUBLE_RETIRE=PASS");

        /* Multi-cluster, multi-tag, multi-slice conflicting replay. */
        issue_capture(0, 3'd1, 30'd5, sl0, net0);
        issue_capture(1, 3'd2, 30'd2, sl1, net1);
        if (sl0 == sl1)
            $fatal(1, "P5 directed multi-slice addresses did not separate");
        pulse_store_two(30'd5, 30'd2);
        snap_backend = backend_count;
        send_resp(sl0, net0, 30'd5, 1'b0, 32'hDEAD2000);
        wait_backend_after(snap_backend, 30'd5, sl2, net2);
        if (net2 != net0)
            $fatal(1, "P5 cluster0 replay identity changed");
        snap_backend = backend_count;
        send_resp(sl1, net1, 30'd2, 1'b0, 32'hDEAD3000);
        wait_backend_after(snap_backend, 30'd2, sl0, net0);
        if (net0 != net1)
            $fatal(1, "P5 cluster1 replay identity changed");
        if (sl2 == sl0)
            $fatal(1, "P5 replay lost multi-slice placement");
        send_resp(sl2, net2, 30'd5, 1'b0, 32'hCAFE1000);
        wait_resp(0, 3'd1, 30'd5, 1'b0, 32'hCAFE1000);
        send_resp(sl0, net0, 30'd2, 1'b0, 32'hCAFE2000);
        wait_resp(1, 3'd2, 30'd2, 1'b0, 32'hCAFE2000);
        $display("PROD_SEAM_P5_MULTI_CLUSTER_MULTI_SLICE=PASS");

        /* A request launched after store observation must not see old cached data. */
        issue_capture(0, 3'd3, 30'd6, sl0, net0);
        send_resp(sl0, net0, 30'd6, 1'b0, 32'h11110000);
        wait_resp(0, 3'd3, 30'd6, 1'b0, 32'h11110000);
        pulse_store_one(30'd6);
        snap_backend = backend_count;
        snap_response = response_count_c[1];
        issue_req(1, 3'd0, 30'd6);
        wait_backend_after(snap_backend, 30'd6, sl1, net1);
        if (response_count_c[1] != snap_response)
            $fatal(1, "P5 post-store request consumed stale cache hit");
        send_resp(sl1, net1, 30'd6, 1'b0, 32'h22220000);
        wait_resp(1, 3'd0, 30'd6, 1'b0, 32'h22220000);
        $display("PROD_SEAM_P5_POST_STORE_VISIBILITY=PASS");

        /* Fault remains payload provenance, not a stale/retry control encoding. */
        issue_capture(1, 3'd1, 30'd7, sl0, net0);
        pulse_store_one(30'd7);
        snap_backend = backend_count;
        send_resp(sl0, net0, 30'd7, 1'b0, 32'hDEAD0000);
        wait_backend_after(snap_backend, 30'd7, sl1, net1);
        send_resp(sl1, net1, 30'd7, 1'b1, 32'h12340000);
        wait_resp(1, 3'd1, 30'd7, 1'b1, 32'h12340000);
        /* Completion must release retry ownership for legal tag reuse. */
        issue_capture(1, 3'd1, 30'd9, sl2, net2);
        send_resp(sl2, net2, 30'd9, 1'b0, 32'h56780000);
        wait_resp(1, 3'd1, 30'd9, 1'b0, 32'h56780000);
        $display("PROD_SEAM_P5_FAULT_PROVENANCE_DISTINCT=PASS");

        if (|req_err || |noc_req_err || |slice_resp_err || |noc_resp_err)
            $fatal(1, "P5 diagnostic error");
        $display("PROD_SEAM_P5_BEHAVIOR=PASS");
        $finish;
    end
endmodule
