`timescale 1ns/1ps

module a0_store_visibility_commit_fence_tb;
    localparam integer WAVE_SIZE = 4;
    localparam integer WAVE_ID_W = 2;
    localparam integer LINE_WORDS = 4;
    localparam integer LINE_ADDR_W = 30;
    localparam integer CLTW = 2;
    localparam integer NTW = 3;

    logic clk;
    logic rst_n;
    always #5 clk = ~clk;

    logic store_launch_v;
    logic [WAVE_ID_W-1:0] store_launch_wave;
    logic [WAVE_ID_W-1:0] store_launch_ctx;
    logic [WAVE_SIZE-1:0] store_launch_mask;
    logic [31:0] store_launch_addr [0:WAVE_SIZE-1];
    logic [31:0] store_launch_wdata [0:WAVE_SIZE-1];

    logic bresp_v;
    logic [WAVE_ID_W-1:0] bresp_wave;
    logic [WAVE_ID_W-1:0] bresp_ctx;
    logic bresp_fault;
    logic [31:0] bresp_rdata [0:WAVE_SIZE-1];

    logic fresp_v;
    logic [WAVE_ID_W-1:0] fresp_wave;
    logic [WAVE_ID_W-1:0] fresp_ctx;
    logic fresp_fault;
    logic [31:0] fresp_rdata [0:WAVE_SIZE-1];

    logic commit_v;
    logic commit_r;
    logic [WAVE_SIZE-1:0] commit_mask;
    logic [31:0] commit_addr [0:WAVE_SIZE-1];
    logic [31:0] commit_wdata [0:WAVE_SIZE-1];
    logic store_pending;

    logic req_v;
    logic req_r;
    logic [CLTW-1:0] req_tag [0:0];
    logic [LINE_ADDR_W-1:0] req_addr [0:0];
    logic req_err;
    logic resp_v;
    logic resp_r;
    logic [CLTW-1:0] resp_tag [0:0];
    logic [LINE_ADDR_W-1:0] resp_addr [0:0];
    logic resp_fault [0:0];
    logic [31:0] resp_data [0:0][0:LINE_WORDS-1];

    logic noc_req_err;
    logic slice_err;
    logic noc_resp_err;
    logic mem_req_v;
    logic mem_req_r;
    logic [NTW-1:0] mem_req_tag [0:0];
    logic [LINE_ADDR_W-1:0] mem_req_addr [0:0];
    logic mem_resp_v;
    logic [NTW-1:0] mem_resp_tag [0:0];
    logic [LINE_ADDR_W-1:0] mem_resp_addr [0:0];
    logic mem_resp_fault [0:0];
    logic [31:0] mem_resp_data [0:0][0:LINE_WORDS-1];

    logic [WAVE_SIZE-1:0] global_store_mask;
    logic [31:0] global_store_addr [0:WAVE_SIZE-1];
    logic [31:0] memory_line [0:LINE_WORDS-1];

    integer commit_count;
    integer frontend_terminal_count;
    integer backend_load_count;
    integer i;

    a0_store_visibility_commit_fence #(
        .WAVE_SIZE(WAVE_SIZE), .WAVE_ID_W(WAVE_ID_W),
        .CONTEXT_ID_W(WAVE_ID_W)
    ) fence (
        .clk(clk), .rst_n(rst_n),
        .store_launch_valid_i(store_launch_v),
        .store_launch_wave_i(store_launch_wave),
        .store_launch_context_i(store_launch_ctx),
        .store_launch_lane_mask_i(store_launch_mask),
        .store_launch_word_addr_i(store_launch_addr),
        .store_launch_wdata_i(store_launch_wdata),
        .backend_resp_valid_i(bresp_v),
        .backend_resp_wave_i(bresp_wave),
        .backend_resp_context_i(bresp_ctx),
        .backend_resp_fault_i(bresp_fault),
        .backend_resp_rdata_i(bresp_rdata),
        .frontend_resp_valid_o(fresp_v),
        .frontend_resp_wave_o(fresp_wave),
        .frontend_resp_context_o(fresp_ctx),
        .frontend_resp_fault_o(fresp_fault),
        .frontend_resp_rdata_o(fresp_rdata),
        .visibility_commit_valid_o(commit_v),
        .visibility_commit_ready_i(commit_r),
        .visibility_commit_lane_mask_o(commit_mask),
        .visibility_commit_word_addr_o(commit_addr),
        .visibility_commit_wdata_o(commit_wdata),
        .store_pending_o(store_pending)
    );

    always_comb begin
        global_store_mask = store_pending ? commit_mask : '0;
        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1)
            global_store_addr[lane] = commit_addr[lane];
    end

    a0_mc_noc_sliced_l2_store_admission_subsystem #(
        .CLUSTER_COUNT(1), .CUS_PER_CLUSTER(1), .MSHR_COUNT(2),
        .LINE_WORDS(LINE_WORDS), .L2_SLICE_COUNT(1),
        .L2_SET_COUNT_PER_SLICE(8), .L2_MISS_COUNT_PER_SLICE(2),
        .STORE_LANES(WAVE_SIZE)
    ) admission (
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
        .global_store_valid_i(store_pending),
        .global_store_lane_mask_i(global_store_mask),
        .global_store_word_addr_i(global_store_addr),
        .noc_req_tag_error_o(noc_req_err),
        .slice_resp_protocol_error_o(slice_err),
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
            commit_count <= 0;
            frontend_terminal_count <= 0;
            backend_load_count <= 0;
            for (integer w = 0; w < LINE_WORDS; w = w + 1)
                memory_line[w] <= 32'h10000000 + 32'(w);
        end else begin
            if (commit_v && commit_r) begin
                commit_count <= commit_count + 1;
                for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                    if (commit_mask[lane]
                        && commit_addr[lane][31:2] == 30'd4)
                        memory_line[commit_addr[lane][1:0]] <= commit_wdata[lane];
                end
            end
            if (fresp_v) frontend_terminal_count <= frontend_terminal_count + 1;
            if (mem_req_v && mem_req_r) backend_load_count <= backend_load_count + 1;
        end
    end

    task automatic pulse_store_launch(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [31:0] word_addr,
        input logic [31:0] wdata
    );
        begin
            @(negedge clk);
            store_launch_v = 1'b1;
            store_launch_wave = wave;
            store_launch_ctx = wave;
            store_launch_mask = '0;
            store_launch_mask[0] = 1'b1;
            store_launch_addr[0] = word_addr;
            store_launch_wdata[0] = wdata;
            @(posedge clk); #1;
            store_launch_v = 1'b0;
        end
    endtask

    task automatic pulse_backend_store_resp(
        input logic [WAVE_ID_W-1:0] wave,
        input logic fault
    );
        begin
            @(negedge clk);
            bresp_v = 1'b1;
            bresp_wave = wave;
            bresp_ctx = wave;
            bresp_fault = fault;
            @(posedge clk); #1;
            bresp_v = 1'b0;
        end
    endtask

    task automatic send_line_resp;
        begin
            @(negedge clk);
            mem_resp_v = 1'b1;
            mem_resp_tag[0] = mem_req_tag[0];
            mem_resp_addr[0] = mem_req_addr[0];
            mem_resp_fault[0] = 1'b0;
            for (integer w = 0; w < LINE_WORDS; w = w + 1)
                mem_resp_data[0][w] = memory_line[w];
            @(posedge clk); #1;
            mem_resp_v = 1'b0;
        end
    endtask

    initial begin
        integer snap_commit;
        integer snap_term;
        integer snap_backend;
        logic [31:0] held_addr;
        logic [31:0] held_data;

        clk = 1'b0;
        rst_n = 1'b0;
        store_launch_v = 1'b0;
        store_launch_wave = '0;
        store_launch_ctx = '0;
        store_launch_mask = '0;
        bresp_v = 1'b0;
        bresp_wave = '0;
        bresp_ctx = '0;
        bresp_fault = 1'b0;
        commit_r = 1'b0;
        req_v = 1'b0;
        req_tag[0] = '0;
        req_addr[0] = '0;
        resp_r = 1'b1;
        mem_req_r = 1'b1;
        mem_resp_v = 1'b0;
        mem_resp_tag[0] = '0;
        mem_resp_addr[0] = '0;
        mem_resp_fault[0] = 1'b0;
        for (i = 0; i < WAVE_SIZE; i = i + 1) begin
            store_launch_addr[i] = '0;
            store_launch_wdata[i] = '0;
            bresp_rdata[i] = '0;
            if (i < LINE_WORDS) mem_resp_data[0][i] = '0;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        /* Launch one physical store.  A non-conflicting line must still progress. */
        pulse_store_launch(2'd1, 32'd16, 32'hA5A5A5A5);
        if (!store_pending) $fatal(1, "P7 store pending did not capture launch");
        @(negedge clk);
        req_v = 1'b1;
        req_tag[0] = 2'd1;
        req_addr[0] = 30'd6;
        begin : wait_nonconflicting_req
            integer guard;
            guard = 0;
            while (guard < 80 && !(mem_req_v && mem_req_r)) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!(mem_req_v && mem_req_r))
                $fatal(1, "P7 non-conflicting load did not progress");
        end
        @(negedge clk); req_v = 1'b0;
        send_line_resp();
        begin : wait_nonconflicting_resp
            integer guard;
            logic found;
            guard = 0; found = 1'b0;
            while (guard < 80 && !found) begin
                @(posedge clk);
                if (resp_v && resp_r) begin
                    if (resp_tag[0] != 2'd1 || resp_addr[0] != 30'd6 || resp_fault[0])
                        $fatal(1, "P7 non-conflicting response identity mismatch");
                    found = 1'b1;
                end
                guard = guard + 1;
            end
            if (!found) $fatal(1, "P7 non-conflicting response timeout");
        end
        if (!store_pending) $fatal(1, "P7 non-conflicting load retired store early");
        $display("PROD_SEAM_P7_NONCONFLICTING_LOAD_PROGRESS=PASS");

        /* A conflicting load must remain held throughout the visibility fence. */
        @(negedge clk);
        req_v = 1'b1;
        req_tag[0] = 2'd0;
        req_addr[0] = 30'd4;
        repeat (3) begin
            @(posedge clk); #1;
            if (req_r || mem_req_v)
                $fatal(1, "P7 conflicting load admitted before store terminal");
        end

        /* Successful backend response must become a commit, not a terminal yet. */
        snap_term = frontend_terminal_count;
        pulse_backend_store_resp(2'd1, 1'b0);
        repeat (2) @(posedge clk); #1;
        if (!commit_v || frontend_terminal_count != snap_term || !store_pending)
            $fatal(1, "P7 successful store response was not fenced");
        $display("PROD_SEAM_P7_TERMINAL_HELD_UNTIL_COMMIT=PASS");

        held_addr = commit_addr[0];
        held_data = commit_wdata[0];
        snap_backend = backend_load_count;
        repeat (5) begin
            @(posedge clk); #1;
            if (!commit_v || commit_addr[0] != held_addr || commit_wdata[0] != held_data)
                $fatal(1, "P7 commit payload changed under backpressure");
            if (frontend_terminal_count != snap_term || backend_load_count != snap_backend || req_r)
                $fatal(1, "P7 visibility fence released early");
        end
        if (held_addr != 32'd16 || held_data != 32'hA5A5A5A5 || !commit_mask[0])
            $fatal(1, "P7 commit payload provenance mismatch");
        $display("PROD_SEAM_P7_COMMIT_PAYLOAD_PROVENANCE=PASS");
        $display("PROD_SEAM_P7_COMMIT_BACKPRESSURE_STABLE=PASS");
        $display("PROD_SEAM_P7_CONFLICTING_LOAD_HELD=PASS");

        /* Commit handshake writes the backend-visible value and releases terminal. */
        snap_commit = commit_count;
        @(negedge clk); commit_r = 1'b1; #1;
        if (!fresp_v || fresp_fault || fresp_wave != 2'd1 || fresp_ctx != 2'd1
            || fresp_rdata[0] != 32'd0)
            $fatal(1, "P7 terminal was not presented for commit handshake");
        @(posedge clk); #1;
        @(negedge clk); commit_r = 1'b0;
        repeat (2) @(posedge clk); #1;
        if (commit_count != snap_commit + 1 || store_pending || commit_v)
            $fatal(1, "P7 commit/terminal accounting failed");
        if (memory_line[0] != 32'hA5A5A5A5)
            $fatal(1, "P7 commit did not causally update backend memory");
        $display("PROD_SEAM_P7_EXACTLY_ONCE_COMMIT=PASS");

        /* Held load may now enter P6 and must receive the commit-updated data. */
        begin : wait_load_req
            integer guard;
            guard = 0;
            while (guard < 80 && !(mem_req_v && mem_req_r)) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!(mem_req_v && mem_req_r)) $fatal(1, "P7 post-commit load backend timeout");
        end
        @(negedge clk); req_v = 1'b0;
        send_line_resp();
        begin : wait_load_resp
            integer guard;
            logic found;
            guard = 0; found = 1'b0;
            while (guard < 80 && !found) begin
                @(posedge clk);
                if (resp_v && resp_r) begin
                    if (resp_tag[0] != 2'd0 || resp_addr[0] != 30'd4 || resp_fault[0]
                        || resp_data[0][0] != 32'hA5A5A5A5)
                        $fatal(1, "P7 post-commit load saw stale data");
                    found = 1'b1;
                end
                guard = guard + 1;
            end
            if (!found) $fatal(1, "P7 architectural load response timeout");
        end
        $display("PROD_SEAM_P7_CAUSAL_BACKEND_VISIBILITY=PASS");

        /* Faulting store bypasses commit publication and preserves fault provenance. */
        snap_commit = commit_count;
        snap_term = frontend_terminal_count;
        pulse_store_launch(2'd2, 32'd20, 32'hDEADBEEF);
        pulse_backend_store_resp(2'd2, 1'b1);
        repeat (2) @(posedge clk); #1;
        if (commit_count != snap_commit || commit_v || store_pending)
            $fatal(1, "P7 faulting store incorrectly published commit");
        if (frontend_terminal_count != snap_term + 1)
            $fatal(1, "P7 fault terminal not forwarded");
        $display("PROD_SEAM_P7_FAULTING_STORE_NO_COMMIT=PASS");
        $display("PROD_SEAM_P7_FAULT_PROVENANCE_DISTINCT=PASS");

        if (req_err || noc_req_err || slice_err || noc_resp_err)
            $fatal(1, "P7 diagnostic error");
        $display("PROD_SEAM_P7_BEHAVIOR=PASS");
        $finish;
    end
endmodule
