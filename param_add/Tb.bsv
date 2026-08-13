// change Add#(tsz, 0, rsz) to Add#(tsz, 1, rsz) to see the carry bit
package Tb;

typedef Bit#(5) MyType; //MyType is an alias of Bit#(5)
typedef SizeOf#(MyType) NumberOfBits; //NumberOfBits is a numeric type, its value is 5
Integer ordinaryNumber = valueOf(NumberOfBits); // can print

function r add(t x, t y) 
   provisos(Bits#(t, tsz), Arith#(t), Bits#(r, rsz), Add#(tsz, 0, rsz) );
   return unpack( zeroExtend(pack(x)) + zeroExtend(pack(y)) );
endfunction

(* synthesize *)
module mkTb (Empty);
   Reg#(MyType)  x <- mkReg(5'h5);
   Reg#(MyType)  y <- mkReg(5'h3);
   
   rule my_add;
      $display("valueOf(SizeOf(MyType))= %0d", ordinaryNumber);
      $display("5+3=%0d", add(x, y) );
      $display("c+d=0x%0x", add(MyType'(5'hc), MyType'(5'hd) ) );
      $display("0x1f+0x1f=0x%0x", add(MyType'(5'h1f), MyType'(5'h1f)) );
      $finish;
   endrule
   
endmodule

endpackage: Tb

