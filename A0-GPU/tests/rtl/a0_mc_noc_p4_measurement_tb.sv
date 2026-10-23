`timescale 1ns/1ps

module a0_mc_noc_p4_measurement_tb #(
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

    logic [CLUSTER_COUNT-1:0] noc_req_tag_error_o;
    logic [L2_SLICE_COUNT-1:0] slice_resp_protocol_error_o;
    logic [CLUSTER_COUNT-1:0] noc_resp_tag_error_o;

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
        .noc_req_tag_error_o(noc_req_tag_error_o),
        .slice_resp_protocol_error_o(slice_resp_protocol_error_o),
        .noc_resp_tag_error_o(noc_resp_tag_error_o),
        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_network_tag_o(line_mem_req_network_tag_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_network_tag_i(line_mem_resp_network_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i)
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
            for (candidate = 0; candidate < 16384; candidate = candidate + 1) begin
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


    function automatic logic [LINE_ADDR_W-1:0] line_for_home_avoiding_set(
        input integer wanted_home,
        input integer avoided_set,
        input integer ordinal
    );
        integer candidate;
        integer seen;
        integer candidate_set;
        begin
            line_for_home_avoiding_set = '0;
            seen = 0;
            for (candidate = 0; candidate < 16384; candidate = candidate + 1) begin
                if (L2_SET_COUNT_PER_SLICE <= 1) begin
                    candidate_set = 0;
                end else begin
                    candidate_set = candidate % L2_SET_COUNT_PER_SLICE;
                end
                if (
                    home_slice(LINE_ADDR_W'(candidate)) == wanted_home
                    && candidate_set != avoided_set
                    && seen == ordinal
                ) begin
                    line_for_home_avoiding_set = LINE_ADDR_W'(candidate);
                    seen = seen + 1;
                end else if (
                    home_slice(LINE_ADDR_W'(candidate)) == wanted_home
                    && candidate_set != avoided_set
                    && seen < ordinal
                ) begin
                    seen = seen + 1;
                end
            end
        end
    endfunction


    function automatic integer count_slice_bits(
        input logic [L2_SLICE_COUNT-1:0] value
    );
        integer index;
        begin
            count_slice_bits = 0;
            for (index = 0; index < L2_SLICE_COUNT; index = index + 1) begin
                if (value[index]) begin
                    count_slice_bits = count_slice_bits + 1;
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
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    line_mem_resp_data_i[slice][word_index] = '0;
                end
            end
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
                $fatal(
                    1,
                    "MC-NOC-P4 unexpected diagnostic: %s local=%b noc_req=%b slice_resp=%b noc_resp=%b",
                    context_label,
                    cluster_local_req_tag_error_o,
                    noc_req_tag_error_o,
                    slice_resp_protocol_error_o,
                    noc_resp_tag_error_o
                );
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
            #1;
            if (
                cluster_local_req_ready_o != '0
                || cluster_local_resp_valid_o != '0
                || line_mem_req_valid_o != '0
                || cluster_local_req_tag_error_o != '0
                || noc_req_tag_error_o != '0
                || slice_resp_protocol_error_o != '0
                || noc_resp_tag_error_o != '0
            ) begin
                $fatal(1, "MC-NOC-P4 reset output gating failed");
            end
            rst_n = 1'b1;
            #1;
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
                if (guard > 200) begin
                    $fatal(1, "MC-NOC-P4 local request timeout cluster=%0d", cluster);
                end
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[cluster] = 1'b0;
            #1;
        end
    endtask


    task automatic capture_backend_request(
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
                if (guard > 240) begin
                    $fatal(1, "MC-NOC-P4 backend request timeout slice=%0d", slice);
                end
            end
            if (!line_mem_req_ready_i[slice]) begin
                $fatal(1, "MC-NOC-P4 capture requires ready backend slice=%0d", slice);
            end
            if (line_mem_req_line_addr_o[slice] !== expected_line) begin
                $fatal(1, "MC-NOC-P4 backend request line mismatch slice=%0d", slice);
            end
            captured_tag = line_mem_req_network_tag_o[slice];
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic capture_backend_request_any(
        input integer slice,
        output logic [NETWORK_TAG_W-1:0] captured_tag,
        output logic [LINE_ADDR_W-1:0] captured_line
    );
        integer guard;
        begin
            guard = 0;
            while (!line_mem_req_valid_o[slice]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 240) begin
                    $fatal(1, "MC-NOC-P4 backend-any timeout slice=%0d", slice);
                end
            end
            if (!line_mem_req_ready_i[slice]) begin
                $fatal(1, "MC-NOC-P4 backend-any observed without ready");
            end
            captured_tag = line_mem_req_network_tag_o[slice];
            captured_line = line_mem_req_line_addr_o[slice];
            @(posedge clk);
            @(negedge clk);
            #1;
        end
    endtask


    task automatic pulse_backend_response(
        input integer slice,
        input logic [NETWORK_TAG_W-1:0] network_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] seed
    );
        integer word_index;
        begin
            if (slice < 0 || slice >= L2_SLICE_COUNT) begin
                $fatal(1, "MC-NOC-P4 response slice out of range: %0d", slice);
            end
            @(negedge clk);
            line_mem_resp_network_tag_i[slice] = network_tag;
            line_mem_resp_line_addr_i[slice] = line_addr;
            line_mem_resp_fault_i[slice] = fault;
            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                line_mem_resp_data_i[slice][word_index] =
                    seed + 32'(word_index);
            end
            line_mem_resp_valid_i[slice] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i[slice] = 1'b0;
            #1;
        end
    endtask


    task automatic validate_response_payload(
        input integer cluster,
        input logic [CLUSTER_LOCAL_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line,
        input logic expected_fault,
        input logic [31:0] expected_seed
    );
        integer word_index;
        begin
            if (
                cluster_local_resp_tag_o[cluster] !== expected_tag
                || cluster_local_resp_line_addr_o[cluster] !== expected_line
                || cluster_local_resp_fault_o[cluster] !== expected_fault
            ) begin
                $fatal(1, "MC-NOC-P4 local response metadata mismatch cluster=%0d", cluster);
            end
            for (
                word_index = 0;
                word_index < LINE_WORDS;
                word_index = word_index + 1
            ) begin
                if (
                    cluster_local_resp_data_o[cluster][word_index]
                    !== expected_seed + 32'(word_index)
                ) begin
                    $fatal(1, "MC-NOC-P4 local response data mismatch cluster=%0d", cluster);
                end
            end
        end
    endtask


    task automatic wait_and_consume_response(
        input integer cluster,
        input logic [CLUSTER_LOCAL_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_line,
        input logic expected_fault,
        input logic [31:0] expected_seed
    );
        integer guard;
        begin
            guard = 0;
            while (!cluster_local_resp_valid_o[cluster]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 240) begin
                    $fatal(1, "MC-NOC-P4 local response timeout cluster=%0d", cluster);
                end
            end
            validate_response_payload(
                cluster,
                expected_tag,
                expected_line,
                expected_fault,
                expected_seed
            );
            cluster_local_resp_ready_i[cluster] = 1'b1;
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
            line_addr = line_for_home(slice, 3);
            cluster_local_resp_ready_i[cluster] = 1'b0;

            drive_local_request(cluster, cu_id, local_tag, line_addr);
            capture_backend_request(slice, line_addr, network_tag);
            if (network_tag !== make_network_tag(cluster, cu_id, local_tag)) begin
                $fatal(1, "MC-NOC-P4 smoke network tag mismatch");
            end
            pulse_backend_response(
                slice,
                network_tag,
                line_addr,
                1'b1,
                32'h4a00_0000
            );
            wait_and_consume_response(
                cluster,
                make_local_tag(cu_id, local_tag),
                line_addr,
                1'b1,
                32'h4a00_0000
            );
            require_no_diagnostics("parameter smoke");
            $display("MC_NOC_P4_PARAMETER_SMOKE=PASS");
        end
    endtask


`ifdef MC_NOC_P4_FULL
    task automatic run_full_scenarios;
        integer cluster;
        integer slice;
        integer index;
        integer round;
        integer opportunity;
        integer guard;
        integer active_count;
        integer expected_rate;
        integer local_index;
        integer response_count;
        integer found_index;
        integer word_index;
        integer warm_set;
        integer hotspot_peak;
        integer balanced_peak;
        integer requests_per_cluster;
        integer service_target;
        integer service_count;
        integer stall_cycles;
        integer request_count [0:CLUSTER_COUNT-1];
        integer service_sequence [0:31];
        logic [CLUSTER_COUNT-1:0] request_accept_mask;
        logic stall_complete;
        logic [CLUSTER_COUNT-1:0] seen_clusters;
        logic [63:0] seen_responses;
        logic [NETWORK_TAG_W-1:0] tags [0:63];
        logic [LINE_ADDR_W-1:0] lines [0:63];
        logic [31:0] seeds [0:63];
        integer clusters [0:63];
        logic [NETWORK_TAG_W-1:0] held_tag;
        logic [LINE_ADDR_W-1:0] held_line;
        logic [31:0] held_data [0:LINE_WORDS-1];
        logic [LINE_ADDR_W-1:0] warm_line;
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
                $fatal(1, "MC-NOC-P4 full suite configuration mismatch");
            end

            hotspot_peak = 0;
            balanced_peak = 0;

            /* 01: reset and one exact miss/refill/response conservation path. */
            reset_epoch();
            lines[0] = line_for_home(0, 20);
            cluster_local_resp_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, lines[0]);
            capture_backend_request(0, lines[0], tags[0]);
            if (tags[0] !== make_network_tag(0, 0, 0)) begin
                $fatal(1, "MC-NOC-P4 basic network tag mismatch");
            end
            pulse_backend_response(0, tags[0], lines[0], 1'b0, 32'h4100_0000);
            wait_and_consume_response(
                0,
                make_local_tag(0, 0),
                lines[0],
                1'b0,
                32'h4100_0000
            );
            require_no_diagnostics("basic conservation");
            $display("MC_NOC_P4_01_RESET_TURNOVER_CONSERVATION=PASS");

            /* 02: continuously refilled same-home contenders, opportunity bound. */
            reset_epoch();
            requests_per_cluster = 3;
            service_target = 2 * CLUSTER_COUNT;
            service_count = 0;
            stall_cycles = 0;
            stall_complete = 1'b0;
            line_mem_req_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i = '1;
            @(negedge clk);
            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                request_count[cluster] = 0;
                cluster_local_req_valid_i[cluster] = 1'b1;
                cluster_local_req_tag_i[cluster] = make_local_tag(0, 0);
                cluster_local_req_line_addr_i[cluster] =
                    line_for_home(0, 60 + cluster*16);
            end
            guard = 0;
            while (service_count < service_target) begin
                #1;
                request_accept_mask =
                    cluster_local_req_valid_i & cluster_local_req_ready_o;
                line_mem_resp_valid_i[0] = 1'b0;
                if (!stall_complete && line_mem_req_valid_o[0]) begin
                    if (stall_cycles == 0) begin
                        held_tag = line_mem_req_network_tag_o[0];
                        held_line = line_mem_req_line_addr_o[0];
                    end else if (
                        line_mem_req_network_tag_o[0] !== held_tag
                        || line_mem_req_line_addr_o[0] !== held_line
                    ) begin
                        $fatal(1, "MC-NOC-P4 ready-low opportunity changed payload");
                    end
                    stall_cycles = stall_cycles + 1;
                end
                if (line_mem_req_valid_o[0] && line_mem_req_ready_i[0]) begin
                    cluster = network_cluster(line_mem_req_network_tag_o[0]);
                    if (cluster < 0 || cluster >= CLUSTER_COUNT) begin
                        $fatal(1, "MC-NOC-P4 sustained RR returned invalid cluster");
                    end
                    local_index = integer'(
                        line_mem_req_network_tag_o[0][LOCAL_TAG_W-1:0]
                    );
                    if (
                        line_mem_req_line_addr_o[0]
                        !== line_for_home(0, 60 + cluster*16 + local_index)
                    ) begin
                        $fatal(1, "MC-NOC-P4 sustained RR payload association failed");
                    end
                    service_sequence[service_count] = cluster;
                    line_mem_resp_valid_i[0] = 1'b1;
                    line_mem_resp_network_tag_i[0] =
                        line_mem_req_network_tag_o[0];
                    line_mem_resp_line_addr_i[0] =
                        line_mem_req_line_addr_o[0];
                    line_mem_resp_fault_i[0] = 1'b0;
                    for (
                        word_index = 0;
                        word_index < LINE_WORDS;
                        word_index = word_index + 1
                    ) begin
                        line_mem_resp_data_i[0][word_index] =
                            32'h4200_0000
                            + 32'(service_count * 32 + word_index);
                    end
                    service_count = service_count + 1;
                end
                @(posedge clk);
                @(negedge clk);
                line_mem_resp_valid_i[0] = 1'b0;
                if (!stall_complete && stall_cycles >= 2) begin
                    stall_complete = 1'b1;
                    line_mem_req_ready_i[0] = 1'b1;
                end
                for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                    if (request_accept_mask[cluster]) begin
                        request_count[cluster] = request_count[cluster] + 1;
                        if (request_count[cluster] < requests_per_cluster) begin
                            cluster_local_req_tag_i[cluster] = make_local_tag(
                                0,
                                request_count[cluster]
                            );
                            cluster_local_req_line_addr_i[cluster] = line_for_home(
                                0,
                                60 + cluster*16 + request_count[cluster]
                            );
                        end else begin
                            cluster_local_req_valid_i[cluster] = 1'b0;
                        end
                    end
                end
                guard = guard + 1;
                if (guard > 240) begin
                    $fatal(1, "MC-NOC-P4 sustained RR service timeout");
                end
            end
            cluster_local_req_valid_i = '0;
            line_mem_resp_valid_i[0] = 1'b0;
            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                if (request_count[cluster] != requests_per_cluster) begin
                    $fatal(
                        1,
                        "MC-NOC-P4 sustained source lost continuous eligibility"
                    );
                end
            end
            if (stall_cycles < 2) begin
                $fatal(1, "MC-NOC-P4 ready-low gap was not exercised");
            end
            for (
                round = 0;
                round <= service_target - CLUSTER_COUNT;
                round = round + 1
            ) begin
                seen_clusters = '0;
                for (
                    opportunity = 0;
                    opportunity < CLUSTER_COUNT;
                    opportunity = opportunity + 1
                ) begin
                    cluster = service_sequence[round + opportunity];
                    seen_clusters[cluster] = 1'b1;
                end
                if (seen_clusters != '1) begin
                    $fatal(
                        1,
                        "MC-NOC-P4 rolling K service-opportunity bound failed"
                    );
                end
            end
            for (
                opportunity = 0;
                opportunity < service_target;
                opportunity = opportunity + 1
            ) begin
                if (
                    service_sequence[opportunity]
                    != opportunity % CLUSTER_COUNT
                ) begin
                    $fatal(1, "MC-NOC-P4 sustained RR prefix sequence changed");
                end
            end
            #1;
            hotspot_peak = 1;
            require_no_diagnostics("same-home RR");
            $display("MC_NOC_P4_02_SUSTAINED_SAME_HOME_RR_OPPORTUNITY_BOUND=PASS");

            /* 03: balanced homes reach min(K,S) on one backend opportunity. */
            reset_epoch();
            expected_rate =
                (CLUSTER_COUNT < L2_SLICE_COUNT)
                    ? CLUSTER_COUNT
                    : L2_SLICE_COUNT;
            @(negedge clk);
            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                lines[cluster] = line_for_home(cluster, 100 + cluster);
                cluster_local_req_tag_i[cluster] = make_local_tag(0, 0);
                cluster_local_req_line_addr_i[cluster] = lines[cluster];
                cluster_local_req_valid_i[cluster] = 1'b1;
                cluster_local_resp_ready_i[cluster] = 1'b0;
            end
            #1;
            if (cluster_local_req_ready_o != '1) begin
                $fatal(1, "MC-NOC-P4 balanced ingress failed");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i = '0;
            #1;
            guard = 0;
            active_count = count_slice_bits(
                line_mem_req_valid_o & line_mem_req_ready_i
            );
            while (active_count != expected_rate) begin
                @(negedge clk);
                #1;
                active_count = count_slice_bits(
                    line_mem_req_valid_o & line_mem_req_ready_i
                );
                guard = guard + 1;
                if (guard > 40) begin
                    $fatal(1, "MC-NOC-P4 balanced throughput not reached");
                end
            end
            balanced_peak = active_count;
            for (slice = 0; slice < expected_rate; slice = slice + 1) begin
                if (
                    line_mem_req_network_tag_o[slice]
                    !== make_network_tag(slice, 0, 0)
                    || line_mem_req_line_addr_o[slice] !== lines[slice]
                ) begin
                    $fatal(1, "MC-NOC-P4 balanced association mismatch");
                end
                tags[slice] = line_mem_req_network_tag_o[slice];
            end
            @(posedge clk);
            @(negedge clk);
            for (slice = 0; slice < expected_rate; slice = slice + 1) begin
                line_mem_resp_valid_i[slice] = 1'b1;
                line_mem_resp_network_tag_i[slice] = tags[slice];
                line_mem_resp_line_addr_i[slice] = lines[slice];
                line_mem_resp_fault_i[slice] = 1'b0;
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    line_mem_resp_data_i[slice][word_index] =
                        32'h4300_0000 + 32'(slice * 32 + word_index);
                end
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            #1;
            for (cluster = 0; cluster < expected_rate; cluster = cluster + 1) begin
                wait_and_consume_response(
                    cluster,
                    make_local_tag(0, 0),
                    lines[cluster],
                    1'b0,
                    32'h4300_0000 + 32'(cluster * 32)
                );
            end
            $display("MC_NOC_P4_03_BALANCED_DISTINCT_HOME_MIN_K_S_THROUGHPUT=PASS");

            /* 04/05: fill P3, P1, and P0; downstream ready turns all over. */
            reset_epoch();
            line_mem_req_ready_i[0] = 1'b0;
            for (index = 0; index < 3; index = index + 1) begin
                lines[index] = line_for_home(0, 150 + index);
                drive_local_request(0, 0, index, lines[index]);
            end
            lines[3] = line_for_home(0, 153);
            @(negedge clk);
            cluster_local_req_tag_i[0] = make_local_tag(0, 3);
            cluster_local_req_line_addr_i[0] = lines[3];
            cluster_local_req_valid_i[0] = 1'b1;
            #1;
            if (cluster_local_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P4 full ready chain was not blocked");
            end
            guard = 0;
            while (!line_mem_req_valid_o[0]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 40) begin
                    $fatal(1, "MC-NOC-P4 full-chain backend head missing");
                end
            end
            held_tag = line_mem_req_network_tag_o[0];
            held_line = line_mem_req_line_addr_o[0];
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                held_data[word_index] = line_mem_resp_data_i[0][word_index];
            end
            repeat (3) begin
                @(negedge clk);
                #1;
                if (
                    cluster_local_req_ready_o[0]
                    || !line_mem_req_valid_o[0]
                    || line_mem_req_network_tag_o[0] !== held_tag
                    || line_mem_req_line_addr_o[0] !== held_line
                ) begin
                    $fatal(1, "MC-NOC-P4 stalled full-chain payload changed");
                end
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    if (line_mem_resp_data_i[0][word_index] !== held_data[word_index]) begin
                        $fatal(1, "MC-NOC-P4 unrelated response input changed");
                    end
                end
            end
            line_mem_req_ready_i[0] = 1'b1;
            #1;
            if (!cluster_local_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P4 full ready chain lacked same-cycle sensitivity");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[0] = 1'b0;
            #1;
            $display("MC_NOC_P4_04_FULL_HOLD_READY_SENSITIVITY=PASS");
            $display("MC_NOC_P4_05_FULL_HOLD_PAYLOAD_STABILITY=PASS");

            /* 06/07: a filled hot path blocks its scalar head, not another cluster. */
            reset_epoch();
            line_mem_req_ready_i[0] = 1'b0;
            for (index = 0; index < 3; index = index + 1) begin
                lines[index] = line_for_home(0, 180 + index);
                drive_local_request(0, 0, index, lines[index]);
            end
            lines[3] = line_for_home(1, 180);
            lines[4] = line_for_home(1, 181);
            @(negedge clk);
            cluster_local_req_tag_i[0] = make_local_tag(0, 3);
            cluster_local_req_line_addr_i[0] = lines[3];
            cluster_local_req_valid_i[0] = 1'b1;
            cluster_local_req_tag_i[1] = make_local_tag(0, 0);
            cluster_local_req_line_addr_i[1] = lines[4];
            cluster_local_req_valid_i[1] = 1'b1;
            #1;
            if (cluster_local_req_ready_o[0]) begin
                $fatal(1, "MC-NOC-P4 scalar HOL request unexpectedly accepted");
            end
            if (!cluster_local_req_ready_o[1]) begin
                $fatal(1, "MC-NOC-P4 independent cluster failed during HOL");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[1] = 1'b0;
            #1;
            capture_backend_request(1, lines[4], tags[4]);
            if (network_cluster(tags[4]) != 1) begin
                $fatal(1, "MC-NOC-P4 HOL isolation routed wrong cluster");
            end
            line_mem_req_ready_i[0] = 1'b1;
            guard = 0;
            while (!cluster_local_req_ready_o[0]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 40) begin
                    $fatal(1, "MC-NOC-P4 scalar HOL did not release");
                end
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i[0] = 1'b0;
            #1;
            capture_backend_request(1, lines[3], tags[3]);
            if (network_cluster(tags[3]) != 0) begin
                $fatal(1, "MC-NOC-P4 released HOL request routed wrong cluster");
            end
            $display("MC_NOC_P4_06_SCALAR_REQUEST_HOL_CHARACTERIZED=PASS");
            $display("MC_NOC_P4_07_OTHER_CLUSTER_HOL_ISOLATION=PASS");

            /* 08/09: O owner responses plus one P0 response hold, then drain. */
            reset_epoch();
            cluster_local_resp_ready_i[0] = 1'b0;
            for (
                index = 0;
                index < CLUSTER_MAX_OUTSTANDING + 1;
                index = index + 1
            ) begin
                cluster = index >> LOCAL_TAG_W;
                local_index = index & ((1 << LOCAL_TAG_W) - 1);
                slice = index % L2_SLICE_COUNT;
                lines[index] = line_for_home(slice, 230 + index);
                seeds[index] = 32'h4800_0000 + 32'(index * 32);
                clusters[index] = cluster;
                drive_local_request(0, cluster, local_index, lines[index]);
                capture_backend_request(slice, lines[index], tags[index]);
                if (tags[index] !== make_network_tag(0, cluster, local_index)) begin
                    $fatal(1, "MC-NOC-P4 O+1 tag mismatch index=%0d", index);
                end
                pulse_backend_response(
                    slice,
                    tags[index],
                    lines[index],
                    1'b0,
                    seeds[index]
                );
            end
            repeat (4) @(posedge clk);
            @(negedge clk);
            #1;
            if (!cluster_local_resp_valid_o[0]) begin
                $fatal(1, "MC-NOC-P4 O+1 response boundary did not retain output");
            end
            $display("MC_NOC_P4_08_LOCAL_RESPONSE_STALL_O_PLUS_ONE_BOUNDARY=PASS");

            seen_responses = '0;
            local_index = integer'(cluster_local_resp_tag_o[0]);
            if (
                local_index < 0
                || local_index >= CLUSTER_MAX_OUTSTANDING + 1
            ) begin
                $fatal(1, "MC-NOC-P4 first O+1 response out of range");
            end
            validate_response_payload(
                0,
                CLUSTER_LOCAL_TAG_W'(local_index),
                lines[local_index],
                1'b0,
                seeds[local_index]
            );
            seen_responses[local_index] = 1'b1;
            response_count = 1;
            guard = 0;
            cluster_local_resp_ready_i[0] = 1'b1;
            while (response_count < CLUSTER_MAX_OUTSTANDING + 1) begin
                @(negedge clk);
                #1;
                if (cluster_local_resp_valid_o[0]) begin
                    local_index = integer'(cluster_local_resp_tag_o[0]);
                    if (
                        local_index < 0
                        || local_index >= CLUSTER_MAX_OUTSTANDING + 1
                        || seen_responses[local_index]
                    ) begin
                        $fatal(1, "MC-NOC-P4 O+1 duplicate/out-of-range response");
                    end
                    validate_response_payload(
                        0,
                        CLUSTER_LOCAL_TAG_W'(local_index),
                        lines[local_index],
                        1'b0,
                        seeds[local_index]
                    );
                    seen_responses[local_index] = 1'b1;
                    response_count = response_count + 1;
                end
                guard = guard + 1;
                if (guard > 300) begin
                    $fatal(1, "MC-NOC-P4 O+1 response drain timeout");
                end
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (seen_responses[CLUSTER_MAX_OUTSTANDING:0] != '1) begin
                $fatal(1, "MC-NOC-P4 O+1 response conservation failed");
            end
            $display("MC_NOC_P4_09_LOCAL_RESPONSE_LOSSLESS_DRAIN=PASS");

            /* 10: all slices return in one no-ready response opportunity. */
            reset_epoch();
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                cluster = slice % CLUSTER_COUNT;
                local_index = slice / CLUSTER_COUNT;
                lines[slice] = line_for_home(slice, 300 + slice);
                seeds[slice] = 32'h4a00_0000 + 32'(slice * 32);
                clusters[slice] = cluster;
                cluster_local_resp_ready_i[cluster] = 1'b0;
                drive_local_request(cluster, 0, local_index, lines[slice]);
                capture_backend_request(slice, lines[slice], tags[slice]);
            end
            @(negedge clk);
            for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                line_mem_resp_valid_i[slice] = 1'b1;
                line_mem_resp_network_tag_i[slice] = tags[slice];
                line_mem_resp_line_addr_i[slice] = lines[slice];
                line_mem_resp_fault_i[slice] = 1'b0;
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    line_mem_resp_data_i[slice][word_index] =
                        seeds[slice] + 32'(word_index);
                end
            end
            @(posedge clk);
            @(negedge clk);
            line_mem_resp_valid_i = '0;
            cluster_local_resp_ready_i = '1;
            #1;
            seen_responses = '0;
            response_count = 0;
            guard = 0;
            while (response_count < L2_SLICE_COUNT) begin
                @(negedge clk);
                #1;
                for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                    if (cluster_local_resp_valid_o[cluster]) begin
                        found_index = -1;
                        for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
                            if (
                                !seen_responses[slice]
                                && clusters[slice] == cluster
                                && cluster_local_resp_tag_o[cluster]
                                    == make_local_tag(0, slice / CLUSTER_COUNT)
                            ) begin
                                found_index = slice;
                            end
                        end
                        if (found_index < 0) begin
                            $fatal(1, "MC-NOC-P4 simultaneous response unmatched");
                        end
                        validate_response_payload(
                            cluster,
                            make_local_tag(0, found_index / CLUSTER_COUNT),
                            lines[found_index],
                            1'b0,
                            seeds[found_index]
                        );
                        seen_responses[found_index] = 1'b1;
                        response_count = response_count + 1;
                    end
                end
                guard = guard + 1;
                if (guard > 200) begin
                    $fatal(1, "MC-NOC-P4 simultaneous response drain timeout");
                end
            end
            $display("MC_NOC_P4_10_SIMULTANEOUS_SLICE_RESPONSES=PASS");

            /* 11/12: fill Q miss slots at one home; another slice remains live. */
            reset_epoch();
            for (
                index = 0;
                index < L2_MISS_COUNT_PER_SLICE;
                index = index + 1
            ) begin
                lines[index] = line_for_home(0, 350 + index);
                drive_local_request(0, 0, index, lines[index]);
                capture_backend_request(0, lines[index], tags[index]);
            end
            lines[L2_MISS_COUNT_PER_SLICE] = line_for_home(
                0,
                350 + L2_MISS_COUNT_PER_SLICE
            );
            drive_local_request(
                0,
                1,
                0,
                lines[L2_MISS_COUNT_PER_SLICE]
            );
            repeat (8) begin
                @(negedge clk);
                #1;
                if (line_mem_req_valid_o[0]) begin
                    $fatal(1, "MC-NOC-P4 Q+1 miss reached saturated backend");
                end
            end
            lines[16] = line_for_home(1, 350);
            drive_local_request(1, 0, 0, lines[16]);
            capture_backend_request(1, lines[16], tags[16]);
            if (network_cluster(tags[16]) != 1) begin
                $fatal(1, "MC-NOC-P4 Q isolation routed wrong cluster");
            end
            $display("MC_NOC_P4_11_MISS_Q_SATURATION=PASS");
            $display("MC_NOC_P4_12_MISS_Q_SLICE_ISOLATION=PASS");

            if (balanced_peak != expected_rate) begin
                $fatal(1, "MC-NOC-P4 balanced hash measurement changed");
            end
            if (hotspot_peak != 1) begin
                $fatal(1, "MC-NOC-P4 hotspot measurement changed");
            end
            $display("MC_NOC_P4_13_HASH_BALANCED_MAPPING=PASS");
            $display("MC_NOC_P4_14_HASH_HOTSPOT_CHARACTERIZED=PASS");

            /* 15: continuous backend responses postpone an already-warm hit. */
            reset_epoch();
            warm_line = line_for_home(0, 0);
            warm_set = integer'(warm_line) % L2_SET_COUNT_PER_SLICE;
            cluster_local_resp_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 0, warm_line);
            capture_backend_request(0, warm_line, tags[0]);
            pulse_backend_response(0, tags[0], warm_line, 1'b0, 32'h4d00_0000);
            wait_and_consume_response(
                0,
                make_local_tag(0, 0),
                warm_line,
                1'b0,
                32'h4d00_0000
            );
            cluster_local_resp_ready_i[1] = 1'b1;
            for (
                index = 0;
                index < L2_MISS_COUNT_PER_SLICE;
                index = index + 1
            ) begin
                lines[index] = line_for_home_avoiding_set(
                    0,
                    warm_set,
                    20 + index
                );
                drive_local_request(1, 0, index, lines[index]);
                capture_backend_request(0, lines[index], tags[index]);
                seeds[index] = 32'h4e00_0000 + 32'(index * 32);
            end
            cluster_local_resp_ready_i[0] = 1'b0;
            drive_local_request(0, 0, 1, warm_line);
            for (
                index = 0;
                index < L2_MISS_COUNT_PER_SLICE;
                index = index + 1
            ) begin
                @(negedge clk);
                line_mem_resp_valid_i[0] = 1'b1;
                line_mem_resp_network_tag_i[0] = tags[index];
                line_mem_resp_line_addr_i[0] = lines[index];
                line_mem_resp_fault_i[0] = 1'b0;
                for (
                    word_index = 0;
                    word_index < LINE_WORDS;
                    word_index = word_index + 1
                ) begin
                    line_mem_resp_data_i[0][word_index] =
                        seeds[index] + 32'(word_index);
                end
                @(posedge clk);
                @(negedge clk);
                #1;
                if (cluster_local_resp_valid_o[0]) begin
                    $fatal(1, "MC-NOC-P4 hit escaped during backend response flood");
                end
            end
            line_mem_resp_valid_i[0] = 1'b0;
            wait_and_consume_response(
                0,
                make_local_tag(0, 1),
                warm_line,
                1'b0,
                32'h4d00_0000
            );
            $display("MC_NOC_P4_15_BACKEND_RESPONSE_HIT_STARVATION_CHARACTERIZED=PASS");

            /* 16: reset flushes a request held at a stalled backend. */
            reset_epoch();
            line_mem_req_ready_i[0] = 1'b0;
            lines[0] = line_for_home(0, 430);
            drive_local_request(0, 0, 0, lines[0]);
            guard = 0;
            while (!line_mem_req_valid_o[0]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 40) begin
                    $fatal(1, "MC-NOC-P4 reset-flush held request missing");
                end
            end
            @(negedge clk);
            rst_n = 1'b0;
            clear_inputs();
            #1;
            if (
                line_mem_req_valid_o != '0
                || cluster_local_resp_valid_o != '0
                || cluster_local_req_ready_o != '0
            ) begin
                $fatal(1, "MC-NOC-P4 reset did not gate held traffic");
            end
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (6) @(posedge clk);
            @(negedge clk);
            #1;
            if (line_mem_req_valid_o != '0 || cluster_local_resp_valid_o != '0) begin
                $fatal(1, "MC-NOC-P4 stale traffic survived reset");
            end
            $display("MC_NOC_P4_16_RESET_FLUSHES_IN_FLIGHT=PASS");

            /* 17: two same-home requests emerge on consecutive opportunities. */
            reset_epoch();
            lines[0] = line_for_home(0, 470);
            lines[1] = line_for_home(0, 471);
            cluster_local_resp_ready_i[0] = 1'b0;
            cluster_local_resp_ready_i[1] = 1'b0;
            @(negedge clk);
            for (cluster = 0; cluster < 2; cluster = cluster + 1) begin
                cluster_local_req_tag_i[cluster] = make_local_tag(0, 0);
                cluster_local_req_line_addr_i[cluster] = lines[cluster];
                cluster_local_req_valid_i[cluster] = 1'b1;
            end
            #1;
            if (!cluster_local_req_ready_o[0] || !cluster_local_req_ready_o[1]) begin
                $fatal(1, "MC-NOC-P4 turnover ingress failed");
            end
            @(posedge clk);
            @(negedge clk);
            cluster_local_req_valid_i = '0;
            guard = 0;
            while (!line_mem_req_valid_o[0]) begin
                @(negedge clk);
                #1;
                guard = guard + 1;
                if (guard > 40) begin
                    $fatal(1, "MC-NOC-P4 turnover first request timeout");
                end
            end
            tags[0] = line_mem_req_network_tag_o[0];
            held_line = line_mem_req_line_addr_o[0];
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!line_mem_req_valid_o[0]) begin
                $fatal(1, "MC-NOC-P4 turnover inserted a bubble");
            end
            tags[1] = line_mem_req_network_tag_o[0];
            if (
                tags[1] == tags[0]
                || line_mem_req_line_addr_o[0] == held_line
            ) begin
                $fatal(1, "MC-NOC-P4 turnover did not replace payload");
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            for (index = 0; index < 2; index = index + 1) begin
                cluster = network_cluster(tags[index]);
                pulse_backend_response(
                    0,
                    tags[index],
                    lines[cluster],
                    1'b0,
                    32'h5000_0000 + 32'(cluster * 32)
                );
            end
            for (cluster = 0; cluster < 2; cluster = cluster + 1) begin
                wait_and_consume_response(
                    cluster,
                    make_local_tag(0, 0),
                    lines[cluster],
                    1'b0,
                    32'h5000_0000 + 32'(cluster * 32)
                );
            end
            $display("MC_NOC_P4_17_SAME_CYCLE_TURNOVER=PASS");

            /* 18: K=3/U=3 plus an opaque unused local-MSHR encoding. */
            reset_epoch();
            lines[0] = line_for_home(3, 520);
            cluster_local_resp_ready_i[2] = 1'b0;
            drive_local_request(2, 2, 3, lines[0]);
            capture_backend_request(3, lines[0], tags[0]);
            if (tags[0] !== make_network_tag(2, 2, 3)) begin
                $fatal(1, "MC-NOC-P4 non-power identity was not preserved");
            end
            pulse_backend_response(3, tags[0], lines[0], 1'b1, 32'h5200_0000);
            wait_and_consume_response(
                2,
                make_local_tag(2, 3),
                lines[0],
                1'b1,
                32'h5200_0000
            );
            $display("MC_NOC_P4_18_NON_POWER_IDENTITY=PASS");

            /* 19: final reverse-com response conservation over all clusters. */
            reset_epoch();
            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                lines[cluster] = line_for_home(cluster, 560 + cluster);
                cluster_local_resp_ready_i[cluster] = 1'b0;
                drive_local_request(cluster, 1, 0, lines[cluster]);
                capture_backend_request(cluster, lines[cluster], tags[cluster]);
                seeds[cluster] = 32'h5400_0000 + 32'(cluster * 32);
            end
            for (
                index = CLUSTER_COUNT - 1;
                index >= 0;
                index = index - 1
            ) begin
                pulse_backend_response(
                    index,
                    tags[index],
                    lines[index],
                    1'b0,
                    seeds[index]
                );
            end
            for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
                wait_and_consume_response(
                    cluster,
                    make_local_tag(1, 0),
                    lines[cluster],
                    1'b0,
                    seeds[cluster]
                );
            end
            repeat (4) @(posedge clk);
            @(negedge clk);
            #1;
            require_no_diagnostics("final conservation");
            if (
                cluster_local_resp_valid_o != '0
                || line_mem_req_valid_o != '0
            ) begin
                $fatal(1, "MC-NOC-P4 final drain left live traffic");
            end
            $display("MC_NOC_P4_19_FINAL_CONSERVATION=PASS");
        end
    endtask
`endif


    initial begin
        rst_n = 1'b0;
        clear_inputs();

`ifdef MC_NOC_P4_FULL
        if (FULL_SCENARIOS != 1) begin
            $fatal(1, "MC-NOC-P4 full define/parameter mismatch");
        end
        run_full_scenarios();
`else
        if (FULL_SCENARIOS != 0) begin
            $fatal(1, "MC-NOC-P4 smoke define/parameter mismatch");
        end
        run_parameter_smoke();
`endif

        $finish;
    end

endmodule
