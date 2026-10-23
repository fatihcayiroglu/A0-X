`timescale 1ns/1ps
module a0_p132_command_bus_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, req_valid = 0, req_write = 0, rsp_ready = 0;
    reg [7:0] req_addr = 0;
    reg [31:0] req_wdata = 0;
    wire req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;
    integer i;
    reg [31:0] status;
    reg completed;

    a0_p132_command_bus #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut (
        .clk(clk),.rst_n(rst_n),
        .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_wdata(req_wdata),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
        .rsp_rdata(rsp_rdata),.rsp_error(rsp_error)
    );

    task automatic access(
        input reg wr, input reg [7:0] addr, input reg [31:0] data,
        input reg expected_error, input reg [31:0] expected_data,
        input reg check_data
    );
        integer timeout;
        begin
            @(negedge clk);
            req_write = wr; req_addr = addr; req_wdata = data; req_valid = 1;
            timeout = 0;
            while (req_ready !== 1'b1) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 30) $fatal(1,"P132 request-ready timeout at %h",addr);
            end
            @(posedge clk);
            @(negedge clk);
            req_valid = 0;
            if (rsp_valid !== 1'b1 || rsp_error !== expected_error)
                $fatal(1,"P132 response error at %h: got valid=%b error=%b expected=%b",
                       addr,rsp_valid,rsp_error,expected_error);
            if (check_data && rsp_rdata !== expected_data)
                $fatal(1,"P132 read mismatch %h: got %h expected %h",
                       addr,rsp_rdata,expected_data);
            // Deliberate backpressure: response cannot mutate or vanish.
            repeat (3) begin
                @(posedge clk);
                @(negedge clk);
                if (!rsp_valid || rsp_error !== expected_error ||
                    (check_data && rsp_rdata !== expected_data) || req_ready)
                    $fatal(1,"P132 response not stable under backpressure");
            end
            rsp_ready = 1;
            @(posedge clk);
            @(negedge clk);
            rsp_ready = 0;
            if (rsp_valid !== 0) $fatal(1,"P132 response not consumed");
        end
    endtask

    task automatic wr(input reg [7:0] addr,input reg [31:0] data,input reg err);
        begin access(1,addr,data,err,0,0); end
    endtask
    task automatic rd(input reg [7:0] addr,input reg [31:0] expected);
        begin access(0,addr,0,0,expected,1); end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        rd(8'h00,32'h41305832);
        rd(8'h04,32'h00000000);
        wr(8'h08,32'h00000002,1); // triangle before initialization
        wr(8'h28,32'h80000000,1); // reserved bits
        wr(8'h08,32'h00000003,1); // conflicting clear/triangle
        wr(8'h05,32'h01020304,1); // misalignment
        wr(8'hfc,32'h01020304,1); // invalid register
        access(0,8'h08,0,1,0,0); // read write-only CONTROL
        wr(8'h0c,32'hff123456,0);
        rd(8'h0c,32'h00123456);
        wr(8'h10,32'h00ffffff,0);
        wr(8'h14,32'h00000000,0);
        wr(8'h18,32'h00000003,0);
        wr(8'h1c,32'h00030000,0);
        wr(8'h20,32'h00ab12cd,0);
        wr(8'h24,32'h00000010,0);
        wr(8'h28,32'h00000004,0); // depth_write, ALWAYS
        rd(8'h28,32'h00000004);
        wr(8'h08,32'h00000004,0); // sticky flag acknowledgment
        rd(8'h04,32'h00000000);
        wr(8'h08,32'h00000001,0); // begin clear
        wr(8'h08,32'h00000001,1); // reject concurrent second clear
        completed = 0;
        for (i=0;i<25;i=i+1) begin
            access(0,8'h04,0,0,0,0);
            status = rsp_rdata;
            if (status[2]) completed = 1;
        end
        if (!completed) $fatal(1,"P132 clear never completed");
        wr(8'h34,32'h00000000,0);
        rd(8'h38,32'h80123456);
        rd(8'h3c,32'h80ffffff);
        wr(8'h34,32'h00040000,0); // invalid Y=4
        rd(8'h38,32'h00000000);
        wr(8'h34,32'h00000000,0);
        wr(8'h08,32'h00000004,0);
        wr(8'h08,32'h00000002,0); // triangle launch
        completed = 0;
        for (i=0;i<40;i=i+1) begin
            access(0,8'h04,0,0,0,0);
            status = rsp_rdata;
            if (status[3]) completed = 1;
        end
        if (!completed) $fatal(1,"P132 triangle never completed");
        wr(8'h08,32'h00000004,0);
        access(0,8'h04,0,0,0,0);
        if (rsp_rdata[4:2] !== 3'b000)
            $fatal(1,"P132 acknowledgement failed %h",rsp_rdata);
        // Reset invalidates any pending response and all state.
        @(negedge clk);
        req_valid = 1; req_write = 0; req_addr = 0;
        @(posedge clk);
        @(negedge clk);
        req_valid = 0;
        if (!rsp_valid) $fatal(1,"P132 reset test: no response");
        rst_n = 0;
        @(posedge clk);
        @(negedge clk);
        if (rsp_valid || req_ready) $fatal(1,"P132 reset leaked response");
        rst_n = 1;
        rd(8'h04,0);
        rd(8'h0c,0);
        $display("P132_REAL_RTL_PASS bounded bus reset/invalid/backpressure/clear/draw");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1,"P132 global watchdog");
    end
endmodule
