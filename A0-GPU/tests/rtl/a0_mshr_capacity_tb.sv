`timescale 1ns/1ps

module a0_mshr_capacity_tb #(
    parameter integer MSHR_COUNT = 4
);
    localparam integer RESIDENT_WAVES = 4;
    localparam integer WAVE_SIZE = 4;
    localparam integer LINE_WORDS = 4;
    localparam integer LINE_ADDR_W = 12;
    localparam integer ENTRY_W = (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT);
    localparam integer OCCUPANCY_W = (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT + 1);
    localparam integer WAVE_ID_W = 2;
    localparam integer VECTOR_REG_INDEX_W = 6;
    localparam integer WORD_SELECT_W = 2;

    logic clk;
    logic rst_n;
    logic req_valid_i;
    logic req_ready_o;
    logic [LINE_ADDR_W-1:0] req_line_addr_i;
    logic [WAVE_ID_W-1:0] req_wave_i;
    logic [WAVE_ID_W-1:0] req_context_i;
    logic [VECTOR_REG_INDEX_W-1:0] req_dst_i;
    logic [WAVE_SIZE-1:0] req_lane_mask_i;
    logic [WORD_SELECT_W-1:0] req_lane_word_select_i [0:WAVE_SIZE-1];
    logic req_fire_o;
    logic req_allocated_o;
    logic req_merged_o;
    logic req_blocked_draining_o;
    logic req_duplicate_waiter_o;
    logic [ENTRY_W-1:0] req_entry_o;
    logic miss_req_valid_o;
    logic miss_req_ready_i;
    logic [ENTRY_W-1:0] miss_req_entry_o;
    logic [LINE_ADDR_W-1:0] miss_req_line_addr_o;
    logic resp_valid_i;
    logic [ENTRY_W-1:0] resp_entry_i;
    logic [LINE_ADDR_W-1:0] resp_line_addr_i;
    logic resp_fault_i;
    logic [31:0] resp_line_data_i [0:LINE_WORDS-1];
    logic resp_accept_o;
    logic resp_tag_error_o;
    logic complete_valid_o;
    logic complete_ready_i;
    logic [ENTRY_W-1:0] complete_entry_o;
    logic [WAVE_ID_W-1:0] complete_wave_o;
    logic [WAVE_ID_W-1:0] complete_context_o;
    logic [VECTOR_REG_INDEX_W-1:0] complete_dst_o;
    logic [WAVE_SIZE-1:0] complete_lane_mask_o;
    logic [WORD_SELECT_W-1:0] complete_lane_word_select_o [0:WAVE_SIZE-1];
    logic complete_fault_o;
    logic [31:0] complete_line_data_o [0:LINE_WORDS-1];
    logic [OCCUPANCY_W-1:0] occupancy_o;
    logic full_o;
    logic empty_o;
    logic [MSHR_COUNT-1:0] valid_mask_o;
    logic [MSHR_COUNT-1:0] issued_mask_o;
    logic [MSHR_COUNT-1:0] response_ready_mask_o;

    integer index;

    a0_mshr_table #(
        .MSHR_COUNT(MSHR_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(LINE_WORDS),
        .LINE_ADDR_W(LINE_ADDR_W)
    ) dut (.*);

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        req_valid_i = 1'b0;
        req_line_addr_i = '0;
        req_wave_i = '0;
        req_context_i = '0;
        req_dst_i = '0;
        req_lane_mask_i = '1;
        miss_req_ready_i = 1'b0;
        resp_valid_i = 1'b0;
        resp_entry_i = '0;
        resp_line_addr_i = '0;
        resp_fault_i = 1'b0;
        complete_ready_i = 1'b0;
        for (index = 0; index < WAVE_SIZE; index = index + 1) begin
            req_lane_word_select_i[index] = WORD_SELECT_W'(index);
        end
        for (index = 0; index < LINE_WORDS; index = index + 1) begin
            resp_line_data_i[index] = '0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (
            !empty_o
            || occupancy_o != '0
            || full_o
            || valid_mask_o != '0
            || issued_mask_o != '0
            || response_ready_mask_o != '0
            || miss_req_valid_o
            || miss_req_entry_o != '0
            || miss_req_line_addr_o != '0
            || resp_accept_o
            || resp_tag_error_o
            || complete_valid_o
            || complete_entry_o != '0
            || complete_wave_o != '0
            || complete_context_o != '0
            || complete_dst_o != '0
            || complete_lane_mask_o != '0
            || complete_fault_o
        ) begin
            $fatal(1, "capacity reset/idle contract mismatch count=%0d", MSHR_COUNT);
        end
        for (int reset_lane = 0; reset_lane < WAVE_SIZE; reset_lane++) begin
            if (complete_lane_word_select_o[reset_lane] != '0) begin
                $fatal(1, "capacity reset completion word-select nonzero lane=%0d", reset_lane);
            end
        end
        for (int reset_word = 0; reset_word < LINE_WORDS; reset_word++) begin
            if (complete_line_data_o[reset_word] != '0) begin
                $fatal(1, "capacity reset completion data nonzero word=%0d", reset_word);
            end
        end

        for (index = 0; index < MSHR_COUNT; index = index + 1) begin
            req_valid_i = 1'b1;
            req_line_addr_i = LINE_ADDR_W'(12'h100 + index);
            req_wave_i = WAVE_ID_W'(index % RESIDENT_WAVES);
            req_context_i = WAVE_ID_W'(index % RESIDENT_WAVES);
            req_dst_i = VECTOR_REG_INDEX_W'(index);
            #1;
            if (!req_ready_o || !req_fire_o || !req_allocated_o || req_entry_o != ENTRY_W'(index)) begin
                $fatal(1, "capacity allocation failed index=%0d count=%0d", index, MSHR_COUNT);
            end
            if (req_merged_o || req_blocked_draining_o || req_duplicate_waiter_o) begin
                $fatal(1, "capacity unique allocation misclassified index=%0d count=%0d", index, MSHR_COUNT);
            end
            @(posedge clk);
            #1;
            if (empty_o || complete_valid_o || resp_accept_o || resp_tag_error_o) begin
                $fatal(1, "capacity idle sideband changed after allocation index=%0d", index);
            end
            if (issued_mask_o != '0 || response_ready_mask_o != '0) begin
                $fatal(1, "capacity request advanced without downstream handshake index=%0d", index);
            end
            if (!miss_req_valid_o || miss_req_entry_o != '0 || miss_req_line_addr_o != LINE_ADDR_W'(12'h100)) begin
                $fatal(1, "capacity oldest-miss arbitration mismatch index=%0d", index);
            end
            for (int mask_index = 0; mask_index < MSHR_COUNT; mask_index++) begin
                if (valid_mask_o[mask_index] != (mask_index <= index)) begin
                    $fatal(1, "capacity valid mask mismatch alloc=%0d bit=%0d", index, mask_index);
                end
            end
            @(negedge clk);
            req_valid_i = 1'b0;
        end

        #1;
        if (!full_o || occupancy_o != OCCUPANCY_W'(MSHR_COUNT)) begin
            $fatal(1, "capacity full mismatch count=%0d occupancy=%0d", MSHR_COUNT, occupancy_o);
        end

        req_valid_i = 1'b1;
        req_line_addr_i = LINE_ADDR_W'(12'h700);
        req_wave_i = 2'd0;
        req_context_i = 2'd0;
        #1;
        if (req_ready_o || req_fire_o) begin
            $fatal(1, "overflow allocation accepted count=%0d", MSHR_COUNT);
        end

        $display("RTL8A_MSHR_CAPACITY=PASS count=%0d", MSHR_COUNT);
        $finish;
    end
endmodule
