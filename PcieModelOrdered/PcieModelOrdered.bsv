// PcieModelOrdered.bsv
//
// Bidirectional PCIe producer-consumer model. Two symmetric sides (A, B)
// each act, simultaneously, as:
//   - a producer of Posted Writes (data) toward the other side
//   - a requester issuing Non-Posted reads toward the other side
//   - a responder that GENERATES a Completion when one of the other
//     side's read requests is actually delivered to it -- completions
//     are not an independent traffic source, they are caused by, and
//     carry the state that exists at the moment of, an incoming read.
//
//        SideA                                          SideB
//   ---------------                                 ---------------
//   pQ  --\                    wireOut(A) --------->  wireIn(B)
//   npQ ---+--[arbiter]--> wireOut(A)                      |
//   cplQ--/  ^                                    (generates a completion
//            |                                     when an NP is delivered)
//    (generated when an incoming NP           wireIn(A) <--------- wireOut(B)
//     is delivered from B)                                    ^
//                                                        pQ/npQ/cplQ --[arbiter]
//
// Each direction (A->B and B->A) is its own ordering domain: a side's own
// Non-Posted reads and Completions must not pass that SAME side's own
// earlier Posted Writes (PCIe ordering table, same as the single-direction
// model). The dependency counter for a Completion is stamped with the
// RESPONDER's pIssuedCount at the moment it generates the completion --
// not with anything the requester knew in advance, since the requester
// has no visibility into the responder's internal state.
//
// DATA CONSISTENCY CHECK (both directions)
//   Side X tracks otherPDelivered: how many of side Y's Posted Writes X
//   has actually received. When X receives a Completion from Y (a reply
//   to X's own earlier read), X checks otherPDelivered >= depCount, i.e.
//   "have I actually received every Posted Write Y had issued at the
//   moment Y generated this completion?" This is the real producer-
//   consumer guarantee: a poll response must never arrive before the
//   data it is reporting on. Both sides run this check independently, so
//   the model verifies consistency in both directions at once.
//
// Build & run:
//   bsc -sim -u -g mkPcieModelOrdered PcieModelOrdered.bsv
//   bsc -sim -e mkPcieModelOrdered -o pcie_sim_ordered bdpi_glue.c
//   ./pcie_sim_ordered
// Two independent, COEXISTING ways to configure a run, both available
// natively in BSV with no workaround needed:
//   compile-time, via -D (clean *.bo/*.ba between builds):
//     bsc -sim -u -g mkPcieModelOrdered -D ENFORCE_ORDERING=0 PcieModelOrdered.bsv
//   runtime, via an environment variable, same compiled binary, no rebuild:
//     NUM_NP_A=2000 PROD_NP_INTERVAL=1 ./pcie_sim_ordered
// The runtime path exists because of one line (the `import "BDPI"` below)
// plus a small Config struct and a configure() method on Side -- compare
// against PcieModelOrdered.bs and BdpiConfig.bsv, where the identical
// capability needed a whole separate file: classic Bluespec Haskell's own
// `foreign` keyword only accepts raw Bit#(n) arguments (no String), and
// `import "BDPI"` does not parse in a .bs file at all (both confirmed by
// trying). Here it's one declaration, inline, no shim file required.
//
// bsc NOTE: every send/receive rule below acts on exactly one queue.
// Never merge several queues' .first/.deq into one rule's if/else branches:
// without -aggressive-conditions bsc attaches each branch's implicit
// "queue non-empty" condition to the WHOLE rule, and the rule can permanently
// stop firing the moment any one of those queues drains -- a real, silent
// failure mode we hit and root-caused while building this model.
//
// INBOUND QUEUES ARE SPLIT PER TLP KIND, NOT SHARED -- and this one is a
// correctness fix, not a style choice. With a single shared inbound FIFO,
// a scenario this model is explicitly meant to support (reads issued every
// cycle, at full write throughput) hits a genuine circular deadlock: CPL's
// send gate needs pSentCount to advance; cplQ fills while waiting; once
// full, recvNp can't drain a completion-triggering read off the shared
// inbound queue; if that read is at the head, EVERY other kind behind it
// -- including the Posted Writes that would advance pSentCount and free
// cplQ -- is head-of-line blocked too. Confirmed by tracing a real run
// (pSentCount froze solid, outQ/pipe/inQ all backed up, all consistent
// with this exact chain). Separate per-kind queues (wireInP/wireInNp/
// wireInCpl) remove the head-of-line blocking entirely, which is also
// exactly why real PCIe keeps separate buffers per TLP type rather than
// one shared receive queue.

package PcieModelOrdered;

import FIFOF :: *;
import Vector :: *;

// --------------------------------------------------------------------------
// Parameters
// --------------------------------------------------------------------------
`ifndef NUM_P_A
`define NUM_P_A 2000       // A's Posted Writes (data) to B
`endif
`ifndef NUM_NP_A
`define NUM_NP_A 200       // A's read requests to B
`endif
`ifndef NUM_P_B
`define NUM_P_B 2000       // B's Posted Writes (data) to A
`endif
`ifndef NUM_NP_B
`define NUM_NP_B 200       // B's read requests to A
`endif
`ifndef P_PAYLOAD_BYTES
`define P_PAYLOAD_BYTES 128
`endif
`ifndef P_OVERHEAD_BYTES
`define P_OVERHEAD_BYTES 24
`endif
`ifndef NP_HEADER_BYTES
`define NP_HEADER_BYTES 20
`endif
`ifndef CPL_PAYLOAD_BYTES
`define CPL_PAYLOAD_BYTES 64
`endif
`ifndef CPL_OVERHEAD_BYTES
`define CPL_OVERHEAD_BYTES 20
`endif
`ifndef LINK_BYTES_PER_CYCLE
`define LINK_BYTES_PER_CYCLE 32
`endif
`ifndef LINK_LATENCY
`define LINK_LATENCY 100
`endif
`ifndef PCIE_GEN
`define PCIE_GEN "Gen3"     // display only -- see note at theoreticalMbps below
`endif
`ifndef NUM_LANES
`define NUM_LANES 8         // display only
`endif
`ifndef CLOCK_RATE_MHZ
`define CLOCK_RATE_MHZ 250  // the clock LINK_BYTES_PER_CYCLE is defined against
`endif
`ifndef CREDITS_P
`define CREDITS_P 16
`endif
`ifndef CREDITS_NP
`define CREDITS_NP 8
`endif
`ifndef CREDITS_CPL
`define CREDITS_CPL 8
`endif
`ifndef PROD_P_INTERVAL
`define PROD_P_INTERVAL 1
`endif
`ifndef PROD_NP_INTERVAL
`define PROD_NP_INTERVAL 20
`endif
`ifndef ENFORCE_ORDERING
`define ENFORCE_ORDERING 1
`endif
`ifndef READ_GAP
`define READ_GAP 4     // a read targets the write issued this many writes ago
`endif

typedef UInt#(32) Cycle;

// PCIE_GEN/NUM_LANES/CLOCK_RATE_MHZ are display context, not independent
// physics: LINK_BYTES_PER_CYCLE is the one parameter that actually drives
// the simulated serialization timing, and it was derived by hand from a
// Gen3 x8 @ 250 MHz link (128b/130b encoding: ~7.88 GB/s effective,
// rounded to 32 B/cycle -- see this conversation's very first turns).
// Changing PCIE_GEN/NUM_LANES here relabels the printed assumptions; it
// does NOT recompute LINK_BYTES_PER_CYCLE for you. If you change the
// generation or lane count, update LINK_BYTES_PER_CYCLE by hand to match,
// the same way the default was derived.
Integer theoreticalMbps = `LINK_BYTES_PER_CYCLE * `CLOCK_RATE_MHZ * 8;

// --------------------------------------------------------------------------
// Runtime (BDPI) configuration -- native and inline, no separate file.
//
// Config holds exactly the parameters that are genuine runtime comparisons
// (counts compared against counters, intervals, READ_GAP, the enforce
// flag). It deliberately does NOT hold structural parameters -- FIFO
// depths, Vector sizes, credit-pool depths, byte sizes -- because BDPI
// calls only execute inside rules, at simulation runtime, strictly after
// Bluespec's static elaboration (which is what decides FIFO depths and
// Vector dimensions) has already finished building the module tree. That
// limitation is identical in both syntaxes; what differs here is how
// little code it takes to use BDPI at all once you've accepted it.
//
// defaultConfig is built directly from the `define values above, so the
// compile-time (-D) and runtime (environment variable) configuration
// paths share one source of truth rather than drifting independently.
typedef struct {
   Cycle numPA;
   Cycle numNPA;
   Cycle numPB;
   Cycle numNPB;
   Cycle prodPInterval;
   Cycle prodNPInterval;
   Cycle readGap;
   Bool  enforceOrdering;
} Config deriving (Bits, Eq);

Config defaultConfig = Config {
   numPA: fromInteger(`NUM_P_A), numNPA: fromInteger(`NUM_NP_A),
   numPB: fromInteger(`NUM_P_B), numNPB: fromInteger(`NUM_NP_B),
   prodPInterval: fromInteger(`PROD_P_INTERVAL), prodNPInterval: fromInteger(`PROD_NP_INTERVAL),
   readGap: fromInteger(`READ_GAP), enforceOrdering: (`ENFORCE_ORDERING != 0)
};

// The entire FFI boundary: one declaration. No separate file, no Bit#(n)-
// only restriction on arguments -- String just works. Contrast with the
// classic-syntax version, where this same line had to move into a
// dedicated .bsv shim because neither of classic syntax's own mechanisms
// (foreign, import "BDPI") could express it directly.
import "BDPI" function Int#(32) bdpi_getenv_int(String name, Int#(32) defaultVal);

function Cycle getU32(String name, Cycle d) =
   unpack(pack(bdpi_getenv_int(name, unpack(pack(d)))));

interface ConfigReader;
   method ActionValue#(Config) load(Config defaults);
endinterface

module mkConfigReader (ConfigReader);
   method ActionValue#(Config) load(Config d);
      let c = Config {
         numPA:           getU32("NUM_P_A",          d.numPA),
         numNPA:          getU32("NUM_NP_A",         d.numNPA),
         numPB:           getU32("NUM_P_B",          d.numPB),
         numNPB:          getU32("NUM_NP_B",         d.numNPB),
         prodPInterval:   getU32("PROD_P_INTERVAL",  d.prodPInterval),
         prodNPInterval:  getU32("PROD_NP_INTERVAL", d.prodNPInterval),
         readGap:         getU32("READ_GAP",         d.readGap),
         enforceOrdering: getU32("ENFORCE_ORDERING", d.enforceOrdering ? 1 : 0) != 0
      };
      return c;
   endmethod
endmodule

typedef enum { TPOSTED, TNONPOSTED, TCOMPLETION } TlpKind deriving (Bits, Eq, FShow);

// BUF_BITS/BUF_SIZE define a small circular buffer each side's writes land
// in. addr is (sequence number mod BUF_SIZE); data is the sequence number
// itself, a simple, independently-recomputable pattern -- the point isn't
// the pattern's sophistication, it's that both sides can independently
// know what SHOULD be at a given address without a side channel.
typedef 5 BufBits;
typedef 32 BufSize;

typedef struct {
   TlpKind    kind;
   Cycle      depCount;  // NP: this side's own pIssuedCount when created.
                          // CPL: the RESPONDER's pIssuedCount when generated.
                          // (TX-ordering gate value -- unrelated to data below.)
   Cycle      seqNum;       // NP: the target write's sequence number. CPL:
                          // echoed straight through, unchanged, so the
                          // expected value is a fixed computation
                          // (pack(seqNum)) rather than a lookup into state
                          // that may have moved on by the time a slow
                          // completion returns. P: this write's own seqNum.
   Bit#(BufBits) addr;   // P: where this write lands (= seqNum mod BufSize).
                          // NP/CPL: which address is being read (= seqNum mod
                          // BufSize) -- a pure function of seqNum, kept
                          // alongside it only so recvP/recvNp don't need
                          // to recompute a mod on every TLP.
   Bit#(32)   data;      // P: the value written (= pack(seqNum)). CPL: the
                          // value actually found at addr by the responder.
   Cycle      tCreate;
} Tlp deriving (Bits, FShow);

// --------------------------------------------------------------------------
// One credit pool per TLP type
// --------------------------------------------------------------------------
interface CreditPool;
   method Bool   avail;
   method Action take;
   method Action give;
endinterface

module mkCreditPool#(Integer n)(CreditPool);
   Reg#(UInt#(16)) credits <- mkReg(fromInteger(n));
   PulseWire takePw <- mkPulseWire;
   PulseWire givePw <- mkPulseWire;
   (* fire_when_enabled, no_implicit_conditions *)
   rule update;
      if (takePw && !givePw)      credits <= credits - 1;
      else if (!takePw && givePw) credits <= credits + 1;
   endrule
   method Bool   avail = (credits != 0);
   method Action take  = takePw.send;
   method Action give  = givePw.send;
endmodule

// --------------------------------------------------------------------------
// One side: producer + requester + responder
// --------------------------------------------------------------------------
// wireIn is split one-FIFO-per-TLP-kind, not a single shared queue. With a
// single inbound FIFO, a completion stuck behind a full cplQ (itself stuck
// behind a starved pSentCount) head-of-line-blocks every OTHER kind behind
// it too, including the very Posted Writes that would un-stick it --
// a genuine circular deadlock, not just a throughput hit, confirmed by
// tracing a real run (see conversation). Separate per-kind receive queues
// are exactly why real PCIe keeps separate buffers per TLP type.
interface Side;
   interface FIFOF#(Tlp) wireOut;     // fully serialized, ready to hand to the link
   interface FIFOF#(Tlp) wireInP;     // top level routes delivered P TLPs here
   interface FIFOF#(Tlp) wireInNp;    // ... NP TLPs here
   interface FIFOF#(Tlp) wireInCpl;   // ... CPL TLPs here
   // Optional runtime override, on top of whatever -D baked in at compile
   // time. Call at most once, from the top level's init rule, right after
   // it has read Config via BDPI. Harmless to never call this at all --
   // the -D-sourced (or hardcoded-default) values keep working exactly as
   // before, since they seed the very registers this method overwrites.
   method Action configure(Cycle newNP, Cycle newNNP, Cycle newNInNP,
                            Cycle newPIntvl, Cycle newNPIntvl, Cycle newReadGap, Bool newEnforce);
   method Bool finished;
   method Action printReport;
endinterface

module mkSide#(Integer sideId, Integer numP, Integer numNP, Integer expectIncomingNP,
               Integer pWireBytes, Integer npWireBytes, Integer cplWireBytes,
               Integer bytesPerCycle, Integer prodPIntvl, Integer prodNPIntvl,
               Integer linkLatI, Bool enforce) (Side);

   Cycle linkLat = fromInteger(linkLatI);

   Integer pSerI   = (pWireBytes   + bytesPerCycle - 1) / bytesPerCycle;
   Integer npSerI  = (npWireBytes  + bytesPerCycle - 1) / bytesPerCycle;
   Integer cplSerI = (cplWireBytes + bytesPerCycle - 1) / bytesPerCycle;
   Cycle pSer   = fromInteger(pSerI);
   Cycle npSer  = fromInteger(npSerI);
   Cycle cplSer = fromInteger(cplSerI);

   // Runtime-tunable parameters: registers, seeded from the -D-sourced (or
   // hardcoded-default) module parameters above, so behavior is identical
   // to before if configure() is never called -- and overwritable at
   // simulation start if it is. This is the only structural difference
   // from the plain `let`s this replaces; everywhere else in the module
   // that reads nP, nNP, etc. is completely unchanged.
   Reg#(Cycle) nP     <- mkReg(fromInteger(numP));
   Reg#(Cycle) nNP    <- mkReg(fromInteger(numNP));
   Reg#(Cycle) nInNP  <- mkReg(fromInteger(expectIncomingNP));
   Reg#(Cycle) pIntvl  <- mkReg(fromInteger(prodPIntvl));
   Reg#(Cycle) npIntvl <- mkReg(fromInteger(prodNPIntvl));
   Reg#(Cycle) readGap <- mkReg(fromInteger(`READ_GAP));
   Reg#(Bool)  enforceReg <- mkReg(enforce);
   // Starts False; the top level is responsible for calling configure()
   // exactly once, unconditionally (whether or not any BDPI override
   // actually changes anything), which also sets this True. This closes a
   // real one-cycle window: without it, a BDPI override that SHRINKS a
   // count (e.g. NUM_P_A=0 for an all-reads pattern) could still let one
   // spurious item through at cyc=0 using the pre-override seed value,
   // since any register write -- configure()'s included -- only takes
   // effect the cycle after it's issued.
   Reg#(Bool) configured <- mkReg(False);

   Reg#(Cycle) cyc <- mkReg(0);
   (* fire_when_enabled, no_implicit_conditions *)
   rule tick; cyc <= cyc + 1; endrule

   FIFOF#(Tlp) pQ   <- mkSizedFIFOF(32);
   FIFOF#(Tlp) npQ  <- mkSizedFIFOF(16);
   FIFOF#(Tlp) cplQ <- mkSizedFIFOF(16);
   CreditPool pCr   <- mkCreditPool(`CREDITS_P);
   CreditPool npCr  <- mkCreditPool(`CREDITS_NP);
   CreditPool cplCr <- mkCreditPool(`CREDITS_CPL);

   FIFOF#(Tuple2#(TlpKind,Cycle)) credRet <- mkSizedFIFOF(16);
   FIFOF#(Tlp) outQ   <- mkSizedFIFOF(8);
   FIFOF#(Tlp) inQ_P   <- mkSizedFIFOF(8);
   FIFOF#(Tlp) inQ_Np  <- mkSizedFIFOF(8);
   FIFOF#(Tlp) inQ_Cpl <- mkSizedFIFOF(8);

   Reg#(Cycle) pIssuedCount <- mkReg(0);
   Reg#(Cycle) pSentCount   <- mkReg(0);
   Reg#(Cycle) otherPDelivered <- mkReg(0);  // # of the OTHER side's P's received

   // mem: data this side has actually received, indexed by address --
   // updated by recvP, read by recvNp when answering an incoming read.
   Vector#(BufSize, Reg#(Bit#(32))) mem <- replicateM(mkReg(0));
   Reg#(Cycle) dataViolations <- mkReg(0);

   Reg#(Cycle) pMade  <- mkReg(0); Reg#(Cycle) pTimer  <- mkReg(0);
   Reg#(Cycle) npMade <- mkReg(0); Reg#(Cycle) npTimer <- mkReg(0);
   Reg#(Cycle) reqReceived <- mkReg(0);  // incoming NPs we've responded to
   Reg#(Cycle) cplReceived <- mkReg(0);  // completions received for our own reads

   Reg#(Cycle) txBusy <- mkReg(0);

   Reg#(UInt#(64)) pLatSum   <- mkReg(0); Reg#(Cycle) pLatMax   <- mkReg(0);
   Reg#(UInt#(64)) reqLatSum <- mkReg(0); Reg#(Cycle) reqLatMax <- mkReg(0);
   Reg#(UInt#(64)) cplLatSum <- mkReg(0); Reg#(Cycle) cplLatMax <- mkReg(0);
   Reg#(Cycle) violations   <- mkReg(0);
   Reg#(Cycle) npHeldCycles <- mkReg(0);
   Reg#(Cycle) cplHeldCycles <- mkReg(0);

   // ======================= PRODUCE (P and NP only -- CPL is generated) =====
   // Each write's data IS its own sequence number -- a pattern either side
   // can recompute independently, with no side channel, which is what
   // makes the data-integrity check below meaningful rather than circular.
   rule produceP (configured && pMade < nP && pTimer == 0);
      let thisSeq = pIssuedCount + 1;
      Bit#(BufBits) addr = truncate(pack(thisSeq));
      Bit#(32)      dat  = pack(thisSeq);
      pQ.enq(Tlp { kind: TPOSTED, depCount: 0, seqNum: thisSeq, addr: addr, data: dat, tCreate: cyc });
      pIssuedCount <= thisSeq;
      pMade  <= pMade + 1;
      pTimer <= pIntvl - 1;
   endrule
   rule produceP_wait (pTimer != 0); pTimer <= pTimer - 1; endrule

   // A read targets the write issued READ_GAP writes ago -- read-after-write
   // by construction. Guarded so no read is issued before that target
   // "exists" in the sense the guard can check (pIssuedCount >= readGap).
   // targetSeq can legitimately come out to 0 (e.g. READ_GAP=0 with no
   // writes at all, for an all-reads pattern); 0 isn't a real write's
   // number, but the data check below asks for pack(0) in that case, which
   // is exactly mem's own reset value, so an honestly-uninitialized address
   // still checks out correctly rather than needing a special case.
   rule produceNP (configured && npMade < nNP && npTimer == 0 && pIssuedCount >= readGap);
      let targetSeq = pIssuedCount - readGap;
      Bit#(BufBits) addr = truncate(pack(targetSeq));
      npQ.enq(Tlp { kind: TNONPOSTED, depCount: pIssuedCount, seqNum: targetSeq, addr: addr, data: 0, tCreate: cyc });
      npMade  <= npMade + 1;
      npTimer <= npIntvl - 1;
   endrule
   rule produceNP_wait (npTimer != 0); npTimer <= npTimer - 1; endrule

   // ======================= SEND (one rule per queue) =======================
   (* descending_urgency = "txSendCpl, txSendNp, txSendP" *)
   rule txSendCpl (txBusy == 0 && cplCr.avail &&
                   (!enforceReg || cplQ.first.depCount <= pSentCount));
      let t = cplQ.first; cplQ.deq;
      outQ.enq(t);
      txBusy <= cplSer - 1;
      cplCr.take;
      credRet.enq(tuple2(TCOMPLETION, cyc + cplSer + 2*linkLat));
   endrule

   rule txSendNp (txBusy == 0 && npCr.avail &&
                  (!enforceReg || npQ.first.depCount <= pSentCount));
      let t = npQ.first; npQ.deq;
      outQ.enq(t);
      txBusy <= npSer - 1;
      npCr.take;
      credRet.enq(tuple2(TNONPOSTED, cyc + npSer + 2*linkLat));
   endrule

   rule txSendP (txBusy == 0 && pCr.avail);
      let t = pQ.first; pQ.deq;
      outQ.enq(t);
      txBusy <= pSer - 1;
      pCr.take;
      pSentCount <= pSentCount + 1;
      credRet.enq(tuple2(TPOSTED, cyc + pSer + 2*linkLat));
      if (sideId == 0)
         $display("sideId=%4d tCreate=%4d tSend=%4d pSer=%4d 1-way-linkLat=%4d credRet=%0d",
            sideId, t.tCreate, cyc, pSer, linkLat, (cyc+pSer+2*linkLat) );
   endrule

   rule txWait (txBusy != 0); txBusy <= txBusy - 1; endrule

   rule creditArrive (tpl_2(credRet.first) <= cyc);
      let e = credRet.first; credRet.deq;
      case (tpl_1(e))
         TPOSTED:     pCr.give;
         TNONPOSTED:  npCr.give;
         TCOMPLETION: cplCr.give;
      endcase
   endrule

   rule statNpHeld (enforceReg && npCr.avail && npQ.first.depCount > pSentCount);
      npHeldCycles <= npHeldCycles + 1;
   endrule
   rule statCplHeld (enforceReg && cplCr.avail && cplQ.first.depCount > pSentCount);
      cplHeldCycles <= cplHeldCycles + 1;
   endrule

   // ======================= RECEIVE (one rule per incoming kind) ============
   // inQ holds whatever the top level has delivered, in arrival order. We
   // peek its kind and route to exactly one handler per firing.
   rule recvP;
      let t = inQ_P.first; inQ_P.deq;
      mem[t.addr] <= t.data;      // the write actually lands, here, now
      otherPDelivered <= otherPDelivered + 1;
      pLatSum <= pLatSum + zeroExtend(cyc - t.tCreate);
      if (cyc - t.tCreate > pLatMax) pLatMax <= cyc - t.tCreate;
   endrule

   // An incoming read request: generate a completion NOW, carrying OUR
   // CURRENT pIssuedCount (the ordering check) and whatever is ACTUALLY
   // sitting in our memory at the requested address (the data check).
   // This can still block if cplQ is full -- but now that only holds up
   // OTHER incoming reads, not incoming writes or completions too.
   rule recvNp;
      let t = inQ_Np.first; inQ_Np.deq;
      cplQ.enq(Tlp { kind: TCOMPLETION, depCount: pIssuedCount,
                     seqNum: t.seqNum, addr: t.addr, data: mem[t.addr], tCreate: cyc });
      reqReceived <= reqReceived + 1;
      reqLatSum <= reqLatSum + zeroExtend(cyc - t.tCreate);
      if (cyc - t.tCreate > reqLatMax) reqLatMax <= cyc - t.tCreate;
   endrule

   // A completion answering one of OUR earlier reads: check BOTH guarantees.
   rule recvCpl;
      let t = inQ_Cpl.first; inQ_Cpl.deq;
      cplReceived <= cplReceived + 1;
      cplLatSum <= cplLatSum + zeroExtend(cyc - t.tCreate);
      if (cyc - t.tCreate > cplLatMax) cplLatMax <= cyc - t.tCreate;
      // Ordering check (unchanged): did enough writes exist by generation time?
      if (otherPDelivered < t.depCount) begin
         violations <= violations + 1;
         $display("t=%0d  Side%0d ORDER VIOLATION: completion says %0d prior writes existed, but only %0d have been received",
                   cyc, sideId, t.depCount, otherPDelivered);
      end
      // Data check (new): the expected value is computed directly from the
      // sequence number this completion itself carries (pack(t.seqNum)) --
      // a fixed, independently-recomputable fact about that specific write,
      // never a lookup into mutable state that could have moved on by the
      // time this (possibly very late) completion arrives.
      if (t.data != pack(t.seqNum)) begin
         dataViolations <= dataViolations + 1;
         $display("t=%0d  Side%0d DATA VIOLATION: seqNum %0d (addr %0d) expected %0d, got %0d",
                   cyc, sideId, t.seqNum, t.addr, pack(t.seqNum), t.data);
      end
   endrule

   // ======================= CREDIT RETURN ====================================
   // (credit return implemented above via credRet + creditArrive)

   method Bool finished =
      configured &&
      pMade == nP && npMade == nNP && cplReceived == nNP && reqReceived == nInNP &&
      !pQ.notEmpty && !npQ.notEmpty && !cplQ.notEmpty && !outQ.notEmpty &&
      !inQ_P.notEmpty && !inQ_Np.notEmpty && !inQ_Cpl.notEmpty;

   method Action printReport;
      $display("---- Side %0d ----", sideId);
      $display("  Posted sent=%0d  Reads sent=%0d  Reads answered=%0d  Completions recv'd=%0d",
                pMade, npMade, reqReceived, cplReceived);
      UInt#(64) pAvg   = (nP    == 0) ? 0 : pLatSum   / zeroExtend(nP);
      UInt#(64) reqAvg = (nInNP == 0) ? 0 : reqLatSum / zeroExtend(nInNP);
      UInt#(64) cplAvg = (nNP   == 0) ? 0 : cplLatSum / zeroExtend(nNP);
      $display("  incoming P avg/max latency   : %0d / %0d cycles", pAvg,   pLatMax);
      $display("  read-request avg/max latency : %0d / %0d cycles", reqAvg, reqLatMax);
      $display("  completion avg/max latency   : %0d / %0d cycles", cplAvg, cplLatMax);
      $display("  NP held by ordering : %0d   CPL held by ordering : %0d", npHeldCycles, cplHeldCycles);
      $display("  ORDER VIOLATIONS: %0d   DATA VIOLATIONS: %0d", violations, dataViolations);

      // Observed throughput on THIS side's own outbound link, computed
      // from what it actually sent (pMade posted writes, npMade reads,
      // reqReceived completions -- by report time all three are fully
      // drained, so reqReceived IS the completion count actually sent).
      // Integer fixed-point throughout, not Real: fromInteger only accepts
      // compile-time Integer, never a runtime register value (confirmed
      // directly -- a plain UInt#(64) register fails to type-check through
      // fromInteger), so Real can only ever help with the theoretical,
      // compile-time-constant side of this, never the observed side.
      UInt#(64) wireBytesSent = zeroExtend(pMade)*fromInteger(pWireBytes)
                              + zeroExtend(npMade)*fromInteger(npWireBytes)
                              + zeroExtend(reqReceived)*fromInteger(cplWireBytes);
      UInt#(64) payloadBytesSent = zeroExtend(pMade) * fromInteger(`P_PAYLOAD_BYTES);
      UInt#(64) clockU64 = fromInteger(`CLOCK_RATE_MHZ);
      UInt#(64) cycU64 = zeroExtend(cyc);
      $display("pWireBytes=%0d npWireBytes=%0d cplWireBytes=%0d wireBytesSent=%0d  payloadBytesSent=%0d cycles=%0d", 
         pWireBytes, npWireBytes, cplWireBytes, wireBytesSent, payloadBytesSent, cycU64);
      UInt#(64) linkMbpsX100    = (cycU64 == 0) ? 0 : (wireBytesSent    * 8 * clockU64 * 100) / cycU64;
      UInt#(64) payloadMbpsX100 = (cycU64 == 0) ? 0 : (payloadBytesSent * 8 * clockU64 * 100) / cycU64;
      UInt#(64) utilX10 = (theoreticalMbps == 0) ? 0 : (linkMbpsX100 * 10) / fromInteger(theoreticalMbps);
      // %0Nd space-pads in BSV's $display, it does not zero-pad (confirmed
      // directly: %03d on 0 prints "  0", not "000"). Splitting a 2-digit
      // fraction into two separate single-digit %0d fields sidesteps the
      // issue entirely -- each digit is always exactly one character, so
      // no padding is ever needed.
      $display("  observed link throughput    : %0d.%0d%0d Mb/s  (%0d.%0d%% of theoretical, all TLP types)",
                linkMbpsX100/100, (linkMbpsX100%100)/10, (linkMbpsX100%100)%10, utilX10/10, utilX10%10);
      $display("  observed payload throughput : %0d.%0d%0d Mb/s  (Posted Writes only, useful data rate)",
                payloadMbpsX100/100, (payloadMbpsX100%100)/10, (payloadMbpsX100%100)%10);
   endmethod

   method Action configure(Cycle newNP, Cycle newNNP, Cycle newNInNP,
                            Cycle newPIntvl, Cycle newNPIntvl, Cycle newReadGap, Bool newEnforce);
      nP <= newNP; nNP <= newNNP; nInNP <= newNInNP;
      pIntvl <= newPIntvl; npIntvl <= newNPIntvl;
      readGap <= newReadGap; enforceReg <= newEnforce;
      configured <= True;
   endmethod

   interface wireOut   = outQ;
   interface wireInP   = inQ_P;
   interface wireInNp  = inQ_Np;
   interface wireInCpl = inQ_Cpl;
endmodule

typedef struct { Tlp t; Cycle tArrive; } InFlight deriving (Bits);

// --------------------------------------------------------------------------
// Top level: two sides, two propagation-delay pipes between them
// --------------------------------------------------------------------------
(* synthesize *)
module mkPcieModelOrdered (Empty);
   Bool enforce = (`ENFORCE_ORDERING != 0);
   Integer pWire   = `P_PAYLOAD_BYTES + `P_OVERHEAD_BYTES;
   Integer npWire  = `NP_HEADER_BYTES;
   Integer cplWire = `CPL_PAYLOAD_BYTES + `CPL_OVERHEAD_BYTES;

   Side sideA <- mkSide(0, `NUM_P_A, `NUM_NP_A, `NUM_NP_B,
                         pWire, npWire, cplWire, `LINK_BYTES_PER_CYCLE,
                         `PROD_P_INTERVAL, `PROD_NP_INTERVAL, `LINK_LATENCY, enforce);
   Side sideB <- mkSide(1, `NUM_P_B, `NUM_NP_B, `NUM_NP_A,
                         pWire, npWire, cplWire, `LINK_BYTES_PER_CYCLE,
                         `PROD_P_INTERVAL, `PROD_NP_INTERVAL, `LINK_LATENCY, enforce);

   ConfigReader cfgReader <- mkConfigReader;

   Reg#(Cycle) cyc <- mkReg(0);
   (* fire_when_enabled, no_implicit_conditions *)
   rule tick; cyc <= cyc + 1; endrule

   Cycle linkLat = fromInteger(`LINK_LATENCY);

   FIFOF#(InFlight) pipeAB <- mkSizedFIFOF(8);
   FIFOF#(InFlight) pipeBA <- mkSizedFIFOF(8);

   Reg#(Bool) configured <- mkReg(False);
   Reg#(Bool) enforceFlag <- mkReg(enforce);

   // Runs exactly once, at cyc=0, before either side can produce anything
   // (each Side's own "configured" register starts False too). One BDPI
   // call per field via cfgReader.load, unconditionally -- this runs
   // whether or not any environment variable is actually set, so the
   // -D-sourced defaultConfig and a BDPI override are just two ways of
   // reaching the same configure() call, never a race between them.
   rule initConfig (!configured);
      configured <= True;
      Config cfg <- cfgReader.load(defaultConfig);
      enforceFlag <= cfg.enforceOrdering;
      sideA.configure(cfg.numPA, cfg.numNPA, cfg.numNPB,
                       cfg.prodPInterval, cfg.prodNPInterval, cfg.readGap, cfg.enforceOrdering);
      sideB.configure(cfg.numPB, cfg.numNPB, cfg.numNPA,
                       cfg.prodPInterval, cfg.prodNPInterval, cfg.readGap, cfg.enforceOrdering);
   endrule

   rule sendAB;
      let t = sideA.wireOut.first; sideA.wireOut.deq;
      pipeAB.enq(InFlight { t: t, tArrive: cyc + linkLat });
   endrule
   rule deliverAB (pipeAB.first.tArrive <= cyc);
      let t = pipeAB.first.t; pipeAB.deq;
      case (t.kind)
         TPOSTED:     sideB.wireInP.enq(t);
         TNONPOSTED:  sideB.wireInNp.enq(t);
         TCOMPLETION: sideB.wireInCpl.enq(t);
      endcase
   endrule

   rule sendBA;
      let t = sideB.wireOut.first; sideB.wireOut.deq;
      pipeBA.enq(InFlight { t: t, tArrive: cyc + linkLat });
   endrule
   rule deliverBA (pipeBA.first.tArrive <= cyc);
      let t = pipeBA.first.t; pipeBA.deq;
      case (t.kind)
         TPOSTED:     sideA.wireInP.enq(t);
         TNONPOSTED:  sideA.wireInNp.enq(t);
         TCOMPLETION: sideA.wireInCpl.enq(t);
      endcase
   endrule

   Reg#(Bool) finished <- mkReg(False);
   // "configured" guards the same vacuous-truth edge case as inside
   // mkSide: at cyc=0, before initConfig has run, both sides' OWN
   // "configured" is also still False, so sideA.finished/sideB.finished
   // already read False then too -- this is here for defense in depth,
   // matching the same standard applied throughout this file.
   rule report (sideA.finished && sideB.finished && !finished && configured);
      finished <= True;
      $display("==== Link assumptions ====");
      $display("  %s x%0d lanes @ %0d MHz  ->  %0d bytes/cycle (effective, hand-derived -- see note above)",
                `PCIE_GEN, `NUM_LANES, `CLOCK_RATE_MHZ, `LINK_BYTES_PER_CYCLE);
      $display("  theoretical link throughput: %0d Mb/s (%0d.%0d Gb/s)",
                theoreticalMbps, theoreticalMbps / 1000, (theoreticalMbps % 1000) / 100);
      $display("");
      $display("==== Bidirectional PCIe producer-consumer model ====");
      $display("ENFORCE_ORDERING=%0d  total cycles=%0d", pack(enforceFlag), cyc);
      sideA.printReport;
      sideB.printReport;
      $finish(0);
   endrule
endmodule
endpackage
