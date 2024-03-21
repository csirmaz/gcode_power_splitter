#!/usr/bin/perl

# Split Cura-generated gcode into parts
# Usage: $0 filename parts

use strict;
use POSIX qw(ceil);
$| = 1;

die "Wrong args" unless @ARGV == 1;
my $filename = $ARGV[0];

# -------------------------- Config ---------------------------------
# Use 0 or 1 for booleans below

my $PARTS = 3;  # The number of parts (blocks) to split into (or more if PART_MAX_LAYERS is set)
my $PART_MAX_LAYERS = -1;  # The max number of layers in a part (or -1 for any)
my $START_LAYER = 0;  # The first layer to output (0-indexed)

my $BREAK_RETRACT = 3;  # How much to retract between parts (mm)
my $BREAK_HOP = 10;  # How much to Z-hop between parts (mm)
my $PRESENT_Y = 220;  # Y coordinate to "present" the print (mm)
my $MAX_Z = 250;  # maximum height (mm)

# The space the print head occupies along the X axis when the nozzle is at 0 (mm)
my $PRINT_HEAD_X_SIDE = 30;

# We always wipe/prep the nozzle on the bed in the first part.
# In subsequent parts we can use "air" prep where the printer extrudes
# and beeps & pauses so the extrusion could be removed.
# This avoids bumping into the part if it is wide, but requires manual intervention. (bool)
# WARNING WITHOUT air prep, the crossbar can also bump into the print at low Y levels!
my $USE_AIR_PREP = 1;

# If using bed prep for all parts, whether to shift them.
# Without this the prep line needs to be removed manually after every part, but the prep area is larger. (bool)
my $SHIFT_BED_PREP = 0;

# Whether to use the initial (higher) nozzle temperature when continuing
my $USE_INIT_TEMP = 0;

# Whether to reheat the bed on the 2nd etc part
my $REHEAT_BED = 0;

# Whether to retrace the last layer of the previous block when starting a new block
# to improve adhesion (bool)
my $DO_IRON = 0;

# Reduce z-height by this amount at every continuation to improve layer adhesion and reduce
# underextrusion. Ratio of layer height. 0 to off.
my $Z_COMPRESSION = 0;

# Flow rate during the first layer when continuing. To combat underextrusion. 100 to off.
my $CONT_FLOW_RATE = 100;

# ---------------------- emergency recovery -------------------

# G92 Z200 ; set Z without homing
# M211 S0 ; Deactive software endstops
# G90 ; absolute pos
# G0 Z300 ; out of the way!
# G28 X0 Y0 ; homing

# G91 ; reative pos

# ----------------------------------------------- input -----------------------------------------------

# Variables to track the state of the 3D printer
my $layer_height;  # height of one layer (unused)
my $layer_count;  # total number of layers
my $extruder_pos;  # extruder positioning mode, abs|rel
my $xyz_pos;  # xyz positioning mode, abs|rel
my $bed_temp;  # current bed temperature
my $init_bed_temp;  # initial bed temperature
my $nozzle_temp;  # current nozzle temperature
my $init_nozzle_temp;  # initial nozzle temperature
my $fan; # current fan state, off|number
my $layer;  # current layer object
my $layer_num = 0;  # current layer number
my $end_code_found;  # Whether the end code block has been found
my $print_min_x;  # The minimum x coordinate of anything printed

my $pos_e;  # current extruder position
my $pos_e_max;  # max extruder position encountered
my $pos_x;  # current x
my $pos_y;  # current y
my $pos_z;  # current z

print("READING INPUT\n");

# These commands are known and we simply ignore them
my %ignoredo = (
    "" => 1,  # when the line is only a comment
    "M105" => 1, # report temp
    "M413" => 1, # power-loss recovery
    "M420" => 1, # bed levelling state
    "G28" => 1, # home
    "M84" => 1, # disable steppers
);

my @LAYERS;

# Return a new layer object
sub new_layer {
    return {
        'num' => $layer_num,
        'current_x' => $pos_x,  # position at the beginning of the layer
        'current_y' => $pos_y,
        'current_z' => $pos_z,
        'current_e' => $pos_e,
        'current_e_max' => $pos_e_max,
        'current_fan' => $fan,
        'current_bed' => $bed_temp,
        'current_nozzle' => $nozzle_temp,
        'gcode' => [],  # lines of gcode belonging to the layer
        'has_first_move'=> 0,  # see below
        'ironing_gcode' => [],
        'can_iron' => 1,
    };
}

# Record the final state in a layer object
sub record_final {
    my $lyr = shift;
    $lyr->{'final_x'} = $pos_x;
    $lyr->{'final_y'} = $pos_y;
    $lyr->{'final_z'} = $pos_z;
    $lyr->{'final_nozzle'} = $nozzle_temp;
}

open(FH, '<', $filename) or die "Cannot open $filename: $!";
while(<FH>) {
    my $line = $_;
    
    if($line =~ /^;Layer height: ([0-9\.]+)\s*$/) {
        $layer_height = $1;
        print "Layer height [$layer_height]\n";
        next;
    }
    
    if($line =~ /^;LAYER_COUNT:\s*([0-9\.]+)\s$/) {
        $layer_count = $1;
        print "Layer count [$layer_count]\n";
        next;
    }
    
    if($line =~ /^;LAYER:\s*([0-9]+)\s$/) {
        if($1 != $layer_num) { die "layer number not consecutive at $layer_num"; }
        if($layer_num == 0) { print("Layer 0 here\n"); }
        if($layer) { record_final($layer); }
        $layer = new_layer();
        push @LAYERS, $layer;
        $layer_num++;
        next;
    }
    
    if($line =~ /^;[ \-]+end code begin/) {
        $end_code_found = 1;
        if($layer) { record_final($layer); }
        $layer = undef;
        next;
    }
    
    my $do;
    my $comment = '';
    if($line =~ /^([^;]*);(.*)$/) {
        $do = $1;
        $comment = $2;
    }else{
        $do = $line;
    }
    
    $do =~ s/^\s*|\s*$//g;
    my @dos = split(/\s+/, $do);
    
    # print "[$line][$do][".join("|",@dos)."][$comment]\n";
    
    if($dos[0] eq "G90") {
        print "* absolute pos\n";
        $extruder_pos = "abs";
        $xyz_pos = "abs";
    }
    elsif($dos[0] eq "G91") {
        print "* relative pos\n";
        $extruder_pos = "rel";
        $xyz_pos = "rel";
        $layer->{'can_iron'} = 0 if $layer;
    }
    elsif($dos[0] eq "M82") {
        print "* absolute extr\n";
        $extruder_pos = "abs";
    }
    elsif($dos[0] eq "M83") {
        print "* relative extr\n";
        $extruder_pos = "rel";
    }
    elsif(($dos[0] eq "M140" or $dos[0] eq "M190") and $dos[1] =~ /^S([0-9\.]+)$/) {
        $bed_temp = $1;
        print "* bed temp [$bed_temp]\n";
        if(!defined $init_bed_temp) {
            $init_bed_temp = $bed_temp;
            print "* init bed temp [$init_bed_temp]\n";
        }
    }
    elsif(($dos[0] eq "M104" or $dos[0] eq "M109") and $dos[1] =~ /^S([0-9\.]+)$/) {
        $nozzle_temp = $1;
        print "* nozzle temp [$nozzle_temp]\n";
        if(!defined $init_nozzle_temp) {
            $init_nozzle_temp = $nozzle_temp;
            print "* init nozzle temp [$init_nozzle_temp]\n";
        }
    }
    elsif($dos[0] eq "M107") {
        print "* fan off\n";
        $fan = "off";
    }
    elsif(($dos[0] eq "M106") and $dos[1] =~ /^S([0-9\.]+)$/) {
        $fan = $1;
        print "* fan [$fan]\n";
    }
    elsif($dos[0] eq "G0" or $dos[0] eq "G1") {
        # go
        my $has_e = 0;
        foreach my $c (@dos) {
            $c =~ /^(.)(.*)$/;
            my $dir = $1;
            my $val = $2;
            next if($dir eq "G"); # skip the command itself
            if($dir eq "E") {
                $has_e = 1;
                if($extruder_pos eq "rel") {
                    $pos_e = "rel";
                    $pos_e_max = "rel";
                }else {
                    $pos_e = $val;
                    if($pos_e_max eq "rel" or $pos_e > $pos_e_max) {
                        $pos_e_max = $pos_e;
                    }
                }
                # print "E [$pos_e][$pos_e_max]\n";
            }
            # WARNING We don't track relative movements because most are absolute
            # and not sure what the position is after a homing
            if($dir eq "X") {
                if($extruder_pos eq "rel") { 
                    $pos_x = "rel"; 
                } else { 
                    $pos_x = $val; 
                    # We only want to check this here, otherwise moves without X would use values from earlier, e.g. the init code
                    if($layer) {
                        if((!defined $print_min_x) or $print_min_x->[0] > $pos_x) { $print_min_x = [$pos_x, $layer_num, $line]; }
                    }
                }
            }
            if($dir eq "Y") {
                if($extruder_pos eq "rel") { $pos_y = "rel"; }
                else { $pos_y = $val; }
            }
            if($dir eq "Z") {
                if($extruder_pos eq "rel") { $pos_z = "rel"; }
                else { $pos_z = $val; }
            }
        }
        
        # A layer often starts with a nonextrusion move. If so we want to initialize a block to the end of that move
        # So for each layer store the end of the first move provided it does no extrusion
        if($layer and (!$layer->{'has_first_move'})) {
            if(!$has_e) {
                $layer->{'first_x'} = $pos_x;
                $layer->{'first_y'} = $pos_y;
                $layer->{'first_z'} = $pos_z;
            }
            $layer->{'has_first_move'} = ($has_e ? 2 : 1);
        }
        
        if($layer) {
            if($extruder_pos eq "rel") {
                $layer->{'can_iron'} = 0;
            } else {
                push @{$layer->{'ironing_gcode'}}, "G0 X$pos_x Y$pos_y Z$pos_z F600 ; ironing" if $layer;
            }
        }

    }
    elsif($dos[0] eq "G92") {
        # set position
        foreach my $c (@dos) {
            $c =~ /^(.)(.*)$/;
            my $dir = $1;
            my $val = $2;
            next if($dir eq "G");
            if($dir eq "E") {
                # Preserve retracted state
                my $retraction = $pos_e_max - $pos_e;
                $pos_e_max = $val + $retraction;
                $pos_e = $val;
            }
            if($dir eq "X") {
                die "Logical coordinate systems are unsupported (G92)";
            }
            if($dir eq "Y") {
                die "Logical coordinate systems are unsupported (G92)";
            }
            if($dir eq "Z") {
                die "Logical coordinate systems are unsupported (G92)";
            }
        }
    }
    elsif($dos[0] eq "M220") {
        # We're not tracking this - reporting only
        # print "> Feedrate: $line";
        die "Feedrate (M220) in main gcode - some features may not work" if $layer;
    }
    elsif($dos[0] eq "M221") {
        # We're not tracking this - reporting only
        # print "> Flowrate: $line";
        die "Flowrate (M221) in main gcode - some features may not work" if $layer;
    }
    elsif($ignoredo{$dos[0]}) { 1; }
    else {
        die "Unknown command [$dos[0]] [$line]\n";
    }
    
    # Debug
    # print "X:$pos_x Y:$pos_y Z:$pos_z E:$pos_e Em:$pos_e_max Layer:$layer Line:$line";
    
    push @{$layer->{'gcode'}}, $line if $layer;
    
}
close(FH);

print "Minimum X coord of the print $print_min_x->[0] at layer $print_min_x->[1] line: $print_min_x->[2]\n";
if((!$USE_AIR_PREP) and $print_min_x->[0] <= $PRINT_HEAD_X_SIDE) {
    die "The minimum X coordinate of the print is too small to let the print head prep the nozzle on the bed (even without shifting)";
}

die "Overall layer count not found" unless $layer_count;  # This is not really necessary though
die "Overall layer count mismatch" unless $layer_num != $layer_count - 1;
die "End gcode block has not been found" unless $end_code_found;

undef $layer;
undef $layer_num;

# -------------------------------------------------------- output -----------------------------------------------

# Loop through layers and produce output
print("WRITING OUTPUT FILES\n");

# Figure out how to split the layers
# For each layer decide which block to put it in
# Returns "skip" if layer should not go into a block
# "part" and "block" are the same thing
sub layer_to_block {
    my $layer = shift;
    
    my $all_layers = $layer_count - $START_LAYER;
    my $layers_per_part = $all_layers / $PARTS;
    if($PART_MAX_LAYERS > 0 and $layers_per_part > $PART_MAX_LAYERS) {
        # print "    LB: max layers restricts. max_layers=$PART_MAX_LAYERS org_layers/block=$layers_per_part\n";
        $layers_per_part = $all_layers / ceil($all_layers / $PART_MAX_LAYERS);
    }

    my $total_parts = ceil(($layer_count - $START_LAYER - 1) / ceil($layers_per_part));
    # print "    LB: parts=$PARTS layer_count=$layer_count all_layers=$all_layers layers/block=$layers_per_part total_parts=$total_parts\n";
    if(!defined $layer) { 
        # print "    LB> final\n";
        return ("final", $total_parts); 
    }
    if($layer->{'num'} < $START_LAYER) { 
        # print "    LB> layer num=$layer->{'num'} SKIP\n";
        return ("skip", $total_parts); 
    }
    my $myblock = int(($layer->{'num'} - $START_LAYER) / ceil($layers_per_part));
    # print "    LB> layer num=$layer->{'num'} block=$myblock\n";
    return ($myblock, $total_parts);
}

# Create ironing code from a layer
sub get_ironing_code {
    my $layer = shift;
    
    unless($layer->{'can_iron'}) {
        print("WARNING: Cannot convert layer #$layer->{'num'} to ironing\n");
        return '';
    }

    my $noztemp = ($USE_INIT_TEMP ? $init_nozzle_temp : $layer->{'current_nozzle'});
    die "No nozzle temp found at layer $layer->{'num'}" unless defined $noztemp;

    my @commands = (
        "; Ironing starts",
        "M107 ; fan off",
        "M109 S$noztemp ; wait nozzle temp",
        "; Ironing layer starts",
        @{$layer->{'ironing_gcode'}},
        "; Ironing ends"
    );
    
    return join("\n", @commands);
}


# We use our own begin and end code blocks
# Render the begin script for a block
sub get_begin {
    my $layer = shift;
    my $block_num = shift; # Which block we're rendering for
    
    my $bedtemp = $layer->{'current_bed'};
    die "No bed temp found at layer $layer->{'num'}" unless defined $bedtemp;
    my $noztemp = ($USE_INIT_TEMP ? $init_nozzle_temp : $layer->{'current_nozzle'});
    die "No nozzle temp found at layer $layer->{'num'}" unless defined $noztemp;
    
    die "Could not find layer height" unless defined $layer_height;
    my $curz = $layer->{'current_z'} + $BREAK_HOP;
    if($Z_COMPRESSION) {
        die "Could not find layer height" unless defined $layer_height;
        $curz += $Z_COMPRESSION * $layer_height * $block_num;
    }
    my $wipex = $block_num * ($SHIFT_BED_PREP ? 5 : 0); # x coord of wiping area - separate the wipes for different blocks
    
    my $wipe_retract = -1;
    #         -0.5     0
    #           *      |================   We are here
    #     e           e_max
    #     *            |================   We want to be here
    my $pe = $layer->{'current_e'};
    die "No E position found  at layer $layer->{'num'}" unless defined $pe;
    my $cur_retract = $layer->{'current_e'} - $layer->{'current_e_max'};
    
    my $fan = '';
    if(defined $layer->{'current_fan'}) {
        $fan = ($layer->{'current_fan'} eq 'off' ? 'M107' : 'M106 S'.$layer->{'current_fan'} );
    }
    # A layer often starts with a nonextrusion move. If so initialize to the end of that move
    my $px = ($layer->{'has_first_move'} == 1 ? $layer->{'first_x'} : $layer->{'current_x'});
    my $py = ($layer->{'has_first_move'} == 1 ? $layer->{'first_y'} : $layer->{'current_y'});
    my $pz = ($layer->{'has_first_move'} == 1 ? $layer->{'first_z'} : $layer->{'current_z'});
    die "Only relative positions found at layer $layer->{'num'}" if $px eq 'rel' or $py eq 'rel' or $pz eq 'rel';
    die "No positions found  at layer $layer->{'num'}" unless((defined $px) and (defined $py) and (defined $pz));
    my $pz2 = $pz + $BREAK_HOP; # approach from above (does not need to use $BREAK_HOP)
    if($pz2 >= $MAX_Z) { die "Z coord ($pz2) excedes maximum ($MAX_Z)"; }
    
    # ----- bed temp -----
    
    my $bedtempcode = '';
    if($block_num == 0 or $REHEAT_BED) {
        $bedtempcode = <<EOD;
M140 S$bedtemp ; bed temp
M105 ; report temp
M190 S$bedtemp ; wait bed temp
EOD
    }
    
    # ----- feedrate -----
    
    # Lower feed rate to increase adhesion to cold layer of prev block
    my $feedrate = ($block_num == 0 ? '' : "M220 S35 ; Slow Feedrate for first layer\n");
    
    # ----- flowrate -----
    
    my $flowrate = (($block_num == 0 || $CONT_FLOW_RATE == 100) ? '' : "M221 S$CONT_FLOW_RATE ; continuation flow rate\n");
    
    # ----- ironing -----
    
    # Go through the last layer to warm layer
    # If not needed, use this block to get to the desired location. Otherwise start from higher up to avoid bumping into things
    my $ironing = "G0 X$px Y$py Z$pz F5000";
    if($block_num > 0 and $DO_IRON) {
        my $prev_layer = $LAYERS[$layer->{'num'} - 1];
        die "layer num mismatch for ironing" unless $prev_layer->{'num'} == $layer->{'num'} - 1;
        $ironing = get_ironing_code($prev_layer);
    }
    
    # ----- debug msg -----
    
    my $msg = 
        "; Rendering begin script for block #$block_num at layer #$layer->{'num'} Inherited Z: $curz\n"
        . "; Layer starts with Bed:$bedtemp Nozzle:$noztemp Fan:$layer->{'current_fan'}\n"
        . "; Layer starts at X:$px Y:$py Z:$pz E:$pe Retract:$cur_retract\n"
    ;
    print($msg);
    
    # ----- homing -----
    
    my $homing;
    if($block_num == 0) {
        # First layer
        $homing = "G28 ; homing\n";
    } else {
        # Cannot home Z as that moves to the middle
        # Note homing moves Z! So we restore Z first
        # Homing XY should happen above the print
        # Knocking XY is easy so best to home
        $homing = <<EOD;
G92 Z$curz ; set Z without homing
M211 S0 ; Deactive software endstops
G90 ; absolute pos
G28 X0 Y0 ; homing
EOD
    }
    
    # ----- wiping -----
    
    my $wiping;
    if($block_num == 0 or !$USE_AIR_PREP) {
        # Wipe on bed
        $wiping = <<EOD;
; Wiping on bed
G0 X$wipex.2 Y10 Z10 F5000.0 ; Move to start position allow space to extrude

M104 S$noztemp ; nozzle temp
M105 ; report temp
M109 S$noztemp ; wait nozzle temp

G1 X$wipex.2 Y20 Z0.28 F1500 E0 ; diagonal down; undo end code retract
G1 X$wipex.2 Y160.0 Z0.28 F1500.0 E15 ;Draw the first line
G1 X$wipex.4 Y160.0 Z0.28 F5000.0 ;Move to side a little
G1 X$wipex.4 Y40 Z0.28 F1500.0 E30 ;Draw the second line

G92 E0 ; Reset Extruder pos
G1 E$wipe_retract F600 ; Retract a bit
G0 X$wipex.0 Y40 Z0.28 F1000 ; wipe across
G0 X$wipex.5 Y60 Z0.28 F1000 ; more wipe
G0 X$wipex.0 Y80 Z0.28 F1000 ; more wipe
EOD
    } else {
        # Wiping in air
        # We don't go down to the bed in case we bump into the print
        $wiping = <<EOD;
; Wiping / extruding in air
G0 X0 Y0 F5000 ; Move to front corner

M104 S$noztemp ; nozzle temp
M105 ; report temp
M109 S$noztemp ; wait nozzle temp

G1 E30 F500 ; undo end code extract and extract more
M106 ; full fan speed
G4 S2 ; dwell 4s
M300 S440 P200 ; beep
M0 CLEANME ; pause, wait for user (may only pause octoprint)
M107 ; fan off
G92 E0 ; Reset Extruder pos
G1 E$wipe_retract F600 ; Retract a bit
EOD
    }
    
    # ----- code -----
    
    return <<EOD;
$msg
    
M413 S0 ; Power loss off
M220 S100 ; Reset Feedrate
M221 S100 ; Reset Flowrate

$bedtempcode
$homing
M420 S1; Enable mesh leveling

G90 ; absolute pos
M82 ; absolute E
G92 E-$BREAK_RETRACT ; Reset Extruder pos

G0 X0 Y0 ; avoid bumping into the model (if homing didn't move us back)
G Z10

$wiping

; move to desired place from above
M220 S100 ; Reset Feedrate
G0 Z$pz2 F5000
G0 X$px Y$py Z$pz2 F5000

$ironing
M220 S100 ; Reset Feedrate

; Restore E and retraction
G1 E$cur_retract F1500
G92 E$pe
G1 E$pe F1800

$fan ; restore fan
$flowrate
$feedrate
EOD
}


# This is added after the first layer in a block
sub get_after_layer {
    my $lyr = shift;
    
    my $noztemp = $lyr->{'final_nozzle'}; # Restore after possibly higher value
    die "No nozzle temp found at layer $lyr->{'num'}" unless defined $noztemp;
    return "M220 S100 ; Reset Feedrate\nM221 S100 ; Reset Flowrate\nM104 S$noztemp ; nozzle temp\n";
}


# Render the end script for a block
sub get_end {
    my $lyr = shift;
    my $block_num = shift; # Which block we're rendering for
    my $total_blocks = shift;
    
    unless(defined $lyr) { die "No layer object given to get_end() at block $block_num"; }
    my $z = $lyr->{'final_z'};
    unless((defined $z) and ($z ne "rel")) { die "No final Z position at layer $lyr->{'num'}"; }
    print("  Rendering end script for block $block_num\n  Layer #$lyr->{'num'} ($layer_count total) Final Z: $z\n");
    if($z > $MAX_Z) { die "Z pos already higher than MAX_Z"; }
    $z += $BREAK_HOP;
    if($z > $MAX_Z) {
        die "Cannot achieve hop" unless $block_num == $total_blocks - 1;
        # Allow smaller hop at the top
        $z = $MAX_Z; 
    }

    return <<EOD
G91 ; relative XYZ
M83 ; relative E
; retract filament, move Z slightly upwards
G1 E-$BREAK_RETRACT F4500
M82 ; absolute E
G90 ; absolute XYZ
G0 Z$z F4500
; move to a safe rest position
G0 X0 Y$PRESENT_Y
M106 S0 ; Turn-off fan
M104 S0 ; Turn-off hotend
M140 S0 ; Turn-off bed
M18 S60 ; disable all steppers after 1min
M300 S440 P200 ; beep
EOD
}


my $prev_block = -1;  # which block/part the previous layer belongs to
my $layer_of_block = 0;  # counter
my $prev_layer;  # previous layer object
foreach my $lyr (@LAYERS, undef) {
    my ($block, $total_blocks) = layer_to_block($lyr);
    if($block eq "skip") { next; }
    
    if($block != $prev_block) {
        # End previous block
        if($prev_block >= 0) {
            print("Ending block #$prev_block ($layer_of_block layers)\n");
            print FH "; ========== end code ========\n";
            print FH get_end($prev_layer, $prev_block, $total_blocks);
            close(FH);
        }
        # Start new block
        if(defined $lyr) {
            print("Starting block #$block ($total_blocks blocks total)\n");
            my $outfile = $filename;
            $outfile =~ s/gcode$//;
            $outfile .= $block.".gcode";
            open(FH, '>', $outfile) or die "Cannot open $outfile: $!";
            print FH "; =========== begin $filename part $block =============\n";
            print FH get_begin($lyr, $block);
            print FH "; =========== start code ends ================\n";
        }
        $layer_of_block = 0;
        $prev_block = $block;
    }
    # Print layer
    if(defined $lyr) {
        print FH "; LAYER $layer_of_block (in part) $lyr->{'num'} (globally)\n";
        print FH join('', @{$lyr->{'gcode'}});
        if($layer_of_block == 0) {
            print FH "; =========== after 1st layer code ===========\n";
            print FH get_after_layer($lyr);
            print FH "; =========== after 1st layer code ends ===========\n";
        }
        $layer_of_block++;
    }
    $prev_layer = $lyr;
}

print("Done!\n");
