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

proc add {f v} {
    switch [lindex $f 0] {
        K {return [list K [expr {[lindex $f 1]+$v}]]}
        V {return [list V [lindex $f 1] \
                       [expr {[lindex $f 2]+$v}]]}
    }
}

proc low {f} {
    switch [lindex $f 0] {
        K {return [list K [expr {[lindex $f 1]&0xff}]]}
        V {error "low"}
    }
}

proc high {f} {
    switch [lindex $f 0] {
        K {return [list K [expr {[lindex $f 1]>>8}]]}
        V {error "high"}
    }
}

# Analyse expression and make a fixup, or fail
proc eat-expr {exp} {
    alt {
        { match {lo\((.*)\)} $exp arg
            set v [eat-expr $arg]
            return [low $v] }
        { match {hi\((.*)\)} $exp arg
            set v [eat-expr $arg]
            return [high $v] }
        { set v [eat-const $exp]; return [list K $v] }
        { match {[A-Za-z][A-Za-z0-9]*} $exp
            return [list V $exp 0] }
        { match {(.+)([+-])(.+)} $exp e1 op e2
            set v1 [eat-expr $e1]
            set v2 [eat-const $e2]
            if {$op == "-"} {set v2 [expr {- $v2}]}
            return [add $v1 $v2] }
    }

    return $exp
}

# Evaluate expression to a fixup
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

proc asm-regimm {reg opimm size rands} {
    match "$reg #(.+)" $rands e1
    set imm [eat-expr $e1]
    opcode $opimm; use $size $imm
}

proc asm-regmem {reg opdir opext opind rands} {
    alt {
        { match "$reg (.+)\\(X\\)" $rands e1
            set off [eat-expr $e1]
            opcode $opind; use 1 $off }
        { match "$reg \\(X\\)" $rands
            opcode $opind; byte 0 }
        { match "$reg (.+)" $rands e1
            set addr [eat-expr $e1]
            alt {
                { check1 $addr; opcode $opdir; use 1 $addr }
                { opcode $opext; use 2 $addr }
            } }
    }
}

proc asm-mem {opext opind rands} {
    alt {
        { match "(.+)\\(X\\)" $rands e1
            set off [eat-expr $e1]
            opcode $opind; use 1 $off }
        { match "\\(X\\)" $rands
            opcode $opind; byte 0 }
        { match "(.+)" $rands e1
            set addr [eat-expr $e1]
            opcode $opext; use 2 $addr }
    }
}

proc asm-branch {op rands} {
    match "(.+)" $rands e1
    set targ [eat-expr $e1]
    opcode $op; use B $targ
}

proc fixed {op} { 
    return [specific {} $op]
}

proc specific {rands op} { 
    return [list [list asm-fixed $rands $op]]
}

proc regmem {R imm dir ext ind size} { 
    return [list [list asm-regimm $R $imm $size] \
                [list asm-regmem $R $dir $ext $ind]]
}

proc regmem8 {R imm dir ext ind} { 
    return [regmem $R $imm $dir $ext $ind 1] 
}

proc regmem16 {R imm dir ext ind} {
    return [regmem $R $imm $dir $ext $ind 2] 
}

proc store {R dir ext ind} { 
    return [list [list asm-regmem $R $dir $ext $ind]]
}

proc unary {A B ext ind} { 
    return [list [list asm-fixed {A} $A] [list asm-fixed {B} $B] \
                [list asm-mem $ext $ind]]
}

proc branch {op} { return [list [list asm-branch $op]] }

proc jump {ext ind} { 
    return [list [list asm-mem $ext $ind]]
}

proc push-pop {A B} { 
    return [list [list asm-fixed {A} $A] [list asm-fixed {B} $B]]
}

# Instructions

proc inst {mnem args} {
    global instr

    set instr($mnem) [eval concat $args]
}

inst adc [regmem8 A 89 99 b9 a9] [regmem8 B c9 d9 f9 e9]
inst add [specific {A B} 1b] [regmem8 A 8b 9b bb ab] [regmem8 B cb db fb eb]
inst and [specific {A B} 14] [regmem8 A 84 94 b4 a4] [regmem8 B c4 d4 f4 e4]
inst asl [unary 48 58 78 68]
inst asr [unary 47 57 77 67]
inst bcc [branch 24]
inst bcs [branch 25]
inst beq [branch 27]
inst bge [branch 2c]
inst bgt [branch 2e]
inst bhi [branch 22]
inst bit [regmem8 A 85 95 b5 a5] [regmem8 B c5 d5 f5 e5]
inst ble [branch 2f]
inst bls [branch 23]
inst blt [branch 2d]
inst bmi [branch 2b]
inst bne [branch 26]
inst bpl [branch 2a]
inst bra [branch 20]
inst bsr [branch 8d]
inst bvc [branch 28]
inst bvs [branch 29]
inst clc [fixed 0c]
inst cli [fixed 0e]
inst clr [unary 4f 5f 7f 6f]
inst clv [fixed 0a]
inst cmp [specific {A B} 11] [regmem8 A 81 91 b1 a1] \
    [regmem8 B c1 d1 f1 e1] [regmem16 X 8c 9c bc ac]
inst com [unary 43 53 73 63]
inst daa [fixed 19]
inst dec [specific SP 34] [specific X 09] [unary 4a 5a 7a 6a] 
inst eor [regmem8 A 88 98 b8 a8] [regmem8 B c8 d8 f8 e8]
inst inc [specific SP 31] [specific X 08] [unary 4c 5c 7c 6c] 
inst hcf [fixed dd]
inst jmp [jump 7e 6e]
inst jsr [jump bd ad]
inst ld [regmem8 A 86 96 b6 a6] [regmem8 B c6 d6 f6 e6] \
    [regmem16 SP 8e 9e be ae] [regmem16 X ce de fe ee]
inst lsr [unary 44 54 74 64]
inst neg [unary 40 50 70 60]
inst nop [fixed 01]
inst ora [regmem8 A 8a 9a ba aa] [regmem8 B ca da fa ea]
inst push [push-pop 36 37]
inst pop [push-pop 32 33]
inst rol [unary 49 59 79 69]
inst ror [unary 46 56 76 66]
inst rti [fixed 3b]
inst rts [fixed 39]
inst sbc [regmem8 A 82 92 b2 a2] [regmem8 B c2 d2 f2 e2]
inst sec [fixed 0d]
inst sei [fixed 0f]
inst sev [fixed 0b]
inst st [store A 97 b7 a7] [store B d7 f7 e7] \
    [store SP 9f df af] [store X df ff ef]
inst sub [specific {A B} 10] [regmem8 A 80 90 b0 a0] [regmem8 B c0 d0 f0 e0]
inst swi [fixed 3f]
inst mov [specific {B A} 16] [specific {CC A} 06] \
    [specific {A B} 17] [specific {A CC} 07] [specific {X SP} 30] \
    [specific {SP X} 35]; # TAB TAP TBA TPA TSX TXS
inst tst [unary 4d 5d 7d 6d]
inst wai [fixed 3e]


# Interface routines

proc I {op args} {
    global instr

    if {[catch {set handlers $instr($op)}]} {
        error "Unknown instruction $op"
    }

    foreach h $handlers {
        try {eval [concat $h [list $args]]; return}
    }
            
    error "Can't assemble $op $args"
}

proc E {name expr} {
    setval $name [evaluate $expr]
}

proc B {args} {
    foreach e $args {
        set v [expr-value $e]
        use 1 $v
    }
}

proc W {args} {
    foreach e $args {
        set v [expr-value $e]
        use 2 $v
    }
}

proc L {label} {
    setval $label [getval "."]
}
