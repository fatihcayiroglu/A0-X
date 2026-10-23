`timescale 1ns/1ps

module a0_memory_service_boundary_rtl9b2_tb;

    localparam integer WAVE_SIZE = 4;
    localparam integer WAVE_ID_W = 2;
    localparam integer LINE_WORDS = 8;
    localparam integer MSHR_COUNT = 2;
    localparam integer ENTRY_W = 1;
    localparam integer LINE_ADDR_W = 29;
    localparam integer L1_SET_COUNT = 8;

    localparam logic [LINE_ADDR_W-1:0] LINE_A = 29'h000040;
    localparam logic [LINE_ADDR_W-1:0] LINE_B = 29'h000041;
    localparam logic [LINE_ADDR_W-1:0] LINE_C = 29'h000042;
    localparam logic [LINE_ADDR_W-1:0] LINE_D = 29'h000043;
    localparam logic [LINE_ADDR_W-1:0] LINE_E = 29'h000044;

    logic clk;
    logic rst_n;

    logic legacy_req_valid_i;
    logic legacy_req_write_i;
    logic [WAVE_ID_W-1:0] legacy_req_wave_i;
    logic [WAVE_ID_W-1:0] legacy_req_context_i;
    logic [WAVE_SIZE-1:0] legacy_req_lane_mask_i;
    logic [31:0] legacy_req_addr_i [0:WAVE_SIZE-1];
    logic [31:0] legacy_req_wdata_i [0:WAVE_SIZE-1];

    logic legacy_req_valid_o;
    logic legacy_req_write_o;
    logic [WAVE_ID_W-1:0] legacy_req_wave_o;
    logic [WAVE_ID_W-1:0] legacy_req_context_o;
    logic [WAVE_SIZE-1:0] legacy_req_lane_mask_o;
    logic [31:0] legacy_req_addr_o [0:WAVE_SIZE-1];
    logic [31:0] legacy_req_wdata_o [0:WAVE_SIZE-1];

    logic legacy_resp_valid_i;
    logic [WAVE_ID_W-1:0] legacy_resp_wave_i;
    logic [WAVE_ID_W-1:0] legacy_resp_context_i;
    logic legacy_resp_fault_i;
    logic [31:0] legacy_resp_rdata_i [0:WAVE_SIZE-1];

    logic legacy_resp_valid_o;
    logic [WAVE_ID_W-1:0] legacy_resp_wave_o;
    logic [WAVE_ID_W-1:0] legacy_resp_context_o;
    logic legacy_resp_fault_o;
    logic [31:0] legacy_resp_rdata_o [0:WAVE_SIZE-1];

    logic line_req_valid_i;
    logic line_req_ready_o;
    logic [ENTRY_W-1:0] line_req_entry_i;
    logic [LINE_ADDR_W-1:0] line_req_line_addr_i;

    logic line_req_valid_o;
    logic line_req_ready_i;
    logic [ENTRY_W-1:0] line_req_entry_o;
    logic [LINE_ADDR_W-1:0] line_req_line_addr_o;

    logic line_resp_valid_i;
    logic [ENTRY_W-1:0] line_resp_entry_i;
    logic [LINE_ADDR_W-1:0] line_resp_line_addr_i;
    logic line_resp_fault_i;
    logic [31:0] line_resp_data_i [0:LINE_WORDS-1];

    logic line_resp_valid_o;
    logic [ENTRY_W-1:0] line_resp_entry_o;
    logic [LINE_ADDR_W-1:0] line_resp_line_addr_o;
    logic line_resp_fault_o;
    logic [31:0] line_resp_data_o [0:LINE_WORDS-1];

    integer lane;
    integer word;

    always #5 clk <= ~clk;

    a0_memory_service_boundary #(
        .WAVE_SIZE(WAVE_SIZE),
        .WAVE_ID_W(WAVE_ID_W),
        .LINE_WORDS(LINE_WORDS),
        .ENTRY_W(ENTRY_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .MSHR_COUNT(MSHR_COUNT),
        .L1_SET_COUNT(L1_SET_COUNT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .cluster_store_observe_enable_i(1'b0),
        .launch_observe_valid_i('0),
        .launch_observe_lane_mask_i('{default: '0}),
        .launch_observe_word_addr_i('{default: '{default: '0}}),
        .legacy_req_valid_i,
        .legacy_req_write_i,
        .legacy_req_wave_i,
        .legacy_req_context_i,
        .legacy_req_lane_mask_i,
        .legacy_req_addr_i,
        .legacy_req_wdata_i,

        .legacy_req_valid_o,
        .legacy_req_write_o,
        .legacy_req_wave_o,
        .legacy_req_context_o,
        .legacy_req_lane_mask_o,
        .legacy_req_addr_o,
        .legacy_req_wdata_o,

        .legacy_resp_valid_i,
        .legacy_resp_wave_i,
        .legacy_resp_context_i,
        .legacy_resp_fault_i,
        .legacy_resp_rdata_i,

        .legacy_resp_valid_o,
        .legacy_resp_wave_o,
        .legacy_resp_context_o,
        .legacy_resp_fault_o,
        .legacy_resp_rdata_o,

        .line_req_valid_i,
        .line_req_ready_o,
        .line_req_entry_i,
        .line_req_line_addr_i,

        .line_req_valid_o,
        .line_req_ready_i,
        .line_req_entry_o,
        .line_req_line_addr_o,

        .line_resp_valid_i,
        .line_resp_entry_i,
        .line_resp_line_addr_i,
        .line_resp_fault_i,
        .line_resp_data_i,

        .line_resp_valid_o,
        .line_resp_entry_o,
        .line_resp_line_addr_o,
        .line_resp_fault_o,
        .line_resp_data_o
    );

    function automatic logic [31:0] line_word_addr(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            line_word_addr = 32'(line_addr << 3);
        end
    endfunction

    task automatic accept_miss(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);

            line_req_valid_i = 1'b1;
            line_req_ready_i = 1'b1;
            line_req_entry_i = entry;
            line_req_line_addr_i = line_addr;

            #1;

            if (
                !line_req_ready_o
                || !line_req_valid_o
                || line_req_entry_o != entry
                || line_req_line_addr_o != line_addr
            ) begin
                $fatal(
                    1,
                    "RTL9B2 miss passthrough mismatch entry=%0d line=%0h",
                    entry,
                    line_addr
                );
            end

            @(posedge clk);
            #1;

            line_req_valid_i = 1'b0;
        end
    endtask

    task automatic send_refill(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] base,
        input logic fault
    );
        begin
            @(negedge clk);

            line_resp_valid_i = 1'b1;
            line_resp_entry_i = entry;
            line_resp_line_addr_i = line_addr;
            line_resp_fault_i = fault;

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                line_resp_data_i[word] = base + word;
            end

            #1;

            if (
                !line_resp_valid_o
                || line_resp_entry_o != entry
                || line_resp_line_addr_o != line_addr
                || line_resp_fault_o != fault
            ) begin
                $fatal(
                    1,
                    "RTL9B2 refill forward mismatch entry=%0d line=%0h",
                    entry,
                    line_addr
                );
            end

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                if (
                    line_resp_data_o[word]
                    != base + word
                ) begin
                    $fatal(
                        1,
                        "RTL9B2 refill data mismatch word=%0d",
                        word
                    );
                end
            end

            @(posedge clk);
            #1;

            line_resp_valid_i = 1'b0;
            line_resp_fault_i = 1'b0;

            #1;
        end
    endtask

    task automatic expect_hit(
        input logic [ENTRY_W-1:0] entry,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic [31:0] expected_base
    );
        begin
            @(negedge clk);

            line_req_valid_i = 1'b1;
            line_req_ready_i = 1'b1;
            line_req_entry_i = entry;
            line_req_line_addr_i = line_addr;

            #1;

            if (!line_req_ready_o) begin
                $fatal(1, "RTL9B2 expected hit was not accepted");
            end

            if (line_req_valid_o) begin
                $fatal(1, "RTL9B2 hit leaked to backend");
            end

            @(posedge clk);
            #1;

            line_req_valid_i = 1'b0;

            #1;

            if (
                !line_resp_valid_o
                || line_resp_fault_o
                || line_resp_entry_o != entry
                || line_resp_line_addr_o != line_addr
            ) begin
                $fatal(1, "RTL9B2 hit response metadata mismatch");
            end

            for (word = 0; word < LINE_WORDS; word = word + 1) begin
                if (
                    line_resp_data_o[word]
                    != expected_base + word
                ) begin
                    $fatal(
                        1,
                        "RTL9B2 hit response data mismatch word=%0d",
                        word
                    );
                end
            end

            @(posedge clk);
            #1;
        end
    endtask

    task automatic launch_store(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            @(negedge clk);

            legacy_req_valid_i = 1'b1;
            legacy_req_write_i = 1'b1;
            legacy_req_lane_mask_i = '0;
            legacy_req_lane_mask_i[0] = 1'b1;
            legacy_req_addr_i[0] = line_word_addr(line_addr);
            legacy_req_wdata_i[0] = 32'h5A5A_0001;

            #1;

            if (
                !legacy_req_valid_o
                || !legacy_req_write_o
                || !legacy_req_lane_mask_o[0]
                || legacy_req_addr_o[0]
                    != line_word_addr(line_addr)
                || legacy_req_wdata_o[0]
                    != 32'h5A5A_0001
            ) begin
                $fatal(1, "RTL9B2 legacy store bypass mismatch");
            end

            @(posedge clk);
            #1;

            legacy_req_valid_i = 1'b0;
            legacy_req_write_i = 1'b0;
            legacy_req_lane_mask_i = '0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        legacy_req_valid_i = 1'b0;
        legacy_req_write_i = 1'b0;
        legacy_req_wave_i = '0;
        legacy_req_context_i = '0;
        legacy_req_lane_mask_i = '0;

        legacy_resp_valid_i = 1'b0;
        legacy_resp_wave_i = '0;
        legacy_resp_context_i = '0;
        legacy_resp_fault_i = 1'b0;

        line_req_valid_i = 1'b0;
        line_req_ready_i = 1'b1;
        line_req_entry_i = '0;
        line_req_line_addr_i = '0;

        line_resp_valid_i = 1'b0;
        line_resp_entry_i = '0;
        line_resp_line_addr_i = '0;
        line_resp_fault_i = 1'b0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            legacy_req_addr_i[lane] = '0;
            legacy_req_wdata_i[lane] = '0;
            legacy_resp_rdata_i[lane] = 32'h8000_0000 + lane;
        end

        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            line_resp_data_i[word] = '0;
        end

        repeat (2) @(posedge clk);
        #1;
        rst_n = 1'b1;

        @(posedge clk);
        #1;

        /*
         * Legacy read bypass remains unchanged.
         */
        @(negedge clk);

        legacy_req_valid_i = 1'b1;
        legacy_req_write_i = 1'b0;
        legacy_req_wave_i = 2'd2;
        legacy_req_context_i = 2'd1;
        legacy_req_lane_mask_i = 4'b0101;
        legacy_req_addr_i[0] = 32'h0000_0100;
        legacy_req_addr_i[2] = 32'h0000_0102;

        #1;

        if (
            !legacy_req_valid_o
            || legacy_req_write_o
            || legacy_req_wave_o != 2'd2
            || legacy_req_context_o != 2'd1
            || legacy_req_lane_mask_o != 4'b0101
            || legacy_req_addr_o[0] != 32'h0000_0100
            || legacy_req_addr_o[2] != 32'h0000_0102
        ) begin
            $fatal(1, "RTL9B2 legacy read bypass mismatch");
        end

        $display("RTL9B2_LEGACY_READ_BYPASS_UNCHANGED=PASS");

        legacy_req_valid_i = 1'b0;
        legacy_req_lane_mask_i = '0;

        /*
         * Legacy response traffic also remains an exact bypass.
         * This exercises every boundary response output rather than
         * suppressing the V1 UNUSEDSIGNAL diagnostics.
         */
        legacy_resp_valid_i = 1'b1;
        legacy_resp_wave_i = 2'd3;
        legacy_resp_context_i = 2'd1;
        legacy_resp_fault_i = 1'b1;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            legacy_resp_rdata_i[lane] =
                32'h9100_0000 + lane;
        end

        #1;

        if (
            !legacy_resp_valid_o
            || legacy_resp_wave_o != 2'd3
            || legacy_resp_context_o != 2'd1
            || !legacy_resp_fault_o
        ) begin
            $fatal(
                1,
                "RTL9B2 legacy response scalar bypass mismatch"
            );
        end

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (
                legacy_resp_rdata_o[lane]
                != 32'h9100_0000 + lane
            ) begin
                $fatal(
                    1,
                    "RTL9B2 legacy response data bypass mismatch lane=%0d",
                    lane
                );
            end
        end

        $display(
            "RTL9B2_LEGACY_RESPONSE_BYPASS_UNCHANGED=PASS"
        );

        legacy_resp_valid_i = 1'b0;
        legacy_resp_fault_i = 1'b0;

        /*
         * Reset must leave cache invalid. First request therefore misses.
         */
        accept_miss(1'b0, LINE_A);

        $display("RTL9B2_RESET_CACHE_INVALID=PASS");
        $display("RTL9B2_LINE_COLD_MISS_REACHES_BACKEND=PASS");

        send_refill(
            1'b0,
            LINE_A,
            32'hA100_0000,
            1'b0
        );

        $display("RTL9B2_REFILL_REACHES_MSHR=PASS");

        expect_hit(
            1'b1,
            LINE_A,
            32'hA100_0000
        );

        $display("RTL9B2_REFILL_INSTALLS_L1=PASS");
        $display("RTL9B2_SECOND_LINE_REQUEST_HITS_L1=PASS");
        $display("RTL9B2_L1_HIT_SUPPRESSES_BACKEND_REQUEST=PASS");
        $display("RTL9B2_ENTRY_TAG_PRESERVED=PASS");
        $display("RTL9B2_LINE_ADDRESS_PRESERVED=PASS");

        /*
         * A physical legacy store bypasses unchanged and invalidates L1.
         */
        launch_store(LINE_A);

        $display("RTL9B2_LEGACY_STORE_BYPASS_UNCHANGED=PASS");

        accept_miss(1'b0, LINE_A);

        $display("RTL9B2_LEGACY_STORE_INVALIDATES_L1=PASS");

        send_refill(
            1'b0,
            LINE_A,
            32'hA200_0000,
            1'b0
        );

        /*
         * Faulted refill is forwarded but never cached.
         */
        accept_miss(1'b0, LINE_C);

        send_refill(
            1'b0,
            LINE_C,
            32'hC100_0000,
            1'b1
        );

        $display("RTL9B2_FAULTED_REFILL_FORWARDED=PASS");

        accept_miss(1'b0, LINE_C);

        $display("RTL9B2_FAULTED_REFILL_NOT_CACHED=PASS");

        send_refill(
            1'b0,
            LINE_C,
            32'hC200_0000,
            1'b0
        );

        /*
         * Store launch kills an already outstanding matching refill.
         */
        accept_miss(1'b1, LINE_B);

        launch_store(LINE_B);

        $display("RTL9B2_STORE_KILLS_OUTSTANDING_REFILL=PASS");

        send_refill(
            1'b1,
            LINE_B,
            32'hB100_0000,
            1'b0
        );

        $display("RTL9B2_KILLED_REFILL_STILL_FORWARDED=PASS");

        accept_miss(1'b1, LINE_B);

        $display("RTL9B2_KILLED_REFILL_NOT_CACHED=PASS");

        send_refill(
            1'b1,
            LINE_B,
            32'hB200_0000,
            1'b0
        );

        /*
         * Same-cycle store + refill must suppress installation.
         */
        accept_miss(1'b0, LINE_D);

        @(negedge clk);

        legacy_req_valid_i = 1'b1;
        legacy_req_write_i = 1'b1;
        legacy_req_lane_mask_i = 4'b0001;
        legacy_req_addr_i[0] = line_word_addr(LINE_D);

        line_resp_valid_i = 1'b1;
        line_resp_entry_i = 1'b0;
        line_resp_line_addr_i = LINE_D;
        line_resp_fault_i = 1'b0;

        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            line_resp_data_i[word] = 32'hD100_0000 + word;
        end

        #1;

        if (
            !legacy_req_valid_o
            || !legacy_req_write_o
            || !line_resp_valid_o
            || line_resp_entry_o != 1'b0
            || line_resp_line_addr_o != LINE_D
        ) begin
            $fatal(1, "RTL9B2 same-cycle store/refill forward mismatch");
        end

        @(posedge clk);
        #1;

        legacy_req_valid_i = 1'b0;
        legacy_req_write_i = 1'b0;
        legacy_req_lane_mask_i = '0;
        line_resp_valid_i = 1'b0;

        #1;

        accept_miss(1'b0, LINE_D);

        $display("RTL9B2_SAME_CYCLE_STORE_REFILL_INVALIDATE_WINS=PASS");

        send_refill(
            1'b0,
            LINE_D,
            32'hD200_0000,
            1'b0
        );

        /*
         * Legacy bypass and an L1 hit operate independently.
         */
        accept_miss(1'b1, LINE_E);

        send_refill(
            1'b1,
            LINE_E,
            32'hE100_0000,
            1'b0
        );

        @(negedge clk);

        legacy_req_valid_i = 1'b1;
        legacy_req_write_i = 1'b0;
        legacy_req_lane_mask_i = 4'b0011;
        legacy_req_addr_i[0] = 32'h0000_0900;
        legacy_req_addr_i[1] = 32'h0000_0901;

        line_req_valid_i = 1'b1;
        line_req_ready_i = 1'b1;
        line_req_entry_i = 1'b0;
        line_req_line_addr_i = LINE_E;

        #1;

        if (
            !legacy_req_valid_o
            || legacy_req_write_o
            || legacy_req_lane_mask_o != 4'b0011
        ) begin
            $fatal(1, "RTL9B2 dual-channel legacy side mismatch");
        end

        if (
            !line_req_ready_o
            || line_req_valid_o
        ) begin
            $fatal(1, "RTL9B2 dual-channel L1-hit side mismatch");
        end

        @(posedge clk);
        #1;

        legacy_req_valid_i = 1'b0;
        legacy_req_lane_mask_i = '0;
        line_req_valid_i = 1'b0;

        #1;

        if (
            !line_resp_valid_o
            || line_resp_entry_o != 1'b0
            || line_resp_line_addr_o != LINE_E
            || line_resp_data_o[0] != 32'hE100_0000
        ) begin
            $fatal(1, "RTL9B2 dual-channel hit response mismatch");
        end

        $display("RTL9B2_LEGACY_AND_LINE_CHANNEL_INDEPENDENCE=PASS");

        @(posedge clk);
        #1;

        $display("RTL9B2_MEMORY_SERVICE_BOUNDARY_INTEGRATION_TB=PASS");
        $finish;
    end

endmodule
