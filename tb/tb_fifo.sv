`include "uarch.svh"

// Directed + random unit test for fifo.sv.
//
// Reference model: a SystemVerilog queue mirroring every accepted push/pop.
// Directed phases pin down the contract (reset state, fill/full, drain/empty,
// simultaneous push+pop, pointer wrap, flush semantics); a seeded random soak
// then hammers the same contract under arbitrary valid/ready/flush patterns.
//
// Run with -GDEPTH=1 to cover the ptr_next() DEPTH==1 special case.
module tb_fifo #(
    parameter int DEPTH = 4
);
    typedef logic [31:0] T;

    logic clk, rst_n, flush;
    T     in_data;
    logic in_valid, in_ready;
    T     out_data;
    logic out_valid, out_ready;

    fifo #(
        .T(T),
        .DEPTH(DEPTH)
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .flush(flush),
        .in_data(in_data),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .out_data(out_data),
        .out_valid(out_valid),
        .out_ready(out_ready)
    );

    T mirror[$];
    int checked_pops;
    T next_val;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Invariant monitor: occupancy bounds and valid/empty consistency hold on
    // every cycle of every phase, not just where a directed check looks.
    always @(posedge clk) begin
        if (rst_n) begin
            assert (32'(u_fifo.count_q) <= DEPTH)
                else $fatal(1, "FAIL invariant: count %0d > DEPTH", u_fifo.count_q);
            assert (!(out_valid && u_fifo.count_q == '0))
                else $fatal(1, "FAIL invariant: out_valid while empty");
            assert (!(in_ready && 32'(u_fifo.count_q) == DEPTH))
                else $fatal(1, "FAIL invariant: in_ready while full");
        end
    end

    task automatic check(input string name, input logic cond);
        if (!cond) $fatal(1, "FAIL %s", name);
        $display("PASS %s", name);
    endtask

    // Drive one cycle: set inputs after the negedge, let combinational
    // outputs settle, decide what the DUT must do this edge, verify data,
    // then advance the clock and update the mirror model.
    task automatic step(input logic iv, input logic orx, input logic fl);
        logic will_push, will_pop;
        @(negedge clk);
        in_valid  = iv;
        in_data   = next_val;
        out_ready = orx;
        flush     = fl;
        #1;
        will_push = in_valid && in_ready && !flush;
        will_pop  = out_valid && out_ready;
        if (fl && out_valid)
            $fatal(1, "FAIL flush gate: out_valid high during flush cycle");
        if (will_pop) begin
            if (out_data !== mirror[0])
                $fatal(1, "FAIL data order: pop #%0d got %08x expected %08x",
                       checked_pops, out_data, mirror[0]);
            checked_pops++;
        end
        @(posedge clk);
        if (fl) begin
            mirror.delete();
        end else begin
            if (will_push) begin
                mirror.push_back(next_val);
                next_val++;
            end
            if (will_pop) void'(mirror.pop_front());
        end
        #1;
        if (32'(u_fifo.count_q) != mirror.size())
            $fatal(1, "FAIL occupancy: dut %0d model %0d",
                   u_fifo.count_q, mirror.size());
    endtask

    task automatic idle_cycle();
        step(1'b0, 1'b0, 1'b0);
    endtask

    int seed;
    int rnd;

    initial begin
        in_valid = 1'b0;
        in_data = '0;
        out_ready = 1'b0;
        flush = 1'b0;
        next_val = 32'hA000_0000;
        checked_pops = 0;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        // 1. Reset state: empty, accepting
        check("reset: empty and accepting", !out_valid && in_ready);

        // 2. Fill to full: in_ready must drop exactly at DEPTH entries
        for (int i = 0; i < DEPTH; i++) begin
            check("accepting while not full", in_ready);
            step(1'b1, 1'b0, 1'b0);
        end
        check("full: in_ready deasserted", !in_ready && out_valid);

        // 3. Push attempt at full is refused (no acceptance, no data loss)
        step(1'b1, 1'b0, 1'b0);
        check("push at full refused", mirror.size() == DEPTH);

        // 4. Push+pop offered at full: only the pop may occur
        step(1'b1, 1'b1, 1'b0);
        check("push+pop at full: pop only", mirror.size() == DEPTH - 1);

        // 5. Simultaneous push+pop while partially full: occupancy stable,
        //    data flows in order (skipped for DEPTH==1: no such occupancy)
        if (DEPTH > 1) begin
            repeat (2 * DEPTH) step(1'b1, 1'b1, 1'b0);
            check("simultaneous push+pop: occupancy stable",
                  mirror.size() == DEPTH - 1);
        end

        // 6. Drain to empty: FIFO order verified by the mirror on every pop
        while (mirror.size() > 0) step(1'b0, 1'b1, 1'b0);
        check("drained: out_valid deasserted", !out_valid);

        // 7. Pop attempt at empty is ignored
        step(1'b0, 1'b1, 1'b0);
        check("pop at empty ignored", !out_valid && mirror.size() == 0);

        // 8. Pointer wrap: several full laps around the storage
        repeat (4 * DEPTH) begin
            step(1'b1, 1'b0, 1'b0);
            step(1'b0, 1'b1, 1'b0);
        end
        check("pointer wrap: data intact across laps", mirror.size() == 0);

        // 9. Flush semantics: refill, then flush with a push offered in the
        //    same cycle - the push must be dropped and the queue emptied
        repeat (DEPTH) step(1'b1, 1'b0, 1'b0);
        step(1'b1, 1'b0, 1'b1);
        idle_cycle();
        check("flush: empty, same-cycle push dropped",
              !out_valid && in_ready && mirror.size() == 0);

        // 10. Random soak: arbitrary valid/ready with occasional flush,
        //     mirror-checked every cycle. +SEED overrides for reproduction.
        if (!$value$plusargs("SEED=%d", seed)) seed = 32'hC0FFEE;
        $display("random soak seed=%0d", seed);
        void'($urandom(seed));
        repeat (2000) begin
            rnd = $urandom_range(0, 99);
            step($urandom_range(0, 1) != 0,
                 $urandom_range(0, 1) != 0,
                 rnd < 2);
        end
        while (mirror.size() > 0) step(1'b0, 1'b1, 1'b0);
        check("random soak survived, drained clean", !out_valid);

        $display("tb_fifo DEPTH=%0d: ALL TESTS PASSED (%0d pops checked)",
                 DEPTH, checked_pops);
        $finish;
    end

    initial begin
        repeat (50000) @(posedge clk);
        $fatal(1, "tb_fifo: timeout");
    end
endmodule
