// Simulation-only behavioral AXI4 slave DRAM (burst-capable, INCR only).
// Word-addressed array; upper address bits wrap, matching the old
// tb_top.sv dram[] indexing (addr[INDEX_W+1:2]).
// Reads with arid == BOOT_ROM_ID at byte addresses 0x0/0x4 return the boot
// trampoline (lui x1, 0x80000; jalr x0, 0(x1)), preserving the old
// instruction-fetch reset-vector special case.
module axi_dram_model #(
    parameter int MEM_WORDS   = 1 << 16,
    parameter int BOOT_ROM_ID = 0
) (
    input  logic clk_i,
    input  logic rst_i,
    axi_if.slave s
);
    localparam int INDEX_W = $clog2(MEM_WORDS);

    // Initialized hierarchically by the testbench (zero-fill, then optional
    // $readmemh) to avoid cross-module initial-block ordering races.
    logic [31:0] mem [MEM_WORDS];

    typedef enum logic [1:0] {
        W_IDLE = 2'd0,
        W_DATA = 2'd1,
        W_RESP = 2'd2
    } w_state_e;

    typedef enum logic [0:0] {
        R_IDLE = 1'd0,
        R_DATA = 1'd1
    } r_state_e;

    w_state_e w_state_q;
    r_state_e r_state_q;
    logic [29:0] waddr_q, raddr_q;
    logic [3:0] wid_q, rid_q;
    logic [7:0] rlen_q, rcnt_q;

    assign s.awready = (w_state_q == W_IDLE);
    assign s.wready  = (w_state_q == W_DATA);
    assign s.bvalid  = (w_state_q == W_RESP);
    assign s.bid     = wid_q;
    assign s.bresp   = 2'b00;

    assign s.arready = (r_state_q == R_IDLE);
    assign s.rvalid  = (r_state_q == R_DATA);
    assign s.rid     = rid_q;
    assign s.rresp   = 2'b00;
    assign s.rlast   = (rcnt_q == rlen_q);

    always_comb begin
        if (32'(rid_q) == 32'(BOOT_ROM_ID) && {raddr_q, 2'b00} == 32'h0000_0000) begin
            s.rdata = 32'h8000_00b7;
        end else if (32'(rid_q) == 32'(BOOT_ROM_ID) && {raddr_q, 2'b00} == 32'h0000_0004) begin
            s.rdata = 32'h0000_8067;
        end else begin
            s.rdata = mem[raddr_q[INDEX_W-1:0]];
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            w_state_q <= W_IDLE;
            r_state_q <= R_IDLE;
            waddr_q <= '0;
            raddr_q <= '0;
            wid_q <= '0;
            rid_q <= '0;
            rlen_q <= '0;
            rcnt_q <= '0;
        end else begin
            unique case (w_state_q)
                W_IDLE: begin
                    if (s.awvalid) begin
                        waddr_q <= s.awaddr[31:2];
                        wid_q <= s.awid;
                        w_state_q <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (s.wvalid) begin
                        if (s.wstrb[0]) mem[waddr_q[INDEX_W-1:0]][7:0]   <= s.wdata[7:0];
                        if (s.wstrb[1]) mem[waddr_q[INDEX_W-1:0]][15:8]  <= s.wdata[15:8];
                        if (s.wstrb[2]) mem[waddr_q[INDEX_W-1:0]][23:16] <= s.wdata[23:16];
                        if (s.wstrb[3]) mem[waddr_q[INDEX_W-1:0]][31:24] <= s.wdata[31:24];
                        waddr_q <= waddr_q + 1'b1;
                        if (s.wlast) begin
                            w_state_q <= W_RESP;
                        end
                    end
                end
                default: begin // W_RESP
                    if (s.bready) begin
                        w_state_q <= W_IDLE;
                    end
                end
            endcase

            unique case (r_state_q)
                R_IDLE: begin
                    if (s.arvalid) begin
                        raddr_q <= s.araddr[31:2];
                        rid_q <= s.arid;
                        rlen_q <= s.arlen;
                        rcnt_q <= '0;
                        r_state_q <= R_DATA;
                    end
                end
                default: begin // R_DATA
                    if (s.rready) begin
                        raddr_q <= raddr_q + 1'b1;
                        rcnt_q <= rcnt_q + 1'b1;
                        if (s.rlast) begin
                            r_state_q <= R_IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
