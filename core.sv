`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE
// > Handles processing 1 block at a time
// > The core also has its own scheduler to manage control flow
// > Each core contains 1 fetcher & decoder, register files, ALUs, LSUs, PCs, and a shared L1 data cache
module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4,
    parameter L1_CACHE_SIZE_BYTES = 64,
    parameter L1_CACHE_LINE_SIZE_BYTES = 8
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Block Metadata
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Program Memory
    output reg program_mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input reg program_mem_read_ready,
    input reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory (single per-core miss/write-through port)
    output reg data_mem_read_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address,
    input reg data_mem_read_ready,
    input reg [DATA_MEM_DATA_BITS-1:0] data_mem_read_data,
    output reg data_mem_write_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address,
    output reg [DATA_MEM_DATA_BITS-1:0] data_mem_write_data,
    input reg data_mem_write_ready,

    // Optional cache stats for evaluation / debug
    output wire [31:0] l1_cache_accesses,
    output wire [31:0] l1_cache_hits,
    output wire [31:0] l1_cache_misses
);
    // State
    reg [2:0] core_state;
    reg [2:0] fetcher_state;
    reg [15:0] instruction;

    // Intermediate Signals
    reg [7:0] current_pc;
    wire [7:0] next_pc[THREADS_PER_BLOCK-1:0];
    reg [7:0] rs[THREADS_PER_BLOCK-1:0];
    reg [7:0] rt[THREADS_PER_BLOCK-1:0];
    reg [1:0] lsu_state[THREADS_PER_BLOCK-1:0];
    reg [7:0] lsu_out[THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out[THREADS_PER_BLOCK-1:0];

    // LSU <-> L1 cache signals
    reg [THREADS_PER_BLOCK-1:0] lsu_read_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_read_address [THREADS_PER_BLOCK-1:0];
    reg [THREADS_PER_BLOCK-1:0] lsu_read_ready;
    reg [DATA_MEM_DATA_BITS-1:0] lsu_read_data [THREADS_PER_BLOCK-1:0];
    reg [THREADS_PER_BLOCK-1:0] lsu_write_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_write_address [THREADS_PER_BLOCK-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] lsu_write_data [THREADS_PER_BLOCK-1:0];
    reg [THREADS_PER_BLOCK-1:0] lsu_write_ready;

    // Decoded Instruction Signals
    reg [3:0] decoded_rd_address;
    reg [3:0] decoded_rs_address;
    reg [3:0] decoded_rt_address;
    reg [2:0] decoded_nzp;
    reg [7:0] decoded_immediate;

    // Decoded Control Signals
    reg decoded_reg_write_enable;
    reg decoded_mem_read_enable;
    reg decoded_mem_write_enable;
    reg decoded_nzp_write_enable;
    reg [1:0] decoded_reg_input_mux;
    reg [1:0] decoded_alu_arithmetic_mux;
    reg decoded_alu_output_mux;
    reg decoded_pc_mux;
    reg decoded_ret;

    // Fetcher
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction)
    );

    // Decoder
    decoder decoder_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_ret(decoded_ret)
    );

    // Scheduler
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .fetcher_state(fetcher_state),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_ret(decoded_ret),
        .lsu_state(lsu_state),
        .current_pc(current_pc),
        .next_pc(next_pc),
        .done(done)
    );

    // Shared per-core L1 cache.
    // Design choice for tiny-gpu: keep the cache direct-mapped.
    // This minimizes hardware/state overhead and is enough to expose the
    // performance difference between contiguous and adversarial access patterns.
    l1_data_cache #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_PORTS(THREADS_PER_BLOCK),
        .CACHE_SIZE_BYTES(L1_CACHE_SIZE_BYTES),
        .LINE_SIZE_BYTES(L1_CACHE_LINE_SIZE_BYTES)
    ) l1_cache_instance (
        .clk(clk),
        .reset(reset),
        .consumer_read_valid(lsu_read_valid),
        .consumer_read_address(lsu_read_address),
        .consumer_read_ready(lsu_read_ready),
        .consumer_read_data(lsu_read_data),
        .consumer_write_valid(lsu_write_valid),
        .consumer_write_address(lsu_write_address),
        .consumer_write_data(lsu_write_data),
        .consumer_write_ready(lsu_write_ready),
        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_ready(data_mem_write_ready),
        .stat_accesses(l1_cache_accesses),
        .stat_hits(l1_cache_hits),
        .stat_misses(l1_cache_misses)
    );

    // Dedicated ALU, LSU, registers, & PC unit for each thread this core has capacity for
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            alu alu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                .decoded_alu_output_mux(decoded_alu_output_mux),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i])
            );

            lsu lsu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .mem_read_valid(lsu_read_valid[i]),
                .mem_read_address(lsu_read_address[i]),
                .mem_read_ready(lsu_read_ready[i]),
                .mem_read_data(lsu_read_data[i]),
                .mem_write_valid(lsu_write_valid[i]),
                .mem_write_address(lsu_write_address[i]),
                .mem_write_data(lsu_write_data[i]),
                .mem_write_ready(lsu_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state[i]),
                .lsu_out(lsu_out[i])
            );

            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .block_id(block_id),
                .core_state(core_state),
                .decoded_reg_write_enable(decoded_reg_write_enable),
                .decoded_reg_input_mux(decoded_reg_input_mux),
                .decoded_rd_address(decoded_rd_address),
                .decoded_rs_address(decoded_rs_address),
                .decoded_rt_address(decoded_rt_address),
                .decoded_immediate(decoded_immediate),
                .alu_out(alu_out[i]),
                .lsu_out(lsu_out[i]),
                .rs(rs[i]),
                .rt(rt[i])
            );

            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(core_state),
                .decoded_nzp(decoded_nzp),
                .decoded_immediate(decoded_immediate),
                .decoded_nzp_write_enable(decoded_nzp_write_enable),
                .decoded_pc_mux(decoded_pc_mux),
                .alu_out(alu_out[i]),
                .current_pc(current_pc),
                .next_pc(next_pc[i])
            );
        end
    endgenerate
endmodule
