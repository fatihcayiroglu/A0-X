`timescale 1ns/1ps

module a0_memory_coalescer_tb;

    localparam integer WAVE_SIZE = 32;
    localparam integer ADDRESS_WIDTH = 32;
    localparam integer TRANSACTION_WORDS = 8;

    localparam integer COUNT_WIDTH =
        $clog2(WAVE_SIZE + 1);


    logic [WAVE_SIZE-1:0]
        lane_mask;

    logic [ADDRESS_WIDTH-1:0]
        word_addr [0:WAVE_SIZE-1];


    logic [COUNT_WIDTH-1:0]
        lane_requests;

    logic [COUNT_WIDTH-1:0]
        unique_words;

    logic [COUNT_WIDTH-1:0]
        transaction_count;

    logic [WAVE_SIZE-1:0]
        segment_valid;

    logic [ADDRESS_WIDTH-1:0]
        segment_id [0:WAVE_SIZE-1];


    logic [31:0]
        mask_image [0:0];

    logic [31:0]
        address_image [0:WAVE_SIZE-1];


    integer lane;
    integer slot;
    integer result_file;


    a0_memory_coalescer #(
        .WAVE_SIZE(
            WAVE_SIZE
        ),
        .ADDRESS_WIDTH(
            ADDRESS_WIDTH
        ),
        .TRANSACTION_WORDS(
            TRANSACTION_WORDS
        )
    ) dut (
        .lane_mask(
            lane_mask
        ),
        .word_addr(
            word_addr
        ),

        .lane_requests(
            lane_requests
        ),
        .unique_words(
            unique_words
        ),
        .transaction_count(
            transaction_count
        ),

        .segment_valid(
            segment_valid
        ),
        .segment_id(
            segment_id
        )
    );


    initial begin

        lane_mask = '0;

        for (
            lane = 0;
            lane < WAVE_SIZE;
            lane = lane + 1
        ) begin
            word_addr[lane] = '0;
        end


        $readmemh(
            "mask.hex",
            mask_image
        );

        $readmemh(
            "addresses.hex",
            address_image
        );


        lane_mask =
            mask_image[0][
                WAVE_SIZE-1:0
            ];


        for (
            lane = 0;
            lane < WAVE_SIZE;
            lane = lane + 1
        ) begin
            word_addr[lane] =
                address_image[lane];
        end


        /*
         * Allow combinational network to settle.
         */
        #1;


        result_file =
            $fopen(
                "coalescer_result.hex",
                "w"
            );


        if (result_file == 0) begin
            $fatal(
                1,
                "RTL3A result file open failed"
            );
        end


        /*
         * Header:
         *
         * [0] lane requests
         * [1] unique words
         * [2] transactions
         */
        $fdisplay(
            result_file,
            "%08x",
            lane_requests
        );

        $fdisplay(
            result_file,
            "%08x",
            unique_words
        );

        $fdisplay(
            result_file,
            "%08x",
            transaction_count
        );


        /*
         * Remaining lines are the deterministic
         * transaction segment IDs.
         */
        for (
            slot = 0;
            slot < WAVE_SIZE;
            slot = slot + 1
        ) begin

            if (segment_valid[slot]) begin

                $fdisplay(
                    result_file,
                    "%08x",
                    segment_id[slot]
                );
            end
        end


        $fclose(result_file);


        $display(
            "RTL3A_TB=PASS requests=%0d unique=%0d transactions=%0d",
            lane_requests,
            unique_words,
            transaction_count
        );


        $finish;
    end

endmodule
