// Demonstrates the difference between:
//   ==   Eq class's logical equality -- Verilog-style: an X bit in
//        either operand makes the WHOLE result indeterminate (X),
//        not a definite True/False.
//   ===  case/strict equality -- always yields a definite True/False,
//        even when operands contain X/Z. X matches X; X never matches
//        a defined 0 or 1.
//
// Tests 1-2 use fully-defined values, where == and === must agree.
// Tests 3-4 use X (via the ? unspecified-value literal, BSV's
// equivalent of BH's `_`) to show where they diverge. As with the BH
// version, watch the ACTUAL simulator output for tests 3-4 rather
// than trusting any comment here -- Bluesim's specific handling of
// an indeterminate `if` condition is worth confirming empirically.

function Bool eq3 (Bit#(n) x, Bit#(n) y);
  return \=== (x,y);
endfunction

(* synthesize *)
module mkTb(Empty);
    Reg#(Bit#(8)) cyc <- mkReg(0);

    rule run;
        cyc <= cyc + 1;
        case (cyc)
            1: begin
                $display("-- Test 1: two matching, fully-defined values --");
                Bit#(8) a = 5;
                Bit#(8) b = 5;
                if (a == b)
                    $display("==  : True");
                else
                    $display("==  : False");
                if (eq3(a,b))  //(a === b)
                    $display("=== : True");
                else
                    $display("=== : False");
            end

            2: begin
                $display("-- Test 2: two different, fully-defined values --");
                Bit#(8) a = 5;
                Bit#(8) b = 9;
                if (a == b)
                    $display("==  : True");
                else
                    $display("==  : False");
                if (eq3(a,b)) //(a === b)
                    $display("=== : True");
                else
                    $display("=== : False");
            end

            3: begin
                $display("-- Test 3: two matching X (unspecified) values --");
                Bit#(8) a = ?;
                Bit#(8) b = ?;
                if (a == b)
                    $display("==  : True");
                else
                    $display("==  : False  <- watch: is this really False, or is the condition itself X and the simulator just took the else branch?");
                if (eq3(a,b)) // (a === b)
                    $display("=== : True   <- === treats matching X patterns as equal");
                else
                    $display("=== : False");
            end

            4: begin
                $display("-- Test 4: one X value vs one defined value --");
                Bit#(8) a = ?;
                Bit#(8) b = 5;
                if (a == b)
                    $display("==  : True");
                else
                    $display("==  : False  <- again, check whether this is a real False or a resolved-X");
                if (eq3(a,b))  // (a === b)
                    $display("=== : True");
                else
                    $display("=== : False  <- === is unambiguous: X never equals a defined bit");
            end

            5: $finish(0);
        endcase
    endrule
endmodule


/*
Error: "Tb.bsv", line 31, column 23: (P0005)
  Unexpected `==='; expected `.', `(', `[', operator, SV 3.1a keyword
  `matches', `&&&', or `)'
Command exited with non-zero status 1
*/

