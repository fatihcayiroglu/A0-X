`timescale 1ns/1ps

module a0_mc_noc_sliced_l2_subsystem_tb #(
    parameter integer CLUSTER_COUNT = 3,
    parameter integer CUS_PER_CLUSTER = 3,
    parameter integer MSHR_COUNT = 3,
    parameter integer LINE_WORDS = 4,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer L2_SET_COUNT_PER_SLICE = 8,
    parameter integer L2_MISS_COUNT_PER_SLICE = 4,
    parameter integer FULL_SCENARIOS = 1
);

    localparam integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS);
    localparam integer LINE_ADDR_W = 32 - WORD_SELECT_W;
    localparam integer CLUSTER_ID_W =
        (CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT);
    localparam integer CU_ID_W =
        (CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER);
    localparam integer LOCAL_TAG_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT);
    localparam integer CLUSTER_LOCAL_TAG_W = CU_ID_W + LOCAL_TAG_W;
    localparam integer NETWORK_TAG_W = CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W;
    localparam integer SLICE_ID_W =
        (L2_SLICE_COUNT <= 1) ? 1 : $clog2(L2_SLICE_COUNT);
    localparam integer SLICE_HASH_SHIFT =
        (L2_SET_COUNT_PER_SLICE <= 1)
            ? 0
            : $clog2(L2_SET_COUNT_PER_SLICE);
    localparam integer CLUSTER_MAX_OUTSTANDING =
        CUS_PER_CLUSTER * MSHR_COUNT;
    localparam integer OWNER_SLOT_W =
        (CLUSTER_MAX_OUTSTANDING <= 1)
            ? 1
            : $clog2(CLUSTER_MAX_OUTSTANDING);

    logic clk;
    logic rst_n;

    logic [CLUSTER_COUNT-1:0] cluster_local_req_valid_i;
    logic [CLUSTER_COUNT-1:0] cluster_local_req_ready_o;
    logic [CLUSTER_LOCAL_TAG_W-1:0]
        cluster_local_req_tag_i [0:CLUSTER_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        cluster_local_req_line_addr_i [0:CLUSTER_COUNT-1];
    logic [CLUSTER_COUNT-1:0] cluster_local_req_tag_error_o;

    logic [CLUSTER_COUNT-1:0] cluster_local_resp_valid_o;
    logic [CLUSTER_COUNT-1:0] cluster_local_resp_ready_i;
    logic [CLUSTER_LOCAL_TAG_W-1:0]
        cluster_local_resp_tag_o [0:CLUSTER_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        cluster_local_resp_line_addr_o [0:CLUSTER_COUNT-1];
    logic cluster_local_resp_fault_o [0:CLUSTER_COUNT-1];
    logic [31:0]
        cluster_local_resp_data_o [0:CLUSTER_COUNT-1][0:LINE_WORDS-1];

    logic [L2_SLICE_COUNT-1:0] line_mem_req_valid_o;
    logic [L2_SLICE_COUNT-1:0] line_mem_req_ready_i;
    logic [NETWORK_TAG_W-1:0]
        line_mem_req_network_tag_o [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o [0:L2_SLICE_COUNT-1];

    logic [L2_SLICE_COUNT-1:0] line_mem_resp_valid_i;
    logic [NETWORK_TAG_W-1:0]
        line_mem_resp_network_tag_i [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i [0:L2_SLICE_COUNT-1];
    logic line_mem_resp_fault_i [0:L2_SLICE_COUNT-1];
    logic [31:0]
        line_mem_resp_data_i [0:L2_SLICE_COUNT-1][0:LINE_WORDS-1];

    logic [CLUSTER_COUNT-1:0] noc_req_tag_error_o;
    logic [L2_SLICE_COUNT-1:0] slice_resp_protocol_error_o;
    logic [CLUSTER_COUNT-1:0] noc_resp_tag_error_o;

    integer local_accept_count [0:CLUSTER_COUNT-1];
    integer local_emit_count [0:CLUSTER_COUNT-1];
    integer backend_req_count [0:L2_SLICE_COUNT-1];
    integer backend_resp_count [0:L2_SLICE_COUNT-1];

    integer monitor_cluster;
    integer monitor_slice;


    a0_mc_noc_sliced_l2_subsystem #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .L2_SET_COUNT_PER_SLICE(L2_SET_COUNT_PER_SLICE),
        .L2_MISS_COUNT_PER_SLICE(L2_MISS_COUNT_PER_SLICE),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .CLUSTER_ID_W(CLUSTER_ID_W),
        .CU_ID_W(CU_ID_W),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLUSTER_LOCAL_TAG_W(CLUSTER_LOCAL_TAG_W),
        .NETWORK_TAG_W(NETWORK_TAG_W),
        .SLICE_ID_W(SLICE_ID_W),
        .CLUSTER_MAX_OUTSTANDING(CLUSTER_MAX_OUTSTANDING),
        .OWNER_SLOT_W(OWNER_SLOT_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_local_req_valid_i(cluster_local_req_valid_i),
        .cluster_local_req_ready_o(cluster_local_req_ready_o),
        .cluster_local_req_tag_i(cluster_local_req_tag_i),
        .cluster_local_req_line_addr_i(cluster_local_req_line_addr_i),
        .cluster_local_req_tag_error_o(cluster_local_req_tag_error_o),
        .cluster_local_resp_valid_o(cluster_local_resp_valid_o),
        .cluster_local_resp_ready_i(cluster_local_resp_ready_i),
        .cluster_local_resp_tag_o(cluster_local_resp_tag_o),
        .cluster_local_resp_line_addr_o(cluster_local_resp_line_addr_o),
        .cluster_local_resp_fault_o(cluster_local_resp_fault_o),
        .cluster_local_resp_data_o(cluster_local_resp_data_o),
        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_network_tag_o(line_mem_req_network_tag_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_network_tag_i(line_mem_resp_network_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i),
        .noc_req_tag_error_o(noc_req_tag_error_o),
        .slice_resp_protocol_error_o(slice_resp_protocol_error_o),
        .noc_resp_tag_error_o(noc_resp_tag_error_o)
    );


    initial clk = 1'b0;
    always #5 clk = ~clk;


    function automatic logic [CLUSTER_LOCAL_TAG_W-1:0] make_local_tag(
        input integer cu_id,
        input integer local_tag
    );
        begin
            make_local_tag = CLUSTER_LOCAL_TAG_W'(
                (cu_id << LOCAL_TAG_W) | local_tag
            );
        end
    endfunction


    function automatic logic [NETWORK_TAG_W-1:0] make_network_tag(
        input integer cluster_id,
        input integer cu_id,
        input integer local_tag
    );
        begin
            make_network_tag = NETWORK_TAG_W'(
                (cluster_id << CLUSTER_LOCAL_TAG_W)
                | (cu_id << LOCAL_TAG_W)
                | local_tag
            );
        end
    endfunction


    function automatic integer network_cluster(
        input logic [NETWORK_TAG_W-1:0] network_tag
    );
        begin
            network_cluster =
                integer'(network_tag) >> CLUSTER_LOCAL_TAG_W;
        end
    endfunction


    function automatic integer home_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        logic [SLICE_ID_W-1:0] low_bits;
        logic [SLICE_ID_W-1:0] high_bits;
        begin
            if (L2_SLICE_COUNT <= 1) begin
                home_slice = 0;
            end else begin
                low_bits = SLICE_ID_W'(line_addr);
                high_bits = SLICE_ID_W'(line_addr >> SLICE_HASH_SHIFT);
                home_slice = integer'({
                    {(32-SLICE_ID_W){1'b0}},
                    (low_bits ^ high_bits)
                });
            end
        end
    endfunction


    function automatic logic [LINE_ADDR_W-1:0] line_for_home(
        input integer wanted_home,
        input integer ordinal
    );
        integer candidate;
        integer seen;
        begin
            line_for_home = '0;
            seen = 0;
            for (candidate = 0; candidate < 4096; candidate = candidate + 1) begin
                if (
                    home_slice(LINE_ADDR_W'(candidate)) == wanted_home
                    && seen == ordinal
                ) begin
                    line_for_home = LINE_ADDR_W'(candidate);
                    seen = seen + 1;
                end else if (
                    home_slice(LINE_ADDR_W'(candidate)) == wanted_home
                    && seen < ordinal
                ) begin
                    seen = seen + 1;
                end
            end
        end
    endfunction


    task automatic clear_inputs;
        integer cluster;
        integer slice;
        integer word_index;
        begin
            cluster_local_req_valid_i = '0;
            cluster_local_resp_ready_i = '1;
            line_mem_req_ready_i = '1;
            line_mem_resp_valid_i = '0;

            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                cluster_local_req_tag_i[cluster] = '0;
                cluster_local_req_line_addr_i[cluster] = '0;
            end

            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                line_mem_resp_network_tag_i[slice] = '0;
                line_mem_resp_line_addr_i[slice] = '0;
                line_mem_resp_fault_i[slice] = 1'b0;
                for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                    line_mem_resp_data_i[slice][word_index] = '0;
                end
            end
        end
    endtask


    task automatic reset_epoch;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            clear_inputs();
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask


    task automatic require_no_diagnostics(input string context_label);
        begin
            if (
                cluster_local_req_tag_error_o != '0
                || noc_req_tag_error_o != '0
                || slice_resp_protocol_error_o != '0
                || noc_resp_tag_error_o != '0
            ) begin
                $fatal(1, "MC-NOC-P3 unexpected diagnostic: %s", context_label);
            end
        end
    endtask


    task automatic drive_local_request(
        input integer cluster,
        input integer cu_id,
        input integer local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        integer guard;
        begin
            @(negedge clk);
            cluster_local_req_tag_i[cluster] = make_local_tag(cu_id, local_tag);
            cluster_local_req_line_addr_i[cluster] = line_addr;
            cluster_local_req_valid_i[cluster] = 1'b1;
            #1;
            guard = 0;
            while (!cluster_local_req_ready_o[cluster]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 80) begin
                    $fatal(1, "MC-NOC-P3 local request timeout cluster=%0d", cluster);
                end
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[cluster] = 1'b0;
            #1;
        end
    endtask


    task automatic wait_backend_stalled(
        input integer slice,
        input logic [LINE_ADDR_W-1:0] expected_line,
        output logic [NETWORK_TAG_W-1:0] captured_tag
    );
        integer guard;
        begin
            guard = 0;
            while (!line_mem_req_valid_o[slice]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100) begin
                    $fatal(1, "MC-NOC-P3 backend request timeout slice=%0d", slice);
                end
            end
            if (line_mem_req_line_addr_o[slice] !== expected_line) begin
                $fatal(1, "MC-NOC-P3 backend line mismatch slice=%0d", slice);
            end
            captured_tag = line_mem_req_network_tag_o[slice];
        end
    endtask


    task automatic release_backend_request(input integer slice);
        begin
            if (slice < 0 || slice >= L2_SLICE_COUNT) begin
                $fatal(1, "MC-NOC-P3 release slice out of range: %0d", slice);
            end
            @(negedge clk);
            line_mem_req_ready_i[slice] = 1'b1;
            #1;
            if (!line_mem_req_valid_o[slice]) begin
                $fatal(1, "MC-NOC-P3 backend request disappeared before handshake");
            end
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic send_backend_response(
        input integer slice,
        input logic [NETWORK_TAG_W-1:0] network_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] seed
    );
        integer word_index;
        begin
            if (slice < 0 || slice >= L2_SLICE_COUNT) begin
                $fatal(1, "MC-NOC-P3 response slice out of range: %0d", slice);
            end
            @(negedge clk);
            line_mem_resp_network_tag_i[slice] = network_tag;
            line_mem_resp_line_addr_i[slice] = line_addr;
            line_mem_resp_fault_i[slice] = fault;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                line_mem_resp_data_i[slice][word_index] = seed + 32'(word_index);
            end
            line_mem_resp_valid_i[slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i[slice] = 1'b0;
            #1;
        end
    endtask


    task automatic wait_local_response(
        input integer cluster,
        input logic [CLUSTER_LOCAL_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line,
        input logic expected_fault,
        input logic [31:0] expected_seed
    );
        integer guard;
        integer word_index;
        begin
            guard = 0;
            while (!cluster_local_resp_valid_o[cluster]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100) begin
                    $fatal(1, "MC-NOC-P3 local response timeout cluster=%0d", cluster);
                end
            end
            if (
                cluster_local_resp_tag_o[cluster] !== expected_tag
                || cluster_local_resp_line_addr_o[cluster] !== expected_line
                || cluster_local_resp_fault_o[cluster] !== expected_fault
            ) begin
                $fatal(1, "MC-NOC-P3 local response metadata mismatch cluster=%0d", cluster);
            end
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                if (
                    cluster_local_resp_data_o[cluster][word_index]
                    !== expected_seed + 32'(word_index)
                ) begin
                    $fatal(1, "MC-NOC-P3 local response data mismatch cluster=%0d", cluster);
                end
            end
        end
    endtask


    task automatic consume_local_response(input integer cluster);
        begin
            if (cluster < 0 || cluster >= CLUSTER_COUNT) begin
                $fatal(1, "MC-NOC-P3 consume cluster out of range: %0d", cluster);
            end
            @(negedge clk);
            cluster_local_resp_ready_i[cluster] = 1'b1;
            #1;
            if (!cluster_local_resp_valid_o[cluster]) begin
                $fatal(1, "MC-NOC-P3 local response disappeared before handshake");
            end
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic run_parameter_smoke;
        integer cluster;
        integer cu_id;
        integer local_tag;
        integer slice;
        logic [LINE_ADDR_W-1:0] line_addr;
        logic [NETWORK_TAG_W-1:0] network_tag;
        begin
            reset_epoch();
            cluster = CLUSTER_COUNT - 1;
            cu_id = CUS_PER_CLUSTER - 1;
            local_tag = (1 << LOCAL_TAG_W) - 1;
            slice = L2_SLICE_COUNT - 1;
            line_addr = line_for_home(slice, 1);
            line_mem_req_ready_i[slice] = 1'b0;
            cluster_local_resp_ready_i[cluster] = 1'b0;

            drive_local_request(cluster, cu_id, local_tag, line_addr);
            wait_backend_stalled(slice, line_addr, network_tag);
            if (network_tag !== make_network_tag(cluster, cu_id, local_tag)) begin
                $fatal(1, "MC-NOC-P3 smoke network tag mismatch");
            end
            release_backend_request(slice);
            send_backend_response(slice, network_tag, line_addr, 1'b1, 32'h5100_0000);
            wait_local_response(
                cluster,
                make_local_tag(cu_id, local_tag),
                line_addr,
                1'b1,
                32'h5100_0000
            );
            require_no_diagnostics("parameter smoke");
            consume_local_response(cluster);
            $display("MC_NOC_P3_PARAMETER_SMOKE=PASS");
        end
    endtask


`ifdef MC_NOC_P3_FULL
    task automatic run_full_scenarios;
        integer guard;
        integer index;
        integer word_index;
        integer slice;
        integer cluster;
        integer total_accepts;
        integer total_emits;
        integer total_backend_requests;
        integer total_backend_responses;
        integer backend_before;
        logic [CLUSTER_COUNT-1:0] seen_clusters;
        logic [CLUSTER_LOCAL_TAG_W-1:0] first_local_tag;
        logic [NETWORK_TAG_W-1:0] tag_a;
        logic [NETWORK_TAG_W-1:0] tag_b;
        logic [NETWORK_TAG_W-1:0] tag_list [0:11];
        logic [LINE_ADDR_W-1:0] line_a;
        logic [LINE_ADDR_W-1:0] line_b;
        logic [LINE_ADDR_W-1:0] line_list [0:11];
        integer cluster_list [0:11];
        integer slice_list [0:11];
        logic [NETWORK_TAG_W-1:0] held_network_tag;
        logic [LINE_ADDR_W-1:0] held_line;
        logic [CLUSTER_LOCAL_TAG_W-1:0] held_local_tag;
        logic held_fault;
        logic [31:0] held_data [0:LINE_WORDS-1];
        begin
            if (
                CLUSTER_COUNT != 3
                || CUS_PER_CLUSTER != 3
                || MSHR_COUNT != 3
                || LINE_WORDS != 4
                || L2_SLICE_COUNT != 4
                || L2_SET_COUNT_PER_SLICE != 8
                || L2_MISS_COUNT_PER_SLICE != 4
            ) begin
                $fatal(1, "MC-NOC-P3 full suite configuration mismatch");
            end

            reset_epoch();
            @(negedge clk);
            rst_n = 1'b0;
            #1;
            if (
                cluster_local_req_ready_o != '0
                || cluster_local_req_tag_error_o != '0
                || cluster_local_resp_valid_o != '0
                || line_mem_req_valid_o != '0
                || noc_req_tag_error_o != '0
                || slice_resp_protocol_error_o != '0
                || noc_resp_tag_error_o != '0
            ) begin
                $fatal(1, "MC-NOC-P3 reset outputs were not gated");
            end
            $display("MC_NOC_P3_01_RESET_OUTPUTS_GATED=PASS");
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            if (
                cluster_local_resp_valid_o != '0
                || line_mem_req_valid_o != '0
            ) begin
                $fatal(1, "MC-NOC-P3 reset release was not empty");
            end
            require_no_diagnostics("reset release");
            $display("MC_NOC_P3_02_RESET_RELEASE_EMPTY=PASS");

            line_a = line_for_home(0, 0);
            line_mem_req_ready_i[0] = 1'b0;
            @(negedge clk);
            cluster_local_req_tag_i[0] = make_local_tag(2, 1);
            cluster_local_req_line_addr_i[0] = line_a;
            cluster_local_req_valid_i[0] = 1'b1;
            #1;
            if (!cluster_local_req_ready_o[0] || line_mem_req_valid_o != '0) begin
                $fatal(1, "MC-NOC-P3 local request bypassed registered path");
            end
            $display("MC_NOC_P3_03_LOCAL_REQUEST_REGISTERED_NO_BYPASS=PASS");
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[0] = 1'b0;
            #1;
            wait_backend_stalled(0, line_a, tag_a);
            if (
                tag_a[NETWORK_TAG_W-1 -: CLUSTER_ID_W]
                !== CLUSTER_ID_W'(0)
            ) begin
                $fatal(1, "MC-NOC-P3 backend tag lacks cluster prefix");
            end
            $display("MC_NOC_P3_04_CLUSTER_PREFIX_ADDED_AT_BACKEND=PASS");
            if (tag_a !== make_network_tag(0, 2, 1)) begin
                $fatal(1, "MC-NOC-P3 backend CU/local tag changed");
            end
            $display("MC_NOC_P3_05_CU_LOCAL_TAG_EXACT_AT_BACKEND=PASS");
            if (home_slice(line_a) != 0) begin
                $fatal(1, "MC-NOC-P3 line/home hash mismatch");
            end
            $display("MC_NOC_P3_06_LINE_AND_HOME_HASH_EXACT=PASS");
            if (line_mem_req_valid_o !== L2_SLICE_COUNT'(1)) begin
                $fatal(1, "MC-NOC-P3 cold miss reached non-home backend");
            end
            $display("MC_NOC_P3_07_COLD_MISS_REACHES_ONLY_HOME_BACKEND=PASS");
            held_network_tag = line_mem_req_network_tag_o[0];
            held_line = line_mem_req_line_addr_o[0];
            repeat (3) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    !line_mem_req_valid_o[0]
                    || line_mem_req_network_tag_o[0] !== held_network_tag
                    || line_mem_req_line_addr_o[0] !== held_line
                ) begin
                    $fatal(1, "MC-NOC-P3 stalled backend request changed");
                end
            end
            $display("MC_NOC_P3_08_BACKEND_REQUEST_STALL_STABLE=PASS");
            release_backend_request(0);
            cluster_local_resp_ready_i[0] = 1'b0;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h1000_0000);
            wait_local_response(0, make_local_tag(2, 1), line_a, 1'b0, 32'h1000_0000);
            consume_local_response(0);

            reset_epoch();
            line_a = line_for_home(0, 2);
            line_b = line_for_home(0, 3);
            line_mem_req_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(0, line_a, tag_a);

            /*
             * Keep the first P3 seam entry stalled while a second request for
             * the same slice advances into the upstream P2/P1 hold.  When the
             * first request handshakes, the seam must dequeue and replace on
             * that exact edge; enqueue wins and the new payload is visible at
             * the backend without an empty cycle.
             */
            drive_local_request(0, 0, 1, line_b);

            repeat (4) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    !line_mem_req_valid_o[0]
                    || line_mem_req_network_tag_o[0] !== tag_a
                    || line_mem_req_line_addr_o[0] !== line_a
                ) begin
                    $fatal(1, "MC-NOC-P3 first turnover payload changed while stalled");
                end
            end

            @(negedge clk);
            line_mem_req_ready_i[0] = 1'b1;
            #1;
            if (
                !line_mem_req_valid_o[0]
                || line_mem_req_network_tag_o[0] !== tag_a
                || line_mem_req_line_addr_o[0] !== line_a
            ) begin
                $fatal(1, "MC-NOC-P3 retiring turnover payload changed");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_req_ready_i[0] = 1'b0;
            #1;

            if (!line_mem_req_valid_o[0]) begin
                $fatal(1, "MC-NOC-P3 seam turnover inserted a backend bubble");
            end
            if (
                line_mem_req_network_tag_o[0]
                    !== make_network_tag(0, 0, 1)
                || line_mem_req_line_addr_o[0] !== line_b
            ) begin
                $fatal(1, "MC-NOC-P3 seam turnover mixed replacement payload");
            end
            tag_b = line_mem_req_network_tag_o[0];
            release_backend_request(0);
            if (tag_a === tag_b) begin
                $fatal(1, "MC-NOC-P3 backend turnover collapsed identities");
            end
            $display("MC_NOC_P3_09_BACKEND_REQUEST_TURNOVER=PASS");
            cluster_local_resp_ready_i[0] = 1'b0;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h1010_0000);
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h1010_0000);
            consume_local_response(0);
            cluster_local_resp_ready_i[0] = 1'b0;
            send_backend_response(0, tag_b, line_b, 1'b0, 32'h1020_0000);
            wait_local_response(0, make_local_tag(0, 1), line_b, 1'b0, 32'h1020_0000);
            consume_local_response(0);

            reset_epoch();
            line_a = line_for_home(2, 4);
            line_mem_req_ready_i[2] = 1'b0;
            cluster_local_resp_ready_i[1] = 1'b0;
            drive_local_request(1, 1, 3, line_a);
            wait_backend_stalled(2, line_a, tag_a);
            if (tag_a !== make_network_tag(1, 1, 3)) begin
                $fatal(1, "MC-NOC-P3 opaque local tag changed");
            end
            release_backend_request(2);
            send_backend_response(2, tag_a, line_a, 1'b0, 32'h1030_0000);
            wait_local_response(1, make_local_tag(1, 3), line_a, 1'b0, 32'h1030_0000);
            consume_local_response(1);
            $display("MC_NOC_P3_10_OPAQUE_UNUSED_LOCAL_TAG_ROUND_TRIP=PASS");

            reset_epoch();
            line_a = line_for_home(0, 5);
            line_b = line_for_home(1, 5);
            line_mem_req_ready_i[0] = 1'b0;
            line_mem_req_ready_i[1] = 1'b0;
            @(negedge clk);
            cluster_local_req_tag_i[0] = make_local_tag(2, 1);
            cluster_local_req_line_addr_i[0] = line_a;
            cluster_local_req_tag_i[1] = make_local_tag(0, 2);
            cluster_local_req_line_addr_i[1] = line_b;
            cluster_local_req_valid_i[0] = 1'b1;
            cluster_local_req_valid_i[1] = 1'b1;
            #1;
            if (!cluster_local_req_ready_o[0] || !cluster_local_req_ready_o[1]) begin
                $fatal(1, "MC-NOC-P3 two-cluster local accepts not concurrent");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i = '0;
            #1;
            guard = 0;
            while (!(line_mem_req_valid_o[0] && line_mem_req_valid_o[1])) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100) begin
                    $fatal(1, "MC-NOC-P3 different-home backend valids did not overlap");
                end
            end
            $display("MC_NOC_P3_11_TWO_CLUSTER_DIFFERENT_HOME_BACKEND_OVERLAP=PASS");
            tag_a = line_mem_req_network_tag_o[0];
            tag_b = line_mem_req_network_tag_o[1];
            if (
                tag_a !== make_network_tag(0, 2, 1)
                || tag_b !== make_network_tag(1, 0, 2)
                || line_mem_req_line_addr_o[0] !== line_a
                || line_mem_req_line_addr_o[1] !== line_b
            ) begin
                $fatal(1, "MC-NOC-P3 overlapping backend identities changed");
            end
            $display("MC_NOC_P3_12_OVERLAP_BACKEND_NETWORK_TAGS_EXACT=PASS");
            @(negedge clk);
            line_mem_req_ready_i[0] = 1'b1;
            line_mem_req_ready_i[1] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cluster_local_resp_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i[1] = 1'b0;
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h1100_0000);
            wait_local_response(1, make_local_tag(0, 2), line_b, 1'b0, 32'h1100_0000);
            if (cluster_local_resp_valid_o[0]) begin
                $fatal(1, "MC-NOC-P3 reverse response leaked to earlier cluster");
            end
            consume_local_response(1);
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h1200_0000);
            wait_local_response(0, make_local_tag(2, 1), line_a, 1'b0, 32'h1200_0000);
            $display("MC_NOC_P3_13_REVERSE_ORDER_CLUSTER_CU_TAG_RESTORE=PASS");
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                if (
                    cluster_local_resp_data_o[0][word_index]
                    !== 32'h1200_0000 + 32'(word_index)
                ) begin
                    $fatal(1, "MC-NOC-P3 reverse response data changed");
                end
            end
            $display("MC_NOC_P3_14_REVERSE_ORDER_LINE_DATA_EXACT=PASS");
            consume_local_response(0);
            require_no_diagnostics("two-cluster reverse order");

            reset_epoch();
            line_a = line_for_home(0, 7);
            line_b = line_for_home(1, 7);
            line_mem_req_ready_i[0] = 1'b0;
            line_mem_req_ready_i[1] = 1'b0;
            fork
                drive_local_request(0, 1, 2, line_a);
                drive_local_request(2, 1, 2, line_b);
            join
            wait_backend_stalled(0, line_a, tag_a);
            wait_backend_stalled(1, line_b, tag_b);
            if (
                tag_a[CLUSTER_LOCAL_TAG_W-1:0]
                    !== tag_b[CLUSTER_LOCAL_TAG_W-1:0]
                || network_cluster(tag_a) == network_cluster(tag_b)
            ) begin
                $fatal(1, "MC-NOC-P3 same suffix was not cluster-distinct");
            end
            release_backend_request(0);
            release_backend_request(1);
            cluster_local_resp_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i[2] = 1'b0;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h1300_0000);
            wait_local_response(0, make_local_tag(1, 2), line_a, 1'b0, 32'h1300_0000);
            consume_local_response(0);
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h1400_0000);
            wait_local_response(2, make_local_tag(1, 2), line_b, 1'b0, 32'h1400_0000);
            consume_local_response(2);
            $display("MC_NOC_P3_15_SAME_SUFFIX_DIFFERENT_CLUSTERS_DISTINCT=PASS");

            reset_epoch();
            line_a = line_for_home(0, 9);
            line_b = line_for_home(1, 9);
            line_mem_req_ready_i[0] = 1'b0;
            line_mem_req_ready_i[1] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            drive_local_request(0, 0, 1, line_b);
            wait_backend_stalled(0, line_a, tag_a);
            wait_backend_stalled(1, line_b, tag_b);
            release_backend_request(0);
            release_backend_request(1);
            cluster_local_resp_ready_i[0] = 1'b0;
            @(negedge clk);
            line_mem_resp_valid_i[0] = 1'b1;
            line_mem_resp_valid_i[1] = 1'b1;
            line_mem_resp_network_tag_i[0] = tag_a;
            line_mem_resp_network_tag_i[1] = tag_b;
            line_mem_resp_line_addr_i[0] = line_a;
            line_mem_resp_line_addr_i[1] = line_b;
            line_mem_resp_fault_i[0] = 1'b0;
            line_mem_resp_fault_i[1] = 1'b0;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                line_mem_resp_data_i[0][word_index] = 32'h1500_0000 + 32'(word_index);
                line_mem_resp_data_i[1][word_index] = 32'h1600_0000 + 32'(word_index);
            end
            #1;
            require_no_diagnostics("same-cluster simultaneous responses");
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            #1;
            $display("MC_NOC_P3_16_SAME_CLUSTER_DIFFERENT_SLICE_SIMULTANEOUS_RESPONSES=PASS");
            guard = 0;
            while (!cluster_local_resp_valid_o[0]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100) $fatal(1, "MC-NOC-P3 first simultaneous response lost");
            end
            first_local_tag = cluster_local_resp_tag_o[0];
            if (first_local_tag === make_local_tag(0, 0)) begin
                wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h1500_0000);
                consume_local_response(0);
                cluster_local_resp_ready_i[0] = 1'b0;
                wait_local_response(0, make_local_tag(0, 1), line_b, 1'b0, 32'h1600_0000);
            end else if (first_local_tag === make_local_tag(0, 1)) begin
                wait_local_response(0, make_local_tag(0, 1), line_b, 1'b0, 32'h1600_0000);
                consume_local_response(0);
                cluster_local_resp_ready_i[0] = 1'b0;
                wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h1500_0000);
            end else begin
                $fatal(1, "MC-NOC-P3 unexpected simultaneous response tag");
            end
            consume_local_response(0);
            $display("MC_NOC_P3_17_SAME_CLUSTER_SIMULTANEOUS_NO_LOSS=PASS");

            reset_epoch();
            line_a = line_for_home(2, 10);
            line_b = line_for_home(3, 10);
            line_mem_req_ready_i[2] = 1'b0;
            line_mem_req_ready_i[3] = 1'b0;
            fork
                drive_local_request(0, 0, 0, line_a);
                drive_local_request(1, 2, 1, line_b);
            join
            wait_backend_stalled(2, line_a, tag_a);
            wait_backend_stalled(3, line_b, tag_b);
            release_backend_request(2);
            release_backend_request(3);
            cluster_local_resp_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i[1] = 1'b0;
            @(negedge clk);
            line_mem_resp_valid_i[2] = 1'b1;
            line_mem_resp_valid_i[3] = 1'b1;
            line_mem_resp_network_tag_i[2] = tag_a;
            line_mem_resp_network_tag_i[3] = tag_b;
            line_mem_resp_line_addr_i[2] = line_a;
            line_mem_resp_line_addr_i[3] = line_b;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                line_mem_resp_data_i[2][word_index] = 32'h1700_0000 + 32'(word_index);
                line_mem_resp_data_i[3][word_index] = 32'h1800_0000 + 32'(word_index);
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            #1;
            guard = 0;
            while (!(cluster_local_resp_valid_o[0] && cluster_local_resp_valid_o[1])) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100) $fatal(1, "MC-NOC-P3 per-cluster outputs did not overlap");
            end
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h1700_0000);
            wait_local_response(1, make_local_tag(2, 1), line_b, 1'b0, 32'h1800_0000);
            $display("MC_NOC_P3_18_DIFFERENT_CLUSTERS_SIMULTANEOUS_LOCAL_OUTPUT=PASS");
            @(negedge clk);
            cluster_local_resp_ready_i[0] = 1'b1;
            cluster_local_resp_ready_i[1] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            line_a = line_for_home(0, 12);
            line_b = line_for_home(1, 12);
            line_mem_req_ready_i[0] = 1'b0;
            line_mem_req_ready_i[1] = 1'b0;
            fork
                drive_local_request(0, 0, 0, line_a);
                drive_local_request(1, 0, 0, line_b);
            join
            wait_backend_stalled(0, line_a, tag_a);
            held_network_tag = tag_a;
            held_line = line_a;
            wait_backend_stalled(1, line_b, tag_b);
            release_backend_request(1);
            cluster_local_resp_ready_i[1] = 1'b0;
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h1900_0000);
            wait_local_response(1, make_local_tag(0, 0), line_b, 1'b0, 32'h1900_0000);
            if (
                !line_mem_req_valid_o[0]
                || line_mem_req_network_tag_o[0] !== held_network_tag
                || line_mem_req_line_addr_o[0] !== held_line
            ) begin
                $fatal(1, "MC-NOC-P3 stalled backend blocked or changed peer");
            end
            consume_local_response(1);
            $display("MC_NOC_P3_19_BACKEND_BACKPRESSURE_ISOLATED_PER_SLICE=PASS");
            release_backend_request(0);
            cluster_local_resp_ready_i[0] = 1'b0;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h1910_0000);
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h1910_0000);
            consume_local_response(0);

            reset_epoch();
            line_a = line_for_home(0, 14);
            line_b = line_for_home(1, 14);
            line_mem_req_ready_i[0] = 1'b0;
            line_mem_req_ready_i[1] = 1'b0;
            fork
                drive_local_request(0, 1, 0, line_a);
                drive_local_request(1, 1, 0, line_b);
            join
            wait_backend_stalled(0, line_a, tag_a);
            wait_backend_stalled(1, line_b, tag_b);
            release_backend_request(0);
            release_backend_request(1);
            cluster_local_resp_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i[1] = 1'b0;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h2000_0000);
            wait_local_response(0, make_local_tag(1, 0), line_a, 1'b0, 32'h2000_0000);
            held_local_tag = cluster_local_resp_tag_o[0];
            held_line = cluster_local_resp_line_addr_o[0];
            held_fault = cluster_local_resp_fault_o[0];
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                held_data[word_index] = cluster_local_resp_data_o[0][word_index];
            end
            repeat (3) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    !cluster_local_resp_valid_o[0]
                    || cluster_local_resp_tag_o[0] !== held_local_tag
                    || cluster_local_resp_line_addr_o[0] !== held_line
                    || cluster_local_resp_fault_o[0] !== held_fault
                ) begin
                    $fatal(1, "MC-NOC-P3 local response changed under backpressure");
                end
                for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                    if (cluster_local_resp_data_o[0][word_index] !== held_data[word_index]) begin
                        $fatal(1, "MC-NOC-P3 stalled local data changed");
                    end
                end
            end
            $display("MC_NOC_P3_20_LOCAL_RESPONSE_BACKPRESSURE_STABLE=PASS");
            cluster_local_resp_ready_i[1] = 1'b1;
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h2100_0000);
            guard = 0;
            while (local_emit_count[1] == 0) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100) $fatal(1, "MC-NOC-P3 ready peer did not progress");
            end
            if (!cluster_local_resp_valid_o[0]) begin
                $fatal(1, "MC-NOC-P3 stalled response vanished during peer progress");
            end
            $display("MC_NOC_P3_21_LOCAL_RESPONSE_BACKPRESSURE_ISOLATED_PER_CLUSTER=PASS");
            backend_before = local_emit_count[0];
            consume_local_response(0);
            repeat (3) @(posedge clk);
            @(negedge clk);
            #1;
            if (local_emit_count[0] != backend_before + 1 || cluster_local_resp_valid_o[0]) begin
                $fatal(1, "MC-NOC-P3 local response was not exactly once");
            end
            $display("MC_NOC_P3_22_LOCAL_RESPONSE_EXACTLY_ONCE=PASS");

            reset_epoch();
            line_mem_req_ready_i[2] = 1'b0;
            for (cluster = 0; cluster < 3; cluster = cluster + 1) begin
                line_list[cluster] = line_for_home(2, 20 + cluster);
            end
            @(negedge clk);
            for (cluster = 0; cluster < 3; cluster = cluster + 1) begin
                cluster_local_req_tag_i[cluster] = make_local_tag(cluster, 0);
                cluster_local_req_line_addr_i[cluster] = line_list[cluster];
                cluster_local_req_valid_i[cluster] = 1'b1;
            end
            #1;
            if (cluster_local_req_ready_o != 3'b111) begin
                $fatal(1, "MC-NOC-P3 same-home contenders did not enter endpoints");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i = '0;
            #1;
            seen_clusters = '0;
            for (index = 0; index < 3; index = index + 1) begin
                guard = 0;
                while (!line_mem_req_valid_o[2]) begin
                    @(negedge clk);
                    #1;
                    guard = guard + 1;
                    if (guard > 100) $fatal(1, "MC-NOC-P3 same-slice contender starved");
                end
                tag_list[index] = line_mem_req_network_tag_o[2];
                cluster_list[index] = network_cluster(tag_list[index]);
                slice_list[index] = 2;
                if (
                    cluster_list[index] < 0
                    || cluster_list[index] >= 3
                    || seen_clusters[cluster_list[index]]
                ) begin
                    $fatal(1, "MC-NOC-P3 same-slice RR repeated/invalid cluster");
                end
                seen_clusters[cluster_list[index]] = 1'b1;
                if (line_mem_req_line_addr_o[2] !== line_list[cluster_list[index]]) begin
                    $fatal(1, "MC-NOC-P3 same-slice line did not follow cluster tag");
                end
                @(negedge clk);
                line_mem_req_ready_i[2] = 1'b1;
                @(posedge clk);
                @(negedge clk);
                line_mem_req_ready_i[2] = 1'b0;
                #1;
            end
            if (seen_clusters != 3'b111) begin
                $fatal(1, "MC-NOC-P3 same-slice RR failed bounded progress");
            end
            $display("MC_NOC_P3_23_SAME_SLICE_CROSS_CLUSTER_RR_PROGRESS=PASS");
            for (index = 2; index >= 0; index = index - 1) begin
                cluster_local_resp_ready_i[cluster_list[index]] = 1'b0;
                send_backend_response(
                    slice_list[index],
                    tag_list[index],
                    line_list[cluster_list[index]],
                    1'b0,
                    32'h2200_0000 + 32'(index * 32)
                );
                wait_local_response(
                    cluster_list[index],
                    make_local_tag(cluster_list[index], 0),
                    line_list[cluster_list[index]],
                    1'b0,
                    32'h2200_0000 + 32'(index * 32)
                );
                consume_local_response(cluster_list[index]);
            end
            $display("MC_NOC_P3_24_SAME_SLICE_REVERSE_ORDER_BACKEND_RESPONSE=PASS");

            reset_epoch();
            line_a = line_for_home(3, 30);
            line_mem_req_ready_i[3] = 1'b0;
            cluster_local_resp_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(3, line_a, tag_a);
            release_backend_request(3);
            send_backend_response(3, tag_a, line_a, 1'b0, 32'h2300_0000);
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h2300_0000);
            consume_local_response(0);
            backend_before = backend_req_count[3];
            line_mem_req_ready_i[3] = 1'b0;
            cluster_local_resp_ready_i[2] = 1'b0;
            drive_local_request(2, 2, 1, line_a);
            wait_local_response(2, make_local_tag(2, 1), line_a, 1'b0, 32'h2300_0000);
            if (network_cluster(tag_a) != 0) begin
                $fatal(1, "MC-NOC-P3 initial shared-line owner was wrong");
            end
            $display("MC_NOC_P3_25_SHARED_L2_CROSS_CLUSTER_HIT=PASS");
            if (backend_req_count[3] != backend_before || line_mem_req_valid_o[3]) begin
                $fatal(1, "MC-NOC-P3 shared L2 hit reached backend");
            end
            $display("MC_NOC_P3_26_SHARED_L2_HIT_SUPPRESSES_BACKEND=PASS");
            consume_local_response(2);

            reset_epoch();
            line_a = line_for_home(1, 32);
            line_mem_req_ready_i[1] = 1'b0;
            cluster_local_resp_ready_i[1] = 1'b0;
            drive_local_request(1, 2, 0, line_a);
            wait_backend_stalled(1, line_a, tag_a);
            release_backend_request(1);
            send_backend_response(1, tag_a, line_a, 1'b1, 32'h2400_0000);
            wait_local_response(1, make_local_tag(2, 0), line_a, 1'b1, 32'h2400_0000);
            consume_local_response(1);
            $display("MC_NOC_P3_27_FAULT_RESPONSE_PRESERVED=PASS");
            line_mem_req_ready_i[1] = 1'b0;
            drive_local_request(1, 2, 1, line_a);
            wait_backend_stalled(1, line_a, tag_b);
            if (tag_b !== make_network_tag(1, 2, 1)) begin
                $fatal(1, "MC-NOC-P3 post-fault miss tag mismatch");
            end
            $display("MC_NOC_P3_28_FAULTED_REFILL_NOT_INSTALLED=PASS");
            release_backend_request(1);
            cluster_local_resp_ready_i[1] = 1'b0;
            send_backend_response(1, tag_b, line_a, 1'b0, 32'h2410_0000);
            wait_local_response(1, make_local_tag(2, 1), line_a, 1'b0, 32'h2410_0000);
            consume_local_response(1);

            reset_epoch();
            line_a = line_for_home(2, 34);
            line_mem_req_ready_i[2] = 1'b0;
            cluster_local_resp_ready_i[0] = 1'b0;
            drive_local_request(0, 1, 0, line_a);
            wait_backend_stalled(2, line_a, tag_a);
            @(negedge clk);
            line_mem_req_ready_i[2] = 1'b1;
            line_mem_resp_valid_i[2] = 1'b1;
            line_mem_resp_network_tag_i[2] = tag_a;
            line_mem_resp_line_addr_i[2] = line_a;
            line_mem_resp_fault_i[2] = 1'b0;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                line_mem_resp_data_i[2][word_index] = 32'h2500_0000 + 32'(word_index);
            end
            #1;
            if (!line_mem_req_valid_o[2]) begin
                $fatal(1, "MC-NOC-P3 same-cycle backend request not present");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i[2] = 1'b0;
            #1;
            wait_local_response(0, make_local_tag(1, 0), line_a, 1'b0, 32'h2500_0000);
            consume_local_response(0);
            $display("MC_NOC_P3_29_SAME_CYCLE_BACKEND_COMPLETION=PASS");

            reset_epoch();
            line_a = line_for_home(0, 36);
            line_b = line_for_home(1, 36);
            line_mem_req_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(0, line_a, tag_a);
            release_backend_request(0);
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h2600_0000);
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h2600_0000);
            line_mem_req_ready_i[1] = 1'b0;
            @(negedge clk);
            cluster_local_resp_ready_i[0] = 1'b1;
            cluster_local_req_tag_i[0] = make_local_tag(0, 0);
            cluster_local_req_line_addr_i[0] = line_b;
            cluster_local_req_valid_i[0] = 1'b1;
            #1;
            if (!cluster_local_resp_valid_o[0] || !cluster_local_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P3 local retire/reuse was not concurrent");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[0] = 1'b0;
            cluster_local_resp_ready_i[0] = 1'b0;
            #1;
            wait_backend_stalled(1, line_b, tag_b);
            if (tag_b !== tag_a) begin
                $fatal(1, "MC-NOC-P3 safe tag reuse changed identity");
            end
            release_backend_request(1);
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h2610_0000);
            wait_local_response(0, make_local_tag(0, 0), line_b, 1'b0, 32'h2610_0000);
            consume_local_response(0);
            $display("MC_NOC_P3_30_SAME_CYCLE_TAG_REUSE_AFTER_LOCAL_RETIRE=PASS");

            reset_epoch();
            line_a = line_for_home(0, 38);
            line_b = line_for_home(1, 38);
            line_mem_req_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(0, line_a, tag_a);
            release_backend_request(0);
            backend_before = 0;
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                backend_before = backend_before + backend_req_count[slice];
            end
            line_mem_req_ready_i[1] = 1'b0;
            drive_local_request(0, 0, 0, line_b);
            repeat (5) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (line_mem_req_valid_o[1]) begin
                    $fatal(1, "MC-NOC-P3 owned duplicate reached backend early");
                end
            end
            total_backend_requests = 0;
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                total_backend_requests = total_backend_requests + backend_req_count[slice];
            end
            if (
                total_backend_requests != backend_before
                || cluster_local_req_tag_error_o[0]
                || noc_req_tag_error_o[0]
            ) begin
                $fatal(1, "MC-NOC-P3 duplicate hold/error policy changed");
            end
            cluster_local_resp_ready_i[0] = 1'b0;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h2700_0000);
            wait_backend_stalled(1, line_b, tag_b);
            consume_local_response(0);
            release_backend_request(1);
            cluster_local_resp_ready_i[0] = 1'b0;
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h2710_0000);
            wait_local_response(0, make_local_tag(0, 0), line_b, 1'b0, 32'h2710_0000);
            consume_local_response(0);
            $display("MC_NOC_P3_31_OWNED_DUPLICATE_HELD_BEFORE_BACKEND=PASS");

            reset_epoch();
            for (index = 0; index < 9; index = index + 1) begin
                slice_list[index] = index % L2_SLICE_COUNT;
                line_list[index] = line_for_home(slice_list[index], 45 + index);
                line_mem_req_ready_i[slice_list[index]] = 1'b0;
                drive_local_request(0, index / 3, index % 3, line_list[index]);
                wait_backend_stalled(slice_list[index], line_list[index], tag_list[index]);
                release_backend_request(slice_list[index]);
            end
            backend_before = 0;
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                backend_before = backend_before + backend_req_count[slice];
            end
            line_a = line_for_home(0, 70);
            drive_local_request(0, 0, 3, line_a);
            line_b = line_for_home(1, 70);
            @(negedge clk);
            cluster_local_req_tag_i[0] = make_local_tag(1, 3);
            cluster_local_req_line_addr_i[0] = line_b;
            cluster_local_req_valid_i[0] = 1'b1;
            repeat (4) begin
                #1;
                if (
                    cluster_local_req_ready_o[0]
                    || cluster_local_req_tag_error_o[0]
                    || noc_req_tag_error_o[0]
                ) begin
                    $fatal(1, "MC-NOC-P3 full owner boundary did not backpressure");
                end
                @(posedge clk);
                @(negedge clk);
            end
            cluster_local_req_valid_i[0] = 1'b0;
            #1;
            total_backend_requests = 0;
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                total_backend_requests = total_backend_requests + backend_req_count[slice];
            end
            if (total_backend_requests != backend_before) begin
                $fatal(1, "MC-NOC-P3 full boundary leaked extra backend request");
            end
            $display("MC_NOC_P3_32_BOUNDARY_BACKPRESSURE_PROPAGATES_NO_LOSS=PASS");

            reset_epoch();
            line_a = line_for_home(0, 75);
            @(negedge clk);
            cluster_local_req_tag_i[0] = make_local_tag(3, 0);
            cluster_local_req_line_addr_i[0] = line_a;
            cluster_local_req_valid_i[0] = 1'b1;
            #1;
            if (
                !cluster_local_req_tag_error_o[0]
                || cluster_local_req_ready_o[0]
                || noc_req_tag_error_o != '0
                || line_mem_req_valid_o != '0
            ) begin
                $fatal(1, "MC-NOC-P3 invalid local CU was not rejected locally");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i = '0;
            #1;
            $display("MC_NOC_P3_33_INVALID_LOCAL_CU_REJECTED=PASS");

            reset_epoch();
            line_a = line_for_home(0, 80);
            @(negedge clk);
            line_mem_resp_valid_i[0] = 1'b1;
            line_mem_resp_network_tag_i[0] = make_network_tag(0, 0, 0);
            line_mem_resp_line_addr_i[0] = line_a;
            #1;
            if (!slice_resp_protocol_error_o[0] || cluster_local_resp_valid_o != '0) begin
                $fatal(1, "MC-NOC-P3 orphan backend response was not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            #1;
            $display("MC_NOC_P3_34_ORPHAN_BACKEND_RESPONSE_REJECTED=PASS");

            reset_epoch();
            line_a = line_for_home(0, 82);
            line_b = line_for_home(0, 83);
            line_mem_req_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(0, line_a, tag_a);
            release_backend_request(0);
            @(negedge clk);
            line_mem_resp_valid_i[0] = 1'b1;
            line_mem_resp_network_tag_i[0] = tag_a;
            line_mem_resp_line_addr_i[0] = line_b;
            #1;
            if (!slice_resp_protocol_error_o[0]) begin
                $fatal(1, "MC-NOC-P3 wrong-line response was not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            cluster_local_resp_ready_i[0] = 1'b0;
            #1;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h2800_0000);
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h2800_0000);
            consume_local_response(0);
            $display("MC_NOC_P3_35_WRONG_LINE_RESPONSE_REJECTED_OWNER_SURVIVES=PASS");

            reset_epoch();
            line_a = line_for_home(0, 85);
            line_mem_req_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(0, line_a, tag_a);
            release_backend_request(0);
            @(negedge clk);
            line_mem_resp_valid_i[1] = 1'b1;
            line_mem_resp_network_tag_i[1] = tag_a;
            line_mem_resp_line_addr_i[1] = line_a;
            #1;
            if (!slice_resp_protocol_error_o[1]) begin
                $fatal(1, "MC-NOC-P3 wrong-home response was not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            cluster_local_resp_ready_i[0] = 1'b0;
            #1;
            send_backend_response(0, tag_a, line_a, 1'b0, 32'h2900_0000);
            wait_local_response(0, make_local_tag(0, 0), line_a, 1'b0, 32'h2900_0000);
            consume_local_response(0);
            $display("MC_NOC_P3_36_WRONG_HOME_RESPONSE_REJECTED_OWNER_SURVIVES=PASS");

            reset_epoch();
            line_a = line_for_home(0, 87);
            @(negedge clk);
            line_mem_resp_valid_i[0] = 1'b1;
            line_mem_resp_network_tag_i[0] = make_network_tag(3, 0, 0);
            line_mem_resp_line_addr_i[0] = line_a;
            #1;
            if (!slice_resp_protocol_error_o[0]) begin
                $fatal(1, "MC-NOC-P3 invalid response cluster not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            line_mem_resp_network_tag_i[0] = make_network_tag(0, 3, 0);
            line_mem_resp_valid_i[0] = 1'b1;
            #1;
            if (!slice_resp_protocol_error_o[0]) begin
                $fatal(1, "MC-NOC-P3 invalid response CU not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            #1;
            $display("MC_NOC_P3_37_INVALID_RESPONSE_CLUSTER_CU_REJECTED=PASS");

            reset_epoch();
            line_a = line_for_home(1, 90);
            line_b = line_for_home(0, 90);
            line_mem_req_ready_i[1] = 1'b0;
            drive_local_request(1, 1, 1, line_a);
            wait_backend_stalled(1, line_a, tag_a);
            release_backend_request(1);
            cluster_local_resp_ready_i[1] = 1'b0;
            @(negedge clk);
            line_mem_resp_valid_i[0] = 1'b1;
            line_mem_resp_network_tag_i[0] = make_network_tag(3, 0, 0);
            line_mem_resp_line_addr_i[0] = line_b;
            line_mem_resp_valid_i[1] = 1'b1;
            line_mem_resp_network_tag_i[1] = tag_a;
            line_mem_resp_line_addr_i[1] = line_a;
            line_mem_resp_fault_i[1] = 1'b0;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                line_mem_resp_data_i[1][word_index] = 32'h3000_0000 + 32'(word_index);
            end
            #1;
            if (
                !slice_resp_protocol_error_o[0]
                || slice_resp_protocol_error_o[1]
            ) begin
                $fatal(1, "MC-NOC-P3 malformed peer diagnostic locality failed");
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            #1;
            wait_local_response(1, make_local_tag(1, 1), line_a, 1'b0, 32'h3000_0000);
            consume_local_response(1);
            $display("MC_NOC_P3_38_MALFORMED_SLICE_PEER_DOES_NOT_BLOCK=PASS");

            reset_epoch();
            line_a = line_for_home(0, 92);
            line_b = line_for_home(1, 92);
            line_mem_req_ready_i[0] = 1'b0;
            line_mem_req_ready_i[1] = 1'b0;
            drive_local_request(0, 0, 0, line_a);
            wait_backend_stalled(0, line_a, tag_a);
            drive_local_request(1, 0, 0, line_b);
            wait_backend_stalled(1, line_b, tag_b);
            release_backend_request(1);
            cluster_local_resp_ready_i[1] = 1'b0;
            send_backend_response(1, tag_b, line_b, 1'b0, 32'h3100_0000);
            wait_local_response(1, make_local_tag(0, 0), line_b, 1'b0, 32'h3100_0000);
            @(negedge clk);
            rst_n = 1'b0;
            #1;
            if (
                line_mem_req_valid_o != '0
                || cluster_local_resp_valid_o != '0
                || cluster_local_req_ready_o != '0
            ) begin
                $fatal(1, "MC-NOC-P3 reset did not gate held/in-flight work");
            end
            clear_inputs();
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            repeat (6) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (line_mem_req_valid_o != '0 || cluster_local_resp_valid_o != '0) begin
                    $fatal(1, "MC-NOC-P3 reset produced phantom traffic");
                end
                require_no_diagnostics("post-reset flush");
            end
            $display("MC_NOC_P3_39_RESET_FLUSHES_IN_FLIGHT_AND_HELD=PASS");

            reset_epoch();
            for (index = 0; index < 6; index = index + 1) begin
                cluster_list[index] = index % 3;
                slice_list[index] = index % 4;
                line_list[index] = line_for_home(slice_list[index], 100 + index);
                line_mem_req_ready_i[slice_list[index]] = 1'b0;
                drive_local_request(
                    cluster_list[index],
                    index % 3,
                    (index / 3),
                    line_list[index]
                );
                wait_backend_stalled(
                    slice_list[index],
                    line_list[index],
                    tag_list[index]
                );
                release_backend_request(slice_list[index]);
                cluster_local_resp_ready_i[cluster_list[index]] = 1'b0;
            end
            for (index = 5; index >= 0; index = index - 1) begin
                send_backend_response(
                    slice_list[index],
                    tag_list[index],
                    line_list[index],
                    1'b0,
                    32'h3200_0000 + 32'(index * 32)
                );
                wait_local_response(
                    cluster_list[index],
                    make_local_tag(index % 3, index / 3),
                    line_list[index],
                    1'b0,
                    32'h3200_0000 + 32'(index * 32)
                );
                consume_local_response(cluster_list[index]);
                cluster_local_resp_ready_i[cluster_list[index]] = 1'b0;
            end
            repeat (8) @(posedge clk);
            @(negedge clk);
            #1;
            total_accepts = 0;
            total_emits = 0;
            total_backend_requests = 0;
            total_backend_responses = 0;
            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                total_accepts = total_accepts + local_accept_count[cluster];
                total_emits = total_emits + local_emit_count[cluster];
            end
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                total_backend_requests = total_backend_requests + backend_req_count[slice];
                total_backend_responses = total_backend_responses + backend_resp_count[slice];
            end
            if (
                total_accepts != 6
                || total_emits != 6
                || total_backend_requests != 6
                || total_backend_responses != 6
                || cluster_local_resp_valid_o != '0
                || line_mem_req_valid_o != '0
            ) begin
                $fatal(1, "MC-NOC-P3 final conservation/drain mismatch");
            end
            require_no_diagnostics("final conservation");
            $display("MC_NOC_P3_40_FINAL_CONSERVATION_DRAIN=PASS");
        end
    endtask
`endif


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (
                monitor_cluster = 0;
                monitor_cluster < CLUSTER_COUNT;
                monitor_cluster = monitor_cluster + 1
            ) begin
                local_accept_count[monitor_cluster] <= 0;
                local_emit_count[monitor_cluster] <= 0;
            end
            for (
                monitor_slice = 0;
                monitor_slice < L2_SLICE_COUNT;
                monitor_slice = monitor_slice + 1
            ) begin
                backend_req_count[monitor_slice] <= 0;
                backend_resp_count[monitor_slice] <= 0;
            end
        end else begin
            for (
                monitor_cluster = 0;
                monitor_cluster < CLUSTER_COUNT;
                monitor_cluster = monitor_cluster + 1
            ) begin
                if (
                    cluster_local_req_valid_i[monitor_cluster]
                    && cluster_local_req_ready_o[monitor_cluster]
                ) begin
                    local_accept_count[monitor_cluster]
                        <= local_accept_count[monitor_cluster] + 1;
                end
                if (
                    cluster_local_resp_valid_o[monitor_cluster]
                    && cluster_local_resp_ready_i[monitor_cluster]
                ) begin
                    local_emit_count[monitor_cluster]
                        <= local_emit_count[monitor_cluster] + 1;
                end
            end
            for (
                monitor_slice = 0;
                monitor_slice < L2_SLICE_COUNT;
                monitor_slice = monitor_slice + 1
            ) begin
                if (
                    line_mem_req_valid_o[monitor_slice]
                    && line_mem_req_ready_i[monitor_slice]
                ) begin
                    backend_req_count[monitor_slice]
                        <= backend_req_count[monitor_slice] + 1;
                end
                if (line_mem_resp_valid_i[monitor_slice]) begin
                    backend_resp_count[monitor_slice]
                        <= backend_resp_count[monitor_slice] + 1;
                end
            end
        end
    end


    initial begin
        rst_n = 1'b0;
        clear_inputs();
        if (FULL_SCENARIOS != 0) begin
`ifdef MC_NOC_P3_FULL
            run_full_scenarios();
`else
            $fatal(1, "MC-NOC-P3 full scenarios requested without compile guard");
`endif
        end else begin
            run_parameter_smoke();
        end
        $finish;
    end

endmodule
