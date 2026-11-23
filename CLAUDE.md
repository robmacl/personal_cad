# Personal CAD

Robert's own SolidWorks work: parts for 3D printing (FDM, his own printer) and for machining.
Not a git repository.

## Before any design work

Load the `solidworks-cad` skill (`~/.claude/skills/solidworks-cad/SKILL.md`). It covers attaching to
the running SolidWorks, the generator pattern, API pitfalls, and checking. Claude designs and builds
the parts by script; it does not hand back sketches for Robert to model.

## Layout

- `3D print/` — older hand-modelled parts, 2021–2025 (gears, frames, caddies, brackets, boxes), with
  their STL/3MF exports, drawings and two Cura profiles (`pla_plus`, `overture_petg_coarse_black`).
  All of it is Robert's own work: read for reference, never overwrite. New exports get new names.
- `light_box/` — new design, started Nov 2026, built by script (see below).

## Convention for scripted projects

Each new project gets its own directory, laid out like the squeeze-controller example the skill points
to:

- `<project>/generate/` — `*_params.json` (every dimension, mm), the generator `.ps1`, the section
  and clash check, drawing script.
- `<project>/` — the SLDPRT/SLDASM output, dated print exports, and a `*_notes.txt` design-notes file
  saying what the numbers mean, what was checked and what was not.

The JSON and the script are the design; the SLDPRT is output and is rebuilt in place.

## Precision and fits

These are one-off parts, mostly 3D printed, fitted to materials Robert has on the bench. Don't go
crazy with precision.

- Design in slop and overlap: slots, floating fits, clearance that a screw or adhesive takes up.
  A fit that only works if a caliper reading is right to 0.1 mm is a design fault, not a
  measurement problem. Don't chase hundredths on sheet metal, hardware-store extrusion or prints.
- But don't design to worst-case datasheet tolerances either. That piles up slop nobody needs
  (official tolerances on acrylic sheet thickness, for one, are very wide). Robert measures the
  actual material for the project so the design can use the measured value plus a modest margin.
  The point of his measuring is to catch big surprises, not to supply a fourth significant figure.
- So: measured value, sensible clearance, and one adjustable feature where two uncertain things meet.
  When his numbers don't quite close, pick the reading that matters for the part and move on.
- Not a blanket rule: for work projects and machined parts he sometimes holds tighter tolerances.
  Ask or follow the drawing there; this section is about the home one-offs.

## Bench

- Printers/materials: FDM in PETG or carbon-fibre PLA. Screw holes for thread-forming screws or
  inserts are modelled slightly undersize and finished with a drill and stop bushing.
- Reference on hand: `3D print/Self-tapping screws for thermoplastics.pdf`.
