import StmtFSM::*;
import FIFOF::*;
import BypassFIFO_MODIFIED::*;

(* synthesize *)
module mkTb(Empty);

   // Instantiate the DUT (Design Under Test)
   FIFOF#(UInt#(8)) fifo <- mkBypassFIFO_MODIFIED(4);

   Stmt directed_test =
   seq
      $display("Starting Bypass FIFO testbench at time = ", $time);

      // Test Case 1: Simple enqueue and dequeue
      $display("enq 0x01 at time ", $time);
      fifo.enq(8'h01);

      $display("enq 0x02 at time ", $time);         
      fifo.enq(8'h02);

      $display("enq 0x03 at time ", $time);         
      fifo.enq(8'h03);

      $display("enq 0x04 at time ", $time);                  
      fifo.enq(8'h04);

      if (fifo.first() != 8'h01) 
         $display("Test Case 1 Failed: Expected 0x01 at time= ", $time);
      else
         $display("Test Case 1 Passed: Expected 0x01 at time= ", $time);            
      fifo.deq();

      if (fifo.first() != 8'h02) 
         $display("Test Case 1 Failed: Expected 0x02 at time= ", $time);
      else
         $display("Test Case 1 Passed: Expected 0x02 at time= ", $time);
      fifo.deq();

      // Test Case 2: Bypass behavior
      $display("enq 0x05 at time ", $time);         
      fifo.enq(8'h05);

      $display("enq 0x06 at time ", $time);                  
      fifo.enq(8'h06);

      $display("enq 0x07 at time ", $time);                           
      fifo.enq(8'h07);

      $display("enq 0x08 at time ", $time);                           
      fifo.enq(8'h08);

      $display("enq 0x09 at time ", $time);                                    
      fifo.enq(8'h09); // Bypass occurs here

      if (fifo.first() != 8'h03) 
         $display("Test Case 2 Failed: Expected 0x03 Found= 0x%08x at time= ", fifo.first(), $time);
      else
         $display("Test Case 2 Passed: Expected 0x03 at time= ", $time);            
      fifo.deq();

      if (fifo.first() != 8'h04) 
         $display("Test Case 2 Failed: Expected 0x04 Found= 0x%08x at time= ", fifo.first(), $time);
      else
         $display("Test Case 2 Passed: Expected 0x04 at time= ", $time);
      fifo.deq();

      // Check bypassed value
      if (fifo.first() != 8'h09) 
         $display("Test Case 2 Failed: Expected 0x09 Found= 0x%08x at time= ", fifo.first(), $time);
      else
         $display("Test Case 2 Passed: Expected 0x09 at time= ", $time);

      fifo.deq();

      $display("Bypass FIFO testbench completed at time= ", $time);

      $finish;
   endseq;

   mkAutoFSM ( directed_test );

endmodule
