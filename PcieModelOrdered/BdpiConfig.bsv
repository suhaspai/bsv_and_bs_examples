// BdpiConfig.bsv
//
// A thin FFI boundary. This is the ONLY file in the project using BSV
// (SystemVerilog-flavoured) syntax -- every other file is classic
// Bluespec Haskell (.bs), by request. It exists purely because classic
// syntax's `foreign` keyword only supports raw Bit#(n) arguments and
// results (confirmed empirically: a String argument gives "Foreign
// function has non-Bit argument/result"), while a clean, name-based
// environment-variable reader needs BSV's richer `import "BDPI"` form,
// which does not parse at all in a .bs file (also confirmed empirically).
// Rather than fight that, the FFI import lives here, wrapped in a normal
// interface/module that a .bs file can import and call exactly like any
// other module -- no foreign-syntax leakage across the boundary.
//
// IMPORTANT LIMITATION, not specific to this file: BDPI calls only
// execute inside rules/methods, at simulation runtime, strictly AFTER
// Bluespec's static elaboration (module instantiation, FIFO sizing,
// Vector dimensions, credit-pool depths) has already completed. There is
// no way to make a BDPI-read value size a FIFO or a Vector -- elaboration
// has already finished building the module tree by the time any rule,
// and therefore any BDPI call, can run. So Config below holds only the
// parameters that are genuinely runtime comparisons (counts compared
// against counters, intervals, the enforce flag) -- never buffer depths,
// byte sizes, or anything else that affects hardware structure.

package BdpiConfig;

import "BDPI" function Int#(32) bdpi_getenv_int(String name, Int#(32) defaultVal);

// The "DefaultValue" struct: every runtime-tunable knob, with its default,
// in one place, so the BDPI-override path and the no-BDPI (env var unset)
// path both start from the exact same values.
typedef struct {
   UInt#(32) numPA;
   UInt#(32) numNPA;
   UInt#(32) numPB;
   UInt#(32) numNPB;
   UInt#(32) prodPInterval;
   UInt#(32) prodNPInterval;
   UInt#(32) readGap;
   Bool      enforceOrdering;
} Config deriving (Bits, Eq);

Config defaultConfig = Config {
   numPA: 2000, numNPA: 200, numPB: 2000, numNPB: 200,
   prodPInterval: 1, prodNPInterval: 20, readGap: 4,
   enforceOrdering: True
};

interface ConfigReader;
   // Reads every field's environment-variable override (if set) on top of
   // the supplied defaults. One BDPI call per field. Call this ONCE, from
   // an init rule at simulation start -- not every cycle; its result is
   // meant to be latched into registers, not re-read continuously.
   method ActionValue#(Config) load(Config defaults);
endinterface

function UInt#(32) getU32(String name, UInt#(32) d) =
   unpack(pack(bdpi_getenv_int(name, unpack(pack(d)))));

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
         enforceOrdering: getU32("ENFORCE_ORDERING", (d.enforceOrdering ? 1 : 0)) != 0
      };
      return c;
   endmethod
endmodule

endpackage
