`include "uarch.svh"

// Direct-mapped cache bridging the core's single-beat mem_req_t/mem_resp_t
// protocol to AXI4 bursts (line fill / dirty write-back).
// WRITE_BACK=1: write-back, write-allocate (D-cache).
// WRITE_BACK=0: read-only (I-cache); the write channels are tied off.
module cache #(
    parameter bit WRITE_BACK = 1'b1,
    parameter int NUM_LINES  = 256,
    parameter int LINE_WORDS = 4
) (
    input  logic                 clk_i,
    input  logic                 rst_i,

    input  uarch_pkg::mem_req_t  req_i,
    output logic                 req_ready_o,
    output uarch_pkg::mem_resp_t resp_o,

    input  logic [3:0]           qos_i,

    axi_if.master                axi
);
    import uarch_pkg::*;

    localparam int WORD_OFF_W = $clog2(LINE_WORDS);
    localparam int OFFSET_W   = WORD_OFF_W + 2;
    localparam int INDEX_W    = $clog2(NUM_LINES);
    localparam int TAG_W      = 32 - INDEX_W - OFFSET_W;
    localparam int BEAT_W     = (LINE_WORDS > 1) ? $clog2(LINE_WORDS) : 1;

    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        LOOKUP    = 3'd1,
        WB_ADDR   = 3'd2,
        WB_DATA   = 3'd3,
        WB_RESP   = 3'd4,
        FILL_ADDR = 3'd5,
        FILL_DATA = 3'd6,
        RESP      = 3'd7
    } state_e;

    state_e state_q;
    mem_req_t req_q;
    logic [BEAT_W-1:0] beat_q;
    logic [31:0] resp_data_q;
    logic err_q;

    logic [31:0] data_ram [NUM_LINES][LINE_WORDS];
    logic [TAG_W-1:0] tag_ram [NUM_LINES];
    logic [NUM_LINES-1:0] valid_q;
    logic [NUM_LINES-1:0] dirty_q;

    logic [TAG_W-1:0] req_tag;
    logic [INDEX_W-1:0] req_idx;
    logic [WORD_OFF_W-1:0] req_word;
    logic hit;

    assign req_tag  = req_q.addr[31 -: TAG_W];
    assign req_idx  = req_q.addr[OFFSET_W +: INDEX_W];
    assign req_word = req_q.addr[2 +: WORD_OFF_W];
    assign hit = valid_q[req_idx] && (tag_ram[req_idx] == req_tag);

    assign req_ready_o = (state_q == IDLE);

    // AXI constant fields
    assign axi.awid    = '0;
    assign axi.awlen   = 8'(LINE_WORDS - 1);
    assign axi.awsize  = 3'b010;
    assign axi.awburst = 2'b01;
    assign axi.awlock  = 1'b0;
    assign axi.awcache = 4'b0011;
    assign axi.awqos   = qos_i;
    assign axi.arid    = '0;
    assign axi.arlen   = 8'(LINE_WORDS - 1);
    assign axi.arsize  = 3'b010;
    assign axi.arburst = 2'b01;
    assign axi.arlock  = 1'b0;
    assign axi.arcache = 4'b0011;
    assign axi.arqos   = qos_i;

    // Write-back uses the victim line's old tag; fill uses the request tag.
    assign axi.awaddr  = {tag_ram[req_idx], req_idx, {OFFSET_W{1'b0}}};
    assign axi.awvalid = (state_q == WB_ADDR);
    assign axi.wdata   = data_ram[req_idx][beat_q];
    assign axi.wstrb   = '1;
    assign axi.wlast   = (beat_q == BEAT_W'(LINE_WORDS - 1));
    assign axi.wvalid  = (state_q == WB_DATA);
    assign axi.bready  = (state_q == WB_RESP);

    assign axi.araddr  = {req_tag, req_idx, {OFFSET_W{1'b0}}};
    assign axi.arvalid = (state_q == FILL_ADDR);
    assign axi.rready  = (state_q == FILL_DATA);

    always_comb begin
        resp_o = '0;
        resp_o.resp_valid = (state_q == RESP);
        resp_o.rdata = resp_data_q;
        resp_o.error = err_q;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q <= IDLE;
            req_q <= '0;
            beat_q <= '0;
            resp_data_q <= '0;
            err_q <= 1'b0;
            valid_q <= '0;
            dirty_q <= '0;
        end else begin
            unique case (state_q)
                IDLE: begin
                    if (req_i.req_valid) begin
                        req_q <= req_i;
                        err_q <= 1'b0;
                        state_q <= LOOKUP;
                    end
                end

                LOOKUP: begin
                    if (hit) begin
                        if (WRITE_BACK && req_q.we) begin
                            if (req_q.be[0]) data_ram[req_idx][req_word][7:0]   <= req_q.wdata[7:0];
                            if (req_q.be[1]) data_ram[req_idx][req_word][15:8]  <= req_q.wdata[15:8];
                            if (req_q.be[2]) data_ram[req_idx][req_word][23:16] <= req_q.wdata[23:16];
                            if (req_q.be[3]) data_ram[req_idx][req_word][31:24] <= req_q.wdata[31:24];
                            dirty_q[req_idx] <= 1'b1;
                        end
                        resp_data_q <= data_ram[req_idx][req_word];
                        state_q <= RESP;
                    end else if (WRITE_BACK && valid_q[req_idx] && dirty_q[req_idx]) begin
                        state_q <= WB_ADDR;
                    end else begin
                        state_q <= FILL_ADDR;
                    end
                end

                WB_ADDR: begin
                    beat_q <= '0;
                    if (axi.awvalid && axi.awready) begin
                        state_q <= WB_DATA;
                    end
                end

                WB_DATA: begin
                    if (axi.wvalid && axi.wready) begin
                        if (axi.wlast) begin
                            state_q <= WB_RESP;
                        end else begin
                            beat_q <= beat_q + 1'b1;
                        end
                    end
                end

                WB_RESP: begin
                    if (axi.bvalid) begin
                        err_q <= err_q | axi.bresp[1];
                        dirty_q[req_idx] <= 1'b0;
                        state_q <= FILL_ADDR;
                    end
                end

                FILL_ADDR: begin
                    beat_q <= '0;
                    if (axi.arvalid && axi.arready) begin
                        state_q <= FILL_DATA;
                    end
                end

                FILL_DATA: begin
                    if (axi.rvalid) begin
                        data_ram[req_idx][beat_q] <= axi.rdata;
                        err_q <= err_q | axi.rresp[1];
                        beat_q <= beat_q + 1'b1;
                        if (axi.rlast) begin
                            tag_ram[req_idx] <= req_tag;
                            valid_q[req_idx] <= 1'b1;
                            dirty_q[req_idx] <= 1'b0;
                            state_q <= LOOKUP;
                        end
                    end
                end

                default: begin // RESP
                    state_q <= IDLE;
                end
            endcase
        end
    end
endmodule
