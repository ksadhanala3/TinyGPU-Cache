`default_nettype none
`timescale 1ns/1ns

// GPU
// > Built to use an external async memory with multi-channel read/write
// > Assumes that the program is loaded into program memory, data into
//   data memory, and threads into the device control register before the
//   start signal is triggered
// > Has memory controllers to interface between external memory and its
//   multiple cores
// > Each core includes a small private L1 data cache for its LSUs
module gpu #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter DATA_MEM_NUM_CHANNELS = 4,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4,
    parameter L1_CACHE_SIZE_BYTES = 64,
    parameter L1_CACHE_LINE_SIZE_BYTES = 8
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Device Control Register
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Program Memory
    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0],
    input wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0],

    // Data Memory
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready,

    // Optional aggregated cache counters for benchmarking
    output wire [31:0] l1_cache_accesses [NUM_CORES-1:0],
    output wire [31:0] l1_cache_hits [NUM_CORES-1:0],
    output wire [31:0] l1_cache_misses [NUM_CORES-1:0]
);
    // Control
    wire [7:0] thread_count;

    // Compute Core State
    reg [NUM_CORES-1:0] core_start;
    reg [NUM_CORES-1:0] core_reset;
    reg [NUM_CORES-1:0] core_done;
    reg [7:0] core_block_id [NUM_CORES-1:0];
    reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0];

    // L1 caches <> Data Memory Controller Channels
    localparam NUM_L1_CACHES = NUM_CORES;
    reg [NUM_L1_CACHES-1:0] cache_read_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] cache_read_address [NUM_L1_CACHES-1:0];
    reg [NUM_L1_CACHES-1:0] cache_read_ready;
    reg [DATA_MEM_DATA_BITS-1:0] cache_read_data [NUM_L1_CACHES-1:0];
    reg [NUM_L1_CACHES-1:0] cache_write_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] cache_write_address [NUM_L1_CACHES-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] cache_write_data [NUM_L1_CACHES-1:0];
    reg [NUM_L1_CACHES-1:0] cache_write_ready;

    // Fetcher <> Program Memory Controller Channels
    localparam NUM_FETCHERS = NUM_CORES;
    reg [NUM_FETCHERS-1:0] fetcher_read_valid;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] fetcher_read_address [NUM_FETCHERS-1:0];
    reg [NUM_FETCHERS-1:0] fetcher_read_ready;
    reg [PROGRAM_MEM_DATA_BITS-1:0] fetcher_read_data [NUM_FETCHERS-1:0];

    dcr dcr_instance (
        .clk(clk),
        .reset(reset),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    // Data Memory Controller
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_L1_CACHES),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk),
        .reset(reset),
        .consumer_read_valid(cache_read_valid),
        .consumer_read_address(cache_read_address),
        .consumer_read_ready(cache_read_ready),
        .consumer_read_data(cache_read_data),
        .consumer_write_valid(cache_write_valid),
        .consumer_write_address(cache_write_address),
        .consumer_write_data(cache_write_data),
        .consumer_write_ready(cache_write_ready),
        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_ready(data_mem_write_ready)
    );

    // Program Memory Controller
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk),
        .reset(reset),
        .consumer_read_valid(fetcher_read_valid),
        .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(fetcher_read_ready),
        .consumer_read_data(fetcher_read_data),
        .consumer_write_valid('0),
        .consumer_write_address('{default: '0}),
        .consumer_write_data('{default: '0}),
        .consumer_write_ready(),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .mem_write_valid(),
        .mem_write_address(),
        .mem_write_data(),
        .mem_write_ready('0)
    );

    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dispatch_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_done(core_done),
        .core_start(core_start),
        .core_reset(core_reset),
        .core_block_id(core_block_id),
        .core_thread_count(core_thread_count),
        .done(done)
    );

    // Compute Cores
    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : cores
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .L1_CACHE_SIZE_BYTES(L1_CACHE_SIZE_BYTES),
                .L1_CACHE_LINE_SIZE_BYTES(L1_CACHE_LINE_SIZE_BYTES)
            ) core_instance (
                .clk(clk),
                .reset(core_reset[i]),
                .start(core_start[i]),
                .done(core_done[i]),
                .block_id(core_block_id[i]),
                .thread_count(core_thread_count[i]),
                .program_mem_read_valid(fetcher_read_valid[i]),
                .program_mem_read_address(fetcher_read_address[i]),
                .program_mem_read_ready(fetcher_read_ready[i]),
                .program_mem_read_data(fetcher_read_data[i]),
                .data_mem_read_valid(cache_read_valid[i]),
                .data_mem_read_address(cache_read_address[i]),
                .data_mem_read_ready(cache_read_ready[i]),
                .data_mem_read_data(cache_read_data[i]),
                .data_mem_write_valid(cache_write_valid[i]),
                .data_mem_write_address(cache_write_address[i]),
                .data_mem_write_data(cache_write_data[i]),
                .data_mem_write_ready(cache_write_ready[i]),
                .l1_cache_accesses(l1_cache_accesses[i]),
                .l1_cache_hits(l1_cache_hits[i]),
                .l1_cache_misses(l1_cache_misses[i])
            );
        end
    endgenerate
endmodule
