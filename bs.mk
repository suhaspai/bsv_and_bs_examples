# rules for bs compile step
ifndef scr
   $(error Please source ../env64.csh and "chex example_dir" before running make)
endif

SHELL    = tcsh
PSEARCH ?= :+

# Bluespec's main.v doesn't support fsdb dumps correctly
MAINV   ?= ${BLUESPECDIR}/Verilog/main.v

# Default target
build: synth
bluesim: synth_bluesim run_bsim
rtlsim: icarus_sim

icarus_sim: synth_icarus run_icarus
verilator_sim: link_verilator run_verilator

# Makefile for small examples
bs_files= ${sim_top} ${sim_rest}

# Output directories
bldex         ?= ${scr}/${tb}
bo_dir        ?= ${bldex}/biboba
i_dir         ?= ${bldex}/info
s_dir         ?= ${bldex}/bsim
v_dir         ?= ${bldex}/src
bsim_dir      ?= ${bldex}/bsim
bs_doc        ?= ${bldex}/doc/bs
rtl_doc       ?= ${bldex}/doc/rtl
mti_dir       ?= ${bldex}/mti
vcs_dir       ?= ${bldex}/vcs
icarus_dir    ?= ${bldex}/icarus
novas_dir     ?= ${bldex}/novas
isim_dir      ?= ${bldex}/isim
xsim_dir      ?= ${bldex}/xsim
vivado_dir    ?= ${bldex}/vivado
verilator_dir ?= ${bldex}/verilator

# Output files
bi_files = ${bs_files:%.bs=${bo_dir}/%.bo}
ba_files = ${bs_files:%.bs=${bo_dir}/mk%.ba}
ba_rules = ${bs_files:%.bs=mk%BA}
v_files  = ${bs_files:%.bs=${v_dir}/mk%.v}
v_rules  = ${bs_files:%.bs=mk%V}
cxx_obj  = ${cxx_files:%.cxx=${s_dir}/%.o}
mkTb     = ${sim_top:%.bs=mk%}

# Transformation Rules
mk%V: %.bs
	mkdir -p ${v_dir} ${bo_dir} ${i_dir}
	/usr/bin/time bsc -u -verilog -elab  \
	-bdir ${bo_dir} -vdir ${v_dir} -info-dir ${i_dir} -p ${PSEARCH} -no-show-method-conf \
	${bsv_compile_flags} \
	-show-schedule -show-compiles -aggressive-conditions -keep-fires -no-inline-rwire   \
	-remove-dollar -show-range-conflict ${link_type} $< |& tee ${v_dir}/synthesis.txt

mk%BA: %.bs
	@mkdir -p ${s_dir} ${bo_dir} ${i_dir}
	/usr/bin/time bsc -u -g ${mkTb} -sim -info-dir ${i_dir} \
	-bdir ${bo_dir} -p ${PSEARCH} ${bsv_compile_flags} \
	-show-schedule -show-compiles -aggressive-conditions -keep-fires -no-inline-rwire   \
	-show-range-conflict ${link_type} $<  |& tee ${s_dir}/bluesim.txt

#--------------------------- verilator via bsc ----------------------------
link_verilator: ${v_dir}/${mkTb}.v
	mkdir -p ${verilator_dir}
	cd ${verilator_dir} && bsc ${rtl_compile_flags} -e mkTb \
	-o out.verilator -vdir ${v_dir} -vsim verilator -keep-fires $< |& tee link_verilator.txt
run_verilator:
	cd ${verilator_dir} && out.verilator
clean_verilator:
	rm -rf ${verilator_dir}

#--------------------------  xsim ----------------------------------
# (bsc -h) and (xelab -h) => -Xv --relax or -Xv --timescale=1ns/1ps
link_xsim: ${xsim_dir}/out.vsim
${xsim_dir}/out.vsim: 
	@echo Linking with xsim
	mkdir -p ${xsim_dir}
	cd ${xsim_dir} && bsc ${rtl_compile_flags} -e ${mkTb} -verilog -Xv --timescale=1ns/1ps \
	-o out.vsim -vdir ${v_dir} -vsim xsim -keep-fires ${v_dir}/${mkTb}.v |& tee link_xsim.txt

# xsim -h
run_xsim: 
	cd ${xsim_dir} && out.vsim -testplusarg bscvcd -testplusarg bsccycle |& tee run_xsim.txt

run_xsim_gui: link_xsim ${xsim_dir}/out.vsim
	cd ${xsim_dir} && out.vsim -gui

clean_link_xsim:
	rm -rf ${xsim_dir}

#---------------------------  isim --------------------------------
link_isim: ${v_dir}/${mkTb}.v
	@echo Linking with isim
	mkdir -p ${isim_dir}
	cd ${isim_dir} && bsc ${rtl_compile_flags} -e ${mkTb} -verilog \
	-o ${isim_dir}/out.vsim -vdir ${v_dir} -vsim isim -keep-fires ${v_dir}/${mkTb}.v 

run_isim: ${isim_dir}/out.vsim
	cd ${isim_dir} && ${isim_dir}/out.vsim.isim -testplusarg bscvcd -testplusarg bsccycle \
	-tclbatch ${isim_dir}/out.vsim.isim.tcl

view_isim: ${isim_dir}/dump.vcd
	gtkwave $< 

run_isim_gui: ${isim_dir}/out.vsim
	${isim_dir}/out.vsim -gui &

#----------------------- vivado ---------------------------------
vivado:
	mkdir -p ${vivado_dir}
	cd ${vivado_dir} && vivado &

${s_dir}/%.o: %.cxx
	@mkdir -p ${s_dir}
	@echo compile C++ code
	${COMPILE.cpp} ${OUTPUT_OPTION} -fPIC $<

#------------------------ iverilog simulator ----------------------
synth_icarus: ${icarus_dir}/${mkTb}
${icarus_dir}/${mkTb}: synth
	mkdir -p ${icarus_dir}
	iverilog -Wall -y . -y ${BLUESPECDIR}/Verilog ${BLUESPECDIR}/Verilog/main.v ${rtl_compile_flags} \
	-y ${v_dir}  -DTOP=${mkTb} -o $@

.PHONY: run_icarus
run_icarus: ${icarus_dir}/${mkTb}
	cd ${icarus_dir} && vvp ${mkTb} +bscvcd +bscycle

${bsim_dir}/scemi_done:
	mkdir -p ${bsim_dir}
	cd ${bsim_dir} && scemilink -p ${bo_dir}:+ --sim --simdir=${s_dir} mkSimuTop 
	touch $@

# bluesim link target
synth_bluesim: ${bsim_dir}/${mkTb}.out
ifneq (${LINK_TYPE},)
${bsim_dir}/${mkTb}.out: ${ba_rules} 
	mkdir -p ${bsim_dir} ${s_dir}
	cd ${bsim_dir} && \
	/usr/bin/time -f "Time=%E" bsc -sim -scemi -e ${mkTb} -bdir ${bo_dir} ${rtl_compile_flags} \
	-simdir ${s_dir} -o $@  |& tee -a bluesim.txt
else
${bsim_dir}/${mkTb}.out: ${ba_rules} ${cxx_obj}
	mkdir -p ${bsim_dir} ${s_dir}
	cd ${bsim_dir} && \
	/usr/bin/time -f "Time=%E" bsc -sim -e ${mkTb} -bdir ${bo_dir} ${rtl_compile_flags} \
	-simdir ${s_dir} -o $@  ${bo_dir}/*.ba ${cxx_obj} |& tee -a bluesim.txt
endif

# Dependency on ${bsim_dir}/bsim is removed. make 'bsim' before 'run_bsim'
.PHONY: run_bsim run_sim run_sim1
run_bsim: ${bsim_dir}/${mkTb}.out
	cd ${bsim_dir} && ./${mkTb}.out +bsccycle -V ${mkTb}.vcd 

# Pick bluesim as the default simulator
run_sim: ${bsim_dir}/bsim
	cd ${bsim_dir} && ./out.bsim +bsccycle -V ${mkTb}.vcd 

run_sim1: run_bsim
	cp tb.gdb ${bsim_dir}
	cd ${bsim_dir} && sleep 5 && emacs -l ${rtl}/gdb.el -f load-gdb

# VCS simulator
${vcs_dir}/simv: synth
	mkdir -p ${vcs_dir}
	cd ${vcs_dir} && vcs -debug_pp -full64 +v2k +libext+.v ${rtl_compile_flags} ${MAINV} \
	+define+BSC_FSDB +define+TOP=${mkTb} \
	-y ${v_dir} -y ${BLUESPECDIR}/Verilog -y . \
	-P ${VERDI_HOME}/share/PLI/VCS/SUSE64/novas.tab ${VERDI_HOME}/share/PLI/VCS/SUSE64/pli.a \
	-o $@ 

.PHONY: run_vcs
run_vcs: ${vcs_dir}/simv 
	cd ${vcs_dir} && ./simv +bscfsdb | tee vcs.txt

# -top ${mkTb} => -top main
.PHONY: view_vcs
view_vcs: ${vcs_dir}/dump.fsdb compile_novas
	cd ${novas_dir} && verdi -top main -lib simu.work \
	-logdir ${novas_dir} -nologo ${waves_rc} -ssf $< &

# MTI simulator
${mti_dir}/simu.work:
	mkdir -p ${mti_dir}
	cd ${mti_dir} && vlib simu.work && vmap work ${mti_dir}/simu.work

${mti_dir}/mti: synth ${mti_dir}/simu.work
	cd ${mti_dir} && vlog -work simu.work ${rtl_compile_flags} +define+TOP=${mkTb} +v2k ${MAINV} \
		-y ${BLUESPECDIR}/Verilog -y ${v_dir}  +libext+.v 
	cd ${mti_dir} && touch mti

.PHONY: run_mti
run_mti: ${mti_dir}/mti
	cd ${mti_dir} && vsim -c -do "run -all; exit" simu.work.main +bscvcd +bsccycle +nowarnTSCALE \
	+dumpFSDB -pli ${VERDI_HOME}/share/PLI/MODELSIM/SUSE64/novas_fli.so | tee mti.txt

view_mti: ${mti_dir}/dump.fsdb ${novas_dir}/nov
	cd ${novas_dir} && verdi -top ${mkTb} -lib simu.work \
	-logdir ${novas_dir} -nologo ${waves_rc} -ssf $< &

.PHONY: vpp
# verilog pre-processed
v_top ?= ${v_dir}/${mkTb}.v
y_dir ?= -y ${BLUESPECDIR}/Verilog -y ${BLUESPECDIR}/Libraries -y ${v_dir} 
vpp: ${v_top}
	cd ${v_dir} && rm -rf work && vlib work 
	cd ${v_dir} && vlog +v2k +libext+.v ${rtl_compile_flags} ${y_dir} $< -E vpp.v


.PHONY: compile_novas
compile_novas: ${novas_dir}/nov
	@echo compiled for Novas

${novas_dir}/nov: 
	mkdir -p ${novas_dir}
	cd ${novas_dir} && vericom -2001 -lib simu.work +libext+.v ${rtl_compile_flags} +define+BSC_FSDB +define+TOP=${mkTb} \
	-y ${BLUESPECDIR}/Verilog -y ${v_dir} ${MAINV}
	touch $@

clean_novas:
	rm -rf ${novas_dir}

# Generates verilog files for synthesis
.PHONY: synth
synth: ${v_rules}

.PHONY: icarus
icarus: ${icarus_dir}/${mkTb}

# Generates verilog files for synthesis
.PHONY: lib
lib: ${v_rules} ${ba_rules}

# Simulation with Bluespec
.PHONY: bsim
bsim: ${bsim_dir}/bsim

# Simulation with Vcs
.PHONY: simv
simv: ${vcs_dir}/simv

# Simulation with Modelsim
.PHONY: mti
mti: ${mti_dir}/mti


# bluespec workstation
.PHONY: spec mti_waves view_sim
spec: 
	bluespec ../tb.bspec

.PHONY: mti_waves bsim_waves waven waves
mti_waves:
	rm -f bluespec_init.tcl
	cp ../bluespec_init.tcl.gtkwave bluespec_init.tcl
	gtkwave -f ${mti_dir}/dump.vcd &
	bluespec tb.bspec &

view_sim: run_sim
	gtkwave -f ${bsim_dir}/${mkTb}.vcd &

waven waves:
	rm -f ${mti_dir}/bluespec_init.tcl
	cp ../bluespec_init.tcl.nwave ${mti_dir}/bluespec_init.tcl
	cd ${mti_dir} && vcd2fsdb dump.vcd
	cd ${mti_dir} && nWave -f dump.vcd.fsdb &
	cp ../tb.bspec ${mti_dir}
	cd ${mti_dir} && bluespec tb.bspec  &

# Clean deletes object files
.PHONY: clean clean_bs clean_mti clean_vcs 
clean_bs:
	rm -rf ${v_dir} ${bo_dir}

clean:
	rm -rf ${scr}/${tb}

clean_vcs:
	rm -rf ${vcs_dir}

clean_mti:
	rm -rf ${mti_dir}

# generate only html documentation. "doxygen -g" shows all defaults
.PHONY: doc_bs
doc_bs: ${bs_doc}/html/index.html
${bs_doc}/html/index.html: ${bs_files}
	mkdir -p ${bs_doc}
	@rm -rf ${bs_doc}/Doxyfile
	@echo "PROJECT_NAME           = ${tb}"           >> ${bs_doc}/Doxyfile
	@echo "OUTPUT_DIRECTORY       = ${bs_doc}"       >> ${bs_doc}/Doxyfile
	@echo "TAB_SIZE               = 4"               >> ${bs_doc}/Doxyfile
	@echo "INPUT                  = ${pwd}"          >> ${bs_doc}/Doxyfile
	@echo "FILE_PATTERNS          = *.h *.bs"        >> ${bs_doc}/Doxyfile
	@echo "SOURCE_BROWSER         = YES"             >> ${bs_doc}/Doxyfile
	@echo "GENERATE_LATEX         = NO"              >> ${bs_doc}/Doxyfile
	doxygen ${bs_doc}/Doxyfile

#	firefox $@

.PHONY: doc_rtl
doc_rtl: ${rtl_doc}/html/index.html
${rtl_doc}/html/index.html:
	mkdir -p ${rtl_doc}
	@rm -rf ${rtl_doc}/Doxyfile
	@echo "PROJECT_NAME           = ${tb}"                          >> ${rtl_doc}/Doxyfile
	@echo "OUTPUT_DIRECTORY       = ${rtl_doc}"                     >> ${rtl_doc}/Doxyfile
	@echo "TAB_SIZE               = 4"                              >> ${rtl_doc}/Doxyfile
	@echo "INPUT                  = ${v_dir} ${MAINV} ${rtl_dir}"   >> ${rtl_doc}/Doxyfile
	@echo "FILE_PATTERNS          = *.h *.v"                        >> ${rtl_doc}/Doxyfile
	@echo "SOURCE_BROWSER         = YES"                            >> ${rtl_doc}/Doxyfile
	@echo "GENERATE_LATEX         = NO"                             >> ${rtl_doc}/Doxyfile
	doxygen ${rtl_doc}/Doxyfile

#	firefox $@

.PHONY: doc
doc: doc_bs doc_rtl
.PHONY: clean_doc
clean_doc:
	rm -rf ${rtl_doc} ${bs_doc}
help:
	@echo
	@echo "   TARGETS:"
	@echo
	@echo "       synth - just compiles bs code in ${v_dir}/*.v"
	@echo
	@echo "        bsim - generates ${bo_dir}/*.bi/bo and Bluesim executable- ${bsim_dir}/bsim"
	@echo "    run_bsim - runs bluesim simulation"
	@echo
	@echo "         mti - Compiles for modelsim simulation in ${mti_dir}"
	@echo "     run_mti - runs modelsim simulation"
	@echo "    view_mti - view fsdb waveform in Verdi"
	@echo
	@echo "      icarus - creates iverilog executable ${icarus_dir}/${mkTb}"
	@echo "  run_icarus - runs iverilog simulation"
	@echo
	@echo "        simv - Creates Vcs executable- ${vcs_dir}/simv"
	@echo "     run_vcs - runs vcs simulation"
	@echo
	@echo "        spec - brings up bluespec workstation"
	@echo
	@echo "     doc_bs - create doxygen documenation of the bs code and view in mozilla"
	@echo
	@echo "     doc_rtl - create doxygen documentation of the compiled rtl code and view in mozilla"
	@echo
	@echo "       clean - deletes ${bldex}"
	@echo

env:
	@echo
	@echo "---------------------------------------------------------"
	@echo "               Makefile Environment"
	@echo "---------------------------------------------------------"	
	@echo "        BS Source files: ${bs_files}"
	@echo "---------------------------------------------------------"
	@echo "           .v directory: ${v_dir}"	
	@echo "     .ba file directory: ${s_dir}"
	@echo ".bi, .bo file directory: ${bo_dir}"
	@echo "---------------------------------------------------------"
	@echo "              CXX files: ${cxx_files}"
	@echo "              DUT files: ${dut_files}"
	@echo "              SYN files: ${syn_files}"
	@echo "              SIM files: ${sim_files}"
	@echo "                V files: ${v_files}"
	@echo "---------------------------------------------------------"
	@echo " For make actions, type: make -n target_name"
	@echo "---------------------------------------------------------"
	@echo


