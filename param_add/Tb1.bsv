// Parameterize adder using provisos
package Tb;

typedef Bit#(5) MyType;
typedef SizeOf#(MyType) NumberOfBits;
Integer ordinaryNumber = valueOf(NumberOfBits);

// Parameterized adder: adds two Bit#(tsz) values and returns Bit#(rsz) (where rsz = tsz + 1)
function Bit#(rsz) add(Bit#(tsz) x, Bit#(tsz) y)
   provisos (
      Add#(tsz, 1, rsz)
   );

   Bit#(rsz) x_ext = zeroExtend(x);
   Bit#(rsz) y_ext = zeroExtend(y);

   return x_ext + y_ext;
endfunction

(* synthesize *)
module mkTb (Empty);
   Reg#(MyType) x <- mkReg(5'h5);
   Reg#(MyType) y <- mkReg(5'h3);
   
   rule my_add;
      $display("valueOf(SizeOf(MyType))= %0d", ordinaryNumber);
      
      Bit#(6) res1 = add(x, y);
      Bit#(6) res2 = add(5'hc, 5'hd);
      Bit#(6) res3 = add(5'h1f, 5'h1f);

      $display("5 + 3 = %0d (0x%0x)", res1, res1);
      $display("c + d = %0d (0x%0x)", res2, res2);
      $display("1f + 1f = %0d (0x%0x)", res3, res3);
      
      $finish;
   endrule
   
endmodule

endpackage: Tb
