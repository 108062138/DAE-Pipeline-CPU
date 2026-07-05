`include "uarch.svh"

// Directed unit test for the memory subsystem:
// I$/D$ -> AXI arbiter -> AXI DRAM slave, no CPU core.
module tb_mem_subsys;
    import uarch_pkg::*;

    logic clk;
    logic rst;
    logic rst_n;
    assign rst_n = ~rst;

    mem_req_t imem_req, dmem_req;
    mem_resp_t imem_resp, dmem_resp;
    logic imem_ready, dmem_ready;

    axi_if #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32),
        .ID_WIDTH(4)
    ) dram_axi (
        .clk(clk),
        .rst_n(rst_n)
    );

    mem_subsys u_mem_subsys (
        .clk_i(clk),
        .rst_i(rst),
        .imem_req_i(imem_req),
        .imem_req_ready_o(imem_ready),
        .imem_resp_o(imem_resp),
        .dmem_req_i(dmem_req),
        .dmem_req_ready_o(dmem_ready),
        .dmem_resp_o(dmem_resp),
        .imem_qos_i(4'd0),
        .dmem_qos_i(4'd1),
        .mem_axi(dram_axi)
    );

    axi_dram_model #(
        .MEM_WORDS(1 << 16),
        .BOOT_ROM_ID(0)
    ) u_dram (
        .clk_i(clk),
        .rst_i(rst),
        .s(dram_axi)
    );

    int aw_count, ar_count;
    always @(posedge clk) begin
        if (!rst && dram_axi.awvalid && dram_axi.awready) aw_count++;
        if (!rst && dram_axi.arvalid && dram_axi.arready) ar_count++;
    end

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $fatal(1, "FAIL %s: got %08x expected %08x", name, got, exp);
        end
        $display("PASS %s (%08x)", name, got);
    endtask

    task automatic check_cnt(input string name, input int got, input int exp);
        if (got != exp) begin
            $fatal(1, "FAIL %s: got %0d expected %0d", name, got, exp);
        end
        $display("PASS %s (%0d)", name, got);
    endtask

    task automatic do_imem_read(input logic [31:0] addr, output logic [31:0] rdata);
        @(negedge clk);
        imem_req = '0;
        imem_req.req_valid = 1'b1;
        imem_req.addr = addr;
        while (!imem_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        imem_req = '0;
        while (!imem_resp.resp_valid) @(negedge clk);
        rdata = imem_resp.rdata;
        if (imem_resp.error) $fatal(1, "FAIL imem read %08x: error response", addr);
        @(negedge clk);
    endtask

    task automatic do_dmem(input logic we, input logic [31:0] addr, input logic [3:0] be,
                           input logic [31:0] wdata, output logic [31:0] rdata);
        @(negedge clk);
        dmem_req = '0;
        dmem_req.req_valid = 1'b1;
        dmem_req.addr = addr;
        dmem_req.we = we;
        dmem_req.be = be;
        dmem_req.wdata = wdata;
        while (!dmem_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        dmem_req = '0;
        while (!dmem_resp.resp_valid) @(negedge clk);
        rdata = dmem_resp.rdata;
        if (dmem_resp.error) $fatal(1, "FAIL dmem access %08x: error response", addr);
        @(negedge clk);
    endtask

    logic [31:0] rdata_i, rdata_d;
    int ar_snap, aw_snap;

    initial begin
        imem_req = '0;
        dmem_req = '0;
        aw_count = 0;
        ar_count = 0;
        for (int i = 0; i < (1 << 16); i++) begin
            u_dram.mem[i] = 32'd0;
        end

        rst = 1'b1;
        repeat (3) @(posedge clk);
        rst = 1'b0;

        // 1. I$ read miss + fill: boot trampoline at 0x0
        do_imem_read(32'h0000_0000, rdata_i);
        check32("icache miss fill @0x0 (boot rom)", rdata_i, 32'h8000_00b7);
        check_cnt("one AR burst after first fetch", ar_count, 1);

        // 2. I$ hit on same line: no new AXI traffic
        do_imem_read(32'h0000_0004, rdata_i);
        check32("icache hit @0x4 (boot rom)", rdata_i, 32'h0000_8067);
        check_cnt("no new AR on icache hit", ar_count, 1);

        // 3. I$ fetch at 0x8000_0000: wraps to mem[0], no trampoline
        do_imem_read(32'h8000_0000, rdata_i);
        check32("icache fetch @0x80000000 wraps to dram", rdata_i, 32'h0000_0000);
        check_cnt("second AR burst", ar_count, 2);

        // 4. D$ write miss -> allocate (read fill), merge, dirty. No AW yet.
        do_dmem(1'b1, 32'h0000_0100, 4'b1111, 32'hDEAD_BEEF, rdata_d);
        check_cnt("write-allocate issues AR", ar_count, 3);
        check_cnt("no writeback yet", aw_count, 0);

        // 5. D$ read hit returns merged data, no AXI traffic
        ar_snap = ar_count;
        do_dmem(1'b0, 32'h0000_0100, 4'b1111, 32'h0, rdata_d);
        check32("dcache read hit @0x100", rdata_d, 32'hDEAD_BEEF);
        check_cnt("no AXI traffic on dcache hit", ar_count, ar_snap);

        // 6. Byte write hit (lane 1), then read back merged word
        do_dmem(1'b1, 32'h0000_0101, 4'b0010, 32'h0000_5500, rdata_d);
        do_dmem(1'b0, 32'h0000_0100, 4'b1111, 32'h0, rdata_d);
        check32("byte-enable merge @0x101", rdata_d, 32'hDEAD_55EF);

        // 7. Conflicting read (same index, different tag) evicts dirty line:
        //    expect one writeback burst (AW) plus one fill (AR)
        ar_snap = ar_count;
        aw_snap = aw_count;
        do_dmem(1'b0, 32'h0000_1100, 4'b1111, 32'h0, rdata_d);
        check32("conflict read @0x1100 (fresh dram)", rdata_d, 32'h0000_0000);
        check_cnt("dirty eviction issues writeback", aw_count, aw_snap + 1);
        check_cnt("conflict miss issues fill", ar_count, ar_snap + 1);

        // 8. Re-read the evicted address: refill from DRAM must return the
        //    written-back data
        do_dmem(1'b0, 32'h0000_0100, 4'b1111, 32'h0, rdata_d);
        check32("writeback data survives eviction", rdata_d, 32'hDEAD_55EF);

        // 9. Concurrent I$ and D$ misses exercise the arbiter
        ar_snap = ar_count;
        fork
            do_imem_read(32'h0000_2000, rdata_i);
            do_dmem(1'b0, 32'h0000_3000, 4'b1111, 32'h0, rdata_d);
        join
        check32("concurrent icache miss", rdata_i, 32'h0000_0000);
        check32("concurrent dcache miss", rdata_d, 32'h0000_0000);
        check_cnt("arbiter served both bursts", ar_count, ar_snap + 2);

        $display("tb_mem_subsys: ALL TESTS PASSED");
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "tb_mem_subsys: timeout");
    end
endmodule
