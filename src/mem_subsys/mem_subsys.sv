`include "uarch.svh"

// Memory subsystem: split L1 I-cache / D-cache, each an AXI master,
// arbitrated onto a single AXI bus exposed via mem_axi (to DRAM).
// Master index 0 = I-cache, 1 = D-cache (stamped into awid/arid by the
// arbiter).
module mem_subsys #(
    parameter int NUM_LINES  = 256,
    parameter int LINE_WORDS = 4
) (
    input  logic                 clk_i,
    input  logic                 rst_i,

    input  uarch_pkg::mem_req_t  imem_req_i,
    output logic                 imem_req_ready_o,
    output uarch_pkg::mem_resp_t imem_resp_o,

    input  uarch_pkg::mem_req_t  dmem_req_i,
    output logic                 dmem_req_ready_o,
    output uarch_pkg::mem_resp_t dmem_resp_o,

    input  logic [3:0]           imem_qos_i,
    input  logic [3:0]           dmem_qos_i,

    axi_if.master                mem_axi
);
    logic rst_n;
    assign rst_n = ~rst_i;

    axi_if #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32),
        .ID_WIDTH(4)
    ) cache_axi [2] (
        .clk(clk_i),
        .rst_n(rst_n)
    );

    cache #(
        .WRITE_BACK(1'b0),
        .NUM_LINES(NUM_LINES),
        .LINE_WORDS(LINE_WORDS)
    ) u_icache (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .req_i(imem_req_i),
        .req_ready_o(imem_req_ready_o),
        .resp_o(imem_resp_o),
        .qos_i(imem_qos_i),
        .axi(cache_axi[0])
    );

    cache #(
        .WRITE_BACK(1'b1),
        .NUM_LINES(NUM_LINES),
        .LINE_WORDS(LINE_WORDS)
    ) u_dcache (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .req_i(dmem_req_i),
        .req_ready_o(dmem_req_ready_o),
        .resp_o(dmem_resp_o),
        .qos_i(dmem_qos_i),
        .axi(cache_axi[1])
    );

    axi_arbiter #(
        .NUM_MASTERS(2),
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32),
        .ID_WIDTH(4)
    ) u_arbiter (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .m(cache_axi),
        .s(mem_axi)
    );
endmodule
