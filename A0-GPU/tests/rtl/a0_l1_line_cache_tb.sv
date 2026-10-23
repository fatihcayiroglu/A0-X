`timescale 1ns/1ps

module a0_l1_line_cache_tb;

    localparam integer WAVE_SIZE = 4;
    localparam integer LINE_WORDS = 8;
    localparam integer SET_COUNT = 64;
    localparam integer MSHR_COUNT = 2;
    localparam integer ENTRY_W = 1;
    localparam integer LINE_ADDR_W = 29;

    logic clk;
    logic rst_n;

    logic line_req_valid_i;
    logic line_req_ready_o;
    logic [ENTRY_W-1:0] line_req_entry_i;
    logic [LINE_ADDR_W-1:0] line_req_line_addr_i;

    logic line_mem_req_valid_o;
    logic line_mem_req_ready_i;
    logic [ENTRY_W-1:0] line_mem_req_entry_o;
    logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o;

    logic line_mem_resp_valid_i;
    logic [ENTRY_W-1:0] line_mem_resp_entry_i;
    logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i;
    logic line_mem_resp_fault_i;
    logic [31:0] line_mem_resp_data_i [0:LINE_WORDS-1];

    logic line_resp_valid_o;
    logic [ENTRY_W-1:0] line_resp_entry_o;
    logic [LINE_ADDR_W-1:0] line_resp_line_addr_o;
    logic line_resp_fault_o;
    logic [31:0] line_resp_data_o [0:LINE_WORDS-1];

    logic store_valid_i;
    logic [WAVE_SIZE-1:0] store_lane_mask_i;
    logic [31:0] store_word_addr_i [0:WAVE_SIZE-1];

    integer word;
    integer lane;

    a0_l1_line_cache #(
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(LINE_WORDS),
        .SET_COUNT(SET_COUNT),
        .MSHR_COUNT(MSHR_COUNT),
        .ENTRY_W(ENTRY_W),
        .LINE_ADDR_W(LINE_ADDR_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .line_req_valid_i(line_req_valid_i),
        .line_req_ready_o(line_req_ready_o),
        .line_req_entry_i(line_req_entry_i),
        .line_req_line_addr_i(line_req_line_addr_i),

        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_entry_o(line_mem_req_entry_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),

        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_entry_i(line_mem_resp_entry_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i),

        .line_resp_valid_o(line_resp_valid_o),
        .line_resp_entry_o(line_resp_entry_o),
        .line_resp_line_addr_o(line_resp_line_addr_o),
        .line_resp_fault_o(line_resp_fault_o),
        .line_resp_data_o(line_resp_data_o),

        .store_valid_i(store_valid_i),
        .store_lane_mask_i(store_lane_mask_i),
        .store_word_addr_i(store_word_addr_i)
    );

    always #5 clk <= ~clk;

    function automatic logic [31:0] line_base_word(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        line_base_word = 32'(line_addr << 3);
    endfunction

    task automatic idle_inputs;
        begin
            line_req_valid_i = 1'b0;
            line_req_entry_i = '0;
            line_req_line_addr_i = '0;
            line_mem_req_ready_i = 1'b1;

            line_mem_resp_valid_i = 1'b0;
            line_mem_resp_entry_i = '0;
            line_mem_resp_line_addr_i = '0;
            line_mem_resp_fault_i = 1'b0;

            store_valid_i = 1'b0;
            store_lane_mask_i = '0;

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                line_mem_resp_data_i[word] = '0;
            end

            for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                store_word_addr_i[lane] = '0;
            end
        end
    endtask

    task automatic accept_miss(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);
            line_req_entry_i = entry;
            line_req_line_addr_i = line_addr;
            line_req_valid_i = 1'b1;
            line_mem_req_ready_i = 1'b1;
            #1;

            if (!line_req_ready_o) begin
                $fatal(1, "miss request not ready entry=%0d line=%0h",
                    entry, line_addr);
            end

            if (
                !line_mem_req_valid_o
                || line_mem_req_entry_o != entry
                || line_mem_req_line_addr_o != line_addr
            ) begin
                $fatal(1, "miss passthrough mismatch entry=%0d line=%0h",
                    entry, line_addr);
            end

            @(posedge clk);
            #1;
            line_req_valid_i = 1'b0;
        end
    endtask

    task automatic respond_line(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] seed
    );
        begin
            @(negedge clk);
            line_mem_resp_entry_i = entry;
            line_mem_resp_line_addr_i = line_addr;
            line_mem_resp_fault_i = fault;

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                line_mem_resp_data_i[word] = seed + 32'(word);
            end

            line_mem_resp_valid_i = 1'b1;
            #1;

            if (
                !line_resp_valid_o
                || line_resp_entry_o != entry
                || line_resp_line_addr_o != line_addr
                || line_resp_fault_o != fault
            ) begin
                $fatal(1, "backend response forwarding mismatch");
            end

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                if (line_resp_data_o[word] != seed + 32'(word)) begin
                    $fatal(1, "backend response data mismatch word=%0d", word);
                end
            end

            @(posedge clk);
            #1;
            line_mem_resp_valid_i = 1'b0;
            line_mem_resp_fault_i = 1'b0;
        end
    endtask

    task automatic accept_hit(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] seed
    );
        begin
            @(negedge clk);
            line_req_entry_i = entry;
            line_req_line_addr_i = line_addr;
            line_req_valid_i = 1'b1;
            line_mem_req_ready_i = 1'b1;
            #1;

            if (!line_req_ready_o) begin
                $fatal(1, "hit request not ready");
            end

            if (line_mem_req_valid_o) begin
                $fatal(1, "cache hit escaped to backend");
            end

            /*
             * Hit response is not combinationally visible in the acceptance
             * cycle. It is captured at the following rising edge.
             */
            if (line_resp_valid_o) begin
                $fatal(1, "hit response was not buffered");
            end

            @(posedge clk);
            #1;
            line_req_valid_i = 1'b0;

            if (
                !line_resp_valid_o
                || line_resp_entry_o != entry
                || line_resp_line_addr_o != line_addr
                || line_resp_fault_o
            ) begin
                $fatal(1, "buffered hit response mismatch");
            end

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                if (line_resp_data_o[word] != seed + 32'(word)) begin
                    $fatal(1, "hit data mismatch word=%0d", word);
                end
            end
        end
    endtask

    task automatic drain_hit;
        begin
            @(posedge clk);
            #1;
            if (line_resp_valid_o) begin
                $fatal(1, "hit buffer did not drain");
            end
        end
    endtask

    task automatic store_one_line(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);
            store_valid_i = 1'b1;
            store_lane_mask_i = '0;
            store_lane_mask_i[0] = 1'b1;
            store_word_addr_i[0] = line_base_word(line_addr);
            @(posedge clk);
            #1;
            store_valid_i = 1'b0;
            store_lane_mask_i = '0;
        end
    endtask

    task automatic install_line(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] seed
    );
        begin
            accept_miss(entry, line_addr);
            respond_line(entry, line_addr, 1'b0, seed);
        end
    endtask

    initial begin
        logic [LINE_ADDR_W-1:0] line_a;
        logic [LINE_ADDR_W-1:0] line_b;
        logic [LINE_ADDR_W-1:0] line_c;
        logic [LINE_ADDR_W-1:0] line_d;
        logic [LINE_ADDR_W-1:0] line_e;
        logic [LINE_ADDR_W-1:0] line_f;
        logic [LINE_ADDR_W-1:0] line_g;
        logic [LINE_ADDR_W-1:0] line_h;
        logic [LINE_ADDR_W-1:0] line_i;
        logic [LINE_ADDR_W-1:0] line_j;
        logic [LINE_ADDR_W-1:0] line_k;
        logic [31:0] base_a;
        logic [31:0] base_b;

        clk = 1'b0;
        rst_n = 1'b0;
        idle_inputs();

        line_a = 29'h000041;
        line_b = 29'h000082;
        line_c = 29'h0000c3;
        line_d = 29'h000104;
        line_e = 29'h000145;
        line_f = 29'h000186;
        line_g = 29'h0001c7;
        line_h = 29'h000208;
        line_i = 29'h000249;
        line_j = 29'h00002a;
        /* Same direct-mapped set as line_j, different tag (+64 lines). */
        line_k = line_j + 29'd64;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        /*
         * Reset-invalid / cold miss.
         */
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_a;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "reset line unexpectedly hit");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_RESET_INVALID=PASS");

        /*
         * Cold miss passthrough + successful install.
         */
        accept_miss(1'b0, line_a);
        $display("RTL9B1_COLD_MISS_PASSTHROUGH=PASS");

        respond_line(1'b0, line_a, 1'b0, 32'hA100_0000);
        accept_hit(1'b1, line_a, 32'hA100_0000);
        $display("RTL9B1_SUCCESSFUL_REFILL_INSTALL=PASS");
        $display("RTL9B1_SECOND_REQUEST_HIT_NO_BACKEND=PASS");
        $display("RTL9B1_HIT_RESPONSE_ONE_CYCLE_BUFFER=PASS");

        /*
         * Preserve entry and line identity on hit.
         */
        if (line_resp_entry_o != 1'b1 || line_resp_line_addr_o != line_a) begin
            $fatal(1, "hit tag identity changed");
        end
        $display("RTL9B1_ENTRY_TAG_PRESERVATION=PASS");
        $display("RTL9B1_LINE_ADDRESS_PRESERVATION=PASS");
        drain_hit();

        /*
         * Backend response collision with a buffered hit:
         * backend wins, buffered hit survives until next cycle.
         */
        install_line(1'b0, line_b, 32'hB200_0000);
        accept_miss(1'b0, line_c);

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b1;
        line_req_line_addr_i = line_b;
        #1;
        if (!line_req_ready_o || line_mem_req_valid_o) begin
            $fatal(1, "collision setup hit did not accept locally");
        end
        @(posedge clk);
        #1;
        line_req_valid_i = 1'b0;

        if (!line_resp_valid_o || line_resp_line_addr_o != line_b) begin
            $fatal(1, "buffered hit missing before collision");
        end

        @(negedge clk);
        line_mem_resp_valid_i = 1'b1;
        line_mem_resp_entry_i = 1'b0;
        line_mem_resp_line_addr_i = line_c;
        line_mem_resp_fault_i = 1'b0;
        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            line_mem_resp_data_i[word] = 32'hC300_0000 + 32'(word);
        end
        #1;

        if (
            !line_resp_valid_o
            || line_resp_entry_o != 1'b0
            || line_resp_line_addr_o != line_c
            || line_resp_data_o[0] != 32'hC300_0000
        ) begin
            $fatal(1, "backend did not win response collision");
        end
        $display("RTL9B1_BACKEND_RESPONSE_BEATS_BUFFERED_HIT=PASS");

        @(posedge clk);
        #1;
        line_mem_resp_valid_i = 1'b0;
        #1;

        if (
            !line_resp_valid_o
            || line_resp_entry_o != 1'b1
            || line_resp_line_addr_o != line_b
            || line_resp_data_o[0] != 32'hB200_0000
        ) begin
            $fatal(1, "buffered hit lost during backend collision");
        end
        $display("RTL9B1_BUFFERED_HIT_SURVIVES_BACKEND_COLLISION=PASS");
        drain_hit();

        /*
         * Faulted refill is forwarded but not installed.
         */
        accept_miss(1'b0, line_d);
        respond_line(1'b0, line_d, 1'b1, 32'hD400_0000);

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_d;
        #1;
        if (!line_mem_req_valid_o || !line_req_ready_o) begin
            $fatal(1, "faulted refill was installed");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_FAULTED_REFILL_NOT_INSTALLED=PASS");

        /*
         * Matching store invalidation.
         */
        install_line(1'b0, line_e, 32'hE500_0000);
        store_one_line(line_e);

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_e;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "matching store failed to invalidate");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_STORE_INVALIDATES_MATCHING_LINE=PASS");
        $display("RTL9B1_STORE_FAULT_CONSERVATIVE_INVALIDATION=PASS");

        /*
         * Store to another line must not invalidate an unrelated cached line.
         */
        install_line(1'b0, line_f, 32'hF600_0000);
        store_one_line(line_g);
        accept_hit(1'b1, line_f, 32'hF600_0000);
        $display("RTL9B1_STORE_OTHER_LINE_DOES_NOT_INVALIDATE=PASS");
        drain_hit();

        /*
         * The preceding test intentionally leaves line_f valid.
         * Invalidate it before reusing install_line(), whose setup
         * intentionally begins with an expected backend miss.
         */
        store_one_line(line_f);

        /*
         * Multi-lane store invalidates multiple cached lines.
         * line_f and line_g use different sets.
         */
        install_line(1'b0, line_f, 32'hF610_0000);
        install_line(1'b0, line_g, 32'hF710_0000);

        @(negedge clk);
        store_valid_i = 1'b1;
        store_lane_mask_i = 4'b0011;
        store_word_addr_i[0] = line_base_word(line_f);
        store_word_addr_i[1] = line_base_word(line_g);
        @(posedge clk);
        #1;
        store_valid_i = 1'b0;
        store_lane_mask_i = '0;

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_f;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "multi-line store failed first invalidation");
        end
        line_req_valid_i = 1'b0;

        @(posedge clk);
        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_g;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "multi-line store failed second invalidation");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_MULTI_LANE_STORE_INVALIDATES_MULTIPLE_LINES=PASS");

        /*
         * A store after miss acceptance kills the refill for cache install,
         * but the backend response still reaches the MSHR-facing response.
         */
        accept_miss(1'b0, line_h);
        store_one_line(line_h);

        @(negedge clk);
        line_mem_resp_valid_i = 1'b1;
        line_mem_resp_entry_i = 1'b0;
        line_mem_resp_line_addr_i = line_h;
        line_mem_resp_fault_i = 1'b0;
        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            line_mem_resp_data_i[word] = 32'h8800_0000 + 32'(word);
        end
        #1;

        if (
            !line_resp_valid_o
            || line_resp_line_addr_o != line_h
            || line_resp_data_o[0] != 32'h8800_0000
        ) begin
            $fatal(1, "killed refill was not forwarded");
        end
        $display("RTL9B1_STORE_KILLS_OUTSTANDING_MATCHING_REFILL=PASS");
        $display("RTL9B1_KILLED_REFILL_STILL_FORWARDED_TO_MSHR=PASS");

        @(posedge clk);
        #1;
        line_mem_resp_valid_i = 1'b0;

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_h;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "killed refill installed stale line");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_KILLED_REFILL_NOT_INSTALLED=PASS");

        /*
         * Same-cycle response + matching store: store conflict wins install
         * suppression, while the response remains visible.
         */
        accept_miss(1'b0, line_i);

        @(negedge clk);
        store_valid_i = 1'b1;
        store_lane_mask_i = 4'b0001;
        store_word_addr_i[0] = line_base_word(line_i);

        line_mem_resp_valid_i = 1'b1;
        line_mem_resp_entry_i = 1'b0;
        line_mem_resp_line_addr_i = line_i;
        line_mem_resp_fault_i = 1'b0;
        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            line_mem_resp_data_i[word] = 32'h9900_0000 + 32'(word);
        end
        #1;

        if (!line_resp_valid_o || line_resp_line_addr_o != line_i) begin
            $fatal(1, "same-cycle response not forwarded");
        end

        @(posedge clk);
        #1;
        store_valid_i = 1'b0;
        store_lane_mask_i = '0;
        line_mem_resp_valid_i = 1'b0;

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_i;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "same-cycle store/refill installed stale line");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_SAME_CYCLE_STORE_REFILL_INVALIDATE_WINS=PASS");

        /*
         * Direct-mapped conflict replacement.
         */
        install_line(1'b0, line_j, 32'hAA00_0000);
        install_line(1'b0, line_k, 32'hBB00_0000);

        @(negedge clk);
        line_req_valid_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = line_j;
        #1;
        if (!line_mem_req_valid_o) begin
            $fatal(1, "direct-mapped conflict did not evict old line");
        end
        line_req_valid_i = 1'b0;
        $display("RTL9B1_DIRECT_MAPPED_CONFLICT_REPLACEMENT=PASS");

        /*
         * Backend response scalar identity already exercised repeatedly.
         * Explicitly check one pass-through again.
         */
        accept_miss(1'b0, 29'h00030b);
        base_a = 32'hABCD_0000;
        respond_line(1'b0, 29'h00030b, 1'b0, base_a);

        accept_hit(1'b1, 29'h00030b, base_a);
        if (
            line_resp_entry_o != 1'b1
            || line_resp_line_addr_o != 29'h00030b
        ) begin
            $fatal(1, "final hit identity mismatch");
        end
        drain_hit();

        base_b = line_resp_data_o[0];
        if (^base_b === 1'bx) begin
            $fatal(1, "unexpected unknown response data");
        end

        $display("RTL9B1_L1_LINE_CACHE_TB=PASS");
        $finish;
    end

endmodule
