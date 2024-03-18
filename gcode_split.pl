#!/usr/bin/perl

# Split Cura-generated gcode into parts
# Usage: $0 filename parts

use strict;
$| = 1;

die "Wrong args" unless @ARGV == 2;
my $filename = $ARGV[0];
my $num_parts = $ARGV[1];

print "Splitting into [$num_parts]\n";

# Config
my $BREAK_RETRACT = 3;
my $BREAK_HOP = 10;
# Config ends

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

my $pos_e;  # current extruder position
my $pos_e_max;  # max extruder position encountered
my $pos_x;  # current x
my $pos_y;  # current y
my $pos_z;  # current z

print("READING INPUT\n");

# These commands are known and we simply ignore them
my %ignoredo = (
    "" => 1,  # when the line is only a comment
    "M105" => 1,
    "M413" => 1,
    "M420" => 1,
    "G28" => 1, # home
    "M220" => 1, # feedrate
    "M221" => 1, # flowrate
    "M84" => 1, # disable steppers
);

my @LAYERS;

# Return a new layer object
sub new_layer {
    return {
        'num'=> $layer_num,
        'current_x'=> $pos_x,  # position at the beginning of the layer
        'current_y'=> $pos_y,
        'current_z'=> $pos_z,
        'current_e'=> $pos_e,
        'current_e_max'=> $pos_e_max,
        'current_fan'=> $fan,
        'current_bed'=> $bed_temp,
        'current_nozzle'=> $nozzle_temp,
        'gcode'=> [],  # lines of gcode belonging to the layer
        'has_first_move'=> 0,  # see below
    };
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
        $layer = new_layer();
        push @LAYERS, $layer;
        $layer_num++;
        next;
    }
    
    if($line =~ /^;[ \-]+end code begin/) {
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
            next if($dir eq "G");
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
                if($extruder_pos eq "rel") { $pos_x = "rel"; }
                else { $pos_x = $val; }
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
                die "logical x used";
            }
            if($dir eq "Y") {
                die "logical y used";
            }
            if($dir eq "Z") {
                die "logical z used";
            }
        }
    }
    
    elsif($ignoredo{$dos[0]}) { 1; }
    else {
        die "Unknown command [$dos[0]] [$line]\n";
    }
    
    if($layer) {
        push @{$layer->{'gcode'}}, $line;
    }
    
}
close(FH);

undef $layer;

die "no layer info" unless $layer_count;
die "layer num mismatch" unless $layer_num != $layer_count - 1;

# -------------------------------------------------------- output -----------------------------------------------

# Loop through layers and produce output
print("WRITING OUTPUT FILES\n");

# We use our own begin and end code blocks
sub get_begin {
    my $layer = shift;
    my $block_num = shift; # Which block we're rendering for
    
    if(($block_num == 0) + ($layer->{'num'} == 0) == 1){
        die "Block num at layer 0 mismatch";
    }
    
    my $bedtemp = $layer->{'current_bed'};
    die "no bed temp" unless defined $bedtemp;
    my $noztemp = $init_nozzle_temp; # $layer->{'current_nozzle'}; # We use the higher value for better adhesion
    die "no noz temp" unless defined $noztemp;
    my $curz = $layer->{'current_z'} + $BREAK_HOP;
    my $wipex = $block_num * 3; # x coord of wiping area - separate the wipes for different blocks
    
    my $wipe_retract = -0.5;
    #         -0.5     0
    #           *      |================   We are here
    #     e           e_max
    #     *            |================   We want to be here
    my $cur_retract = $layer->{'current_e'} - $layer->{'current_e_max'};
    my $pe = $layer->{'current_e'};
    
    my $fan = '';
    if(defined $layer->{'current_fan'}) {
        $fan = ($layer->{'current_fan'} eq 'off' ? 'M107' : 'M106 S'.$layer->{'current_fan'} );
    }
    # A layer often starts with a nonextrusion move. If so initialize to the end of that move
    my $px = ($layer->{'has_first_move'} == 1 ? $layer->{'first_x'} : $layer->{'current_x'});
    my $py = ($layer->{'has_first_move'} == 1 ? $layer->{'first_y'} : $layer->{'current_y'});
    my $pz = ($layer->{'has_first_move'} == 1 ? $layer->{'first_z'} : $layer->{'current_z'});
    die "rel pos" if $px eq 'rel' or $py eq 'rel' or $pz eq 'rel';
    die "no pos" unless((defined $px) and (defined $py) and (defined $pz));
    my $pz2 = $pz + $BREAK_HOP; # approach from above (does not need to use $BREAK_HOP)
    
    # Lower feed rate to increase adhesion to cold layer of prev block
    my $feedrate = ($block_num == 0 ? '' : "M220 S45 ; Slow Feedrate for first layer\n");
    
    my $msg = 
        "; Rendering begin script for block #$block_num at layer #$layer->{'num'}\n"
        . "; Bed:$bedtemp Nozzle:$noztemp Fan:$layer->{'current_fan'}\n"
        . "; X:$px Y:$py Z:$pz E:$pe Retract:$cur_retract\n"
    ;
    print($msg);
    
    my $homing;
    if($layer->{'num'} == 0) {
        # First layer
        $homing = "G28 ; homing\n";
    }else{
        # Cannot home Z as it moves to the middle
        $homing = <<EOD;
G92 Z$curz ; set Z without homing
M211 S0 ; Deactive software endstops
; Note homing moves Z! So we restore Z first
G90 ; absolute pos
G28 X0 Y0 ; homing
EOD
    }
    
    return <<EOD;
$msg
    
M413 S0 ; Power loss off
M220 S100 ;Reset Feedrate
M221 S100 ;Reset Flowrate

M140 S$bedtemp ; bed temp
M105 ; report temp
M190 S$bedtemp ; wait bed temp

$homing
M420 S1; Enable mesh leveling

G90 ; absolute pos
M82 ; absolute E
G92 E-$BREAK_RETRACT ; Reset Extruder pos

G0 X0 Y0 ; avoid bumping into the model (if homing didn't move us back)
G Z10

G1 X$wipex.2 Y10 Z10 F5000.0 ; Move to start position allow space to extrude

M104 S$noztemp ; nozzle temp
M105 ; report temp
M109 S$noztemp ; wait nozzle temp

G1 X$wipex.2 Y20 Z0.28 F1500 E0 ; diagonal down; undo end code retract
G1 X$wipex.2 Y160.0 Z0.28 F1500.0 E15 ;Draw the first line
G1 X$wipex.4 Y160.0 Z0.28 F5000.0 ;Move to side a little
G1 X$wipex.4 Y40 Z0.28 F1500.0 E30 ;Draw the second line

G92 E0 ; Reset Extruder pos
G1 E$wipe_retract F600 ;Retract a bit
G1 X$wipex.0 Y40 Z0.28 F1000 ; wipe across
G1 X$wipex.5 Y60 Z0.28 F1000 ; more wipe
G1 X$wipex.0 Y80 Z0.28 F1000 ; more wipe

; move to desired place from above
G0 Z$pz2
G0 X$px Y$py Z$pz2
G0 X$px Y$py Z$pz

; Restore E and retraction
G1 E$cur_retract F1500
G92 E$pe
G1 E$pe F1800

$fan ; restore fan
$feedrate
EOD
}

# This is added after the first layer in a block
sub get_after_layer {
    my $layer = shift;
    my $noztemp = $layer->{'current_nozzle'}; # Restore after possibly higher value
    die "no noz temp" unless defined $noztemp;
    return "M220 S100 ; Reset Feedrate\nM104 S$noztemp ; nozzle temp\n";
}

sub get_end {
    return <<EOD
G91 ; relative XYZ
M83 ; relative E
; retract filament, move Z slightly upwards
G1 E-$BREAK_RETRACT F4500
G1 Z+$BREAK_HOP F4500
M82 ; absolute E
G90 ; absolute XYZ
; move to a safe rest position
G1 X0 Y220
M106 S0 ; Turn-off fan
M104 S0 ; Turn-off hotend
M140 S0 ; Turn-off bed
M18 S60 ; disable all steppers after 1min
EOD
}

my $prev_block = -1;
my $layer_of_block = 0;
foreach my $lyr (@LAYERS, undef) {
    my $block;
    if(defined $lyr) {
        $block = int($lyr->{'num'} / $layer_count * $num_parts);
        if($block >= $num_parts) { $block = $num_parts - 1; }
    } else {
        $block = $num_parts;
    }
    
    if($block != $prev_block) {
        # End previous block
        if($prev_block >= 0) {
            print("Ending block #$prev_block\n");
            print FH "; ========== end code ========\n";
            print FH get_end();
            close(FH);
        }
        # Start new block
        if(defined $lyr) {
            print("Starting block #$block\n");
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
}

