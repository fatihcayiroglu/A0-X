`timescale 1ns/1ps

module a0_production_multi_cluster_load_subsystem_tb;
    localparam integer CLUSTER_COUNT = 2;
    localparam integer CUS_PER_CLUSTER = 2;
    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;
    localparam integer PROGRAM_WORDS = 256;
    localparam integer MSHR_COUNT = 2;
    localparam integer LINE_WORDS = 8;
    localparam integer L2_SLICE_COUNT = 2;

    localparam integer WAVE_ID_W = 2;
    localparam integer PC_W = 8;
    localparam integer VECTOR_REG_INDEX_W = 6;
    localparam integer SCALAR_REG_INDEX_W = 5;
    localparam integer PREDICATE_INDEX_W = 4;
    localparam integer LINE_ADDR_W = 29;
    localparam integer CLUSTER_LOCAL_TAG_W = 2;
    localparam integer NETWORK_TAG_W = 3;
    localparam integer SLICE_ID_W = 1;

    logic clk;
    logic rst_n;

    logic [CUS_PER_CLUSTER-1:0] run_enable_i [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] program_we_i [0:CLUSTER_COUNT-1];
    logic [PC_W-1:0] program_waddr_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [63:0] program_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] alloc_valid_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] alloc_wave_id_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [PC_W-1:0] alloc_pc_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_SIZE-1:0] alloc_exec_mask_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_ID_W-1:0] alloc_vrf_context_id_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] release_valid_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] release_wave_id_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] scalar_we_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] scalar_wwave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [SCALAR_REG_INDEX_W-1:0] scalar_wreg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [31:0] scalar_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] predicate_we_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] predicate_wwave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [PREDICATE_INDEX_W-1:0] predicate_wreg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_SIZE-1:0] predicate_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] vector_we_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] vector_wcontext_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [VECTOR_REG_INDEX_W-1:0] vector_wreg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [$clog2(WAVE_SIZE)-1:0] vector_wlane_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [31:0] vector_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] mem_resp_valid_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] mem_resp_wave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_ID_W-1:0] mem_resp_context_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] mem_resp_fault_i [0:CLUSTER_COUNT-1];
    logic [31:0] mem_resp_rdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:WAVE_SIZE-1];
    logic [CUS_PER_CLUSTER-1:0] policy_override_valid_i [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] policy_override_wave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_ID_W-1:0] debug_vector_context_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [VECTOR_REG_INDEX_W-1:0] debug_vector_reg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [$clog2(WAVE_SIZE)-1:0] debug_vector_lane_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_ID_W-1:0] debug_context_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_reg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [PREDICATE_INDEX_W-1:0] debug_predicate_reg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];


    logic [CUS_PER_CLUSTER-1:0] alloc_ready_o [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] mem_req_valid_o [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] mem_req_write_o [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] mem_req_wave_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_ID_W-1:0] mem_req_context_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_SIZE-1:0] mem_req_lane_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [31:0] mem_req_addr_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:WAVE_SIZE-1];
    logic [31:0] mem_req_wdata_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:WAVE_SIZE-1];
    logic [1:0] mshr_occupancy_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] mshr_full_o [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] mshr_merge_event_o [0:CLUSTER_COUNT-1];
    logic [RESIDENT_WAVES-1:0] mshr_active_wave_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] mshr_tag_error_o [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] memory_outstanding_o [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] memory_tag_error_o [0:CLUSTER_COUNT-1];
    logic [31:0] debug_vector_data_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] debug_context_valid_o [0:CLUSTER_COUNT-1];
    logic [PC_W-1:0] debug_pc_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_SIZE-1:0] debug_exec_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] debug_halted_o [0:CLUSTER_COUNT-1];
    logic [31:0] debug_scalar_data_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_SIZE-1:0] debug_predicate_data_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] retire_valid_o [0:CLUSTER_COUNT-1];
    logic [WAVE_ID_W-1:0] retire_wave_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [PC_W-1:0] retire_pc_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] engine_busy_o [0:CLUSTER_COUNT-1];
    logic [CUS_PER_CLUSTER-1:0] faulted_o [0:CLUSTER_COUNT-1];
    logic [RESIDENT_WAVES-1:0] valid_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [RESIDENT_WAVES-1:0] ready_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [RESIDENT_WAVES-1:0] halted_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [WAVE_ID_W-1:0] rr_cursor_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1];
    logic [CUS_PER_CLUSTER-1:0] all_halted_o [0:CLUSTER_COUNT-1];
    logic [CLUSTER_COUNT-1:0] store_observe_valid_o;
    logic [(CUS_PER_CLUSTER * WAVE_SIZE)-1:0] store_observe_lane_mask_o [0:CLUSTER_COUNT-1];
    logic [31:0] store_observe_word_addr_o [0:CLUSTER_COUNT-1][0:(CUS_PER_CLUSTER * WAVE_SIZE)-1];

    logic [L2_SLICE_COUNT-1:0] line_mem_req_valid_o;
    logic [L2_SLICE_COUNT-1:0] line_mem_req_ready_i;
    logic [NETWORK_TAG_W-1:0] line_mem_req_network_tag_o [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o [0:L2_SLICE_COUNT-1];
    logic [L2_SLICE_COUNT-1:0] line_mem_resp_valid_i;
    logic [NETWORK_TAG_W-1:0] line_mem_resp_network_tag_i [0:L2_SLICE_COUNT-1];
    logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i [0:L2_SLICE_COUNT-1];
    logic line_mem_resp_fault_i [0:L2_SLICE_COUNT-1];
    logic [31:0] line_mem_resp_data_i [0:L2_SLICE_COUNT-1][0:LINE_WORDS-1];

    logic [CLUSTER_COUNT-1:0] cluster_local_req_tag_error_o;
    logic [CLUSTER_COUNT-1:0] noc_req_tag_error_o;
    logic [L2_SLICE_COUNT-1:0] slice_resp_protocol_error_o;
    logic [CLUSTER_COUNT-1:0] noc_resp_tag_error_o;
    logic [CLUSTER_COUNT-1:0] line_resp_tag_error_o;

    a0_production_multi_cluster_load_subsystem #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .SCALAR_PREDICATE_REG_COUNT(16),
        .RECONV_STACK_DEPTH(16),
        .GLOBAL_MEMORY_WORDS(1024),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .MSHR_COUNT(MSHR_COUNT),
        .MSHR_LINE_WORDS(LINE_WORDS),
        .STORE_QUEUE_DEPTH(4),
        .L1_SET_COUNT(64),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .L2_SET_COUNT_PER_SLICE(4),
        .L2_MISS_COUNT_PER_SLICE(2)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .run_enable_i(run_enable_i), .program_we_i(program_we_i),
        .program_waddr_i(program_waddr_i), .program_wdata_i(program_wdata_i),
        .alloc_valid_i(alloc_valid_i), .alloc_wave_id_i(alloc_wave_id_i),
        .alloc_ready_o(alloc_ready_o), .alloc_pc_i(alloc_pc_i),
        .alloc_exec_mask_i(alloc_exec_mask_i),
        .alloc_vrf_context_id_i(alloc_vrf_context_id_i),
        .release_valid_i(release_valid_i), .release_wave_id_i(release_wave_id_i),
        .scalar_we_i(scalar_we_i), .scalar_wwave_i(scalar_wwave_i),
        .scalar_wreg_i(scalar_wreg_i), .scalar_wdata_i(scalar_wdata_i),
        .predicate_we_i(predicate_we_i), .predicate_wwave_i(predicate_wwave_i),
        .predicate_wreg_i(predicate_wreg_i), .predicate_wdata_i(predicate_wdata_i),
        .vector_we_i(vector_we_i), .vector_wcontext_i(vector_wcontext_i),
        .vector_wreg_i(vector_wreg_i), .vector_wlane_i(vector_wlane_i),
        .vector_wdata_i(vector_wdata_i),
        .mem_req_valid_o(mem_req_valid_o), .mem_req_write_o(mem_req_write_o), .mem_req_wave_o(mem_req_wave_o),
        .mem_req_context_o(mem_req_context_o), .mem_req_lane_mask_o(mem_req_lane_mask_o), .mem_req_addr_o(mem_req_addr_o),
        .mem_req_wdata_o(mem_req_wdata_o), .mem_resp_valid_i(mem_resp_valid_i),
        .mem_resp_wave_i(mem_resp_wave_i), .mem_resp_context_i(mem_resp_context_i),
        .mem_resp_fault_i(mem_resp_fault_i), .mem_resp_rdata_i(mem_resp_rdata_i),
        .mshr_occupancy_o(mshr_occupancy_o), .mshr_full_o(mshr_full_o), .mshr_merge_event_o(mshr_merge_event_o),
        .mshr_active_wave_mask_o(mshr_active_wave_mask_o), .mshr_tag_error_o(mshr_tag_error_o), .memory_outstanding_o(memory_outstanding_o),
        .memory_tag_error_o(memory_tag_error_o), .policy_override_valid_i(policy_override_valid_i),
        .policy_override_wave_i(policy_override_wave_i),
        .debug_vector_context_i(debug_vector_context_i),
        .debug_vector_reg_i(debug_vector_reg_i), .debug_vector_lane_i(debug_vector_lane_i),
        .debug_vector_data_o(debug_vector_data_o), .debug_context_i(debug_context_i),
        .debug_scalar_reg_i(debug_scalar_reg_i), .debug_predicate_reg_i(debug_predicate_reg_i),
        .debug_context_valid_o(debug_context_valid_o), .debug_pc_o(debug_pc_o), .debug_exec_mask_o(debug_exec_mask_o),
        .debug_halted_o(debug_halted_o), .debug_scalar_data_o(debug_scalar_data_o), .debug_predicate_data_o(debug_predicate_data_o),
        .retire_valid_o(retire_valid_o), .retire_wave_o(retire_wave_o), .retire_pc_o(retire_pc_o), .engine_busy_o(engine_busy_o),
        .faulted_o(faulted_o), .valid_mask_o(valid_mask_o), .ready_mask_o(ready_mask_o), .halted_mask_o(halted_mask_o),
        .rr_cursor_o(rr_cursor_o), .all_halted_o(all_halted_o),
        .line_resp_tag_error_o(line_resp_tag_error_o),
        .store_observe_valid_o(store_observe_valid_o), .store_observe_lane_mask_o(store_observe_lane_mask_o),
        .store_observe_word_addr_o(store_observe_word_addr_o),
        .cluster_local_req_tag_error_o(cluster_local_req_tag_error_o),
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

    always #5 clk = ~clk;

    task automatic drive_backend_response(
        input logic [SLICE_ID_W-1:0] slice,
        input logic [NETWORK_TAG_W-1:0] tag,
        input logic [LINE_ADDR_W-1:0] addr,
        input logic [31:0] base
    );
        integer word;
        begin
            @(negedge clk);
            line_mem_resp_network_tag_i[slice] = tag;
            line_mem_resp_line_addr_i[slice] = addr;
            line_mem_resp_fault_i[slice] = 1'b0;
            for (word = 0; word < LINE_WORDS; word = word + 1)
                line_mem_resp_data_i[slice][word] = base + word;
            line_mem_resp_valid_i[slice] = 1'b1;
            @(negedge clk);
            line_mem_resp_valid_i[slice] = 1'b0;
        end
    endtask

    task automatic wait_cluster_response(
        input integer cluster,
        input logic [CLUSTER_LOCAL_TAG_W-1:0] expected_tag,
        input logic [LINE_ADDR_W-1:0] expected_addr,
        input logic [31:0] expected_word0
    );
        integer cycle;
        logic found;
        begin
            found = 1'b0;
            for (cycle = 0; cycle < 80 && !found; cycle = cycle + 1) begin
                @(posedge clk);
                #1;
                if (dut.cluster_line_resp_valid[cluster]) begin
                    if (dut.cluster_line_resp_tag[cluster] != expected_tag)
                        $fatal(1, "cluster %0d local tag restore mismatch", cluster);
                    if (dut.cluster_line_resp_addr[cluster] != expected_addr)
                        $fatal(1, "cluster %0d line address restore mismatch", cluster);
                    if (dut.cluster_line_resp_fault[cluster])
                        $fatal(1, "cluster %0d unexpected refill fault", cluster);
                    if (dut.cluster_line_resp_data[cluster][0] != expected_word0)
                        $fatal(1, "cluster %0d refill data mismatch", cluster);
                    found = 1'b1;
                end
            end
            if (!found)
                $fatal(1, "cluster %0d response timeout", cluster);
        end
    endtask

    integer cluster;
    integer cu;
    integer lane;
    integer slice;
    logic [NETWORK_TAG_W-1:0] tag_slice0;
    logic [NETWORK_TAG_W-1:0] tag_slice1;
    logic seen_slice0;
    logic seen_slice1;
    logic saw_backend_on_hit;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        line_mem_req_ready_i = '1;
        line_mem_resp_valid_i = '0;

        for (slice = 0; slice < L2_SLICE_COUNT; slice = slice + 1) begin
            line_mem_resp_network_tag_i[slice] = '0;
            line_mem_resp_line_addr_i[slice] = '0;
            line_mem_resp_fault_i[slice] = 1'b0;
            for (lane = 0; lane < LINE_WORDS; lane = lane + 1)
                line_mem_resp_data_i[slice][lane] = '0;
        end

        for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
            run_enable_i[cluster] = '0;
            program_we_i[cluster] = '0;
            alloc_valid_i[cluster] = '0;
            release_valid_i[cluster] = '0;
            scalar_we_i[cluster] = '0;
            predicate_we_i[cluster] = '0;
            vector_we_i[cluster] = '0;
            mem_resp_valid_i[cluster] = '0;
            mem_resp_fault_i[cluster] = '0;
            policy_override_valid_i[cluster] = '0;
            for (cu = 0; cu < CUS_PER_CLUSTER; cu = cu + 1) begin
                program_waddr_i[cluster][cu] = '0;
                program_wdata_i[cluster][cu] = '0;
                alloc_wave_id_i[cluster][cu] = '0;
                alloc_pc_i[cluster][cu] = '0;
                alloc_exec_mask_i[cluster][cu] = '1;
                alloc_vrf_context_id_i[cluster][cu] = '0;
                release_wave_id_i[cluster][cu] = '0;
                scalar_wwave_i[cluster][cu] = '0;
                scalar_wreg_i[cluster][cu] = '0;
                scalar_wdata_i[cluster][cu] = '0;
                predicate_wwave_i[cluster][cu] = '0;
                predicate_wreg_i[cluster][cu] = '0;
                predicate_wdata_i[cluster][cu] = '0;
                vector_wcontext_i[cluster][cu] = '0;
                vector_wreg_i[cluster][cu] = '0;
                vector_wlane_i[cluster][cu] = '0;
                vector_wdata_i[cluster][cu] = '0;
                mem_resp_wave_i[cluster][cu] = '0;
                mem_resp_context_i[cluster][cu] = '0;
                policy_override_wave_i[cluster][cu] = '0;
                debug_vector_context_i[cluster][cu] = '0;
                debug_vector_reg_i[cluster][cu] = '0;
                debug_vector_lane_i[cluster][cu] = '0;
                debug_context_i[cluster][cu] = '0;
                debug_scalar_reg_i[cluster][cu] = '0;
                debug_predicate_reg_i[cluster][cu] = '0;
                for (lane = 0; lane < WAVE_SIZE; lane = lane + 1)
                    mem_resp_rdata_i[cluster][cu][lane] = '0;
            end
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        #1;

        for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
            if (alloc_ready_o[cluster] != '1
                || mshr_full_o[cluster] != '0
                || mshr_merge_event_o[cluster] != '0
                || mshr_tag_error_o[cluster] != '0
                || memory_outstanding_o[cluster] != '0
                || memory_tag_error_o[cluster] != '0
                || debug_context_valid_o[cluster] != '0
                || debug_halted_o[cluster] != '0
                || retire_valid_o[cluster] != '0
                || engine_busy_o[cluster] != '0
                || faulted_o[cluster] != '0
                || all_halted_o[cluster] != '0
                || store_observe_valid_o[cluster]
                || store_observe_lane_mask_o[cluster] != '0)
                $fatal(1, "P2 cluster reset status mismatch");
            for (cu = 0; cu < CUS_PER_CLUSTER; cu = cu + 1) begin
                if (mshr_occupancy_o[cluster][cu] != '0
                    || mshr_active_wave_mask_o[cluster][cu] != '0
                    || valid_mask_o[cluster][cu] != '0
                    || ready_mask_o[cluster][cu] != '0
                    || halted_mask_o[cluster][cu] != '0
                    || rr_cursor_o[cluster][cu] != '0)
                    $fatal(1, "P2 per-CU reset status mismatch");
                if (mem_req_valid_o[cluster][cu]) begin
                    if ($isunknown({mem_req_write_o[cluster][cu],
                        mem_req_wave_o[cluster][cu],
                        mem_req_context_o[cluster][cu],
                        mem_req_lane_mask_o[cluster][cu]}))
                        $fatal(1, "P2 legacy memory metadata contains X");
                    for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
                        if ($isunknown(mem_req_addr_o[cluster][cu][lane])
                            || $isunknown(mem_req_wdata_o[cluster][cu][lane]))
                            $fatal(1, "P2 legacy memory lane payload contains X");
                    end
                end
                if (debug_context_valid_o[cluster][cu]
                    && $isunknown({debug_pc_o[cluster][cu],
                        debug_exec_mask_o[cluster][cu],
                        debug_scalar_data_o[cluster][cu],
                        debug_predicate_data_o[cluster][cu],
                        debug_vector_data_o[cluster][cu]}))
                    $fatal(1, "P2 debug payload contains X");
                if (retire_valid_o[cluster][cu]
                    && $isunknown({retire_wave_o[cluster][cu],
                        retire_pc_o[cluster][cu]}))
                    $fatal(1, "P2 retire payload contains X");
            end
            if (store_observe_valid_o[cluster]) begin
                for (lane = 0; lane < (CUS_PER_CLUSTER * WAVE_SIZE); lane = lane + 1)
                    if (store_observe_lane_mask_o[cluster][lane]
                        && $isunknown(store_observe_word_addr_o[cluster][lane]))
                        $fatal(1, "P2 store observation address contains X");
            end
        end

        if (line_mem_req_valid_o != '0
            || cluster_local_req_tag_error_o != '0
            || noc_req_tag_error_o != '0
            || slice_resp_protocol_error_o != '0
            || noc_resp_tag_error_o != '0
            || line_resp_tag_error_o != '0)
            $fatal(1, "P2 reset/idle mismatch");
        $display("PROD_SEAM_P2_RESET_IDLE=PASS");

        /*
         * Same cluster-local tag in different clusters must become unique.
         * Model the real P1 seam protocol: hold valid only until the local
         * ready/valid handshake, while the external backend is stalled so
         * each resulting miss remains observable without duplicating a
         * cluster-local request.
         */
        line_mem_req_ready_i = '0;
        fork
            begin : issue_cluster0
                @(negedge clk);
                force dut.cluster_line_req_valid[0] = 1'b1;
                force dut.cluster_line_req_tag[0] = 2'b01;
                force dut.cluster_line_req_addr[0] = LINE_ADDR_W'(0);
                #1;
                while (!dut.cluster_line_req_ready[0]) begin
                    @(negedge clk);
                    #1;
                end
                @(posedge clk);
                @(negedge clk);
                release dut.cluster_line_req_valid[0];
                release dut.cluster_line_req_tag[0];
                release dut.cluster_line_req_addr[0];
            end
            begin : issue_cluster1
                @(negedge clk);
                force dut.cluster_line_req_valid[1] = 1'b1;
                force dut.cluster_line_req_tag[1] = 2'b01;
                force dut.cluster_line_req_addr[1] = LINE_ADDR_W'(1);
                #1;
                while (!dut.cluster_line_req_ready[1]) begin
                    @(negedge clk);
                    #1;
                end
                @(posedge clk);
                @(negedge clk);
                release dut.cluster_line_req_valid[1];
                release dut.cluster_line_req_tag[1];
                release dut.cluster_line_req_addr[1];
            end
        join

        seen_slice0 = 1'b0;
        seen_slice1 = 1'b0;
        tag_slice0 = '0;
        tag_slice1 = '0;
        for (lane = 0; lane < 80 && !(seen_slice0 && seen_slice1); lane = lane + 1) begin
            @(posedge clk);
            #1;
            if (line_mem_req_valid_o[0]) begin
                seen_slice0 = 1'b1;
                tag_slice0 = line_mem_req_network_tag_o[0];
                if (line_mem_req_line_addr_o[0] != LINE_ADDR_W'(0))
                    $fatal(1, "slice0 request address mismatch");
            end
            if (line_mem_req_valid_o[1]) begin
                seen_slice1 = 1'b1;
                tag_slice1 = line_mem_req_network_tag_o[1];
                if (line_mem_req_line_addr_o[1] != LINE_ADDR_W'(1))
                    $fatal(1, "slice1 request address mismatch");
            end
        end
        if (!(seen_slice0 && seen_slice1))
            $fatal(1, "multi-cluster backend request timeout");
        if (tag_slice0 == tag_slice1)
            $fatal(1, "cluster identity was not encoded into network tag");
        @(negedge clk);
        line_mem_req_ready_i = '1;
        @(posedge clk);
        @(negedge clk);
        $display("PROD_SEAM_P2_MULTI_CLUSTER_TAG_UNIQUENESS=PASS");

        /* Return cluster1 first, then cluster0: local identity must restore. */
        drive_backend_response(1, tag_slice1, LINE_ADDR_W'(1), 32'hB100_0000);
        wait_cluster_response(1, 2'b01, LINE_ADDR_W'(1), 32'hB100_0000);
        $display("PROD_SEAM_P2_OOO_CLUSTER1_RESTORE=PASS");

        drive_backend_response(0, tag_slice0, LINE_ADDR_W'(0), 32'hA000_0000);
        wait_cluster_response(0, 2'b01, LINE_ADDR_W'(0), 32'hA000_0000);
        $display("PROD_SEAM_P2_OOO_CLUSTER0_RESTORE=PASS");

        /* Cluster1 must observe cluster0's filled line as a shared-L2 hit. */
        line_mem_req_ready_i = '0;
        @(negedge clk);
        force dut.cluster_line_req_valid[1] = 1'b1;
        force dut.cluster_line_req_tag[1] = 2'b10;
        force dut.cluster_line_req_addr[1] = LINE_ADDR_W'(0);
        #1;
        while (!dut.cluster_line_req_ready[1]) begin
            @(negedge clk);
            #1;
        end
        @(posedge clk);
        @(negedge clk);
        release dut.cluster_line_req_valid[1];
        release dut.cluster_line_req_tag[1];
        release dut.cluster_line_req_addr[1];
        saw_backend_on_hit = 1'b0;
        begin : wait_shared_hit
            integer hit_cycle;
            logic hit_seen;
            hit_seen = 1'b0;
            for (hit_cycle = 0; hit_cycle < 80 && !hit_seen; hit_cycle = hit_cycle + 1) begin
                @(posedge clk);
                #1;
                if (line_mem_req_valid_o != '0)
                    saw_backend_on_hit = 1'b1;
                if (dut.cluster_line_resp_valid[1]) begin
                    if (dut.cluster_line_resp_tag[1] != 2'b10
                        || dut.cluster_line_resp_addr[1] != LINE_ADDR_W'(0)
                        || dut.cluster_line_resp_data[1][0] != 32'hA000_0000)
                        $fatal(1, "cross-cluster shared-L2 hit payload mismatch");
                    hit_seen = 1'b1;
                end
            end
            if (!hit_seen)
                $fatal(1, "cross-cluster shared-L2 hit timeout");
        end
        if (saw_backend_on_hit)
            $fatal(1, "cross-cluster shared-L2 hit incorrectly reached backend");
        $display("PROD_SEAM_P2_CROSS_CLUSTER_HIT_SUPPRESSES_BACKEND=PASS");
        line_mem_req_ready_i = '1;
        $display("PROD_SEAM_P2_CROSS_CLUSTER_SHARED_L2_HIT=PASS");

        if (cluster_local_req_tag_error_o != '0
            || noc_req_tag_error_o != '0
            || slice_resp_protocol_error_o != '0
            || noc_resp_tag_error_o != '0
            || line_resp_tag_error_o != '0)
            $fatal(1, "P2 diagnostics asserted unexpectedly");
        $display("PROD_SEAM_P2_DIAGNOSTICS_CLEAN=PASS");
        $display("PROD_SEAM_P2_MULTI_CLUSTER_LOAD_TB=PASS");
        $finish;
    end
endmodule
