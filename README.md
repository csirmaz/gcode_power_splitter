# gcode_power_splitter

Split gcode into blocks of layers for 3D printing in multiple stages

Usage: `./gcode_split.pl MYFILE.gcode 3`
where `3` is the number of parts to split the gcode into.

It produces `MYFILE.0.gcode`, `MYFILE.1.gcode` etc. for the parts, which
are horizontal slices of roughly equal height.

The main aim of this script is to produce gcode parts that can be printed in sessions,
even allowing powering down the 3D printer between sessions.

It completely replaces the start and end gcode snippets. These are defined
in `get_begin()` and `get_end()` and may require changes for your printer.
`get_after_layer()` is added after the 1st layer in a part.

The code was written to split Cura-generated gcode files.
Among others, it relies on `; LAYER` comments to identify layers,
and only parses gcode commands that are necessary for its function.
It is also limited to the types of gcode Cura generates, e.g.
it does not parse logical coordinates (`G92`).

It makes best effort to throw errors if it encounters gcode it
was not designed to process.
