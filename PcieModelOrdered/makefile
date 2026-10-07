# To build .bs, run "make TARGET=bs"

MAINV   := ${BSV}/main.v
c_files := bdpi_glue.c

TARGET ?= bsv

ifeq (${TARGET}, bsv) 
   sim_top   := PcieModelOrdered.bsv
   include ${BSV}/bsv.mk
else
   sim_top= PcieModelOrdered.bs
   include ${BSV}/bs.mk
endif

build: synth_bluesim

# read after write (pipelined)
raw:
	setenv NUM_P_A 2000   && \
	setenv NUM_P_B 2000   && \
	setenv NUM_NP_A 2000  && \
	setenv NUM_NP_B 2000  && \
	setenv READ_GAP 0     && \
	${MAKE} run_bsim      | tee raw.txt


# read after read (pipelined)
rar:
	setenv NUM_P_A 0      && \
	setenv NUM_P_B 0      && \
	setenv NUM_NP_A 2000  && \
	setenv NUM_NP_B 2000  && \
	setenv READ_GAP 0     && \
	${MAKE} run_bsim      | tee rar.txt

# write after write (pipelined)
waw:
	setenv NUM_P_A 2000   && \
	setenv NUM_P_B 2000   && \
	setenv NUM_NP_A 0     && \
	setenv NUM_NP_B 0     && \
	${MAKE} run_bsim      | tee waw.txt
