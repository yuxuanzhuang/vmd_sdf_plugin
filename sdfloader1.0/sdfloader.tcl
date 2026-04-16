# Load SDF records into VMD molecules.
# Interactive usage:
#   source sdfloader1.0/sdfloader.tcl
#   set molids [sdfload path/to/file.sdf]
#   set molid  [sdfload -mode trajectory path/to/file.sdf]
#
# If sourced from ~/.vmdrc, standard VMD loads such as
#   mol new path/to/file.sdf
# default to multiple molecules, while
#   mol new path/to/file.sdf type SDF
# uses the compiled trajectory plugin and
#   mol new path/to/file.sdf type SDFMulti
# forces split-record loading through this script.
#
# In the VMD GUI, "File -> New Molecule" can only load the trajectory mode.
# Multi-molecule loading is available through the SDFLoader menu entries.

package provide sdfloader 1.0

namespace eval ::SDFLoader {
    variable version 1.0
    variable elements {
        X H He Li Be B C N O F Ne Na Mg Al Si P
        S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As
        Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn
        Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho
        Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po
        At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md
        No Lr Rf Db Sg Bh Hs Mt Ds Rg
    }
    variable cli_name_fields {NAME Name TITLE Title ID Id}
    variable last_molids {}
    variable menu_registered 0
    variable startup_autoload_done 0
    variable multimol_types {isissdf sdfmulti sdfmols sdfsplit}
    variable trajectory_type_labels {
        sdf
        {structure data file}
        {structure data file (trajectory)}
        {structure data file sdf}
        {structure data file sdf (trajectory)}
    }
    variable multimol_type_labels {
        isissdf
        sdfmulti
        sdfmols
        sdfsplit
        {structure data file (multiple molecule)}
        {structure data file (multiple molecules)}
    }
}

proc ::SDFLoader::split_records {filename} {
    set fh [open $filename r]
    set raw [read $fh]
    close $fh

    set normalized [string map [list "\r\n" "\n" "\r" "\n"] $raw]
    set lines [split $normalized "\n"]

    set records {}
    set current {}
    foreach line $lines {
        if {$line eq "$$$$"} {
            if {[::SDFLoader::record_has_content $current]} {
                lappend records $current
            }
            set current {}
            continue
        }
        lappend current $line
    }

    if {[::SDFLoader::record_has_content $current]} {
        lappend records $current
    }

    return $records
}

proc ::SDFLoader::record_has_content {lines} {
    foreach line $lines {
        if {[string trim $line] ne ""} {
            return 1
        }
    }
    return 0
}

proc ::SDFLoader::parse_counts_field {line start end} {
    set value [string trim [string range $line $start $end]]
    if {$value eq ""} {
        return 0
    }
    if {![string is integer -strict $value]} {
        error "invalid integer field '$value' in counts line"
    }
    return $value
}

proc ::SDFLoader::parse_float_field {line start end} {
    set value [string trim [string range $line $start $end]]
    if {$value eq ""} {
        return 0.0
    }
    if {![string is double -strict $value]} {
        error "invalid floating-point field '$value'"
    }
    return $value
}

proc ::SDFLoader::canonicalize_element {raw} {
    variable elements

    set token [string trim $raw]
    if {$token eq ""} {
        return X
    }

    set upper [string toupper $token]
    array set aliases {
        D H
        T H
        * X
        A X
        Q X
        L X
        LP X
        R X
        R# X
    }
    if {[info exists aliases($upper)]} {
        return $aliases($upper)
    }

    foreach element $elements {
        if {[string equal [string toupper $element] $upper]} {
            return $element
        }
    }

    return X
}

proc ::SDFLoader::atomic_number {element} {
    variable elements
    return [lsearch -exact $elements $element]
}

proc ::SDFLoader::charge_from_v2000_code {code} {
    switch -- $code {
        0 { return 0.0 }
        1 { return 3.0 }
        2 { return 2.0 }
        3 { return 1.0 }
        4 { return 0.0 }
        5 { return -1.0 }
        6 { return -2.0 }
        7 { return -3.0 }
        default { return 0.0 }
    }
}

proc ::SDFLoader::bond_order_from_code {code} {
    switch -- $code {
        1 { return 1.0 }
        2 { return 2.0 }
        3 { return 3.0 }
        4 { return 1.5 }
        5 { return 1.0 }
        6 { return 1.5 }
        7 { return 1.5 }
        8 { return 1.0 }
        default { return 1.0 }
    }
}

proc ::SDFLoader::parse_sdf_properties {lines start_index} {
    set properties {}
    set idx $start_index
    set count [llength $lines]

    while {$idx < $count} {
        set line [lindex $lines $idx]
        incr idx

        if {![regexp {^>\s*<([^>]+)>} $line -> key]} {
            continue
        }

        set values {}
        while {$idx < $count} {
            set value [lindex $lines $idx]
            incr idx
            if {$value eq ""} {
                break
            }
            lappend values $value
        }

        dict set properties [string trim $key] [join $values "\n"]
    }

    return $properties
}

proc ::SDFLoader::charge_property_priority {key} {
    set normalized [string toupper [string trim $key]]

    if {$normalized eq "ATOM.DPROP.PARTIALCHARGE"} {
        return 400
    }
    if {$normalized eq "PARTIALCHARGE"} {
        return 300
    }
    if {[string match "ATOM.DPROP.*" $normalized] && [string match "*PARTIALCHARGE*" $normalized]} {
        return 250
    }
    if {[string match "ATOM.DPROP.*" $normalized] && [string match "*CHARGE*" $normalized]} {
        return 200
    }
    if {[string match "*PARTIALCHARGE*" $normalized]} {
        return 150
    }

    return 0
}

proc ::SDFLoader::apply_property_charges {properties atoms_var} {
    upvar 1 $atoms_var atoms

    if {[llength $atoms] == 0 || [dict size $properties] == 0} {
        return
    }

    set best_priority 0
    set best_values {}

    foreach key [dict keys $properties] {
        set priority [::SDFLoader::charge_property_priority $key]
        if {$priority <= $best_priority} {
            continue
        }

        set values [regexp -all -inline {\S+} [dict get $properties $key]]
        if {[llength $values] != [llength $atoms]} {
            continue
        }

        set parsed {}
        set valid 1
        foreach value $values {
            if {![string is double -strict $value]} {
                set valid 0
                break
            }
            lappend parsed [expr {double($value)}]
        }
        if {!$valid} {
            continue
        }

        set best_priority $priority
        set best_values $parsed
    }

    if {$best_priority == 0} {
        return
    }

    for {set i 0} {$i < [llength $atoms]} {incr i} {
        set atom [lindex $atoms $i]
        dict set atom charge [lindex $best_values $i]
        lset atoms $i $atom
    }
}

proc ::SDFLoader::shell_split {text} {
    set tokens {}
    set current ""
    set quote ""
    set escape 0

    foreach ch [split $text ""] {
        if {$escape} {
            append current $ch
            set escape 0
            continue
        }

        if {$quote ne ""} {
            if {$ch eq "\\" && $quote eq "\""} {
                set escape 1
                continue
            }
            if {$ch eq $quote} {
                set quote ""
                continue
            }
            append current $ch
            continue
        }

        if {$ch eq "'" || $ch eq "\""} {
            set quote $ch
            continue
        }
        if {$ch eq "\\"} {
            set escape 1
            continue
        }
        if {[string is space $ch]} {
            if {$current ne ""} {
                lappend tokens $current
                set current ""
            }
            continue
        }

        append current $ch
    }

    if {$escape} {
        append current "\\"
    }
    if {$current ne ""} {
        lappend tokens $current
    }

    return $tokens
}

proc ::SDFLoader::parse_v2000_atom_line {line atom_index} {
    set x [::SDFLoader::parse_float_field $line 0 9]
    set y [::SDFLoader::parse_float_field $line 10 19]
    set z [::SDFLoader::parse_float_field $line 20 29]
    set raw_symbol [string trim [string range $line 31 33]]
    set charge_code [::SDFLoader::parse_counts_field $line 36 38]

    set element [::SDFLoader::canonicalize_element $raw_symbol]
    if {$raw_symbol eq ""} {
        set raw_symbol $element
    }

    return [dict create \
        index $atom_index \
        x $x y $y z $z \
        raw_symbol $raw_symbol \
        element $element \
        charge [::SDFLoader::charge_from_v2000_code $charge_code]]
}

proc ::SDFLoader::parse_v2000_bond_line {line} {
    set atom1 [::SDFLoader::parse_counts_field $line 0 2]
    set atom2 [::SDFLoader::parse_counts_field $line 3 5]
    set bond_code [::SDFLoader::parse_counts_field $line 6 8]

    if {$atom1 <= 0 || $atom2 <= 0} {
        error "invalid bond atom index in line '$line'"
    }

    return [list \
        [expr {$atom1 - 1}] \
        [expr {$atom2 - 1}] \
        [format "sdf:%s" $bond_code] \
        [::SDFLoader::bond_order_from_code $bond_code]]
}

proc ::SDFLoader::apply_v2000_property_line {line atoms_var} {
    upvar 1 $atoms_var atoms

    set tokens [regexp -all -inline {\S+} $line]
    if {[llength $tokens] < 3} {
        return
    }

    set tag [lindex $tokens 1]
    if {$tag ne "CHG"} {
        return
    }

    set count [lindex $tokens 2]
    if {![string is integer -strict $count]} {
        return
    }

    for {set i 0} {$i < $count} {incr i} {
        set atom_pos [expr {3 + (2 * $i)}]
        set charge_pos [expr {$atom_pos + 1}]
        if {$charge_pos >= [llength $tokens]} {
            break
        }

        set atom_index [lindex $tokens $atom_pos]
        set charge [lindex $tokens $charge_pos]
        if {![string is integer -strict $atom_index] || ![string is integer -strict $charge]} {
            continue
        }

        set atom_zero [expr {$atom_index - 1}]
        if {$atom_zero < 0 || $atom_zero >= [llength $atoms]} {
            continue
        }

        set atom [lindex $atoms $atom_zero]
        dict set atom charge [expr {double($charge)}]
        lset atoms $atom_zero $atom
    }
}

proc ::SDFLoader::parse_v3000_logical_line {lines index_var} {
    upvar 1 $index_var idx

    set logical ""
    set count [llength $lines]

    while {$idx < $count} {
        set line [lindex $lines $idx]
        incr idx

        if {$line eq ""} {
            continue
        }
        if {![string match "M  V30 *" $line]} {
            return $line
        }

        set content [string range $line 7 end]
        if {[string match "*-" $content]} {
            append logical [string trimright [string range $content 0 end-1]]
            continue
        }

        append logical $content
        return $logical
    }

    return ""
}

proc ::SDFLoader::parse_v3000_attribute {token key} {
    if {[regexp [format {^%s=(.+)$} $key] $token -> value]} {
        return $value
    }
    return ""
}

proc ::SDFLoader::parse_v3000_record {lines} {
    set idx 4
    set count [llength $lines]

    while {$idx < $count} {
        set logical [::SDFLoader::parse_v3000_logical_line $lines idx]
        if {$logical eq "BEGIN CTAB"} {
            break
        }
    }
    if {$idx >= $count} {
        error "missing 'M  V30 BEGIN CTAB'"
    }

    set logical [::SDFLoader::parse_v3000_logical_line $lines idx]
    if {![string match "COUNTS *" $logical]} {
        error "missing 'M  V30 COUNTS' block"
    }
    set tokens [regexp -all -inline {\S+} $logical]
    if {[llength $tokens] < 3} {
        error "invalid V3000 counts line '$logical'"
    }
    set natoms [lindex $tokens 1]
    set nbonds [lindex $tokens 2]

    set atoms {}
    set bonds {}

    while {$idx < $count} {
        set logical [::SDFLoader::parse_v3000_logical_line $lines idx]
        if {$logical eq "BEGIN ATOM"} {
            break
        }
    }
    if {$idx >= $count} {
        error "missing 'M  V30 BEGIN ATOM' block"
    }

    while {$idx < $count} {
        set logical [::SDFLoader::parse_v3000_logical_line $lines idx]
        if {$logical eq "END ATOM"} {
            break
        }

        set tokens [regexp -all -inline {\S+} $logical]
        if {[llength $tokens] < 6} {
            error "invalid V3000 atom line '$logical'"
        }

        set raw_symbol [lindex $tokens 1]
        set element [::SDFLoader::canonicalize_element $raw_symbol]
        set charge 0.0
        foreach token [lrange $tokens 6 end] {
            set charge_token [::SDFLoader::parse_v3000_attribute $token CHG]
            if {$charge_token ne "" && [string is integer -strict $charge_token]} {
                set charge [expr {double($charge_token)}]
            }
        }

        lappend atoms [dict create \
            index [expr {[llength $atoms] + 1}] \
            x [lindex $tokens 2] \
            y [lindex $tokens 3] \
            z [lindex $tokens 4] \
            raw_symbol $raw_symbol \
            element $element \
            charge $charge]
    }

    while {$idx < $count} {
        set logical [::SDFLoader::parse_v3000_logical_line $lines idx]
        if {$logical eq "BEGIN BOND"} {
            break
        }
    }
    if {$idx >= $count} {
        error "missing 'M  V30 BEGIN BOND' block"
    }

    while {$idx < $count} {
        set logical [::SDFLoader::parse_v3000_logical_line $lines idx]
        if {$logical eq "END BOND"} {
            break
        }

        set tokens [regexp -all -inline {\S+} $logical]
        if {[llength $tokens] < 4} {
            error "invalid V3000 bond line '$logical'"
        }

        set bond_code [lindex $tokens 1]
        set atom1 [lindex $tokens 2]
        set atom2 [lindex $tokens 3]
        if {![string is integer -strict $atom1] || ![string is integer -strict $atom2]} {
            error "invalid V3000 bond endpoints in '$logical'"
        }

        lappend bonds [list \
            [expr {$atom1 - 1}] \
            [expr {$atom2 - 1}] \
            [format "sdf:%s" $bond_code] \
            [::SDFLoader::bond_order_from_code $bond_code]]
    }

    set properties [::SDFLoader::parse_sdf_properties $lines $idx]
    ::SDFLoader::apply_property_charges $properties atoms
    return [dict create atoms $atoms bonds $bonds properties $properties expected_atoms $natoms expected_bonds $nbonds]
}

proc ::SDFLoader::parse_v2000_record {lines} {
    if {[llength $lines] < 4} {
        error "record is too short to contain an MDL mol block"
    }

    set counts_line [lindex $lines 3]
    set natoms [::SDFLoader::parse_counts_field $counts_line 0 2]
    set nbonds [::SDFLoader::parse_counts_field $counts_line 3 5]

    set min_lines [expr {4 + $natoms + $nbonds}]
    if {[llength $lines] < $min_lines} {
        error "record ended before atom/bond blocks were complete"
    }

    set atoms {}
    for {set i 0} {$i < $natoms} {incr i} {
        lappend atoms [::SDFLoader::parse_v2000_atom_line [lindex $lines [expr {4 + $i}]] [expr {$i + 1}]]
    }

    set bonds {}
    set bond_start [expr {4 + $natoms}]
    for {set i 0} {$i < $nbonds} {incr i} {
        lappend bonds [::SDFLoader::parse_v2000_bond_line [lindex $lines [expr {$bond_start + $i}]]]
    }

    set idx [expr {$bond_start + $nbonds}]
    set count [llength $lines]
    while {$idx < $count} {
        set line [lindex $lines $idx]
        incr idx
        if {$line eq "M  END"} {
            break
        }
        if {[string match "M  *" $line]} {
            ::SDFLoader::apply_v2000_property_line $line atoms
        }
    }
    if {$idx > $count || [lindex $lines [expr {$idx - 1}]] ne "M  END"} {
        error "missing 'M  END' terminator"
    }

    set properties [::SDFLoader::parse_sdf_properties $lines $idx]
    ::SDFLoader::apply_property_charges $properties atoms
    return [dict create atoms $atoms bonds $bonds properties $properties expected_atoms $natoms expected_bonds $nbonds]
}

proc ::SDFLoader::parse_record {lines} {
    if {[llength $lines] < 4} {
        error "record is too short to parse"
    }

    set name [string trim [lindex $lines 0]]
    set version_line [lindex $lines 3]
    if {[string match "*V3000*" $version_line]} {
        set block [::SDFLoader::parse_v3000_record $lines]
    } else {
        set block [::SDFLoader::parse_v2000_record $lines]
    }

    dict set block name $name
    return $block
}

proc ::SDFLoader::sanitize_name_fragment {text fallback} {
    set cleaned [regsub -all {[^[:alnum:]]} [string trim $text] ""]
    if {$cleaned eq ""} {
        return $fallback
    }
    return $cleaned
}

proc ::SDFLoader::resname_from_record {record_name} {
    set cleaned [string toupper [::SDFLoader::sanitize_name_fragment $record_name MOL]]
    return [string range $cleaned 0 7]
}

proc ::SDFLoader::molecule_name {record filename record_number} {
    variable cli_name_fields

    set name [dict get $record name]
    if {$name eq ""} {
        foreach field $cli_name_fields {
            if {[dict exists $record properties $field]} {
                set name [string trim [dict get $record properties $field]]
                if {$name ne ""} {
                    break
                }
            }
        }
    }
    if {$name eq ""} {
        set stem [file rootname [file tail $filename]]
        set name [format "%s_%d" $stem $record_number]
    }
    return $name
}

proc ::SDFLoader::build_atom_rows {record mol_name} {
    set resname [::SDFLoader::resname_from_record $mol_name]
    array set counters {}
    set rows {}

    foreach atom [dict get $record atoms] {
        set element [dict get $atom element]
        set raw_symbol [dict get $atom raw_symbol]

        if {$element ne "X"} {
            set prefix $element
        } else {
            set prefix [string toupper [::SDFLoader::sanitize_name_fragment $raw_symbol X]]
        }
        if {![info exists counters($prefix)]} {
            set counters($prefix) 0
        }
        incr counters($prefix)

        lappend rows [list \
            [format "%s%d" $prefix $counters($prefix)] \
            $raw_symbol \
            $element \
            $resname \
            1 \
            A \
            SDF \
            [dict get $atom charge] \
            [dict get $atom x] \
            [dict get $atom y] \
            [dict get $atom z] \
            [::SDFLoader::atomic_number $element]]
    }

    return $rows
}

proc ::SDFLoader::ensure_vmd_packages {} {
    if {[catch {package require topotools 1.8} err]} {
        error "topotools 1.8 is required inside VMD: $err"
    }
}

proc ::SDFLoader::is_sdf_filename {filename} {
    set lower [string tolower [file tail $filename]]
    return [expr {[string match *.sdf $lower] || [string match *.sd $lower]}]
}

proc ::SDFLoader::is_sdf_type {type} {
    variable trajectory_type_labels

    set normalized [string tolower [string trim $type]]
    return [expr {$normalized in $trajectory_type_labels}]
}

proc ::SDFLoader::is_multimol_type {type} {
    variable multimol_type_labels

    set normalized [string tolower [string trim $type]]
    return [expr {$normalized in $multimol_type_labels}]
}

proc ::SDFLoader::normalize_mode {mode} {
    set normalized [string tolower [string trim $mode]]
    switch -- $normalized {
        molecule -
        molecules -
        multi -
        multimol -
        multimolecule -
        multimolecules {
            return molecules
        }
        frame -
        frames -
        trajectory -
        traj {
            return trajectory
        }
    }
    error "unsupported SDF load mode '$mode': expected molecules or trajectory"
}

proc ::SDFLoader::extract_type_option {args} {
    set count [llength $args]
    for {set i 0} {$i < $count} {incr i} {
        if {![string equal -nocase [lindex $args $i] "type"]} {
            continue
        }
        incr i
        if {$i < $count} {
            return [lindex $args $i]
        }
        break
    }
    return ""
}

proc ::SDFLoader::requested_mode {subcmd args} {
    if {$subcmd ni {new addfile}} {
        return ""
    }
    if {[llength $args] == 0} {
        return ""
    }

    set target [lindex $args 0]
    if {[string equal -nocase $target "atoms"]} {
        return ""
    }

    set type [::SDFLoader::extract_type_option {*}[lrange $args 1 end]]
    if {$type ne ""} {
        if {[::SDFLoader::is_multimol_type $type]} {
            return molecules
        }
        if {[::SDFLoader::is_sdf_type $type]} {
            return trajectory
        }
        return ""
    }

    if {[::SDFLoader::is_sdf_filename $target]} {
        return molecules
    }

    return ""
}

proc ::SDFLoader::handle_mol_new_sdf {filename {mode molecules}} {
    variable last_molids

    set mode [::SDFLoader::normalize_mode $mode]
    set result [::SDFLoader::load $filename $mode]
    if {$mode eq "trajectory"} {
        set last_molids [list $result]
        return $result
    }

    set last_molids $result
    if {[llength $last_molids] > 1} {
        puts [format "Info) SDF import created %d molecules from %s" [llength $last_molids] [file tail $filename]]
    }
    return [lindex $last_molids end]
}

proc ::SDFLoader::mol_dispatch {args} {
    if {[llength $args] == 0} {
        return [uplevel 1 [list ::SDFLoader::core_mol]]
    }

    set subcmd [lindex $args 0]
    set subargs [lrange $args 1 end]

    set mode [::SDFLoader::requested_mode $subcmd {*}$subargs]
    if {$mode eq ""} {
        return [uplevel 1 [list ::SDFLoader::core_mol {*}$args]]
    }

    set filename [lindex $subargs 0]
    switch -- $subcmd {
        new {
            if {$mode eq "trajectory"} {
                set rewritten {}
                set skip_next 0
                foreach arg $subargs {
                    if {$skip_next} {
                        lappend rewritten SDF
                        set skip_next 0
                        continue
                    }
                    if {[string equal -nocase $arg type]} {
                        lappend rewritten $arg
                        set skip_next 1
                        continue
                    }
                    lappend rewritten $arg
                }
                if {!$skip_next} {
                    return [uplevel 1 [list ::SDFLoader::core_mol new {*}$rewritten]]
                }
                return -code error "missing value after 'type' option"
            }
            return [::SDFLoader::handle_mol_new_sdf $filename $mode]
        }
        addfile {
            return -code error "SDF import is only supported through 'mol new' or 'sdfload'; 'mol addfile' cannot append SDF records to an existing molecule."
        }
    }

    return [uplevel 1 [list ::SDFLoader::core_mol {*}$args]]
}

proc ::SDFLoader::molecule_dispatch {args} {
    if {[llength $args] == 0} {
        return [uplevel 1 [list ::SDFLoader::core_molecule]]
    }

    set subcmd [lindex $args 0]
    set subargs [lrange $args 1 end]

    set mode [::SDFLoader::requested_mode $subcmd {*}$subargs]
    if {$mode eq ""} {
        return [uplevel 1 [list ::SDFLoader::core_molecule {*}$args]]
    }

    set filename [lindex $subargs 0]
    switch -- $subcmd {
        new {
            if {$mode eq "trajectory"} {
                set rewritten {}
                set skip_next 0
                foreach arg $subargs {
                    if {$skip_next} {
                        lappend rewritten SDF
                        set skip_next 0
                        continue
                    }
                    if {[string equal -nocase $arg type]} {
                        lappend rewritten $arg
                        set skip_next 1
                        continue
                    }
                    lappend rewritten $arg
                }
                if {!$skip_next} {
                    return [uplevel 1 [list ::SDFLoader::core_molecule new {*}$rewritten]]
                }
                return -code error "missing value after 'type' option"
            }
            return [::SDFLoader::handle_mol_new_sdf $filename $mode]
        }
        addfile {
            return -code error "SDF import is only supported through 'mol new' or 'sdfload'; 'mol addfile' cannot append SDF records to an existing molecule."
        }
    }

    return [uplevel 1 [list ::SDFLoader::core_molecule {*}$args]]
}

proc ::SDFLoader::install_mol_wrapper {} {
    if {![llength [info commands ::mol]] || ![llength [info commands ::molecule]]} {
        return
    }

    if {![llength [info commands ::SDFLoader::core_mol]]} {
        rename ::mol ::SDFLoader::core_mol
        proc ::mol {args} {
            return [uplevel 1 [list ::SDFLoader::mol_dispatch {*}$args]]
        }
    }

    if {![llength [info commands ::SDFLoader::core_molecule]]} {
        rename ::molecule ::SDFLoader::core_molecule
        proc ::molecule {args} {
            return [uplevel 1 [list ::SDFLoader::molecule_dispatch {*}$args]]
        }
    }
}

proc ::SDFLoader::gui_open {{mode molecules}} {
    set filename [tk_getOpenFile \
        -title "Load SDF File" \
        -filetypes {{{SDF Files} {.sdf .sd}} {{All Files} {*}}}]
    if {$filename eq ""} {
        return
    }
    ::SDFLoader::load $filename $mode
}

proc ::SDFLoader::register_menu {} {
    variable menu_registered

    if {$menu_registered} {
        return
    }
    if {![info exists ::tk_version]} {
        return
    }
    if {![llength [info commands menu]]} {
        return
    }

    catch {menu tk register sdfloadgui_multi [list ::SDFLoader::gui_open molecules] "Data/Load SDF As Molecules"}
    catch {menu tk register sdfloadgui_traj [list ::SDFLoader::gui_open trajectory] "Data/Load SDF As Trajectory"}
    set menu_registered 1
}

proc ::SDFLoader::parse_file_records {filename} {
    set normalized [file normalize $filename]
    if {![file exists $normalized]} {
        error "file not found: $filename"
    }

    set record_lines_list [::SDFLoader::split_records $normalized]
    if {[llength $record_lines_list] == 0} {
        error "no SDF records found in $filename"
    }

    set parsed_records {}
    set record_number 0
    foreach record_lines $record_lines_list {
        incr record_number
        if {[catch {
            lappend parsed_records [::SDFLoader::parse_record $record_lines]
        } err opts]} {
            return -options $opts [list $normalized $record_number $err]
        }
    }

    return [list $normalized $parsed_records]
}

proc ::SDFLoader::build_xyz_rows {record} {
    set rows {}
    foreach atom [dict get $record atoms] {
        lappend rows [list [dict get $atom x] [dict get $atom y] [dict get $atom z]]
    }
    return $rows
}

proc ::SDFLoader::bond_signature {record} {
    set signature {}
    foreach bond [dict get $record bonds] {
        lassign $bond atom1 atom2 _type order
        if {$atom1 > $atom2} {
            lassign [list $atom2 $atom1] atom1 atom2
        }
        lappend signature [format "%d:%d:%.3f" $atom1 $atom2 $order]
    }
    return [lsort -dictionary $signature]
}

proc ::SDFLoader::trajectory_compatible {reference candidate} {
    set ref_atoms [dict get $reference atoms]
    set cand_atoms [dict get $candidate atoms]
    if {[llength $ref_atoms] != [llength $cand_atoms]} {
        return 0
    }

    for {set i 0} {$i < [llength $ref_atoms]} {incr i} {
        if {[dict get [lindex $ref_atoms $i] element] ne [dict get [lindex $cand_atoms $i] element]} {
            return 0
        }
    }

    return [expr {[::SDFLoader::bond_signature $reference] eq [::SDFLoader::bond_signature $candidate]}]
}

proc ::SDFLoader::append_trajectory_frame {molid record} {
    animate dup $molid
    set frame [expr {[molinfo $molid get numframes] - 1}]
    set sel [atomselect $molid all frame $frame]
    $sel set {x y z} [::SDFLoader::build_xyz_rows $record]
    $sel delete
}

proc ::SDFLoader::build_molecule {record filename record_number} {
    ::SDFLoader::ensure_vmd_packages

    set atoms [dict get $record atoms]
    set bonds [dict get $record bonds]
    set natoms [llength $atoms]

    if {$natoms == 0} {
        error "record $record_number has no atoms"
    }

    set mol_name [::SDFLoader::molecule_name $record $filename $record_number]
    set molid [mol new atoms $natoms]
    animate dup $molid
    mol rename $molid $mol_name

    set sel [atomselect $molid all]
    $sel set {name type element resname resid chain segname charge x y z atomicnumber} \
        [::SDFLoader::build_atom_rows $record $mol_name]
    $sel delete

    if {[llength $bonds] > 0} {
        topo setbondlist both -molid $molid $bonds
        catch {mol dataflag $molid set bonds}
    }

    topo guessatom mass element -molid $molid
    topo guessatom radius element -molid $molid
    mol reanalyze $molid
    catch {::TopoTools::adddefaultrep $molid}

    return $molid
}

proc ::SDFLoader::load_as_molecules {filename parsed_records} {
    variable last_molids

    set molids {}
    set record_number 0
    foreach parsed $parsed_records {
        incr record_number
        lappend molids [::SDFLoader::build_molecule $parsed $filename $record_number]
    }

    set last_molids $molids
    return $molids
}

proc ::SDFLoader::load_as_trajectory {filename parsed_records} {
    variable last_molids

    set record_count [llength $parsed_records]
    if {$record_count == 0} {
        error "no SDF records found in $filename"
    }

    set reference [lindex $parsed_records 0]
    set molid [::SDFLoader::build_molecule $reference $filename 1]
    set kept 1
    set skipped {}

    for {set i 1} {$i < $record_count} {incr i} {
        set record [lindex $parsed_records $i]
        if {![::SDFLoader::trajectory_compatible $reference $record]} {
            lappend skipped [expr {$i + 1}]
            continue
        }
        ::SDFLoader::append_trajectory_frame $molid $record
        incr kept
    }

    set last_molids [list $molid]
    if {$kept > 1 || [llength $skipped] > 0} {
        puts [format "Info) SDF trajectory import kept %d/%d records as frames from %s" $kept $record_count [file tail $filename]]
    }
    if {[llength $skipped] > 0} {
        puts [format "Info) Skipped incompatible SDF records: %s" [join $skipped ", "]]
    }

    return $molid
}

proc ::SDFLoader::load {filename {mode molecules}} {
    set mode [::SDFLoader::normalize_mode $mode]

    set parsed_info [::SDFLoader::parse_file_records $filename]
    if {[llength $parsed_info] == 3} {
        lassign $parsed_info normalized record_number parse_error
        error "failed to load record $record_number from $filename: $parse_error"
    }
    lassign $parsed_info normalized parsed_records

    switch -- $mode {
        molecules {
            return [::SDFLoader::load_as_molecules $normalized $parsed_records]
        }
        trajectory {
            return [::SDFLoader::load_as_trajectory $normalized $parsed_records]
        }
    }

    error "unsupported SDF load mode '$mode'"
}

proc ::SDFLoader::startup_sdf_candidates {} {
    if {![llength [info commands ::pid]]} {
        return {}
    }

    if {[catch {set cmdline [exec ps -ww -o args= -p [pid]]}]} {
        return {}
    }

    set tokens [::SDFLoader::shell_split [string trim $cmdline]]
    if {[llength $tokens] <= 1} {
        return {}
    }

    set files {}
    foreach token [lrange $tokens 1 end] {
        if {![::SDFLoader::is_sdf_filename $token]} {
            continue
        }
        if {![file exists $token]} {
            continue
        }

        set normalized [file normalize $token]
        if {[lsearch -exact $files $normalized] < 0} {
            lappend files $normalized
        }
    }

    return $files
}

proc ::SDFLoader::autoload_startup_sdf {} {
    variable startup_autoload_done

    if {$startup_autoload_done} {
        return
    }
    set startup_autoload_done 1

    if {![llength [info commands ::molinfo]]} {
        return
    }
    if {[catch {set molids [molinfo list]}]} {
        return
    }
    if {[llength $molids] > 0} {
        return
    }

    if {[info exists ::argv] && [llength $::argv] > 0} {
        return
    }

    set files [::SDFLoader::startup_sdf_candidates]
    if {![llength $files]} {
        return
    }

    set loaded {}
    foreach filename $files {
        if {[catch {set new_molids [::SDFLoader::load $filename molecules]} err]} {
            puts stderr [format "Warning) Failed to recover startup SDF load for %s: %s" $filename $err]
            continue
        }
        foreach molid $new_molids {
            lappend loaded $molid
        }
    }

    if {[llength $loaded] > 0} {
        puts [format "Info) Recovered startup SDF load via sdfloader.tcl: %s" [join $files ", "]]
    }
}

proc ::SDFLoader::main {argv} {
    set mode molecules
    set args $argv
    if {[llength $args] >= 2 && [string equal -nocase [lindex $args 0] "-mode"]} {
        set mode [::SDFLoader::normalize_mode [lindex $args 1]]
        set args [lrange $args 2 end]
    }

    if {[llength $args] < 1} {
        puts stderr "usage: vmd -dispdev text -e sdfloader.tcl -args ?-mode molecules|trajectory? <file.sdf>"
        return 1
    }

    set filename [lindex $args 0]
    set result [::SDFLoader::load $filename $mode]
    if {$mode eq "trajectory"} {
        puts [format "Loaded SDF trajectory molid: %s" $result]
    } else {
        puts [format "Loaded %d SDF record(s): %s" [llength $result] [join $result ", "]]
    }
    return 0
}

proc ::sdfload {args} {
    set mode molecules
    set params $args
    if {[llength $params] >= 2 && [string equal -nocase [lindex $params 0] "-mode"]} {
        set mode [::SDFLoader::normalize_mode [lindex $params 1]]
        set params [lrange $params 2 end]
    }
    if {[llength $params] != 1} {
        error "usage: sdfload ?-mode molecules|trajectory? <file.sdf>"
    }
    return [::SDFLoader::load [lindex $params 0] $mode]
}

proc ::sdftrajload {filename} {
    return [::SDFLoader::load $filename trajectory]
}

::SDFLoader::install_mol_wrapper
::SDFLoader::register_menu
::SDFLoader::autoload_startup_sdf
