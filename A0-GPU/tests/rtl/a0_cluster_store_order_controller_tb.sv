`timescale 1ns/1ps

module a0_cluster_store_order_controller_tb;
    localparam integer CU_COUNT = 3;
    localparam integer WAVE_SIZE = 32;
    localparam integer LINE_WORDS = 8;
    localparam integer WAVE_ID_W = 2;
    localparam integer CONTEXT_ID_W = 2;
    localparam integer LINE_ADDR_W = 29;
    localparam integer CU_ID_W = (CU_COUNT <= 1) ? 1 : $clog2(CU_COUNT);
    localparam integer LANE_ID_W = (WAVE_SIZE <= 1) ? 1 : $clog2(WAVE_SIZE);
    localparam logic [LINE_ADDR_W-1:0] LINE_A = 29'h000040;
    localparam logic [LINE_ADDR_W-1:0] LINE_B = 29'h000041;
    localparam logic [LINE_ADDR_W-1:0] LINE_C = 29'h000042;

    logic clk;
    logic rst_n;
    logic [CU_COUNT-1:0] store_launch_valid_i;
    logic [WAVE_ID_W-1:0] store_launch_wave_i [0:CU_COUNT-1];
    logic [CONTEXT_ID_W-1:0]
        store_launch_context_i [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0]
        store_launch_lane_mask_i [0:CU_COUNT-1];
    logic [31:0]
        store_launch_word_addr_i [0:CU_COUNT-1][0:WAVE_SIZE-1];
    logic [CU_COUNT-1:0] store_terminal_valid_i;
    logic [WAVE_ID_W-1:0] store_terminal_wave_i [0:CU_COUNT-1];
    logic [CONTEXT_ID_W-1:0]
        store_terminal_context_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] store_terminal_fault_i;
    logic [CU_COUNT-1:0] fabric_candidate_valid_i;
    logic [LINE_ADDR_W-1:0]
        fabric_candidate_line_addr_i [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] fabric_peer_conflict_o;
    logic [CU_COUNT-1:0] pending_store_valid_o;
    logic [CU_COUNT-1:0] launch_observe_valid_o;
    logic [WAVE_SIZE-1:0]
        launch_observe_lane_mask_o [0:CU_COUNT-1];
    logic [31:0]
        launch_observe_word_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1];
    logic [CU_COUNT-1:0] ordering_store_valid_o;
    logic [WAVE_SIZE-1:0]
        ordering_store_lane_mask_o [0:CU_COUNT-1];
    logic [31:0]
        ordering_store_word_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1];
    logic [CU_COUNT-1:0] terminal_store_valid_o;
    logic [CU_COUNT-1:0] terminal_store_fault_o;
    logic [WAVE_SIZE-1:0]
        terminal_store_lane_mask_o [0:CU_COUNT-1];
    logic [31:0]
        terminal_store_word_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1];

    integer cu;
    integer lane;

    always #5 clk = ~clk;

    a0_cluster_store_order_controller #(
        .CU_COUNT(CU_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(LINE_WORDS),
        .WAVE_ID_W(WAVE_ID_W),
        .CONTEXT_ID_W(CONTEXT_ID_W)
    ) dut (.*);

    function automatic logic [31:0] word_addr(
        input logic [LINE_ADDR_W-1:0] line_addr,
        input integer word_offset
    );
        word_addr = (32'(line_addr) << 3) | 32'(word_offset);
    endfunction

    task automatic clear_launch;
        begin
            store_launch_valid_i = '0;
            for (cu = 0; cu < CU_COUNT; cu = cu + 1) begin
                store_launch_wave_i[cu] = '0;
                store_launch_context_i[cu] = '0;
                store_launch_lane_mask_i[cu] = '0;
                for (lane = 0; lane < WAVE_SIZE; lane = lane + 1)
                    store_launch_word_addr_i[cu][lane] = '0;
            end
        end
    endtask

    task automatic clear_terminal;
        begin
            store_terminal_valid_i = '0;
            store_terminal_fault_i = '0;
            for (cu = 0; cu < CU_COUNT; cu = cu + 1) begin
                store_terminal_wave_i[cu] = '0;
                store_terminal_context_i[cu] = '0;
            end
        end
    endtask

    task automatic clear_candidates;
        begin
            fabric_candidate_valid_i = '0;
            for (cu = 0; cu < CU_COUNT; cu = cu + 1)
                fabric_candidate_line_addr_i[cu] = '0;
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            clear_launch();
            clear_terminal();
            clear_candidates();
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask

    task automatic configure_launch(
        input logic [CU_ID_W-1:0] source,
        input logic [WAVE_ID_W-1:0] wave,
        input logic [CONTEXT_ID_W-1:0] context_id,
        input logic [LANE_ID_W-1:0] selected_lane,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input integer offset
    );
        begin
            store_launch_valid_i[source] = 1'b1;
            store_launch_wave_i[source] = wave;
            store_launch_context_i[source] = context_id;
            store_launch_lane_mask_i[source] = '0;
            store_launch_lane_mask_i[source][selected_lane] = 1'b1;
            store_launch_word_addr_i[source][selected_lane] =
                word_addr(line_addr, offset);
        end
    endtask

    task automatic expect_conflict(
        input integer target,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic expected
    );
        begin
            clear_candidates();
            fabric_candidate_valid_i[target] = 1'b1;
            fabric_candidate_line_addr_i[target] = line_addr;
            #1;
            if (fabric_peer_conflict_o[target] != expected)
                $fatal(1, "conflict mismatch target=%0d line=%h", target,
                       line_addr);
        end
    endtask

    task automatic pulse_terminal(
        input logic [CU_ID_W-1:0] source,
        input logic [WAVE_ID_W-1:0] wave,
        input logic [CONTEXT_ID_W-1:0] context_id,
        input logic fault,
        input logic expected_match
    );
        begin
            @(negedge clk);
            clear_terminal();
            store_terminal_valid_i[source] = 1'b1;
            store_terminal_wave_i[source] = wave;
            store_terminal_context_i[source] = context_id;
            store_terminal_fault_i[source] = fault;
            #1;
            if (terminal_store_valid_o[source] != expected_match)
                $fatal(1, "terminal match mismatch source=%0d", source);
            if (terminal_store_fault_o[source]
                != (expected_match && fault))
                $fatal(1, "terminal fault mismatch source=%0d", source);
            @(posedge clk);
            @(negedge clk);
            clear_terminal();
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        clear_launch();
        clear_terminal();
        clear_candidates();

        reset_dut();
        if (pending_store_valid_o != '0 || ordering_store_valid_o != '0
            || terminal_store_valid_o != '0 || fabric_peer_conflict_o != '0
            || launch_observe_valid_o != '0)
            $fatal(1, "reset idle mismatch");

        /* Raw launch is immediately broadcast and blocks a peer candidate. */
        fabric_candidate_valid_i[0] = 1'b1;
        fabric_candidate_line_addr_i[0] = LINE_A;
        @(negedge clk);
        configure_launch(1, 2'd1, 2'd2, 7, LINE_A, 3);
        #1;
        if (launch_observe_valid_o != 3'b010
            || launch_observe_lane_mask_o[1] != 32'h0000_0080
            || launch_observe_word_addr_o[1][7] != word_addr(LINE_A, 3)
            || !ordering_store_valid_o[1]
            || !fabric_peer_conflict_o[0]
            || pending_store_valid_o[1])
            $fatal(1, "raw launch observation/conflict mismatch");
        @(posedge clk);
        @(negedge clk);
        clear_launch();
        #1;
        if (!pending_store_valid_o[1] || !ordering_store_valid_o[1]
            || !fabric_peer_conflict_o[0]
            || ordering_store_word_addr_o[1][7] != word_addr(LINE_A, 3))
            $fatal(1, "pending metadata was not retained");

        /* Wrong owner tags neither close nor release the pending slot. */
        pulse_terminal(1, 2'd0, 2'd2, 1'b0, 1'b0);
        pulse_terminal(1, 2'd1, 2'd3, 1'b1, 1'b0);
        if (!pending_store_valid_o[1] || !fabric_peer_conflict_o[0])
            $fatal(1, "mismatched response released ordering state");

        /* Success closes inclusively and releases on the next cycle. */
        @(negedge clk);
        clear_terminal();
        store_terminal_valid_i[1] = 1'b1;
        store_terminal_wave_i[1] = 2'd1;
        store_terminal_context_i[1] = 2'd2;
        #1;
        if (!terminal_store_valid_o[1] || terminal_store_fault_o[1]
            || !pending_store_valid_o[1] || !fabric_peer_conflict_o[0]
            || terminal_store_lane_mask_o[1] != 32'h0000_0080
            || terminal_store_word_addr_o[1][7] != word_addr(LINE_A, 3))
            $fatal(1, "successful terminal inclusive close mismatch");
        @(posedge clk);
        @(negedge clk);
        clear_terminal();
        #1;
        if (pending_store_valid_o[1] || ordering_store_valid_o[1]
            || fabric_peer_conflict_o[0])
            $fatal(1, "successful terminal did not release next cycle");

        /* Scatter metadata remains lossless across multiple lines. */
        reset_dut();
        @(negedge clk);
        store_launch_valid_i[2] = 1'b1;
        store_launch_wave_i[2] = 2'd3;
        store_launch_context_i[2] = 2'd1;
        store_launch_lane_mask_i[2][0] = 1'b1;
        store_launch_lane_mask_i[2][17] = 1'b1;
        store_launch_word_addr_i[2][0] = word_addr(LINE_A, 1);
        store_launch_word_addr_i[2][17] = word_addr(LINE_C, 5);
        @(posedge clk);
        @(negedge clk);
        clear_launch();
        #1;
        if (ordering_store_lane_mask_o[2] != 32'h0002_0001
            || ordering_store_word_addr_o[2][0] != word_addr(LINE_A, 1)
            || ordering_store_word_addr_o[2][17]
                != word_addr(LINE_C, 5))
            $fatal(1, "scatter metadata collapsed");
        expect_conflict(0, LINE_A, 1'b1);
        expect_conflict(0, LINE_C, 1'b1);
        expect_conflict(0, LINE_B, 1'b0);
        expect_conflict(2, LINE_A, 1'b0);

        /* Fault is also terminal and remains inclusive at the edge. */
        clear_candidates();
        fabric_candidate_valid_i[0] = 1'b1;
        fabric_candidate_line_addr_i[0] = LINE_C;
        @(negedge clk);
        clear_terminal();
        store_terminal_valid_i[2] = 1'b1;
        store_terminal_wave_i[2] = 2'd3;
        store_terminal_context_i[2] = 2'd1;
        store_terminal_fault_i[2] = 1'b1;
        #1;
        if (!terminal_store_valid_o[2] || !terminal_store_fault_o[2]
            || !pending_store_valid_o[2] || !fabric_peer_conflict_o[0]
            || !terminal_store_lane_mask_o[2][17])
            $fatal(1, "fault terminal inclusive close mismatch");
        @(posedge clk);
        @(negedge clk);
        clear_terminal();
        #1;
        if (pending_store_valid_o[2] || fabric_peer_conflict_o[0])
            $fatal(1, "fault terminal did not release next cycle");

        /* Independent slots and non-power-of-two CU routing. */
        reset_dut();
        @(negedge clk);
        configure_launch(1, 2'd1, 2'd0, 1, LINE_A, 0);
        configure_launch(2, 2'd2, 2'd1, 2, LINE_B, 7);
        @(posedge clk);
        @(negedge clk);
        clear_launch();
        expect_conflict(0, LINE_A, 1'b1);
        expect_conflict(0, LINE_B, 1'b1);
        expect_conflict(0, LINE_C, 1'b0);
        expect_conflict(1, LINE_A, 1'b0);
        expect_conflict(1, LINE_B, 1'b1);
        expect_conflict(2, LINE_A, 1'b1);
        expect_conflict(2, LINE_B, 1'b0);

        /* Same-line block survives until the last of two sources closes. */
        reset_dut();
        @(negedge clk);
        configure_launch(1, 2'd0, 2'd1, 3, LINE_A, 2);
        configure_launch(2, 2'd2, 2'd3, 9, LINE_A, 6);
        @(posedge clk);
        @(negedge clk);
        clear_launch();
        expect_conflict(0, LINE_A, 1'b1);
        pulse_terminal(1, 2'd0, 2'd1, 1'b0, 1'b1);
        if (pending_store_valid_o != 3'b100)
            $fatal(1, "first resolve damaged second pending slot");
        expect_conflict(0, LINE_A, 1'b1);
        pulse_terminal(2, 2'd2, 2'd3, 1'b1, 1'b1);
        expect_conflict(0, LINE_A, 1'b0);

        $display("A0_CLUSTER_STORE_ORDER_CONTROLLER_TB=PASS");
        $finish;
    end
endmodule
