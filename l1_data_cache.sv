`default_nettype none
`timescale 1ns/1ns

// PER-CORE L1 DATA CACHE
// > Shared by all LSUs in a core
// > Direct-mapped, write-through, write-allocate
// > Byte-addressed data memory (DATA_BITS is expected to be 8 in tiny-gpu)
// > On a load/store miss, fetches the full cache line from global memory before completing the request
module l1_data_cache #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_PORTS = 4,
    parameter CACHE_SIZE_BYTES = 64,
    parameter LINE_SIZE_BYTES = 8
) (
    input wire clk,
    input wire reset,

    // LSU-side interface (one port per thread LSU)
    input reg [NUM_PORTS-1:0] consumer_read_valid,
    input reg [ADDR_BITS-1:0] consumer_read_address [NUM_PORTS-1:0],
    output reg [NUM_PORTS-1:0] consumer_read_ready,
    output reg [DATA_BITS-1:0] consumer_read_data [NUM_PORTS-1:0],

    input reg [NUM_PORTS-1:0] consumer_write_valid,
    input reg [ADDR_BITS-1:0] consumer_write_address [NUM_PORTS-1:0],
    input reg [DATA_BITS-1:0] consumer_write_data [NUM_PORTS-1:0],
    output reg [NUM_PORTS-1:0] consumer_write_ready,

    // Global-memory-side interface (one miss/write-through transaction at a time)
    output reg mem_read_valid,
    output reg [ADDR_BITS-1:0] mem_read_address,
    input reg mem_read_ready,
    input reg [DATA_BITS-1:0] mem_read_data,

    output reg mem_write_valid,
    output reg [ADDR_BITS-1:0] mem_write_address,
    output reg [DATA_BITS-1:0] mem_write_data,
    input reg mem_write_ready,

    // Simple counters for evaluation / debug
    output reg [31:0] stat_accesses,
    output reg [31:0] stat_hits,
    output reg [31:0] stat_misses
);
    localparam NUM_LINES = CACHE_SIZE_BYTES / LINE_SIZE_BYTES;
    localparam OFFSET_BITS = $clog2(LINE_SIZE_BYTES);
    localparam INDEX_BITS = $clog2(NUM_LINES);
    localparam TAG_BITS = ADDR_BITS - OFFSET_BITS - INDEX_BITS;

    localparam IDLE = 2'b00;
    localparam FILLING = 2'b01;
    localparam STORE_WAIT = 2'b10;

    reg [1:0] cache_state;

    reg cache_valid [NUM_LINES-1:0];
    reg [TAG_BITS-1:0] cache_tag [NUM_LINES-1:0];
    reg [DATA_BITS-1:0] cache_data [NUM_LINES-1:0][LINE_SIZE_BYTES-1:0];

    reg [$clog2(NUM_PORTS)-1:0] outstanding_port;
    reg outstanding_is_write;
    reg [ADDR_BITS-1:0] outstanding_address;
    reg [DATA_BITS-1:0] outstanding_write_data;
    reg [OFFSET_BITS-1:0] fill_offset;
    reg [ADDR_BITS-1:0] outstanding_line_base;

    function automatic [OFFSET_BITS-1:0] get_offset(input [ADDR_BITS-1:0] address);
        get_offset = address[OFFSET_BITS-1:0];
    endfunction

    function automatic [INDEX_BITS-1:0] get_index(input [ADDR_BITS-1:0] address);
        get_index = address[OFFSET_BITS +: INDEX_BITS];
    endfunction

    function automatic [TAG_BITS-1:0] get_tag(input [ADDR_BITS-1:0] address);
        get_tag = address[ADDR_BITS-1 -: TAG_BITS];
    endfunction

    function automatic [ADDR_BITS-1:0] get_line_base(input [ADDR_BITS-1:0] address);
        get_line_base = {address[ADDR_BITS-1:OFFSET_BITS], {OFFSET_BITS {1'b0}}};
    endfunction

    integer line;
    integer byte_index;
    integer port;
    integer started_port;
    integer access_inc;
    integer hit_inc;
    integer miss_inc;
    reg [INDEX_BITS-1:0] active_index;
    reg [OFFSET_BITS-1:0] active_offset;
    reg [TAG_BITS-1:0] active_tag;
    reg hit;

    always @(posedge clk) begin
        if (reset) begin
            cache_state <= IDLE;

            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;

            consumer_read_ready <= 0;
            consumer_write_ready <= 0;

            stat_accesses <= 0;
            stat_hits <= 0;
            stat_misses <= 0;

            outstanding_port <= 0;
            outstanding_is_write <= 0;
            outstanding_address <= 0;
            outstanding_write_data <= 0;
            fill_offset <= 0;
            outstanding_line_base <= 0;

            for (line = 0; line < NUM_LINES; line = line + 1) begin
                cache_valid[line] <= 0;
                cache_tag[line] <= 0;
                for (byte_index = 0; byte_index < LINE_SIZE_BYTES; byte_index = byte_index + 1) begin
                    cache_data[line][byte_index] <= 0;
                end
            end
            for (port = 0; port < NUM_PORTS; port = port + 1) begin
                consumer_read_data[port] <= 0;
            end
        end else begin
            // Ready signals are single-cycle pulses.
            consumer_read_ready <= 0;
            consumer_write_ready <= 0;

            // Only assert global memory valid when this cycle actively issues a transaction.
            mem_read_valid <= 0;
            mem_write_valid <= 0;

            access_inc = 0;
            hit_inc = 0;
            miss_inc = 0;
            started_port = -1;

            case (cache_state)
                IDLE: begin
                    // First, opportunistically complete all hits in the current cycle.
                    for (port = 0; port < NUM_PORTS; port = port + 1) begin
                        if (consumer_read_valid[port]) begin
                            active_index = get_index(consumer_read_address[port]);
                            active_offset = get_offset(consumer_read_address[port]);
                            active_tag = get_tag(consumer_read_address[port]);
                            hit = cache_valid[active_index] && (cache_tag[active_index] == active_tag);

                            if (hit) begin
                                consumer_read_ready[port] <= 1;
                                consumer_read_data[port] <= cache_data[active_index][active_offset];
                                access_inc = access_inc + 1;
                                hit_inc = hit_inc + 1;
                            end else if (started_port == -1) begin
                                started_port = port;
                                outstanding_port <= port[$clog2(NUM_PORTS)-1:0];
                                outstanding_is_write <= 0;
                                outstanding_address <= consumer_read_address[port];
                                outstanding_write_data <= 0;
                                outstanding_line_base <= get_line_base(consumer_read_address[port]);
                                fill_offset <= 0;

                                mem_read_valid <= 1;
                                mem_read_address <= get_line_base(consumer_read_address[port]);
                                cache_state <= FILLING;

                                access_inc = access_inc + 1;
                                miss_inc = miss_inc + 1;
                            end
                        end else if (consumer_write_valid[port]) begin
                            active_index = get_index(consumer_write_address[port]);
                            active_offset = get_offset(consumer_write_address[port]);
                            active_tag = get_tag(consumer_write_address[port]);
                            hit = cache_valid[active_index] && (cache_tag[active_index] == active_tag);

                            if (hit && started_port == -1) begin
                                cache_data[active_index][active_offset] <= consumer_write_data[port];

                                outstanding_port <= port[$clog2(NUM_PORTS)-1:0];
                                outstanding_is_write <= 1;
                                outstanding_address <= consumer_write_address[port];
                                outstanding_write_data <= consumer_write_data[port];
                                cache_state <= STORE_WAIT;

                                mem_write_valid <= 1;
                                mem_write_address <= consumer_write_address[port];
                                mem_write_data <= consumer_write_data[port];

                                access_inc = access_inc + 1;
                                hit_inc = hit_inc + 1;
                                started_port = port;
                            end else if (!hit && started_port == -1) begin
                                started_port = port;
                                outstanding_port <= port[$clog2(NUM_PORTS)-1:0];
                                outstanding_is_write <= 1;
                                outstanding_address <= consumer_write_address[port];
                                outstanding_write_data <= consumer_write_data[port];
                                outstanding_line_base <= get_line_base(consumer_write_address[port]);
                                fill_offset <= 0;

                                mem_read_valid <= 1;
                                mem_read_address <= get_line_base(consumer_write_address[port]);
                                cache_state <= FILLING;

                                access_inc = access_inc + 1;
                                miss_inc = miss_inc + 1;
                            end
                        end
                    end
                end

                FILLING: begin
                    active_index = get_index(outstanding_address);
                    mem_read_valid <= 1;
                    mem_read_address <= outstanding_line_base + fill_offset;

                    if (mem_read_ready) begin
                        cache_data[active_index][fill_offset] <= mem_read_data;

                        if (fill_offset == LINE_SIZE_BYTES - 1) begin
                            cache_valid[active_index] <= 1;
                            cache_tag[active_index] <= get_tag(outstanding_address);

                            if (outstanding_is_write) begin
                                cache_data[active_index][get_offset(outstanding_address)] <= outstanding_write_data;
                                cache_state <= STORE_WAIT;
                            end else begin
                                consumer_read_ready[outstanding_port] <= 1;
                                if (get_offset(outstanding_address) == fill_offset) begin
                                    consumer_read_data[outstanding_port] <= mem_read_data;
                                end else begin
                                    consumer_read_data[outstanding_port] <= cache_data[active_index][get_offset(outstanding_address)];
                                end
                                cache_state <= IDLE;
                            end
                        end else begin
                            fill_offset <= fill_offset + 1'b1;
                        end
                    end
                end

                STORE_WAIT: begin
                    mem_write_valid <= 1;
                    mem_write_address <= outstanding_address;
                    mem_write_data <= outstanding_write_data;

                    if (mem_write_ready) begin
                        consumer_write_ready[outstanding_port] <= 1;
                        cache_state <= IDLE;
                    end
                end
            endcase

            stat_accesses <= stat_accesses + access_inc;
            stat_hits <= stat_hits + hit_inc;
            stat_misses <= stat_misses + miss_inc;
        end
    end
endmodule
