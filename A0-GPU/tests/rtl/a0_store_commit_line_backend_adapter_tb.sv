`timescale 1ns/1ps

module a0_store_commit_line_backend_adapter_tb;
    localparam integer WAVE_SIZE = 4;
    localparam integer WAVE_ID_W = 2;
    localparam integer LINE_WORDS = 4;
    localparam integer LINE_ADDR_W = 30;
    localparam integer CLTW = 2;
    localparam integer NTW = 3;
    localparam integer COMMIT_PORTS = 3;
    localparam integer LINE_PORTS = 2;
    localparam integer BACKEND_TAG_W = 4;
    localparam integer MEMORY_WORDS = 64;

    logic clk;
    logic rst_n;
    always #5 clk = ~clk;

    logic store_launch_v;
    logic [WAVE_ID_W-1:0] store_launch_wave;
    logic [WAVE_ID_W-1:0] store_launch_ctx;
    logic [WAVE_SIZE-1:0] store_launch_mask;
    logic [31:0] store_launch_addr [0:WAVE_SIZE-1];
    logic [31:0] store_launch_wdata [0:WAVE_SIZE-1];
    logic store_bresp_v;
    logic [WAVE_ID_W-1:0] store_bresp_wave;
    logic [WAVE_ID_W-1:0] store_bresp_ctx;
    logic store_bresp_fault;
    logic [31:0] store_bresp_rdata [0:WAVE_SIZE-1];
    logic store_fresp_v;
    logic [WAVE_ID_W-1:0] store_fresp_wave;
    logic [WAVE_ID_W-1:0] store_fresp_ctx;
    logic store_fresp_fault;
    logic [31:0] store_fresp_rdata [0:WAVE_SIZE-1];
    logic fence_commit_v;
    logic fence_commit_r;
    logic [WAVE_SIZE-1:0] fence_commit_mask;
    logic [31:0] fence_commit_addr [0:WAVE_SIZE-1];
    logic [31:0] fence_commit_wdata [0:WAVE_SIZE-1];
    logic store_pending;

    logic [0:0] p6_req_v;
    logic [0:0] p6_req_r;
    logic [CLTW-1:0] p6_req_tag [0:0];
    logic [LINE_ADDR_W-1:0] p6_req_addr [0:0];
    logic [0:0] p6_req_err;
    logic [0:0] p6_resp_v;
    logic [0:0] p6_resp_r;
    logic [CLTW-1:0] p6_resp_tag [0:0];
    logic [LINE_ADDR_W-1:0] p6_resp_addr [0:0];
    logic p6_resp_fault [0:0];
    logic [31:0] p6_resp_data [0:0][0:LINE_WORDS-1];
    logic [0:0] noc_req_err;
    logic [0:0] slice_err;
    logic [0:0] noc_resp_err;
    logic [0:0] p6_mem_req_v;
    logic [0:0] p6_mem_req_r;
    logic [NTW-1:0] p6_mem_req_tag [0:0];
    logic [LINE_ADDR_W-1:0] p6_mem_req_addr [0:0];
    logic [0:0] p6_mem_resp_v;
    logic [NTW-1:0] p6_mem_resp_tag [0:0];
    logic [LINE_ADDR_W-1:0] p6_mem_resp_addr [0:0];
    logic p6_mem_resp_fault [0:0];
    logic [31:0] p6_mem_resp_data [0:0][0:LINE_WORDS-1];
    logic [WAVE_SIZE-1:0] global_store_mask;
    logic [31:0] global_store_addr [0:WAVE_SIZE-1];

    logic [COMMIT_PORTS-1:0] commit_v;
    logic [COMMIT_PORTS-1:0] commit_r;
    logic [WAVE_SIZE-1:0] commit_mask [0:COMMIT_PORTS-1];
    logic [31:0] commit_addr [0:COMMIT_PORTS-1][0:WAVE_SIZE-1];
    logic [31:0] commit_wdata [0:COMMIT_PORTS-1][0:WAVE_SIZE-1];
    logic syn_commit1_v;
    logic syn_commit2_v;
    logic [WAVE_SIZE-1:0] syn_commit1_mask;
    logic [WAVE_SIZE-1:0] syn_commit2_mask;
    logic [31:0] syn_commit1_addr [0:WAVE_SIZE-1];
    logic [31:0] syn_commit2_addr [0:WAVE_SIZE-1];
    logic [31:0] syn_commit1_wdata [0:WAVE_SIZE-1];
    logic [31:0] syn_commit2_wdata [0:WAVE_SIZE-1];

    logic [LINE_PORTS-1:0] line_req_v;
    logic [LINE_PORTS-1:0] line_req_r;
    logic [NTW-1:0] line_req_tag [0:LINE_PORTS-1];
    logic [LINE_ADDR_W-1:0] line_req_addr [0:LINE_PORTS-1];
    logic syn_line_v;
    logic [NTW-1:0] syn_line_tag;
    logic [LINE_ADDR_W-1:0] syn_line_addr;
    logic [LINE_PORTS-1:0] line_resp_v;
    logic [NTW-1:0] line_resp_tag [0:LINE_PORTS-1];
    logic [LINE_ADDR_W-1:0] line_resp_addr [0:LINE_PORTS-1];
    logic line_resp_fault [0:LINE_PORTS-1];
    logic [31:0] line_resp_data [0:LINE_PORTS-1][0:LINE_WORDS-1];
    logic backend_resp_protocol_error;

    logic backend_cmd_v;
    logic backend_cmd_r;
    logic backend_cmd_write;
    logic [BACKEND_TAG_W-1:0] backend_cmd_read_tag;
    logic [31:0] backend_cmd_word_addr;
    logic [31:0] backend_cmd_wdata;
    logic [LINE_ADDR_W-1:0] backend_cmd_line_addr;
    logic backend_resp_v;
    logic [BACKEND_TAG_W-1:0] backend_resp_read_tag;
    logic [LINE_ADDR_W-1:0] backend_resp_line_addr;
    logic backend_resp_fault;
    logic [31:0] backend_resp_data [0:LINE_WORDS-1];

    logic backend_read_pending_q;
    logic [BACKEND_TAG_W-1:0] backend_read_tag_q;
    logic [LINE_ADDR_W-1:0] backend_read_addr_q;
    logic backend_read_fault_q;
    logic [31:0] backend_read_data_q [0:LINE_WORDS-1];
    logic [31:0] memory [0:MEMORY_WORDS-1];

    integer backend_write_count;
    integer backend_read_count;
    integer store_terminal_count;
    integer fence_commit_count;
    integer synthetic_line_count;
    integer p6_req_accept_count;
    integer commit1_accept_count;
    integer commit2_accept_count;
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
        .backend_resp_valid_i(store_bresp_v),
        .backend_resp_wave_i(store_bresp_wave),
        .backend_resp_context_i(store_bresp_ctx),
        .backend_resp_fault_i(store_bresp_fault),
        .backend_resp_rdata_i(store_bresp_rdata),
        .frontend_resp_valid_o(store_fresp_v),
        .frontend_resp_wave_o(store_fresp_wave),
        .frontend_resp_context_o(store_fresp_ctx),
        .frontend_resp_fault_o(store_fresp_fault),
        .frontend_resp_rdata_o(store_fresp_rdata),
        .visibility_commit_valid_o(fence_commit_v),
        .visibility_commit_ready_i(fence_commit_r),
        .visibility_commit_lane_mask_o(fence_commit_mask),
        .visibility_commit_word_addr_o(fence_commit_addr),
        .visibility_commit_wdata_o(fence_commit_wdata),
        .store_pending_o(store_pending)
    );

    always_comb begin
        global_store_mask = store_pending ? fence_commit_mask : '0;
        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1)
            global_store_addr[lane] = fence_commit_addr[lane];
    end

    a0_mc_noc_sliced_l2_store_admission_subsystem #(
        .CLUSTER_COUNT(1), .CUS_PER_CLUSTER(1), .MSHR_COUNT(2),
        .LINE_WORDS(LINE_WORDS), .L2_SLICE_COUNT(1),
        .L2_SET_COUNT_PER_SLICE(8), .L2_MISS_COUNT_PER_SLICE(2),
        .STORE_LANES(WAVE_SIZE)
    ) admission (
        .clk(clk), .rst_n(rst_n),
        .cluster_local_req_valid_i(p6_req_v),
        .cluster_local_req_ready_o(p6_req_r),
        .cluster_local_req_tag_i(p6_req_tag),
        .cluster_local_req_line_addr_i(p6_req_addr),
        .cluster_local_req_tag_error_o(p6_req_err),
        .cluster_local_resp_valid_o(p6_resp_v),
        .cluster_local_resp_ready_i(p6_resp_r),
        .cluster_local_resp_tag_o(p6_resp_tag),
        .cluster_local_resp_line_addr_o(p6_resp_addr),
        .cluster_local_resp_fault_o(p6_resp_fault),
        .cluster_local_resp_data_o(p6_resp_data),
        .global_store_valid_i(store_pending),
        .global_store_lane_mask_i(global_store_mask),
        .global_store_word_addr_i(global_store_addr),
        .noc_req_tag_error_o(noc_req_err),
        .slice_resp_protocol_error_o(slice_err),
        .noc_resp_tag_error_o(noc_resp_err),
        .line_mem_req_valid_o(p6_mem_req_v),
        .line_mem_req_ready_i(p6_mem_req_r),
        .line_mem_req_network_tag_o(p6_mem_req_tag),
        .line_mem_req_line_addr_o(p6_mem_req_addr),
        .line_mem_resp_valid_i(p6_mem_resp_v),
        .line_mem_resp_network_tag_i(p6_mem_resp_tag),
        .line_mem_resp_line_addr_i(p6_mem_resp_addr),
        .line_mem_resp_fault_i(p6_mem_resp_fault),
        .line_mem_resp_data_i(p6_mem_resp_data)
    );

    always_comb begin
        commit_v = '0;
        commit_v[0] = fence_commit_v;
        commit_v[1] = syn_commit1_v;
        commit_v[2] = syn_commit2_v;
        commit_mask[0] = fence_commit_mask;
        commit_mask[1] = syn_commit1_mask;
        commit_mask[2] = syn_commit2_mask;
        for (integer lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            commit_addr[0][lane] = fence_commit_addr[lane];
            commit_wdata[0][lane] = fence_commit_wdata[lane];
            commit_addr[1][lane] = syn_commit1_addr[lane];
            commit_wdata[1][lane] = syn_commit1_wdata[lane];
            commit_addr[2][lane] = syn_commit2_addr[lane];
            commit_wdata[2][lane] = syn_commit2_wdata[lane];
        end
        fence_commit_r = commit_r[0];

        line_req_v = '0;
        line_req_v[0] = p6_mem_req_v[0];
        line_req_v[1] = syn_line_v;
        line_req_tag[0] = p6_mem_req_tag[0];
        line_req_tag[1] = syn_line_tag;
        line_req_addr[0] = p6_mem_req_addr[0];
        line_req_addr[1] = syn_line_addr;
        p6_mem_req_r[0] = line_req_r[0];

        p6_mem_resp_v[0] = line_resp_v[0];
        p6_mem_resp_tag[0] = line_resp_tag[0];
        p6_mem_resp_addr[0] = line_resp_addr[0];
        p6_mem_resp_fault[0] = line_resp_fault[0];
        for (integer word = 0; word < LINE_WORDS; word = word + 1)
            p6_mem_resp_data[0][word] = line_resp_data[0][word];
    end

    a0_store_commit_line_backend_adapter #(
        .COMMIT_PORT_COUNT(COMMIT_PORTS),
        .STORE_LANES(WAVE_SIZE),
        .LINE_PORT_COUNT(LINE_PORTS),
        .LINE_WORDS(LINE_WORDS),
        .NETWORK_TAG_W(NTW)
    ) adapter (
        .clk(clk), .rst_n(rst_n),
        .commit_valid_i(commit_v), .commit_ready_o(commit_r),
        .commit_lane_mask_i(commit_mask),
        .commit_word_addr_i(commit_addr), .commit_wdata_i(commit_wdata),
        .line_req_valid_i(line_req_v), .line_req_ready_o(line_req_r),
        .line_req_network_tag_i(line_req_tag),
        .line_req_line_addr_i(line_req_addr),
        .line_resp_valid_o(line_resp_v),
        .line_resp_network_tag_o(line_resp_tag),
        .line_resp_line_addr_o(line_resp_addr),
        .line_resp_fault_o(line_resp_fault),
        .line_resp_data_o(line_resp_data),
        .backend_resp_protocol_error_o(backend_resp_protocol_error),
        .backend_cmd_valid_o(backend_cmd_v),
        .backend_cmd_ready_i(backend_cmd_r),
        .backend_cmd_write_o(backend_cmd_write),
        .backend_cmd_read_tag_o(backend_cmd_read_tag),
        .backend_cmd_word_addr_o(backend_cmd_word_addr),
        .backend_cmd_wdata_o(backend_cmd_wdata),
        .backend_cmd_line_addr_o(backend_cmd_line_addr),
        .backend_resp_valid_i(backend_resp_v),
        .backend_resp_read_tag_i(backend_resp_read_tag),
        .backend_resp_line_addr_i(backend_resp_line_addr),
        .backend_resp_fault_i(backend_resp_fault),
        .backend_resp_data_i(backend_resp_data)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            backend_resp_v <= 1'b0;
            backend_resp_read_tag <= '0;
            backend_resp_line_addr <= '0;
            backend_resp_fault <= 1'b0;
            backend_read_pending_q <= 1'b0;
            backend_read_tag_q <= '0;
            backend_read_addr_q <= '0;
            backend_read_fault_q <= 1'b0;
            backend_write_count <= 0;
            backend_read_count <= 0;
            store_terminal_count <= 0;
            fence_commit_count <= 0;
            synthetic_line_count <= 0;
            p6_req_accept_count <= 0;
            commit1_accept_count <= 0;
            commit2_accept_count <= 0;
            for (integer word = 0; word < LINE_WORDS; word = word + 1) begin
                backend_resp_data[word] <= '0;
                backend_read_data_q[word] <= '0;
            end
            for (integer word = 0; word < MEMORY_WORDS; word = word + 1)
                memory[word] <= 32'h10000000 + 32'(word);
        end else begin
            backend_resp_v <= backend_read_pending_q;
            backend_resp_read_tag <= backend_read_tag_q;
            backend_resp_line_addr <= backend_read_addr_q;
            backend_resp_fault <= backend_read_fault_q;
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                backend_resp_data[word] <= backend_read_data_q[word];
            backend_read_pending_q <= 1'b0;

            if (backend_cmd_v && backend_cmd_r && backend_cmd_write) begin
                if (backend_cmd_word_addr >= MEMORY_WORDS)
                    $fatal(1, "P8 TB backend write out of range");
                memory[backend_cmd_word_addr] <= backend_cmd_wdata;
                backend_write_count <= backend_write_count + 1;
            end

            if (backend_cmd_v && backend_cmd_r && !backend_cmd_write) begin
                logic [31:0] base_word;
                base_word = {backend_cmd_line_addr, 2'b00};
                backend_read_pending_q <= 1'b1;
                backend_read_tag_q <= backend_cmd_read_tag;
                backend_read_addr_q <= backend_cmd_line_addr;
                backend_read_fault_q <= (backend_cmd_line_addr == 30'd9);
                for (integer word = 0; word < LINE_WORDS; word = word + 1) begin
                    if (base_word + 32'(word) < MEMORY_WORDS)
                        backend_read_data_q[word] <= memory[base_word + 32'(word)];
                    else
                        backend_read_data_q[word] <= '0;
                end
                backend_read_count <= backend_read_count + 1;
            end

            if (store_fresp_v)
                store_terminal_count <= store_terminal_count + 1;
            if (fence_commit_v && fence_commit_r)
                fence_commit_count <= fence_commit_count + 1;
            if (line_resp_v[1])
                synthetic_line_count <= synthetic_line_count + 1;
            if (p6_req_v[0] && p6_req_r[0])
                p6_req_accept_count <= p6_req_accept_count + 1;
            if (commit_v[1] && commit_r[1])
                commit1_accept_count <= commit1_accept_count + 1;
            if (commit_v[2] && commit_r[2])
                commit2_accept_count <= commit2_accept_count + 1;
        end
    end

    task automatic launch_store_two(
        input logic [WAVE_ID_W-1:0] wave,
        input logic [31:0] addr0,
        input logic [31:0] data0,
        input logic [31:0] addr1,
        input logic [31:0] data1
    );
        begin
            @(negedge clk);
            store_launch_v = 1'b1;
            store_launch_wave = wave;
            store_launch_ctx = wave;
            store_launch_mask = '0;
            store_launch_mask[0] = 1'b1;
            store_launch_mask[1] = 1'b1;
            store_launch_addr[0] = addr0;
            store_launch_addr[1] = addr1;
            store_launch_wdata[0] = data0;
            store_launch_wdata[1] = data1;
            @(posedge clk); #1;
            store_launch_v = 1'b0;
        end
    endtask

    task automatic pulse_store_response(
        input logic [WAVE_ID_W-1:0] wave,
        input logic fault
    );
        begin
            @(negedge clk);
            store_bresp_v = 1'b1;
            store_bresp_wave = wave;
            store_bresp_ctx = wave;
            store_bresp_fault = fault;
            @(posedge clk); #1;
            store_bresp_v = 1'b0;
        end
    endtask

    initial begin
        integer snap_write;
        integer snap_read;
        integer snap_terminal;
        integer snap_commit;
        integer snap_syn_resp;
        logic [31:0] held_word_addr;
        logic [31:0] held_wdata;
        logic saw_first_store_beat;
        logic saw_interleaved_read;

        clk = 1'b0;
        rst_n = 1'b0;
        store_launch_v = 1'b0;
        store_launch_wave = '0;
        store_launch_ctx = '0;
        store_launch_mask = '0;
        store_bresp_v = 1'b0;
        store_bresp_wave = '0;
        store_bresp_ctx = '0;
        store_bresp_fault = 1'b0;
        p6_req_v = '0;
        p6_req_tag[0] = '0;
        p6_req_addr[0] = '0;
        p6_resp_r = '1;
        syn_commit1_v = 1'b0;
        syn_commit2_v = 1'b0;
        syn_commit1_mask = '0;
        syn_commit2_mask = '0;
        syn_line_v = 1'b0;
        syn_line_tag = '0;
        syn_line_addr = '0;
        backend_cmd_r = 1'b1;
        for (i = 0; i < WAVE_SIZE; i = i + 1) begin
            store_launch_addr[i] = '0;
            store_launch_wdata[i] = '0;
            store_bresp_rdata[i] = '0;
            syn_commit1_addr[i] = '0;
            syn_commit2_addr[i] = '0;
            syn_commit1_wdata[i] = '0;
            syn_commit2_wdata[i] = '0;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        /* P7 store pending holds a conflicting P6 load. */
        launch_store_two(2'd1, 32'd16, 32'hA5A5A5A5,
                               32'd17, 32'hB6B6B6B6);
        @(negedge clk);
        p6_req_v[0] = 1'b1;
        p6_req_tag[0] = 2'd0;
        p6_req_addr[0] = 30'd4;
        repeat (3) begin
            @(posedge clk); #1;
            if (p6_req_r[0] || p6_mem_req_v[0])
                $fatal(1, "P8 conflicting load escaped before visibility commit");
        end
        $display("PROD_SEAM_P8_CONFLICTING_REFILL_HELD=PASS");

        /* A successful store response becomes a P7 commit source. */
        pulse_store_response(2'd1, 1'b0);
        begin : wait_commit_valid
            integer guard;
            guard = 0;
            while (guard < 30 && !fence_commit_v) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!fence_commit_v) $fatal(1, "P8 fence commit did not appear");
        end

        /* Once the adapter owns the commit, backend backpressure must hold the beat. */
        backend_cmd_r = 1'b0;
        begin : wait_store_cmd
            integer guard;
            guard = 0;
            while (guard < 30 && !(backend_cmd_v && backend_cmd_write)) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!(backend_cmd_v && backend_cmd_write))
                $fatal(1, "P8 adapter did not present store beat");
        end
        held_word_addr = backend_cmd_word_addr;
        held_wdata = backend_cmd_wdata;
        snap_terminal = store_terminal_count;
        snap_commit = fence_commit_count;
        repeat (3) begin
            @(posedge clk); #1;
            if (!backend_cmd_v || !backend_cmd_write
                || backend_cmd_word_addr != held_word_addr
                || backend_cmd_wdata != held_wdata
                || fence_commit_r || store_terminal_count != snap_terminal
                || fence_commit_count != snap_commit)
                $fatal(1, "P8 store beat/commit changed under backend backpressure");
        end
        $display("PROD_SEAM_P8_BACKEND_BACKPRESSURE_STABLE=PASS");

        /* A non-conflicting refill may interleave between a two-beat commit. */
        @(negedge clk);
        syn_line_v = 1'b1;
        syn_line_tag = 3'd5;
        syn_line_addr = 30'd7;
        backend_cmd_r = 1'b1;
        snap_write = backend_write_count;
        snap_read = backend_read_count;
        saw_first_store_beat = 1'b0;
        saw_interleaved_read = 1'b0;
        begin : wait_main_commit
            integer guard;
            guard = 0;
            while (guard < 80 && fence_commit_count == snap_commit) begin
                @(posedge clk); #1;
                if (backend_write_count > snap_write)
                    saw_first_store_beat = 1'b1;
                if (saw_first_store_beat && backend_read_count > snap_read)
                    saw_interleaved_read = 1'b1;
                if (syn_line_v && line_req_r[1])
                    syn_line_v = 1'b0;
                guard = guard + 1;
            end
            if (fence_commit_count != snap_commit + 1)
                $fatal(1, "P8 main commit did not complete");
        end
        if (!saw_first_store_beat || !saw_interleaved_read)
            $fatal(1, "P8 non-conflicting refill did not interleave fairly");
        if (store_terminal_count != snap_terminal + 1 || store_pending)
            $fatal(1, "P8 P7 terminal was not coupled to final backend write");
        if (store_fresp_wave != 2'd1 || store_fresp_ctx != 2'd1
            || store_fresp_fault)
            $fatal(1, "P8 successful store terminal identity/provenance mismatch");
        if (memory[16] != 32'hA5A5A5A5 || memory[17] != 32'hB6B6B6B6)
            $fatal(1, "P8 committed store beats did not reach backend memory");
        $display("PROD_SEAM_P8_NONCONFLICTING_REFILL_PROGRESS=PASS");
        $display("PROD_SEAM_P8_COMMIT_ACK_AFTER_FINAL_WRITE=PASS");

        /* The held conflicting load now enters and must read the committed words. */
        begin : wait_cluster_accept
            integer guard;
            integer accept_before;
            guard = 0;
            accept_before = p6_req_accept_count;
            while (guard < 80 && p6_req_accept_count == accept_before) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (p6_req_accept_count != accept_before + 1)
                $fatal(1, "P8 post-commit load was never accepted");
        end
        @(negedge clk); p6_req_v[0] = 1'b0;
        begin : wait_p6_response
            integer guard;
            logic found;
            guard = 0; found = 1'b0;
            while (guard < 120 && !found) begin
                @(posedge clk);
                if (p6_resp_v[0] && p6_resp_r[0]) begin
                    if (p6_resp_tag[0] != 2'd0 || p6_resp_addr[0] != 30'd4
                        || p6_resp_fault[0]
                        || p6_resp_data[0][0] != 32'hA5A5A5A5
                        || p6_resp_data[0][1] != 32'hB6B6B6B6)
                        $fatal(1, "P8 refill did not observe committed store value");
                    found = 1'b1;
                end
                guard = guard + 1;
            end
            if (!found) $fatal(1, "P8 post-commit P6 response timeout");
        end
        $display("PROD_SEAM_P8_CAUSAL_COMMIT_TO_REFILL_VISIBILITY=PASS");

        /* Three-port commit RR: after port 0, simultaneous ports 1/2 choose 1 then 2. */
        snap_write = backend_write_count;
        @(negedge clk);
        syn_commit1_mask = '0; syn_commit1_mask[0] = 1'b1;
        syn_commit2_mask = '0; syn_commit2_mask[0] = 1'b1;
        syn_commit1_addr[0] = 32'd24; syn_commit1_wdata[0] = 32'h11112222;
        syn_commit2_addr[0] = 32'd28; syn_commit2_wdata[0] = 32'h33334444;
        syn_commit1_v = 1'b1; syn_commit2_v = 1'b1;
        begin : wait_commit1
            integer guard;
            integer accept_before;
            guard = 0;
            accept_before = commit1_accept_count;
            while (guard < 80 && commit1_accept_count == accept_before) begin
                @(posedge clk); #1;
                if (backend_write_count > snap_write
                    && memory[24] != 32'h11112222)
                    $fatal(1, "P8 RR did not select commit port 1 first");
                guard = guard + 1;
            end
            if (commit1_accept_count != accept_before + 1)
                $fatal(1, "P8 commit port 1 timeout");
        end
        @(negedge clk); syn_commit1_v = 1'b0;
        begin : wait_commit2
            integer guard;
            integer accept_before;
            guard = 0;
            accept_before = commit2_accept_count;
            while (guard < 80 && commit2_accept_count == accept_before) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (commit2_accept_count != accept_before + 1)
                $fatal(1, "P8 commit port 2 timeout");
        end
        @(negedge clk); syn_commit2_v = 1'b0;
        repeat (2) @(posedge clk); #1;
        if (memory[24] != 32'h11112222 || memory[28] != 32'h33334444)
            $fatal(1, "P8 multi-port commit data mismatch");
        $display("PROD_SEAM_P8_COMMIT_ROUND_ROBIN_FAIRNESS=PASS");

        /* Read identity/fault provenance survives unified-tag routing. */
        snap_read = backend_read_count;
        snap_syn_resp = synthetic_line_count;
        @(negedge clk);
        syn_line_v = 1'b1;
        syn_line_tag = 3'd6;
        syn_line_addr = 30'd9;
        begin : wait_fault_read_accept
            integer guard;
            guard = 0;
            while (guard < 80 && !line_req_r[1]) begin
                @(posedge clk); #1; guard = guard + 1;
            end
            if (!line_req_r[1]) $fatal(1, "P8 fault read was not accepted");
        end
        @(negedge clk); syn_line_v = 1'b0;
        begin : wait_fault_read_resp
            integer guard;
            logic found;
            guard = 0; found = 1'b0;
            while (guard < 80 && !found) begin
                @(posedge clk);
                if (line_resp_v[1]) begin
                    if (line_resp_tag[1] != 3'd6 || line_resp_addr[1] != 30'd9
                        || !line_resp_fault[1])
                        $fatal(1, "P8 read fault/tag provenance mismatch");
                    found = 1'b1;
                end
                guard = guard + 1;
            end
            if (!found) $fatal(1, "P8 fault read response timeout");
        end
        @(posedge clk); #1;
        if (backend_read_count != snap_read + 1
            || synthetic_line_count != snap_syn_resp + 1)
            $fatal(1, "P8 read accounting mismatch");
        $display("PROD_SEAM_P8_READ_TAG_AND_FAULT_PROVENANCE=PASS");

        /* A faulting P7 store never enters the P8 commit/write path. */
        snap_write = backend_write_count;
        snap_terminal = store_terminal_count;
        launch_store_two(2'd2, 32'd40, 32'hDEADBEEF,
                               32'd41, 32'hCAFEBABE);
        pulse_store_response(2'd2, 1'b1);
        repeat (4) @(posedge clk); #1;
        if (backend_write_count != snap_write || fence_commit_v || store_pending)
            $fatal(1, "P8 faulting store incorrectly reached commit backend");
        if (store_terminal_count != snap_terminal + 1
            || store_fresp_wave != 2'd2 || store_fresp_ctx != 2'd2
            || !store_fresp_fault || store_fresp_rdata[0] != 32'd0)
            $fatal(1, "P8 fault terminal provenance mismatch");
        $display("PROD_SEAM_P8_FAULTING_STORE_NO_BACKEND_COMMIT=PASS");

        if (p6_req_err != '0 || noc_req_err != '0 || slice_err != '0
            || noc_resp_err != '0 || backend_resp_protocol_error)
            $fatal(1, "P8 diagnostic error");
        $display("PROD_SEAM_P8_BEHAVIOR=PASS");
        $finish;
    end
endmodule
