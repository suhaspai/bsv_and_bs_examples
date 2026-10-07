// bdpi_glue.c
//
// Implements the single BDPI function BdpiConfig.bsv imports. Reads an
// environment variable as an integer, falling back to the supplied
// default when the variable is unset or empty. This is what lets
// PcieModelOrdered.bs be configured per-run without recompiling: set
// NUM_P_A, NUM_NP_A, NUM_P_B, NUM_NP_B, PROD_P_INTERVAL, PROD_NP_INTERVAL,
// READ_GAP, or ENFORCE_ORDERING in the environment before running the
// compiled simulator.

#include <stdlib.h>
#include <stdint.h>

extern "C" {
   
   int32_t bdpi_getenv_int(const char* name, int32_t defaultVal) {
      const char* v = getenv(name);
      if (v == NULL || v[0] == '\0') return defaultVal;
      return (int32_t) atoi(v);
   }
}

