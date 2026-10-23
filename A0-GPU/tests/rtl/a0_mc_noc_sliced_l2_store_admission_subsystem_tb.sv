`timescale 1ns/1ps

module a0_mc_noc_sliced_l2_store_admission_subsystem_tb;
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

    integer backend_total;
    integer backend_line4;
    integer backend_line6;
    integer backend_line7;
    integer backend_line12;
    integer resp_count_c0;
    integer resp_count_c1;
    logic [NTW-1:0] last_tag_line4;
    logic [NTW-1:0] last_tag_line6;
    logic [NTW-1:0] last_tag_line7;
    logic [NTW-1:0] last_tag_line12;
    logic last_slice_line4;
    logic last_slice_line6;
    logic last_slice_line7;
    logic last_slice_line12;
    integer i;
    integer j;

    a0_mc_noc_sliced_l2_store_admission_subsystem #(
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
            backend_total <= 0;
            backend_line4 <= 0;
            backend_line6 <= 0;
            backend_line7 <= 0;
            backend_line12 <= 0;
            resp_count_c0 <= 0;
            resp_count_c1 <= 0;
            last_tag_line4 <= '0;
            last_tag_line6 <= '0;
            last_tag_line7 <= '0;
            last_tag_line12 <= '0;
            last_slice_line4 <= 1'b0;
            last_slice_line6 <= 1'b0;
            last_slice_line7 <= 1'b0;
            last_slice_line12 <= 1'b0;
        end else begin
            if (resp_v[0] && resp_r[0]) resp_count_c0 <= resp_count_c0 + 1;
            if (resp_v[1] && resp_r[1]) resp_count_c1 <= resp_count_c1 + 1;
            for (integer s = 0; s < S; s = s + 1) begin
                if (mem_req_v[s] && mem_req_r[s]) begin
                    backend_total <= backend_total + 1;
                    case (mem_req_addr[s])
                        30'd4: begin
                            backend_line4 <= backend_line4 + 1;
                            last_tag_line4 <= mem_req_tag[s];
                            last_slice_line4 <= 1'(s);
                        end
                        30'd6: begin
                            backend_line6 <= backend_line6 + 1;
                            last_tag_line6 <= mem_req_tag[s];
                            last_slice_line6 <= 1'(s);
                        end
                        30'd7: begin
                            backend_line7 <= backend_line7 + 1;
                            last_tag_line7 <= mem_req_tag[s];
                            last_slice_line7 <= 1'(s);
                        end
                        30'd12: begin
                            backend_line12 <= backend_line12 + 1;
                            last_tag_line12 <= mem_req_tag[s];
                            last_slice_line12 <= 1'(s);
                        end
                        default: begin end
                    endcase
                end
            end
        end
    end

    task automatic hold_store(input logic [LAW-1:0] addr);
        begin
            @(negedge clk);
            store_v = 1'b1;
            store_mask = '0;
            store_mask[0] = 1'b1;
            store_word_addr[0] = {addr, 2'b00};
        end
    endtask

    task automatic release_store;
        begin
            @(negedge clk);
            store_v = 1'b0;
            store_mask = '0;
        end
    endtask

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
                end else guard = guard + 1;
            end
            if (guard != 1000) $fatal(1, "P6 request timeout");
        end
    endtask

    task automatic wait_line_count(input integer which, input integer target);
        integer guard;
        integer cur;
        begin
            guard = 0;
            cur = 0;
            while (guard < 220 && cur < target) begin
                @(posedge clk); #1;
                case (which)
                    4: cur = backend_line4;
                    6: cur = backend_line6;
                    7: cur = backend_line7;
                    12: cur = backend_line12;
                    default: cur = -1;
                endcase
                guard = guard + 1;
            end
            if (cur < target) $fatal(1, "P6 backend line %0d timeout target=%0d got=%0d", which, target, cur);
        end
    endtask

    task automatic send_resp(
        input logic slice,
        input logic [NTW-1:0] tag,
        input logic [LAW-1:0] addr,
        input logic fault,
        input logic [31:0] base
    );
        begin
            @(negedge clk);
            mem_resp_v[slice] = 1'b1;
            mem_resp_tag[slice] = tag;
            mem_resp_addr[slice] = addr;
            mem_resp_fault[slice] = fault;
            for (integer w = 0; w < W; w = w + 1)
                mem_resp_data[slice][w] = base + 32'(w);
            @(posedge clk); #1;
            mem_resp_v[slice] = 1'b0;
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
                    if (resp_tag[cluster] != tag || resp_addr[cluster] != addr
                        || resp_fault[cluster] != fault || resp_data[cluster][0] != data0)
                        $fatal(1, "P6 architectural response mismatch");
                    found = 1'b1;
                end
                guard = guard + 1;
            end
            if (!found) $fatal(1, "P6 architectural response timeout");
        end
    endtask

    initial begin
        logic [NTW-1:0] original_retry_tag;
        integer snap_c0_resp;
        integer snap_line4;
        integer snap_line6;

        clk = 1'b0;
        rst_n = 1'b0;
        req_v = '0;
        resp_r = '1;
        store_v = 1'b0;
        store_mask = '0;
        mem_req_r = '1;
        mem_resp_v = '0;
        for (i = 0; i < C; i = i + 1) begin
            req_tag[i] = '0;
            req_addr[i] = '0;
        end
        for (i = 0; i < LANES; i = i + 1) store_word_addr[i] = '0;
        for (i = 0; i < S; i = i + 1) begin
            mem_resp_tag[i] = '0;
            mem_resp_addr[i] = '0;
            mem_resp_fault[i] = 1'b0;
            for (j = 0; j < W; j = j + 1) mem_resp_data[i][j] = '0;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        /* Same-cycle pending store and conflicting new load: request must be held. */
        snap_line4 = backend_line4;
        @(negedge clk);
        store_v = 1'b1;
        store_mask = '0;
        store_mask[0] = 1'b1;
        store_word_addr[0] = {30'd4, 2'b00};
        req_v[0] = 1'b1;
        req_tag[0] = 3'd0;
        req_addr[0] = 30'd4;
        #1;
        if (req_r[0]) $fatal(1, "P6 same-cycle conflicting request was ready");
        repeat (5) begin
            @(posedge clk); #1;
            if (req_r[0] || backend_line4 != snap_line4)
                $fatal(1, "P6 conflicting request escaped while store pending");
        end
        $display("PROD_SEAM_P6_SAME_CYCLE_STORE_LOAD_HOLD=PASS");
        $display("PROD_SEAM_P6_NO_PREMATURE_BACKEND_MISS=PASS");

        /* Different cluster + different slice must progress while line4 is blocked. */
        issue_req(1, 3'd0, 30'd12);
        wait_line_count(12, 1);
        if (last_slice_line12 == last_slice_line4 && backend_line4 != 0)
            $fatal(1, "P6 directed slice separation unexpectedly collapsed");
        send_resp(last_slice_line12, last_tag_line12, 30'd12, 1'b0, 32'h12120000);
        wait_resp(1, 3'd0, 30'd12, 1'b0, 32'h12120000);
        $display("PROD_SEAM_P6_NONCONFLICTING_PROGRESS=PASS");

        /* Store quiescence admits held load exactly once and returns fresh value. */
        release_store();
        wait_line_count(4, snap_line4 + 1);
        @(negedge clk);
        req_v[0] = 1'b0;
        repeat (5) @(posedge clk);
        if (backend_line4 != snap_line4 + 1)
            $fatal(1, "P6 held request generated duplicate backend traffic");
        send_resp(last_slice_line4, last_tag_line4, 30'd4, 1'b0, 32'h44440000);
        wait_resp(0, 3'd0, 30'd4, 1'b0, 32'h44440000);
        $display("PROD_SEAM_P6_POST_STORE_ADMIT_EXACTLY_ONCE=PASS");
        $display("PROD_SEAM_P6_POST_STORE_FRESH_VISIBILITY=PASS");

        /* Create a stale P5 completion, then keep the store pending. */
        issue_req(0, 3'd1, 30'd6);
        wait_line_count(6, 1);
        original_retry_tag = last_tag_line6;
        hold_store(30'd6);
        @(posedge clk); #1;
        snap_c0_resp = resp_count_c0;
        send_resp(last_slice_line6, last_tag_line6, 30'd6, 1'b0, 32'hDEAD6000);
        snap_line6 = backend_line6;
        repeat (10) begin
            @(posedge clk); #1;
            if (backend_line6 != snap_line6)
                $fatal(1, "P6 replay storm generated request while store pending");
            if (resp_count_c0 != snap_c0_resp)
                $fatal(1, "P6 stale retry response escaped architecturally");
        end
        $display("PROD_SEAM_P6_RETRY_STORM_PREVENTED=PASS");

        /* A non-conflicting same-cluster request may bypass the blocked retry. */
        issue_req(0, 3'd2, 30'd7);
        wait_line_count(7, 1);
        send_resp(last_slice_line7, last_tag_line7, 30'd7, 1'b0, 32'h77770000);
        wait_resp(0, 3'd2, 30'd7, 1'b0, 32'h77770000);
        if (backend_line6 != snap_line6)
            $fatal(1, "P6 blocked retry leaked during same-cluster bypass");
        $display("PROD_SEAM_P6_SAME_CLUSTER_BYPASS_PROGRESS=PASS");

        /* Quiescence releases the exact retry identity once; fresh fault is preserved. */
        release_store();
        wait_line_count(6, snap_line6 + 1);
        if (last_tag_line6 != original_retry_tag)
            $fatal(1, "P6 retry requester identity changed");
        repeat (5) @(posedge clk);
        if (backend_line6 != snap_line6 + 1)
            $fatal(1, "P6 retry duplicated after store quiescence");
        send_resp(last_slice_line6, last_tag_line6, 30'd6, 1'b1, 32'h66660000);
        wait_resp(0, 3'd1, 30'd6, 1'b1, 32'h66660000);
        repeat (5) @(posedge clk);
        if (resp_count_c0 != snap_c0_resp + 2)
            $fatal(1, "P6 response accounting/double-retire failure");
        $display("PROD_SEAM_P6_RETRY_IDENTITY_PRESERVED=PASS");
        $display("PROD_SEAM_P6_FAULT_PROVENANCE_DISTINCT=PASS");
        $display("PROD_SEAM_P6_NO_DOUBLE_RETIRE=PASS");

        if (|req_err || |noc_req_err || |slice_resp_err || |noc_resp_err)
            $fatal(1, "P6 diagnostic error");
        $display("PROD_SEAM_P6_BEHAVIOR=PASS");
        $finish;
    end
endmodule
