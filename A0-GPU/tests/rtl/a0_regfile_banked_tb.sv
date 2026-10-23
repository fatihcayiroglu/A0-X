`timescale 1ns/1ps

module a0_regfile_banked_tb;

    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer WAVE_SIZE = 32;
    localparam integer PHYSICAL_LANES = 8;
    localparam integer BANK_COUNT = 4;
    localparam integer READ_PORTS = 3;
    localparam integer DATA_W = PHYSICAL_LANES * 32;

    logic clk;
    logic rst_n;

    logic [READ_PORTS-1:0] read_valid;
    logic [5:0] read_reg [0:READ_PORTS-1];
    logic [1:0] read_beat [0:READ_PORTS-1];
    logic [READ_PORTS-1:0] read_ready;
    logic [READ_PORTS-1:0] read_bank_conflict;
    logic [READ_PORTS-1:0] read_resp_valid;
    logic [DATA_W-1:0] read_resp_data [0:READ_PORTS-1];

    logic write_valid;
    logic [5:0] write_reg;
    logic [1:0] write_beat;
    logic [PHYSICAL_LANES-1:0] write_lane_mask;
    logic [DATA_W-1:0] write_data;
    logic write_ready;

    integer port_index;


    a0_regfile_banked #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(BANK_COUNT),
        .READ_PORTS(READ_PORTS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid(read_valid),
        .read_reg(read_reg),
        .read_beat(read_beat),
        .read_ready(read_ready),
        .read_bank_conflict(read_bank_conflict),
        .read_resp_valid(read_resp_valid),
        .read_resp_data(read_resp_data),
        .write_valid(write_valid),
        .write_reg(write_reg),
        .write_beat(write_beat),
        .write_lane_mask(write_lane_mask),
        .write_data(write_data),
        .write_ready(write_ready)
    );


    always #5 clk = ~clk;


    function automatic logic [DATA_W-1:0] make_beat(
        input logic [31:0] base
    );
        integer l;
        begin
            make_beat = '0;
            for (l = 0; l < PHYSICAL_LANES; l = l + 1) begin
                make_beat[l*32 +: 32] = base + l;
            end
        end
    endfunction


    function automatic logic [DATA_W-1:0] merge_masked(
        input logic [DATA_W-1:0] old_value,
        input logic [DATA_W-1:0] new_value,
        input logic [PHYSICAL_LANES-1:0] lane_mask
    );
        integer l;
        begin
            merge_masked = old_value;
            for (l = 0; l < PHYSICAL_LANES; l = l + 1) begin
                if (lane_mask[l]) begin
                    merge_masked[l*32 +: 32] = new_value[l*32 +: 32];
                end
            end
        end
    endfunction


    task automatic clear_reads;
        begin
            read_valid = '0;
            for (port_index = 0; port_index < READ_PORTS; port_index = port_index + 1) begin
                read_reg[port_index] = '0;
                read_beat[port_index] = '0;
            end
        end
    endtask


    task automatic clear_write;
        begin
            write_valid = 1'b0;
            write_reg = '0;
            write_beat = '0;
            write_lane_mask = '0;
            write_data = '0;
        end
    endtask


    task automatic reset_dut;
        begin
            clear_reads();
            clear_write();
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            if (read_resp_valid !== '0) begin
                $fatal(1, "read response valid after reset");
            end
            $display("RTL6_RF_RESET_CONTROL=PASS");
        end
    endtask


    task automatic write_one(
        input logic [5:0] reg_index,
        input logic [1:0] beat_index,
        input logic [PHYSICAL_LANES-1:0] lane_mask,
        input logic [DATA_W-1:0] value
    );
        begin
            @(negedge clk);
            write_valid = 1'b1;
            write_reg = reg_index;
            write_beat = beat_index;
            write_lane_mask = lane_mask;
            write_data = value;
            #1;
            if (!write_ready) begin
                $fatal(1, "write unexpectedly rejected reg=%0d beat=%0d", reg_index, beat_index);
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_write();
        end
    endtask


    task automatic read_one_expect(
        input logic [5:0] reg_index,
        input logic [1:0] beat_index,
        input logic [DATA_W-1:0] expected
    );
        begin
            @(negedge clk);
            clear_reads();
            read_valid[0] = 1'b1;
            read_reg[0] = reg_index;
            read_beat[0] = beat_index;
            #1;
            if (!read_ready[0] || read_bank_conflict[0]) begin
                $fatal(1, "single read not accepted reg=%0d beat=%0d", reg_index, beat_index);
            end
            @(posedge clk);
            #1;
            if (!read_resp_valid[0]) begin
                $fatal(1, "single read response missing");
            end
            if (read_resp_data[0] !== expected) begin
                $fatal(1, "single read mismatch reg=%0d beat=%0d", reg_index, beat_index);
            end
            @(negedge clk);
            clear_reads();
        end
    endtask


    initial begin
        logic [DATA_W-1:0] a;
        logic [DATA_W-1:0] b;
        logic [DATA_W-1:0] c;
        logic [DATA_W-1:0] old_value;
        logic [DATA_W-1:0] new_value;
        logic [DATA_W-1:0] merged_value;
        logic [PHYSICAL_LANES-1:0] partial_mask;

        clk = 1'b0;
        rst_n = 1'b0;
        clear_reads();
        clear_write();

        reset_dut();

        a = make_beat(32'h1000_0000);
        write_one(6'd5, 2'd2, '1, a);
        read_one_expect(6'd5, 2'd2, a);
        $display("RTL6_RF_BASIC_READ_WRITE=PASS");

        old_value = make_beat(32'h2000_0000);
        new_value = make_beat(32'hA000_0000);
        partial_mask = 8'b0101_1010;
        merged_value = merge_masked(old_value, new_value, partial_mask);
        write_one(6'd9, 2'd1, '1, old_value);
        write_one(6'd9, 2'd1, partial_mask, new_value);
        read_one_expect(6'd9, 2'd1, merged_value);
        $display("RTL6_RF_MASKED_WRITE=PASS");

        a = make_beat(32'h3000_0000);
        b = make_beat(32'h3100_0000);
        c = make_beat(32'h3200_0000);
        write_one(6'd0, 2'd0, '1, a);
        write_one(6'd1, 2'd0, '1, b);
        write_one(6'd2, 2'd0, '1, c);

        @(negedge clk);
        clear_reads();
        read_valid = 3'b111;
        read_reg[0] = 6'd0;
        read_reg[1] = 6'd1;
        read_reg[2] = 6'd2;
        read_beat[0] = 2'd0;
        read_beat[1] = 2'd0;
        read_beat[2] = 2'd0;
        #1;
        if (read_ready !== 3'b111 || read_bank_conflict !== 3'b000) begin
            $fatal(1, "different-bank reads did not issue in parallel ready=%b conflict=%b", read_ready, read_bank_conflict);
        end
        @(posedge clk);
        #1;
        if (read_resp_valid !== 3'b111) begin
            $fatal(1, "parallel response valid mismatch %b", read_resp_valid);
        end
        if (read_resp_data[0] !== a || read_resp_data[1] !== b || read_resp_data[2] !== c) begin
            $fatal(1, "parallel read data mismatch");
        end
        @(negedge clk);
        clear_reads();
        $display("RTL6_RF_DIFFERENT_BANK_PARALLEL=PASS");

        write_one(6'd4, 2'd0, '1, b);
        write_one(6'd8, 2'd0, '1, c);

        @(negedge clk);
        clear_reads();
        read_valid = 3'b111;
        read_reg[0] = 6'd0;
        read_reg[1] = 6'd4;
        read_reg[2] = 6'd8;
        read_beat[0] = 2'd0;
        read_beat[1] = 2'd0;
        read_beat[2] = 2'd0;
        #1;
        if (read_ready !== 3'b001) begin
            $fatal(1, "same-bank priority mismatch ready=%b", read_ready);
        end
        if (read_bank_conflict !== 3'b110) begin
            $fatal(1, "same-bank conflict mismatch conflict=%b", read_bank_conflict);
        end
        @(posedge clk);
        #1;
        if (read_resp_valid !== 3'b001 || read_resp_data[0] !== a) begin
            $fatal(1, "same-bank accepted response mismatch");
        end
        @(negedge clk);
        clear_reads();
        $display("RTL6_RF_SAME_BANK_CONFLICT=PASS");

        old_value = make_beat(32'h4000_0000);
        new_value = make_beat(32'hB000_0000);
        partial_mask = 8'b1010_0101;
        merged_value = merge_masked(old_value, new_value, partial_mask);
        write_one(6'd7, 2'd1, '1, old_value);

        @(negedge clk);
        clear_reads();
        read_valid[0] = 1'b1;
        read_reg[0] = 6'd7;
        read_beat[0] = 2'd1;
        write_valid = 1'b1;
        write_reg = 6'd7;
        write_beat = 2'd1;
        write_lane_mask = partial_mask;
        write_data = new_value;
        #1;
        if (!read_ready[0] || !write_ready) begin
            $fatal(1, "read/write bypass request not accepted");
        end
        @(posedge clk);
        #1;
        if (!read_resp_valid[0] || read_resp_data[0] !== merged_value) begin
            $fatal(1, "same-cycle write-through bypass mismatch");
        end
        @(negedge clk);
        clear_reads();
        clear_write();
        read_one_expect(6'd7, 2'd1, merged_value);
        $display("RTL6_RF_READ_AFTER_WRITE_BYPASS=PASS");

        a = make_beat(32'h5000_0000);
        b = make_beat(32'h5100_0000);
        write_one(6'd10, 2'd0, '1, a);
        write_one(6'd10, 2'd1, '1, b);
        read_one_expect(6'd10, 2'd0, a);
        read_one_expect(6'd10, 2'd1, b);
        $display("RTL6_RF_BEAT_ISOLATION=PASS");

        $display("RTL6_BANKED_REGFILE_TB=PASS");
        $finish;
    end

endmodule
