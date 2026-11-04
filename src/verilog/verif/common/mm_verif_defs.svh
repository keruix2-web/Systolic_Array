`ifndef __MM_VERIF_DEFS__
`define __MM_VERIF_DEFS__

// Action block for every assertion: count the failure for the testbench summary and report it
`define SVA_FAIL(msg) begin mm_verif_pkg::sva_errors++; $error("[SVA] %s", msg); end

`endif
