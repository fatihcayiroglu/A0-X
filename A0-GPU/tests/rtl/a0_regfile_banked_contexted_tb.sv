`timescale 1ns/1ps

module a0_regfile_banked_contexted_tb;

    localparam integer CONTEXT_COUNT = 2;
    localparam integer VECTOR_REG_COUNT = 8;
    localparam integer WAVE_SIZE = 8;
    localparam integer PHYSICAL_LANES = 4;
    localparam integer BANK_COUNT = 4;
    localparam integer READ_PORTS = 2;
    localparam integer DATA_W = PHYSICAL_LANES * 32;

    logic clk;
    logic rst_n;

    logic [READ_PORTS-1:0] read_valid;
    logic [0:0] read_context [0:READ_PORTS-1];
    logic [2:0] read_reg [0:READ_PORTS-1];
    logic [0:0] read_beat [0:READ_PORTS-1];
    logic [READ_PORTS-1:0] read_ready;
    logic [READ_PORTS-1:0] read_bank_conflict;
    logic [READ_PORTS-1:0] read_resp_valid;
    logic [DATA_W-1:0] read_resp_data [0:READ_PORTS-1];

    logic write_valid;
    logic [0:0] write_context;
    logic [2:0] write_reg;
    logic [0:0] write_beat;
    logic [PHYSICAL_LANES-1:0] write_lane_mask;
    logic [DATA_W-1:0] write_data;
    logic write_ready;

    localparam logic [DATA_W-1:0] CTX0_A = {
        32'hA000_0003,
        32'hA000_0002,
        32'hA000_0001,
        32'hA000_0000
    };

    localparam logic [DATA_W-1:0] CTX1_B = {
        32'hB000_0003,
        32'hB000_0002,
        32'hB000_0001,
        32'hB000_0000
    };

    localparam logic [DATA_W-1:0] CTX0_MASKED = {
        32'hA000_0003,
        32'hCCCC_0002,
        32'hA000_0001,
        32'hDDDD_0000
    };


    a0_regfile_banked_contexted #(
        .CONTEXT_COUNT(CONTEXT_COUNT),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(BANK_COUNT),
        .READ_PORTS(READ_PORTS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid(read_valid),
        .read_context(read_context),
        .read_reg(read_reg),
        .read_beat(read_beat),
        .read_ready(read_ready),
        .read_bank_conflict(read_bank_conflict),
        .read_resp_valid(read_resp_valid),
        .read_resp_data(read_resp_data),
        .write_valid(write_valid),
        .write_context(write_context),
        .write_reg(write_reg),
        .write_beat(write_beat),
        .write_lane_mask(write_lane_mask),
        .write_data(write_data),
        .write_ready(write_ready)
    );


    always #5 clk = ~clk;


    task automatic clear_io;
        begin
            read_valid = '0;
            write_valid = 1'b0;
            write_context = '0;
            write_reg = '0;
            write_beat = '0;
            write_lane_mask = '0;
            write_data = '0;
        end
    endtask


    task automatic write_full(
        input logic context_id,
        input logic [2:0] reg_id,
        input logic [DATA_W-1:0] value
    );
        begin
            @(negedge clk);
            clear_io();
            write_valid = 1'b1;
            write_context = context_id;
            write_reg = reg_id;
            write_beat = 1'd0;
            write_lane_mask = '1;
            write_data = value;
            #1;
            if (!write_ready) begin
                $fatal(1, "contexted RF full write rejected");
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_io();
        end
    endtask


    task automatic read_expect(
        input integer port_id,
        input logic context_id,
        input logic [2:0] reg_id,
        input logic [DATA_W-1:0] expected
    );
        begin
            @(negedge clk);
            clear_io();
            read_valid[port_id] = 1'b1;
            read_context[port_id] = context_id;
            read_reg[port_id] = reg_id;
            read_beat[port_id] = 1'd0;
            #1;
            if (!read_ready[port_id]) begin
                $fatal(1, "contexted RF read rejected port=%0d", port_id);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            read_valid = '0;
            #1;
            if (
                !read_resp_valid[port_id]
                || read_resp_data[port_id] !== expected
            ) begin
                $fatal(
                    1,
                    "contexted RF read mismatch port=%0d ctx=%0d expected=%h actual=%h",
                    port_id,
                    context_id,
                    expected,
                    read_resp_data[port_id]
                );
            end
        end
    endtask


    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        read_context[0] = '0;
        read_context[1] = '0;
        read_reg[0] = '0;
        read_reg[1] = '0;
        read_beat[0] = '0;
        read_beat[1] = '0;
        clear_io();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (read_resp_valid != '0) begin
            $fatal(1, "contexted RF response-valid not reset");
        end
        $display("RTL7B_CONTEXT_RF_RESET_CONTROL=PASS");

        /* Same logical register, independent resident contexts. */
        write_full(1'd0, 3'd1, CTX0_A);
        write_full(1'd1, 3'd1, CTX1_B);
        read_expect(0, 1'd0, 3'd1, CTX0_A);
        read_expect(0, 1'd1, 3'd1, CTX1_B);
        $display("RTL7B_CONTEXT_RF_ISOLATION=PASS");

        /* Context0 V1 and context1 V1 map to the same physical bank here. */
        @(negedge clk);
        clear_io();
        read_valid = 2'b11;
        read_context[0] = 1'd0;
        read_context[1] = 1'd1;
        read_reg[0] = 3'd1;
        read_reg[1] = 3'd1;
        read_beat[0] = 1'd0;
        read_beat[1] = 1'd0;
        #1;
        if (
            read_ready != 2'b01
            || read_bank_conflict != 2'b10
        ) begin
            $fatal(
                1,
                "cross-context bank conflict mismatch ready=%b conflict=%b",
                read_ready,
                read_bank_conflict
            );
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_io();
        $display("RTL7B_CONTEXT_RF_BANK_CONFLICT=PASS");

        /* Lane-masked physical write must remain context-local. */
        write_valid = 1'b1;
        write_context = 1'd0;
        write_reg = 3'd1;
        write_beat = 1'd0;
        write_lane_mask = 4'b0101;
        write_data = {
            32'hEEEE_0003,
            32'hCCCC_0002,
            32'hEEEE_0001,
            32'hDDDD_0000
        };
        #1;
        if (!write_ready) begin
            $fatal(1, "contexted RF masked write rejected");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_io();
        read_expect(0, 1'd0, 3'd1, CTX0_MASKED);
        read_expect(0, 1'd1, 3'd1, CTX1_B);
        $display("RTL7B_CONTEXT_RF_MASKED_WRITE=PASS");

        /* Exact context/reg/beat read-write collision uses merged bypass. */
        @(negedge clk);
        clear_io();
        read_valid[0] = 1'b1;
        read_context[0] = 1'd0;
        read_reg[0] = 3'd1;
        read_beat[0] = 1'd0;
        write_valid = 1'b1;
        write_context = 1'd0;
        write_reg = 3'd1;
        write_beat = 1'd0;
        write_lane_mask = 4'b0010;
        write_data = {
            32'h0,
            32'h0,
            32'hFACE_0001,
            32'h0
        };
        #1;
        if (!read_ready[0] || !write_ready) begin
            $fatal(1, "contexted RF bypass transaction not accepted");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_io();
        #1;
        if (
            !read_resp_valid[0]
            || read_resp_data[0][63:32] !== 32'hFACE_0001
            || read_resp_data[0][31:0] !== 32'hDDDD_0000
            || read_resp_data[0][95:64] !== 32'hCCCC_0002
            || read_resp_data[0][127:96] !== 32'hA000_0003
        ) begin
            $fatal(1, "exact contexted read/write bypass mismatch");
        end
        $display("RTL7B_CONTEXT_RF_BYPASS=PASS");

        /* Same logical address in a different context must not bypass. */
        @(negedge clk);
        clear_io();
        read_valid[0] = 1'b1;
        read_context[0] = 1'd1;
        read_reg[0] = 3'd1;
        read_beat[0] = 1'd0;
        write_valid = 1'b1;
        write_context = 1'd0;
        write_reg = 3'd1;
        write_beat = 1'd0;
        write_lane_mask = 4'b0001;
        write_data = {
            32'h0,
            32'h0,
            32'h0,
            32'h1234_5678
        };
        #1;
        if (!read_ready[0] || !write_ready) begin
            $fatal(1, "cross-context read/write transaction rejected");
        end
        @(posedge clk);
        #1;
        @(negedge clk);
        clear_io();
        #1;
        if (
            !read_resp_valid[0]
            || read_resp_data[0] !== CTX1_B
        ) begin
            $fatal(1, "cross-context write incorrectly bypassed into read");
        end
        $display("RTL7B_CONTEXT_RF_NO_CROSS_BYPASS=PASS");

        $display("RTL7B_CONTEXTED_REGFILE_TB=PASS");
        $finish;
    end

endmodule
