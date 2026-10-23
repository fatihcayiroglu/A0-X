`timescale 1ns/1ps

module a0_store_commit_duplicate_canonicalizer_tb;
    localparam integer CLUSTER_COUNT = 1;
    localparam integer CUS_PER_CLUSTER = 1;
    localparam integer STORE_LANES = 4;
    localparam integer L2_SLICE_COUNT = 1;
    localparam integer LINE_WORDS = 4;
    localparam integer NETWORK_TAG_W = 2;
    localparam integer READ_TRACK_COUNT = 2;
    localparam integer READ_EPOCH_W = 4;
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

    logic [31:0] memory [0:255];
    integer write_count;
    integer read_cmd_count;
    integer commit_accept_count;
    integer line_accept_count;
    integer line_resp_count;
    integer protocol_error_count;
    logic [31:0] write_addr_seen [0:7];
    logic [31:0] write_data_seen [0:7];
    logic [EXT_READ_ID_W-1:0] last_read_id;
    logic [LINE_ADDR_W-1:0] last_read_line;
    logic [NETWORK_TAG_W-1:0] last_resp_tag;
    logic [LINE_ADDR_W-1:0] last_resp_addr;
    logic [31:0] last_resp_data [0:LINE_WORDS-1];

    a0_production_store_backend_collision_seam #(
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
            write_count <= 0;
            read_cmd_count <= 0;
            commit_accept_count <= 0;
            line_accept_count <= 0;
            line_resp_count <= 0;
            protocol_error_count <= 0;
            last_read_id <= '0;
            last_read_line <= '0;
            last_resp_tag <= '0;
            last_resp_addr <= '0;
            for (integer i = 0; i < 8; i = i + 1) begin
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

            if (backend_cmd_v && backend_cmd_r) begin
                if (backend_cmd_write) begin
                    if (write_count >= 8)
                        $fatal(1, "P11 write capture overflow");
                    write_addr_seen[write_count] <= backend_cmd_word_addr;
                    write_data_seen[write_count] <= backend_cmd_wdata;
                    memory[backend_cmd_word_addr[7:0]] <= backend_cmd_wdata;
                    write_count <= write_count + 1;
                end else begin
                    last_read_id <= backend_cmd_id;
                    last_read_line <= backend_cmd_line_addr;
                    read_cmd_count <= read_cmd_count + 1;
                end
            end

            if (line_resp_v[0]) begin
                line_resp_count <= line_resp_count + 1;
                last_resp_tag <= line_resp_tag[0];
                last_resp_addr <= line_resp_addr[0];
                for (integer w = 0; w < LINE_WORDS; w = w + 1)
                    last_resp_data[w] <= line_resp_data[0][w];
                if (line_resp_fault[0])
                    $fatal(1, "P11 unexpected refill fault");
            end
        end
    end

    task automatic wait_commit_accept(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 120 && commit_accept_count < target) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (commit_accept_count != target)
                $fatal(1, "P11 commit acceptance timeout");
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
                $fatal(1, "P11 line request acceptance timeout");
            @(negedge clk);
            line_req_v[0] = 1'b0;
        end
    endtask

    task automatic wait_read_cmd(input integer target);
        integer guard;
        begin
            guard = 0;
            while (guard < 120 && read_cmd_count < target) begin
                @(posedge clk); #1;
                guard = guard + 1;
            end
            if (read_cmd_count != target)
                $fatal(1, "P11 read command timeout");
        end
    endtask

    task automatic respond_from_memory;
        logic [7:0] base_word;
        begin
            base_word = 8'(last_read_line << WORD_SELECT_W);
            @(negedge clk);
            backend_resp_v = 1'b1;
            backend_resp_id = last_read_id;
            backend_resp_line_addr = last_read_line;
            backend_resp_fault = 1'b0;
            for (integer w = 0; w < LINE_WORDS; w = w + 1)
                backend_resp_data[w] = memory[integer'(base_word) + w];
            @(posedge clk); #1;
            @(negedge clk);
            backend_resp_v = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    initial begin : test
        logic [31:0] held_addr;
        logic [31:0] held_data;
        logic held_write;
        integer resp_before;

        clk = 1'b0;
        rst_n = 1'b0;
        backend_cmd_r = 1'b0;
        backend_resp_v = 1'b0;
        backend_resp_id = '0;
        backend_resp_line_addr = '0;
        backend_resp_fault = 1'b0;
        epoch_reuse_safe = 1'b0;
        line_req_v = '0;
        line_req_tag[0] = '0;
        line_req_addr[0] = '0;
        commit_valid[0] = '0;
        commit_mask[0][0] = '0;
        for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
            commit_addr[0][0][lane] = '0;
            commit_wdata[0][0][lane] = '0;
        end
        for (integer w = 0; w < LINE_WORDS; w = w + 1)
            backend_resp_data[w] = '0;
        for (integer m = 0; m < 256; m = m + 1)
            memory[m] = 32'hc000_0000 + 32'(m);

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;

        /* Three lanes collide at word 0x10; lane 3 must win. Lane 1 is unique. */
        @(negedge clk);
        commit_addr[0][0][0] = 32'h0000_0010;
        commit_wdata[0][0][0] = 32'h1111_0000;
        commit_addr[0][0][1] = 32'h0000_0011;
        commit_wdata[0][0][1] = 32'h2222_1111;
        commit_addr[0][0][2] = 32'h0000_0010;
        commit_wdata[0][0][2] = 32'h3333_2222;
        commit_addr[0][0][3] = 32'h0000_0010;
        commit_wdata[0][0][3] = 32'h4444_3333;
        commit_mask[0][0] = 4'b1111;
        commit_valid[0][0] = 1'b1;
        #1;
        if (!duplicate_collapse[0][0])
            $fatal(1, "P11 duplicate collision was not diagnosed");
        $display("PROD_SEAM_P11_DUPLICATE_DETECT=PASS");
        $display("PROD_SEAM_P11_MULTI_COLLISION=PASS");

        /* Backend is stalled: the first canonical beat must remain stable. */
        repeat (20) begin
            @(posedge clk); #1;
            if (backend_cmd_v && backend_cmd_write) break;
        end
        if (!(backend_cmd_v && backend_cmd_write))
            $fatal(1, "P11 first canonical write never appeared");
        held_addr = backend_cmd_word_addr;
        held_data = backend_cmd_wdata;
        held_write = backend_cmd_write;
        repeat (3) begin
            @(posedge clk); #1;
            if (!backend_cmd_v || backend_cmd_write != held_write
                || backend_cmd_word_addr != held_addr
                || backend_cmd_wdata != held_data)
                $fatal(1, "P11 backend command changed under backpressure");
            if (commit_ready[0][0])
                $fatal(1, "P11 commit became ready before visible writes");
        end
        $display("PROD_SEAM_P11_BACKPRESSURE_STABILITY=PASS");

        @(negedge clk); backend_cmd_r = 1'b1;
        wait_commit_accept(1);
        @(negedge clk); commit_valid[0][0] = 1'b0;
        repeat (2) @(posedge clk); #1;

        if (write_count != 2)
            $fatal(1, "P11 duplicate commit emitted wrong number of writes");
        if (write_addr_seen[0] == write_addr_seen[1])
            $fatal(1, "P11 emitted duplicate backend word write");
        $display("PROD_SEAM_P11_SINGLE_WRITE_PER_WORD=PASS");

        if (!((write_addr_seen[0] == 32'h11 && write_data_seen[0] == 32'h2222_1111)
              || (write_addr_seen[1] == 32'h11 && write_data_seen[1] == 32'h2222_1111)))
            $fatal(1, "P11 unrelated lane write was lost");
        $display("PROD_SEAM_P11_UNRELATED_PRESERVED=PASS");

        if (memory[8'h10] != 32'h4444_3333)
            $fatal(1, "P11 highest active lane did not win duplicate word");
        $display("PROD_SEAM_P11_HIGHEST_LANE_WIN=PASS");
        $display("PROD_SEAM_P11_COMMIT_READY_AFTER_CANONICAL_WRITES=PASS");

        /* Refill the line and prove the visible value is the canonical winner. */
        resp_before = line_resp_count;
        issue_line(NETWORK_TAG_W'(2), LINE_ADDR_W'(32'h10 >> WORD_SELECT_W));
        wait_read_cmd(1);
        respond_from_memory();
        if (line_resp_count != resp_before + 1
            || last_resp_tag != NETWORK_TAG_W'(2)
            || last_resp_addr != LINE_ADDR_W'(32'h10 >> WORD_SELECT_W)
            || last_resp_data[0] != 32'h4444_3333
            || last_resp_data[1] != 32'h2222_1111)
            $fatal(1, "P11 post-store refill did not observe canonical values");
        $display("PROD_SEAM_P11_POST_STORE_REFILL_WINNER_VISIBLE=PASS");

        if (protocol_error_count != 0 || protocol_error
            || read_duplicate || read_capacity_full || epoch_wrap_block
            || read_outstanding != '0 || epoch_outstanding != '0)
            $fatal(1, "P11 predecessor protocol state not clean");
        if (next_generation != READ_EPOCH_W'(1))
            $fatal(1, "P11 P10 generation accounting mismatch");
        $display("PROD_SEAM_P11_NO_PREDECESSOR_PROTOCOL_ERROR=PASS");
        $display("PROD_SEAM_P11_BEHAVIOR=PASS");
        $finish;
    end
endmodule
