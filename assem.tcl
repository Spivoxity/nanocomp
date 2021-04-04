# M6800 assembler

# The source is written as a TCL script containing a sequence of calls.
# Instruction formats are a bit unconventional, in that we write
#
# add A #3
# add A 4(X)
# add A B
#
# for various kinds of ADD instruction
#
# Write 'source assem.tcl' at the start and 'fixup; output-c' at the
# end of the assembly language program

# Exceptions

proc alt {scripts} {
    foreach s $scripts {
        set rc [catch {uplevel $s} result]
        if {$rc == 0} {
            return
        } elseif {$rc != 99} {
            uplevel [list return -code $rc $result]
        }
    }

    return -code 99
}

proc fail {} { return -code 99 }

proc try {script} {
    set rc [catch {uplevel $script} result]
    if {$rc != 0 && $rc != 99} {
        uplevel [list return -code $rc $result]
    }
}

proc match {patt target args} {
    set vs {}
    foreach a $args {
        upvar $a v-$a
        lappend vs v-$a
    }

    if {[eval [list regexp "^$patt\$" $target _] $vs]} return
    fail
}


# Symbols

# Get value of name, which must be defined
proc getval {name} {
    global symval

    if {[catch {set v $symval($name)}]} {
        error "$name is not defined"
    }

    return $v
}

# Set name to a known value
proc setval {name val} {
    global symval

    if {$name != "." && [info exists symval($name)]} {
        error "$name is multiply defined"
    }

    set symval($name) $val
}

# Analyse a constant, or fail
proc eat-const {exp} {
    global symval

    alt {
        { match {[0-9]+} $exp; return $exp }
        { match {0x[0-9a-f]+} $exp; return [expr {$exp}] }
        { match {[A-Za-z][A-Za-z0-9]*} $exp;
            if {[catch {set v $symval($exp)}]} fail
            return $v }
    }
}

# Known or unknown values are represented as lists [K val] or [V sym off]

# Add a value and a constant
proc addoff {f v} {
    switch [lindex $f 0] {
        K {return [list K [expr {[lindex $f 1]+$v}]]}
        V {return [list V [lindex $f 1] \
                       [expr {[lindex $f 2]+$v}]]}
    }
}

# Take the low-order byte of a value (must be known)
proc low {f} {
    switch [lindex $f 0] {
        K {return [list K [expr {[lindex $f 1]&0xff}]]}
        V {error "low"}
    }
}

# Take the high-order byte of a value (must be known)
proc high {f} {
    switch [lindex $f 0] {
        K {return [list K [expr {[lindex $f 1]>>8}]]}
        V {error "high"}
    }
}

for {set i 0} {$i < 10} {incr i} {
    set here($i) 0
}

# Analyse expression and make a value, or fail
proc eat-expr {exp} {
    global here

    alt {
        { match {lo\((.*)\)} $exp arg
            set v [eat-expr $arg]
            return [low $v] }
        { match {hi\((.*)\)} $exp arg
            set v [eat-expr $arg]
            return [high $v] }
        { set v [eat-const $exp]; return [list K $v] }
        { match {([0-9])b} $exp h;
            return [list V "here$h.$here($h)" 0] }
        { match {([0-9])f} $exp h;
            return [list V "here$h.[expr {$here($h)+1}]" 0] }
        { match {[A-Za-z][A-Za-z0-9]*} $exp
            return [list V $exp 0] }
        { match {(.+)([+-])(.+)} $exp e1 op e2
            set v1 [eat-expr $e1]
            set v2 [eat-const $e2]
            if {$op == "-"} {set v2 [expr {- $v2}]}
            return [addoff $v1 $v2] }
    }

    return $exp
}

# Evaluate expression to a value
proc expr-value {exp} {
    try {return [eat-expr $exp]}
    error "bad expression $exp"
}

# Evaluate expression to known value
proc evaluate {exp} {
    set v [expr-value $exp]
    switch [lindex $v 0] {
        K { return [lindex $v 1] }
        V { error "$exp is not known" }
    }
}

proc check1 {fix} {
    switch [lindex $fix 0] {
        K { set v [lindex $fix 1]
            if {$v >= 0 && $v < 256} return }
    }

    fail
}

proc do-use {size val} {
    switch $size {
        1 { byte [expr {$val & 0xff}] }
        2 { byte [expr {($val >> 8) & 0xff}]
            byte [expr {$val & 0xff}] }
        B { 
            if {$val == 0} {
                byte 0
            } else {
                set a [getval "."]
                set off [expr {$val - $a - 1}]
                if {$off < -128 || $off >= 128} {error "branch oflo"}
                byte [expr {$off & 0xff}]
            }
        }
    }
}

set fixes {}

proc use {size fix} {
    global fixes

    switch [lindex $fix 0] {
        K { do-use $size [lindex $fix 1] }
        V { lappend fixes [getval "."] $size [lindex $fix 1] [lindex $fix 2]
            do-use $size 0 }
    }
}

proc fixup {} {
    global fixes

    foreach {a s x n} $fixes {
        setval "." $a
        do-use $s [expr {[getval $x] + $n}]
    }
}

set min 0xffff; set max 0

proc byte {b} {
    global min max mem
    set a [getval "."]
    if {$a < $min} {set min $a}
    set mem($a) $b
    incr a
    if {$a > $max} {set max $a}
    setval "." $a
}

proc opcode {op} {
    byte 0x$op
}

proc output {} {
    global mem min max

    set a $min
    while {$a < $max} {
        if {! [info exists mem($a)]} {
            incr a
        } else {
            puts -nonewline [format "%04x" $a]
            set i 0
            while {$i < 16 && [info exists mem($a)]} {
                puts -nonewline [format " %02x" $mem($a)]
                incr i; incr a
            }
            puts ""
        }
    }
}

proc output-c {} {
    global mem min max

    set origin [expr {0x1000}]

    if {$min < $origin || $max > 0x1400} error

    for {set i $origin} {$i < $min} {incr i} {set mem($i) 0}

    puts "#include <avr/pgmspace.h>"
    puts [format "int codelen = %d;" [expr {$max-$origin+1}]]
    puts -nonewline "const uint8_t code\[] PROGMEM = {"
    for {set i $origin} {$i < $max} {incr i} {
        if {$i % 8 == 0} {puts -nonewline "\n    "}
        puts -nonewline [format " 0x%02x," $mem($i)]
    }
    puts "\n};"
}

# Instruction assemblers

proc asm-fixed {patts op rands} {
    match $patts $rands
    opcode $op
}

proc asm-regimm {reg op size rands} {
    match "$reg #(.+)" $rands e1
    set imm [eat-expr $e1]
    opcode $op; use $size $imm
}

proc asm-regmem {reg op rands} {
    alt {
        { match "$reg (.+)\\(X\\)" $rands e1
            set off [eat-expr $e1]
            opcode [hexadd $op 10]; use 1 $off }
        { match "$reg \\(X\\)" $rands
            opcode [hexadd $op 10]; byte 0 }
        { match "$reg (.+)" $rands e1
            set addr [eat-expr $e1]
            alt {
                { check1 $addr; opcode $op; use 1 $addr }
                { opcode [hexadd $op 20]; use 2 $addr }
            } }
    }
}

proc asm-mem {op rands} {
    alt {
        { match "(.+)\\(X\\)" $rands e1
            set off [eat-expr $e1]
            opcode $op; use 1 $off }
        { match "\\(X\\)" $rands
            opcode $op; byte 0 }
        { match "(.+)" $rands e1
            set addr [eat-expr $e1]
            opcode [hexadd $op 10]; use 2 $addr }
    }
}

proc asm-branch {op rands} {
    match "(.+)" $rands e1
    set targ [eat-expr $e1]
    opcode $op; use B $targ
}


proc hexadd {a b} {
    set a "0x$a"
    set b "0x$b"
    return [format "%2x" [expr {$a+$b}]]
}

# Instructions

proc assemble {op rands} {
    global instr

    if {[catch {set handlers $instr($op)}]} {
        error "Unknown instruction $op"
    }

    foreach h $handlers {
        try {eval [concat $h [list $rands]]; return}
    }
            
    error "Can't assemble $op $rands"
}
    

proc make-inst {mnem args} {
    global instr
    lappend instr($mnem) $args

    if {[llength [info procs $mnem]] == 0} {
        proc $mnem {args} [concat [list assemble $mnem] {$args}]
    }
}

proc fixed {mnem rands op} {
    make-inst $mnem asm-fixed $rands $op
}

proc memop {mnem op} {
    make-inst $mnem asm-mem $op
}

proc branch {mnem op} {
    make-inst $mnem asm-branch $op
}

proc regmem {mnem R op} {
    make-inst $mnem asm-regmem $R $op
}

proc monop {mnem op} {
    fixed $mnem A $op
    fixed $mnem B [hexadd $op 10]
    memop $mnem [hexadd $op 20]
}

proc immop {mnem R op size} {
    make-inst $mnem asm-regimm $R $op $size
    regmem $mnem $R [hexadd $op 10]
}

proc binop {mnem op} {
    immop $mnem A $op 1
    immop $mnem B [hexadd $op 40] 1
}

binop adc 89
fixed add {A B} 1b
binop add 8b
fixed and {A B} 14
binop and 84
monop asl 48
monop asr 47
branch bcc 24
branch bcs 25
branch beq 27
branch bge 2c
branch bgt 2e
branch bhi 22
binop bit 85
branch ble 2f
branch bls 23
branch blt 2d
branch bmi 2b
branch bne 26
branch bpl 2a
branch bra 20
branch bsr 8d
branch bvc 28
branch bvs 29
fixed clc {} 0c
fixed cli {} 0e
monop clr 4f
fixed clv {} 0a
fixed cmp {A B} 11
binop cmp 81
immop cmp X 8c 2
monop com 43
fixed daa {} 19
fixed dec SP 34
fixed dec X 09
monop dec 4a
binop eor 88
fixed inc X 08
fixed inc SP 31
monop inc 4c
fixed hcf {} dd
memop jmp 6e
memop jsr ad
binop ld 86
immop ld SP 8e 2
immop ld X ce 2
monop lsr 44
monop neg 40
fixed nop {} 01
binop or 8a
fixed push A 36
fixed push B 37
fixed pop A 32
fixed pop B 33
monop rol 49
monop ror 46
fixed rti {} 3b
fixed rts {} 39
binop sbc 82
fixed sec {} 0d
fixed sei {} 0f
fixed sev {} 0b
regmem st A 97
regmem st B d7
regmem st SP 9f
regmem st X df
fixed sub {A B} 10
binop sub 80
fixed swi {} 3f
fixed mov {B A} 16
fixed mov {CC A} 06
fixed mov {A B} 17
fixed mov {A CC} 07
fixed mov {X SP} 30
fixed mov {SP X} 35
monop tst 4d
fixed wai {} 3e


# Interface routines

proc .equ {name expr} {
    setval $name [evaluate $expr]
}

proc .byte {args} {
    foreach e $args {
        set v [expr-value $e]
        use 1 $v
    }
}

proc .word {args} {
    foreach e $args {
        set v [expr-value $e]
        use 2 $v
    }
}

proc label {label} {
    setval $label [getval "."]
}

proc unknown {cmd args} {
    global here

    if {[regexp {^([0-9]):$} $cmd _ h]} {
        incr here($h)
        label here$h.$here($h)
        return
    }

    if {[regexp {^(.*):$} $cmd _ label]} {
        label $label
        return
    }

    puts stderr "unknown: $cmd $args"
    exit 1
}
