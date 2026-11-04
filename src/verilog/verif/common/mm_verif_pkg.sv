/******************************************************************************
 Package Name : mm_verif_pkg
 Description :
     Shared state for the matrix_mult verification environment.

     Every checker increments sva_errors when an assertion fails (through the
     SVA_FAIL macro in mm_verif_defs.svh) so tb_matrix_mult can include
     assertion failures in its final PASS/FAIL summary.
*******************************************************************************/

`ifndef __MM_VERIF_PKG__
`define __MM_VERIF_PKG__

package mm_verif_pkg;

    int unsigned sva_errors = 0;

endpackage

`endif
