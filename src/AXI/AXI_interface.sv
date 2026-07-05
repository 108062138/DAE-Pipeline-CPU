// AXI4 interface (full burst support). Burst field widths are fixed by the
// AXI4 spec, so only ADDR/DATA/ID widths are parameterized.
// AWPROT/ARPROT are intentionally omitted: single master domain, no
// protection unit downstream. AWQOS/ARQOS are real signals consumed by the
// interconnect arbiter.
interface axi_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int ID_WIDTH   = 4
) (
    input logic clk,
    input logic rst_n
);
    localparam int STRB_WIDTH = DATA_WIDTH / 8;

    // Write address channel (AW)
    logic [ID_WIDTH-1:0]    awid;
    logic [ADDR_WIDTH-1:0]  awaddr;
    logic [7:0]             awlen;
    logic [2:0]             awsize;
    logic [1:0]             awburst;
    logic                   awlock;
    logic [3:0]             awcache;
    logic [3:0]             awqos;
    logic                   awvalid;
    logic                   awready;

    // Write data channel (W)
    logic [DATA_WIDTH-1:0]  wdata;
    logic [STRB_WIDTH-1:0]  wstrb;
    logic                   wlast;
    logic                   wvalid;
    logic                   wready;

    // Write response channel (B)
    logic [ID_WIDTH-1:0]    bid;
    logic [1:0]             bresp;
    logic                   bvalid;
    logic                   bready;

    // Read address channel (AR)
    logic [ID_WIDTH-1:0]    arid;
    logic [ADDR_WIDTH-1:0]  araddr;
    logic [7:0]             arlen;
    logic [2:0]             arsize;
    logic [1:0]             arburst;
    logic                   arlock;
    logic [3:0]             arcache;
    logic [3:0]             arqos;
    logic                   arvalid;
    logic                   arready;

    // Read data channel (R)
    logic [ID_WIDTH-1:0]    rid;
    logic [DATA_WIDTH-1:0]  rdata;
    logic [1:0]             rresp;
    logic                   rlast;
    logic                   rvalid;
    logic                   rready;

    modport master (
        input  clk,
        input  rst_n,
        // AW
        output awid,
        output awaddr,
        output awlen,
        output awsize,
        output awburst,
        output awlock,
        output awcache,
        output awqos,
        output awvalid,
        input  awready,
        // W
        output wdata,
        output wstrb,
        output wlast,
        output wvalid,
        input  wready,
        // B
        input  bid,
        input  bresp,
        input  bvalid,
        output bready,
        // AR
        output arid,
        output araddr,
        output arlen,
        output arsize,
        output arburst,
        output arlock,
        output arcache,
        output arqos,
        output arvalid,
        input  arready,
        // R
        input  rid,
        input  rdata,
        input  rresp,
        input  rlast,
        input  rvalid,
        output rready
    );

    modport slave (
        input  clk,
        input  rst_n,
        // AW
        input  awid,
        input  awaddr,
        input  awlen,
        input  awsize,
        input  awburst,
        input  awlock,
        input  awcache,
        input  awqos,
        input  awvalid,
        output awready,
        // W
        input  wdata,
        input  wstrb,
        input  wlast,
        input  wvalid,
        output wready,
        // B
        output bid,
        output bresp,
        output bvalid,
        input  bready,
        // AR
        input  arid,
        input  araddr,
        input  arlen,
        input  arsize,
        input  arburst,
        input  arlock,
        input  arcache,
        input  arqos,
        input  arvalid,
        output arready,
        // R
        output rid,
        output rdata,
        output rresp,
        output rlast,
        output rvalid,
        input  rready
    );
endinterface : axi_if
