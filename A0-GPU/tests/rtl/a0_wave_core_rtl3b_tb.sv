`timescale 1ns/1ps

module a0_wave_core_rtl3b_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer VECTOR_REG_COUNT = 64;
    localparam integer SCALAR_REG_COUNT = 32;
    localparam integer PREDICATE_REG_COUNT = 16;
    localparam integer SCALAR_PREDICATE_REG_COUNT = 16;

    localparam integer GLOBAL_MEMORY_WORDS = 1024;
    localparam integer PROGRAM_WORDS = 256;

    localparam integer MEM_ADDR_WIDTH =
        $clog2(GLOBAL_MEMORY_WORDS);

    localparam logic [31:0]
        GLOBAL_MEMORY_WORDS_U32 =
            32'(GLOBAL_MEMORY_WORDS);

    logic clk;
    logic rst_n;
    logic run_enable;

    logic program_we;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        program_waddr;

    logic [63:0] program_wdata;

    logic vector_we;

    logic [$clog2(VECTOR_REG_COUNT)-1:0]
        vector_wreg;

    logic [$clog2(WAVE_SIZE)-1:0]
        vector_wlane;

    logic [31:0] vector_wdata;

    logic scalar_we;

    logic [$clog2(SCALAR_REG_COUNT)-1:0]
        scalar_wreg;

    logic [31:0] scalar_wdata;

    logic core_mem_req_valid;
    logic core_mem_req_write;

    logic [WAVE_SIZE-1:0]
        core_mem_req_lane_mask;

    logic [31:0]
        core_mem_req_addr [0:WAVE_SIZE-1];

    logic [31:0]
        core_mem_req_wdata [0:WAVE_SIZE-1];

    logic core_mem_resp_valid;
    logic core_mem_resp_fault;

    logic [31:0]
        core_mem_resp_rdata [0:WAVE_SIZE-1];


    logic txn_req_valid;
    logic txn_req_write;

    logic [31:0]
        txn_segment_id;

    logic [WAVE_SIZE-1:0]
        txn_lane_mask;

    logic [31:0]
        txn_word_addr [0:WAVE_SIZE-1];

    logic [31:0]
        txn_wdata [0:WAVE_SIZE-1];

    logic txn_resp_valid;
    logic txn_resp_fault;

    logic [31:0]
        txn_resp_rdata [0:WAVE_SIZE-1];


    logic halted;
    logic faulted;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        pc;


    logic [63:0]
        program_image [0:PROGRAM_WORDS-1];

    logic [31:0]
        vector_image
            [0:(VECTOR_REG_COUNT * WAVE_SIZE)-1];

    logic [31:0]
        scalar_image [0:SCALAR_REG_COUNT-1];

    logic [31:0]
        memory [0:GLOBAL_MEMORY_WORDS-1];


    integer architectural_requests;
    integer physical_transactions;
    integer expect_fault;
    integer cycles;

    integer mem_lane;

    integer cfg_word;
    integer cfg_reg;
    integer cfg_lane;

    integer dump_reg;
    integer dump_lane;
    integer dump_pred;
    integer dump_mem;

    integer vector_file;
    integer scalar_file;
    integer predicate_file;
    integer scalar_predicate_file;
    integer memory_file;
    integer control_file;


    a0_wave_core #(
        .WAVE_SIZE(WAVE_SIZE),
        .VECTOR_REG_COUNT(
            VECTOR_REG_COUNT
        ),
        .SCALAR_REG_COUNT(
            SCALAR_REG_COUNT
        ),
        .PREDICATE_REG_COUNT(
            PREDICATE_REG_COUNT
        ),
        .SCALAR_PREDICATE_REG_COUNT(
            SCALAR_PREDICATE_REG_COUNT
        ),
        .GLOBAL_MEMORY_WORDS(
            GLOBAL_MEMORY_WORDS
        ),
        .PROGRAM_WORDS(
            PROGRAM_WORDS
        )
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_enable(run_enable),

        .program_we(program_we),
        .program_waddr(program_waddr),
        .program_wdata(program_wdata),

        .vector_we(vector_we),
        .vector_wreg(vector_wreg),
        .vector_wlane(vector_wlane),
        .vector_wdata(vector_wdata),

        .scalar_we(scalar_we),
        .scalar_wreg(scalar_wreg),
        .scalar_wdata(scalar_wdata),

        .mem_req_valid(core_mem_req_valid),
        .mem_req_write(core_mem_req_write),
        .mem_req_lane_mask(
            core_mem_req_lane_mask
        ),
        .mem_req_addr(core_mem_req_addr),
        .mem_req_wdata(core_mem_req_wdata),

        .mem_resp_valid(core_mem_resp_valid),
        .mem_resp_fault(core_mem_resp_fault),
        .mem_resp_rdata(core_mem_resp_rdata),

        .halted(halted),
        .faulted(faulted),
        .pc(pc)
    );


    a0_memory_coalesced_bridge #(
        .WAVE_SIZE(WAVE_SIZE),
        .ADDRESS_WIDTH(32),
        .TRANSACTION_WORDS(8)
    ) memory_bridge (
        .clk(clk),
        .rst_n(rst_n),

        .up_req_valid(core_mem_req_valid),
        .up_req_write(core_mem_req_write),
        .up_req_lane_mask(
            core_mem_req_lane_mask
        ),
        .up_req_addr(core_mem_req_addr),
        .up_req_wdata(core_mem_req_wdata),

        .up_resp_valid(core_mem_resp_valid),
        .up_resp_fault(core_mem_resp_fault),
        .up_resp_rdata(core_mem_resp_rdata),

        .txn_req_valid(txn_req_valid),
        .txn_req_write(txn_req_write),
        .txn_segment_id(txn_segment_id),
        .txn_lane_mask(txn_lane_mask),
        .txn_word_addr(txn_word_addr),
        .txn_wdata(txn_wdata),

        .txn_resp_valid(txn_resp_valid),
        .txn_resp_fault(txn_resp_fault),
        .txn_resp_rdata(txn_resp_rdata)
    );


    always #1 clk = ~clk;


    /*
     * RTL3B physical segment RAM model.
     */
    always_ff @(posedge clk) begin : rtl3b_ram

        logic transaction_fault;

        if (!rst_n) begin

            txn_resp_valid <= 1'b0;
            txn_resp_fault <= 1'b0;

            architectural_requests <= 0;
            physical_transactions <= 0;

            for (
                mem_lane = 0;
                mem_lane < WAVE_SIZE;
                mem_lane = mem_lane + 1
            ) begin
                txn_resp_rdata[mem_lane]
                    <= 32'b0;
            end

        end else begin

            txn_resp_valid <= 1'b0;
            txn_resp_fault <= 1'b0;


            if (
                run_enable
                && core_mem_req_valid
            ) begin
                architectural_requests <=
                    architectural_requests + 1;
            end


            if (
                run_enable
                && txn_req_valid
            ) begin

                physical_transactions <=
                    physical_transactions + 1;

                transaction_fault = 1'b0;


                /*
                 * Validate complete physical
                 * transaction before mutation.
                 */
                for (
                    mem_lane = 0;
                    mem_lane < WAVE_SIZE;
                    mem_lane = mem_lane + 1
                ) begin

                    if (
                        txn_lane_mask[mem_lane]
                    ) begin

                        if (
                            txn_word_addr[mem_lane]
                            >=
                            GLOBAL_MEMORY_WORDS_U32
                        ) begin
                            transaction_fault =
                                1'b1;

                        end else if (
                            (
                                txn_word_addr[
                                    mem_lane
                                ] / 8
                            )
                            != txn_segment_id
                        ) begin
                            transaction_fault =
                                1'b1;
                        end
                    end
                end


                if (transaction_fault) begin

                    txn_resp_fault <= 1'b1;

                end else begin

                    for (
                        mem_lane = 0;
                        mem_lane < WAVE_SIZE;
                        mem_lane = mem_lane + 1
                    ) begin

                        if (
                            txn_lane_mask[mem_lane]
                        ) begin

                            if (txn_req_write) begin

                                memory[
                                    txn_word_addr[
                                        mem_lane
                                    ][MEM_ADDR_WIDTH-1:0]
                                ] <=
                                    txn_wdata[mem_lane];

                            end else begin

                                txn_resp_rdata[
                                    mem_lane
                                ] <= memory[
                                    txn_word_addr[
                                        mem_lane
                                    ][MEM_ADDR_WIDTH-1:0]
                                ];
                            end
                        end
                    end
                end


                txn_resp_valid <= 1'b1;
            end
        end
    end


    initial begin : rtl3b_main

        clk = 1'b0;
        rst_n = 1'b0;
        run_enable = 1'b0;

        program_we = 1'b0;
        program_waddr = '0;
        program_wdata = '0;

        vector_we = 1'b0;
        vector_wreg = '0;
        vector_wlane = '0;
        vector_wdata = '0;

        scalar_we = 1'b0;
        scalar_wreg = '0;
        scalar_wdata = '0;

        expect_fault = 0;

        void'(
            $value$plusargs(
                "EXPECT_FAULT=%d",
                expect_fault
            )
        );

        $readmemh(
            "program.hex",
            program_image
        );

        $readmemh(
            "vregs_init.hex",
            vector_image
        );

        $readmemh(
            "sregs_init.hex",
            scalar_image
        );

        $readmemh(
            "memory_init.hex",
            memory
        );


        /*
         * Reset architectural core state.
         */
        repeat (2) @(negedge clk);

        rst_n = 1'b1;


        /*
         * Load instruction memory.
         */
        for (
            cfg_word = 0;
            cfg_word < PROGRAM_WORDS;
            cfg_word = cfg_word + 1
        ) begin

            @(negedge clk);

            program_we = 1'b1;

            program_waddr =
                cfg_word[
                    $clog2(PROGRAM_WORDS)-1:0
                ];

            program_wdata =
                program_image[cfg_word];
        end

        @(negedge clk);
        program_we = 1'b0;


        /*
         * Load vector architectural state.
         */
        for (
            cfg_reg = 0;
            cfg_reg < VECTOR_REG_COUNT;
            cfg_reg = cfg_reg + 1
        ) begin

            for (
                cfg_lane = 0;
                cfg_lane < WAVE_SIZE;
                cfg_lane = cfg_lane + 1
            ) begin

                @(negedge clk);

                vector_we = 1'b1;

                vector_wreg =
                    cfg_reg[
                        $clog2(
                            VECTOR_REG_COUNT
                        )-1:0
                    ];

                vector_wlane =
                    cfg_lane[
                        $clog2(WAVE_SIZE)-1:0
                    ];

                vector_wdata =
                    vector_image[
                        cfg_reg * WAVE_SIZE
                        + cfg_lane
                    ];
            end
        end

        @(negedge clk);
        vector_we = 1'b0;


        /*
         * Load scalar architectural state.
         */
        for (
            cfg_reg = 0;
            cfg_reg < SCALAR_REG_COUNT;
            cfg_reg = cfg_reg + 1
        ) begin

            @(negedge clk);

            scalar_we = 1'b1;

            scalar_wreg =
                cfg_reg[
                    $clog2(
                        SCALAR_REG_COUNT
                    )-1:0
                ];

            scalar_wdata =
                scalar_image[cfg_reg];
        end

        @(negedge clk);
        scalar_we = 1'b0;


        /*
         * Begin architectural execution.
         */
        run_enable = 1'b1;

        cycles = 0;

        while (
            !halted
            && cycles < 512
        ) begin
            @(negedge clk);
            cycles = cycles + 1;
        end


        if (!halted) begin
            $fatal(
                1,
                "RTL3B timeout"
            );
        end


        /*
         * Directed active-invalid-address case.
         */
        if (expect_fault != 0) begin

            if (!faulted) begin
                $fatal(
                    1,
                    "RTL3B expected fault missing"
                );
            end

            /*
             * Bounds checking is core-side.
             * No invalid request may escape.
             */
            if (
                architectural_requests != 0
                || physical_transactions != 0
            ) begin
                $fatal(
                    1,
                    "RTL3B invalid access escaped to memory path"
                );
            end

            $display(
                "RTL3B_FAULT_TB=PASS cycles=%0d pc=%0d archreq=%0d transactions=%0d",
                cycles,
                pc,
                architectural_requests,
                physical_transactions
            );

            $finish;
            disable rtl3b_main;
        end


        if (faulted) begin
            $fatal(
                1,
                "RTL3B unexpected fault"
            );
        end


        vector_file =
            $fopen(
                "rtl_vregs.hex",
                "w"
            );

        scalar_file =
            $fopen(
                "rtl_sregs.hex",
                "w"
            );

        predicate_file =
            $fopen(
                "rtl_preds.hex",
                "w"
            );

        scalar_predicate_file =
            $fopen(
                "rtl_qpreds.hex",
                "w"
            );

        memory_file =
            $fopen(
                "rtl_memory.hex",
                "w"
            );

        control_file =
            $fopen(
                "rtl_control.hex",
                "w"
            );


        if (
            vector_file == 0
            || scalar_file == 0
            || predicate_file == 0
            || scalar_predicate_file == 0
            || memory_file == 0
            || control_file == 0
        ) begin
            $fatal(
                1,
                "RTL3B result-file open failed"
            );
        end


        for (
            dump_reg = 0;
            dump_reg < VECTOR_REG_COUNT;
            dump_reg = dump_reg + 1
        ) begin

            for (
                dump_lane = 0;
                dump_lane < WAVE_SIZE;
                dump_lane = dump_lane + 1
            ) begin

                $fdisplay(
                    vector_file,
                    "%08x",
                    dut.vector_regs[
                        dump_reg
                    ][dump_lane]
                );
            end
        end


        for (
            dump_reg = 0;
            dump_reg < SCALAR_REG_COUNT;
            dump_reg = dump_reg + 1
        ) begin

            $fdisplay(
                scalar_file,
                "%08x",
                dut.scalar_regs[
                    dump_reg
                ]
            );
        end


        for (
            dump_pred = 0;
            dump_pred
                < PREDICATE_REG_COUNT;
            dump_pred = dump_pred + 1
        ) begin

            $fdisplay(
                predicate_file,
                "%08x",
                dut.predicate_regs[
                    dump_pred
                ]
            );
        end


        for (
            dump_pred = 0;
            dump_pred
                < SCALAR_PREDICATE_REG_COUNT;
            dump_pred = dump_pred + 1
        ) begin

            $fdisplay(
                scalar_predicate_file,
                "%08x",
                dut.scalar_predicate_regs[
                    dump_pred
                ]
            );
        end


        for (
            dump_mem = 0;
            dump_mem < GLOBAL_MEMORY_WORDS;
            dump_mem = dump_mem + 1
        ) begin

            $fdisplay(
                memory_file,
                "%08x",
                memory[dump_mem]
            );
        end


        /*
         * control[0] = EXEC_MASK
         * control[1] = PC
         * control[2] = reconvergence depth
         * control[3] = architectural memory requests
         * control[4] = physical segment transactions
         */
        $fdisplay(
            control_file,
            "%08x",
            dut.exec_mask
        );

        $fdisplay(
            control_file,
            "%08x",
            pc
        );

        $fdisplay(
            control_file,
            "%08x",
            dut.reconv_sp
        );

        $fdisplay(
            control_file,
            "%08x",
            architectural_requests
        );

        $fdisplay(
            control_file,
            "%08x",
            physical_transactions
        );


        $fclose(vector_file);
        $fclose(scalar_file);
        $fclose(predicate_file);
        $fclose(scalar_predicate_file);
        $fclose(memory_file);
        $fclose(control_file);


        $display(
            "RTL3B_TB=PASS cycles=%0d pc=%0d archreq=%0d transactions=%0d",
            cycles,
            pc,
            architectural_requests,
            physical_transactions
        );

        $finish;
    end

endmodule
