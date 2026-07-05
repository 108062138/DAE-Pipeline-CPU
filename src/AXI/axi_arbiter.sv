// N-master to 1-slave AXI arbiter. Round-robin per channel pair; the grant is
// held for the whole burst (AW..B for writes, AR..RLAST for reads), never
// re-arbitrated per beat. Read and write paths arbitrate independently.
// The winning master's index is stamped into awid/arid so the slave-side ID
// identifies the source master.
module axi_arbiter #(
    parameter int NUM_MASTERS = 2,
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int ID_WIDTH    = 4
) (
    input  logic clk_i,
    input  logic rst_i,
    axi_if.slave  m [NUM_MASTERS],
    axi_if.master s
);
    localparam int STRB_WIDTH = DATA_WIDTH / 8;
    localparam int GRANT_W = (NUM_MASTERS > 1) ? $clog2(NUM_MASTERS) : 1;

    // Interface arrays cannot be indexed with runtime values, so unpack each
    // master's signals into plain arrays first.
    logic [NUM_MASTERS-1:0]  awvalid_v, wvalid_v, bready_v, arvalid_v, rready_v;
    logic [ADDR_WIDTH-1:0]   awaddr_v  [NUM_MASTERS];
    logic [7:0]              awlen_v   [NUM_MASTERS];
    logic [2:0]              awsize_v  [NUM_MASTERS];
    logic [1:0]              awburst_v [NUM_MASTERS];
    logic [NUM_MASTERS-1:0]  awlock_v;
    logic [3:0]              awcache_v [NUM_MASTERS];
    logic [3:0]              awqos_v   [NUM_MASTERS];
    logic [DATA_WIDTH-1:0]   wdata_v   [NUM_MASTERS];
    logic [STRB_WIDTH-1:0]   wstrb_v   [NUM_MASTERS];
    logic [NUM_MASTERS-1:0]  wlast_v;
    logic [ADDR_WIDTH-1:0]   araddr_v  [NUM_MASTERS];
    logic [7:0]              arlen_v   [NUM_MASTERS];
    logic [2:0]              arsize_v  [NUM_MASTERS];
    logic [1:0]              arburst_v [NUM_MASTERS];
    logic [NUM_MASTERS-1:0]  arlock_v;
    logic [3:0]              arcache_v [NUM_MASTERS];
    logic [3:0]              arqos_v   [NUM_MASTERS];

    logic [NUM_MASTERS-1:0]  awready_v, wready_v, bvalid_v, arready_v, rvalid_v;

    typedef enum logic [1:0] {
        W_IDLE = 2'd0,
        W_ADDR = 2'd1,
        W_DATA = 2'd2,
        W_RESP = 2'd3
    } w_state_e;

    typedef enum logic [1:0] {
        R_IDLE = 2'd0,
        R_ADDR = 2'd1,
        R_DATA = 2'd2
    } r_state_e;

    w_state_e w_state_q;
    r_state_e r_state_q;
    logic [GRANT_W-1:0] w_grant_q, r_grant_q;
    logic [GRANT_W-1:0] w_rr_q, r_rr_q;
    logic [GRANT_W-1:0] w_pick, r_pick;
    logic w_req_any, r_req_any;

    for (genvar i = 0; i < NUM_MASTERS; i++) begin : g_unpack
        assign awvalid_v[i] = m[i].awvalid;
        assign awaddr_v[i]  = m[i].awaddr;
        assign awlen_v[i]   = m[i].awlen;
        assign awsize_v[i]  = m[i].awsize;
        assign awburst_v[i] = m[i].awburst;
        assign awlock_v[i]  = m[i].awlock;
        assign awcache_v[i] = m[i].awcache;
        assign awqos_v[i]   = m[i].awqos;
        assign wvalid_v[i]  = m[i].wvalid;
        assign wdata_v[i]   = m[i].wdata;
        assign wstrb_v[i]   = m[i].wstrb;
        assign wlast_v[i]   = m[i].wlast;
        assign bready_v[i]  = m[i].bready;
        assign arvalid_v[i] = m[i].arvalid;
        assign araddr_v[i]  = m[i].araddr;
        assign arlen_v[i]   = m[i].arlen;
        assign arsize_v[i]  = m[i].arsize;
        assign arburst_v[i] = m[i].arburst;
        assign arlock_v[i]  = m[i].arlock;
        assign arcache_v[i] = m[i].arcache;
        assign arqos_v[i]   = m[i].arqos;
        assign rready_v[i]  = m[i].rready;

        assign m[i].awready = awready_v[i];
        assign m[i].wready  = wready_v[i];
        assign m[i].bvalid  = bvalid_v[i];
        assign m[i].bid     = s.bid;
        assign m[i].bresp   = s.bresp;
        assign m[i].arready = arready_v[i];
        assign m[i].rvalid  = rvalid_v[i];
        assign m[i].rid     = s.rid;
        assign m[i].rdata   = s.rdata;
        assign m[i].rresp   = s.rresp;
        assign m[i].rlast   = s.rlast;
    end

    int w_idx, r_idx;

    // Round-robin pick: first requester at or after the rotate pointer.
    always_comb begin
        w_pick = '0;
        w_req_any = 1'b0;
        w_idx = 0;
        for (int k = 0; k < NUM_MASTERS; k++) begin
            w_idx = (int'(w_rr_q) + k) % NUM_MASTERS;
            if (!w_req_any && awvalid_v[w_idx]) begin
                w_pick = GRANT_W'(w_idx);
                w_req_any = 1'b1;
            end
        end

        r_pick = '0;
        r_req_any = 1'b0;
        r_idx = 0;
        for (int k = 0; k < NUM_MASTERS; k++) begin
            r_idx = (int'(r_rr_q) + k) % NUM_MASTERS;
            if (!r_req_any && arvalid_v[r_idx]) begin
                r_pick = GRANT_W'(r_idx);
                r_req_any = 1'b1;
            end
        end
    end

    // Write path: forward the granted master's AW, then its W beats, then
    // route B back to it.
    always_comb begin
        s.awvalid = 1'b0;
        s.awid    = ID_WIDTH'(w_grant_q);
        s.awaddr  = awaddr_v[w_grant_q];
        s.awlen   = awlen_v[w_grant_q];
        s.awsize  = awsize_v[w_grant_q];
        s.awburst = awburst_v[w_grant_q];
        s.awlock  = awlock_v[w_grant_q];
        s.awcache = awcache_v[w_grant_q];
        s.awqos   = awqos_v[w_grant_q];
        s.wvalid  = 1'b0;
        s.wdata   = wdata_v[w_grant_q];
        s.wstrb   = wstrb_v[w_grant_q];
        s.wlast   = wlast_v[w_grant_q];
        s.bready  = 1'b0;
        awready_v = '0;
        wready_v  = '0;
        bvalid_v  = '0;

        if (w_state_q == W_ADDR) begin
            s.awvalid = awvalid_v[w_grant_q];
            awready_v[w_grant_q] = s.awready;
        end
        if (w_state_q == W_DATA) begin
            s.wvalid = wvalid_v[w_grant_q];
            wready_v[w_grant_q] = s.wready;
        end
        if (w_state_q == W_RESP) begin
            bvalid_v[w_grant_q] = s.bvalid;
            s.bready = bready_v[w_grant_q];
        end
    end

    // Read path: forward the granted master's AR, then stream R back to it.
    always_comb begin
        s.arvalid = 1'b0;
        s.arid    = ID_WIDTH'(r_grant_q);
        s.araddr  = araddr_v[r_grant_q];
        s.arlen   = arlen_v[r_grant_q];
        s.arsize  = arsize_v[r_grant_q];
        s.arburst = arburst_v[r_grant_q];
        s.arlock  = arlock_v[r_grant_q];
        s.arcache = arcache_v[r_grant_q];
        s.arqos   = arqos_v[r_grant_q];
        s.rready  = 1'b0;
        arready_v = '0;
        rvalid_v  = '0;

        if (r_state_q == R_ADDR) begin
            s.arvalid = arvalid_v[r_grant_q];
            arready_v[r_grant_q] = s.arready;
        end
        if (r_state_q == R_DATA) begin
            rvalid_v[r_grant_q] = s.rvalid;
            s.rready = rready_v[r_grant_q];
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            w_state_q <= W_IDLE;
            r_state_q <= R_IDLE;
            w_grant_q <= '0;
            r_grant_q <= '0;
            w_rr_q <= '0;
            r_rr_q <= '0;
        end else begin
            unique case (w_state_q)
                W_IDLE: begin
                    if (w_req_any) begin
                        w_grant_q <= w_pick;
                        w_rr_q <= GRANT_W'((int'(w_pick) + 1) % NUM_MASTERS);
                        w_state_q <= W_ADDR;
                    end
                end
                W_ADDR: begin
                    if (s.awvalid && s.awready) begin
                        w_state_q <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (s.wvalid && s.wready && s.wlast) begin
                        w_state_q <= W_RESP;
                    end
                end
                default: begin // W_RESP
                    if (s.bvalid && s.bready) begin
                        w_state_q <= W_IDLE;
                    end
                end
            endcase

            unique case (r_state_q)
                R_IDLE: begin
                    if (r_req_any) begin
                        r_grant_q <= r_pick;
                        r_rr_q <= GRANT_W'((int'(r_pick) + 1) % NUM_MASTERS);
                        r_state_q <= R_ADDR;
                    end
                end
                R_ADDR: begin
                    if (s.arvalid && s.arready) begin
                        r_state_q <= R_DATA;
                    end
                end
                default: begin // R_DATA
                    if (s.rvalid && s.rready && s.rlast) begin
                        r_state_q <= R_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
