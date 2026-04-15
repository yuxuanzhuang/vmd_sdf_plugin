# Load SDF records into VMD molecules.
# Interactive usage:
#   source sdfloader1.0/sdfloader.tcl
#   set molids [sdfload path/to/file.sdf]
#
# If sourced from ~/.vmdrc, standard VMD loads such as
#   mol new path/to/file.sdf
# are intercepted and handled by this script.

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
    set normalized [string tolower [string trim $type]]
    return [expr {$normalized in {isissdf sdf sd}}]
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

proc ::SDFLoader::should_intercept_mol {subcmd args} {
    if {$subcmd ni {new addfile}} {
        return 0
    }
    if {[llength $args] == 0} {
        return 0
    }

    set target [lindex $args 0]
    if {[string equal -nocase $target "atoms"]} {
        return 0
    }

    set type [::SDFLoader::extract_type_option {*}[lrange $args 1 end]]
    if {$type ne ""} {
        set normalized [string tolower [string trim $type]]
        if {$normalized eq "sdf"} {
            return 0
        }
        return [::SDFLoader::is_sdf_type $type]
    }

    return [::SDFLoader::is_sdf_filename $target]
}

proc ::SDFLoader::handle_mol_new_sdf {filename} {
    variable last_molids

    set last_molids [::SDFLoader::load $filename]
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

    if {![::SDFLoader::should_intercept_mol $subcmd {*}$subargs]} {
        return [uplevel 1 [list ::SDFLoader::core_mol {*}$args]]
    }

    set filename [lindex $subargs 0]
    switch -- $subcmd {
        new {
            return [::SDFLoader::handle_mol_new_sdf $filename]
        }
        addfile {
            return -code error "SDF import is only supported through 'mol new' or 'sdfload'; 'mol addfile' cannot append SDF records to an existing molecule."
        }
    }

    return [uplevel 1 [list ::SDFLoader::core_mol {*}$args]]
}

proc ::SDFLoader::install_mol_wrapper {} {
    if {![llength [info commands ::mol]]} {
        return
    }
    if {[llength [info commands ::SDFLoader::core_mol]]} {
        return
    }

    rename ::mol ::SDFLoader::core_mol
    proc ::mol {args} {
        return [uplevel 1 [list ::SDFLoader::mol_dispatch {*}$args]]
    }
}

proc ::SDFLoader::gui_open {} {
    set filename [tk_getOpenFile \
        -title "Load SDF File" \
        -filetypes {{{SDF Files} {.sdf .sd}} {{All Files} {*}}}]
    if {$filename eq ""} {
        return
    }
    ::SDFLoader::load $filename
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

    if {![catch {menu tk register sdfloadgui ::SDFLoader::gui_open "Data/Load SDF"}]} {
        set menu_registered 1
    }
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

proc ::SDFLoader::load {filename} {
    variable last_molids

    set normalized [file normalize $filename]
    if {![file exists $normalized]} {
        error "file not found: $filename"
    }

    set records [::SDFLoader::split_records $normalized]
    if {[llength $records] == 0} {
        error "no SDF records found in $filename"
    }

    set molids {}
    set record_number 0
    foreach record_lines $records {
        incr record_number
        if {[catch {
            set parsed [::SDFLoader::parse_record $record_lines]
            lappend molids [::SDFLoader::build_molecule $parsed $normalized $record_number]
        } err opts]} {
            return -options $opts "failed to load record $record_number from $filename: $err"
        }
    }

    set last_molids $molids
    return $molids
}

proc ::SDFLoader::main {argv} {
    if {[llength $argv] < 1} {
        puts stderr "usage: vmd -dispdev text -e sdfloader.tcl -args <file.sdf>"
        return 1
    }

    set filename [lindex $argv 0]
    set molids [::SDFLoader::load $filename]
    puts [format "Loaded %d SDF record(s): %s" [llength $molids] [join $molids ", "]]
    return 0
}

proc ::sdfload {filename} {
    return [::SDFLoader::load $filename]
}

::SDFLoader::install_mol_wrapper
::SDFLoader::register_menu
