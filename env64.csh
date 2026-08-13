#!/bin/tcsh
#-----------------------------------------------------------------
# Change it here where you want the build output to go 
#-----------------------------------------------------------------
unsetenv LINK_TYPE
unsetenv scr
setenv scr $HOME/scratch
setenv BSV $PWD

#-----------------------------------------------------------------
# Aliases
#-----------------------------------------------------------------
alias chex                              \
    'setenv tb  \!:1;                   \
    setenv bsv $BSV/$tb;                \
    setenv bs  $bsv                     \
    setenv rtl $BSV/$tb/rtl             \
    setenv src $BSV/$tb/src             \
    setenv sv  $BSV/$tb/sv              \
    setenv bldex $scr/$tb               \
    setenv v_dir $scr/$tb/src           \
    setenv bo_dir $scr/$tb/biboba       \
    setenv i_dir $scr/$tb/info          \
    setenv vcs_dir $scr/$tb/vcs         \
    setenv bsim_dir $scr/$tb/bsim       \
    setenv mti_dir $scr/$tb/mti         \
    setenv novas_dir $scr/$tb/novas     \
    setenv CVSROOT $HOME/cvsroot        \
    cd $bsv                             '

# src is C++ testbench source and not compiled verilog code (all eve_scemi_* examples have this directory)
alias bsv 'cd $bsv'
alias src 'cd $src'
alias rtl 'cd $rtl'
alias sv  'cd $sv'

# v_dir is where you find Bluespec compiled verilog. i_dir has scheduling information
alias v_dir    'cd $v_dir'
alias i_dir    'cd $i_dir'
alias vcs_dir  'cd $vcs_dir'
alias mti_dir  'cd $mti_dir'
alias bsim_dir 'cd $bsim_dir'

#-----------------------------------------------------------------
# Misc.
#-----------------------------------------------------------------
setenv TIME "Time= %E"
