`timescale 1ns/1ps
module a0_store_commit_dirty_l2_router_tb;
    localparam integer COMMIT_PORT_COUNT=2;
    localparam integer STORE_LANES=4;
    localparam integer SLICE_COUNT=2;
    localparam integer LINE_WORDS=4;
    localparam integer SLICE_HASH_SHIFT=2;
    logic clk,rst_n;
    logic[COMMIT_PORT_COUNT-1:0]commit_valid_i,commit_ready_o;
    logic[STORE_LANES-1:0]commit_lane_mask_i[0:COMMIT_PORT_COUNT-1];
    logic[31:0]commit_word_addr_i[0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic[31:0]commit_wdata_i[0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic[SLICE_COUNT-1:0]slice_store_valid_o,slice_store_ready_i;
    logic[STORE_LANES-1:0]slice_store_lane_mask_o[0:SLICE_COUNT-1];
    logic[31:0]slice_store_word_addr_o[0:SLICE_COUNT-1][0:STORE_LANES-1];
    logic[31:0]slice_store_wdata_o[0:SLICE_COUNT-1][0:STORE_LANES-1];
    logic busy_o,source_protocol_error_o;
    integer s,l;integer fire_count[0:SLICE_COUNT-1];

    a0_store_commit_dirty_l2_router #(
        .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT),.STORE_LANES(STORE_LANES),
        .SLICE_COUNT(SLICE_COUNT),.LINE_WORDS(LINE_WORDS),
        .SLICE_HASH_SHIFT(SLICE_HASH_SHIFT)
    ) dut(.*);
    initial clk=0; always #5 clk=~clk;

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            for(integer x=0;x<SLICE_COUNT;x=x+1) fire_count[x]<=0;
        end else begin
            for(integer x=0;x<SLICE_COUNT;x=x+1)
                if(slice_store_valid_o[x]&&slice_store_ready_i[x]) fire_count[x]<=fire_count[x]+1;
        end
    end

    task automatic clear_inputs; begin
        commit_valid_i='0; slice_store_ready_i='0;
        for(s=0;s<COMMIT_PORT_COUNT;s=s+1) begin
            commit_lane_mask_i[s]='0;
            for(l=0;l<STORE_LANES;l=l+1) begin
                commit_word_addr_i[s][l]='0; commit_wdata_i[s][l]='0;
            end
        end
    end endtask

    initial begin
        rst_n=0; clear_inputs(); repeat(3) @(posedge clk); @(negedge clk); rst_n=1;

        // Port0 spans both home slices: line0->slice0, line1->slice1.
        commit_valid_i='1;
        commit_lane_mask_i[0]=4'b0011;
        commit_word_addr_i[0][0]=32'd0; commit_wdata_i[0][0]=32'hA0A0_0000;
        commit_word_addr_i[0][1]=32'd4; commit_wdata_i[0][1]=32'hB0B0_0001;
        // Port1 is also pending, used to prove bounded RR handoff.
        commit_lane_mask_i[1]=4'b0001;
        commit_word_addr_i[1][0]=32'd8; commit_wdata_i[1][0]=32'hC0C0_0002;
        slice_store_ready_i=2'b01; #1;
        if(slice_store_valid_o!=2'b11) $fatal(1,"P24 expected both slice valids");
        if(commit_ready_o!=2'b00) $fatal(1,"P24 upstream ack escaped before all slices");
        if(slice_store_lane_mask_o[0]!=4'b0001 || slice_store_lane_mask_o[1]!=4'b0010)
            $fatal(1,"P24 lane partition");
        if(slice_store_word_addr_o[0][0]!=32'd0 || slice_store_wdata_o[0][0]!=32'hA0A0_0000)
            $fatal(1,"P24 slice0 identity");
        if(slice_store_word_addr_o[1][1]!=32'd4 || slice_store_wdata_o[1][1]!=32'hB0B0_0001)
            $fatal(1,"P24 slice1 identity");
        @(posedge clk); @(negedge clk); #1;
        if(!busy_o || slice_store_valid_o!=2'b10 || commit_ready_o!=0)
            $fatal(1,"P24 partial acceptance state");
        if(fire_count[0]!=1 || fire_count[1]!=0) $fatal(1,"P24 first slice count");
        $display("PROD_SEAM_P24_PARTIAL_SLICE_ACCEPT_NO_DUPLICATE=PASS");
        $display("PROD_SEAM_P24_EXACT_LANE_ADDRESS_DATA_ROUTING=PASS");

        // Finish the second slice; only now may P7-shaped upstream see ready.
        slice_store_ready_i=2'b11; #1;
        if(slice_store_valid_o!=2'b10 || commit_ready_o!=2'b01)
            $fatal(1,"P24 final upstream ack");
        @(posedge clk); @(negedge clk);
        commit_valid_i[0]=0; #1;
        if(fire_count[0]!=1 || fire_count[1]!=1) $fatal(1,"P24 duplicate slice write");
        $display("PROD_SEAM_P24_UPSTREAM_ACK_AFTER_ALL_SLICES=PASS");

        // RR moved to port1 and must not starve it.
        #1;
        if(!commit_ready_o[1] || commit_ready_o[0]) $fatal(1,"P24 RR handoff");
        if(slice_store_valid_o!=2'b01 || slice_store_lane_mask_o[0]!=4'b0001)
            $fatal(1,"P24 port1 route");
        @(posedge clk); @(negedge clk); commit_valid_i[1]=0; #1;
        if(fire_count[0]!=2 || fire_count[1]!=1) $fatal(1,"P24 final fire counts");
        if(source_protocol_error_o||busy_o) $fatal(1,"P24 final diagnostics");
        $display("PROD_SEAM_P24_ROUND_ROBIN_COMMIT_PROGRESS=PASS");
        $display("PROD_SEAM_P24_EXACTLY_ONCE_COMMIT_ACK=PASS");
        $display("PROD_SEAM_P24_ROUTER_BEHAVIOR=PASS");
        $finish;
    end
endmodule
