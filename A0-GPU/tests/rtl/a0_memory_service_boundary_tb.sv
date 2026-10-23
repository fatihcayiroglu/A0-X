`timescale 1ns/1ps

module a0_memory_service_boundary_tb;

    localparam integer WAVE_SIZE = 4;
    localparam integer WAVE_ID_W = 2;
    localparam integer LINE_WORDS = 8;
    localparam integer MSHR_COUNT = 4;
    localparam integer ENTRY_W = 2;
    localparam integer LINE_ADDR_W = 29;

    logic clk;
    logic rst_n;

    logic legacy_req_valid_i;
    logic legacy_req_write_i;
    logic legacy_req_valid_o;
    logic legacy_req_write_o;

    logic [WAVE_ID_W-1:0] legacy_req_wave_i;
    logic [WAVE_ID_W-1:0] legacy_req_context_i;
    logic [WAVE_ID_W-1:0] legacy_req_wave_o;
    logic [WAVE_ID_W-1:0] legacy_req_context_o;

    logic [WAVE_SIZE-1:0] legacy_req_lane_mask_i;
    logic [WAVE_SIZE-1:0] legacy_req_lane_mask_o;

    logic [31:0] legacy_req_addr_i [0:WAVE_SIZE-1];
    logic [31:0] legacy_req_addr_o [0:WAVE_SIZE-1];
    logic [31:0] legacy_req_wdata_i [0:WAVE_SIZE-1];
    logic [31:0] legacy_req_wdata_o [0:WAVE_SIZE-1];

    logic legacy_resp_valid_i;
    logic legacy_resp_fault_i;
    logic legacy_resp_valid_o;
    logic legacy_resp_fault_o;

    logic [WAVE_ID_W-1:0] legacy_resp_wave_i;
    logic [WAVE_ID_W-1:0] legacy_resp_context_i;
    logic [WAVE_ID_W-1:0] legacy_resp_wave_o;
    logic [WAVE_ID_W-1:0] legacy_resp_context_o;

    logic [31:0] legacy_resp_rdata_i [0:WAVE_SIZE-1];
    logic [31:0] legacy_resp_rdata_o [0:WAVE_SIZE-1];

    logic line_req_valid_i;
    logic line_req_ready_o;
    logic line_req_valid_o;
    logic line_req_ready_i;

    logic [ENTRY_W-1:0] line_req_entry_i;
    logic [ENTRY_W-1:0] line_req_entry_o;

    logic [LINE_ADDR_W-1:0] line_req_line_addr_i;
    logic [LINE_ADDR_W-1:0] line_req_line_addr_o;

    logic line_resp_valid_i;
    logic line_resp_fault_i;
    logic line_resp_valid_o;
    logic line_resp_fault_o;

    logic [ENTRY_W-1:0] line_resp_entry_i;
    logic [ENTRY_W-1:0] line_resp_entry_o;

    logic [LINE_ADDR_W-1:0] line_resp_line_addr_i;
    logic [LINE_ADDR_W-1:0] line_resp_line_addr_o;

    logic [31:0] line_resp_data_i [0:LINE_WORDS-1];
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
        .L1_SET_COUNT(4)
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
        line_req_ready_i = 1'b0;
        line_req_entry_i = '0;
        line_req_line_addr_i = '0;

        line_resp_valid_i = 1'b0;
        line_resp_entry_i = '0;
        line_resp_line_addr_i = '0;
        line_resp_fault_i = 1'b0;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            legacy_req_addr_i[lane] = 32'h100 + lane;
            legacy_req_wdata_i[lane] = 32'h1000 + lane;
            legacy_resp_rdata_i[lane] = 32'h2000 + lane;
        end

        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            line_resp_data_i[word] = 32'h3000 + word;
        end

        repeat (2) @(posedge clk);
        #1;
        rst_n = 1'b1;

        /*
         * Legacy request remains an exact bypass.
         */
        @(negedge clk);

        legacy_req_valid_i = 1'b1;
        legacy_req_write_i = 1'b1;
        legacy_req_wave_i = 2'd2;
        legacy_req_context_i = 2'd1;
        legacy_req_lane_mask_i = 4'b1011;

        #1;

        if (
            !legacy_req_valid_o
            || !legacy_req_write_o
            || legacy_req_wave_o != 2'd2
            || legacy_req_context_o != 2'd1
            || legacy_req_lane_mask_o != 4'b1011
        ) begin
            $fatal(1, "legacy request scalar passthrough mismatch");
        end

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (
                legacy_req_addr_o[lane] != legacy_req_addr_i[lane]
                || legacy_req_wdata_o[lane] != legacy_req_wdata_i[lane]
            ) begin
                $fatal(1, "legacy request lane passthrough mismatch");
            end
        end

        $display("RTL9A_LEGACY_REQUEST_PASSTHROUGH=PASS");

        legacy_req_valid_i = 1'b0;
        legacy_req_write_i = 1'b0;

        /*
         * Legacy response remains an exact bypass.
         */
        legacy_resp_valid_i = 1'b1;
        legacy_resp_wave_i = 2'd2;
        legacy_resp_context_i = 2'd1;
        legacy_resp_fault_i = 1'b1;

        #1;

        if (
            !legacy_resp_valid_o
            || legacy_resp_wave_o != 2'd2
            || legacy_resp_context_o != 2'd1
            || !legacy_resp_fault_o
        ) begin
            $fatal(1, "legacy response scalar passthrough mismatch");
        end

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            if (
                legacy_resp_rdata_o[lane]
                != legacy_resp_rdata_i[lane]
            ) begin
                $fatal(1, "legacy response lane passthrough mismatch");
            end
        end

        $display("RTL9A_LEGACY_RESPONSE_PASSTHROUGH=PASS");

        legacy_resp_valid_i = 1'b0;

        /*
         * A cold line request preserves the original RTL9A backend-facing
         * request contract.
         */
        line_req_valid_i = 1'b1;
        line_req_ready_i = 1'b1;
        line_req_entry_i = 2'd3;
        line_req_line_addr_i = 29'h12345;

        #1;

        if (
            !line_req_valid_o
            || !line_req_ready_o
            || line_req_entry_o != 2'd3
            || line_req_line_addr_o != 29'h12345
        ) begin
            $fatal(1, "line request passthrough mismatch");
        end

        $display("RTL9A_LINE_REQUEST_PASSTHROUGH=PASS");

        /*
         * Do not clock-accept this compatibility probe. The RTL9A marker
         * verifies the backend-facing cold-miss contract only.
         */
        line_req_valid_i = 1'b0;

        /*
         * Backend response remains visible to the MSHR-facing side.
         */
        line_resp_valid_i = 1'b1;
        line_resp_entry_i = 2'd3;
        line_resp_line_addr_i = 29'h12345;
        line_resp_fault_i = 1'b0;

        #1;

        if (
            !line_resp_valid_o
            || line_resp_entry_o != 2'd3
            || line_resp_line_addr_o != 29'h12345
            || line_resp_fault_o
        ) begin
            $fatal(1, "line response scalar passthrough mismatch");
        end

        for (word = 0; word < LINE_WORDS; word = word + 1) begin
            if (
                line_resp_data_o[word]
                != line_resp_data_i[word]
            ) begin
                $fatal(1, "line response data mismatch");
            end
        end

        $display("RTL9A_LINE_RESPONSE_PASSTHROUGH=PASS");

        line_resp_valid_i = 1'b0;

        /*
         * Legacy and line channels remain independent.
         */
        legacy_req_valid_i = 1'b1;
        legacy_req_write_i = 1'b0;
        legacy_req_lane_mask_i = 4'b0101;

        legacy_resp_valid_i = 1'b1;

        line_req_valid_i = 1'b1;
        line_req_ready_i = 1'b0;
        line_req_entry_i = 2'd2;
        line_req_line_addr_i = 29'h16789;

        line_resp_valid_i = 1'b1;
        line_resp_entry_i = 2'd1;
        line_resp_line_addr_i = 29'h15555;
        line_resp_fault_i = 1'b1;

        #1;

        if (
            !legacy_req_valid_o
            || legacy_req_write_o
            || legacy_req_lane_mask_o != 4'b0101
            || !line_req_valid_o
            || line_req_ready_o
            || !legacy_resp_valid_o
            || !line_resp_valid_o
            || !line_resp_fault_o
        ) begin
            $fatal(1, "dual-channel independence mismatch");
        end

        $display("RTL9A_DUAL_CHANNEL_INDEPENDENCE=PASS");
        $display("RTL9A_MEMORY_SERVICE_BOUNDARY_TB=PASS");

        $finish;
    end

endmodule
