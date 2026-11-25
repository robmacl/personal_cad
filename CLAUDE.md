# Personal CAD

Robert's own SolidWorks work: parts for 3D printing (FDM, his own printer) and for machining.

This is a git repository and a PUBLIC one (github.com/robmacl/personal_cad). Commit and push only
when Robert asks. Third-party files (datasheets, downloaded models) stay on disk but out of git
through `.gitignore`. Bambu Studio `.3mf` project files carry his Bambu account id: ask before
adding one.

## Before any design work

Load the `solidworks-cad` skill (`~/.claude/skills/solidworks-cad/SKILL.md`). It covers attaching to
the running SolidWorks, the generator pattern, API pitfalls, and checking. Claude designs and builds
the parts by script; it does not hand back sketches for Robert to model.

## Layout

- `3D print/` — older hand-modelled parts, 2021–2025 (gears, frames, caddies, brackets, boxes), with
  their STL/3MF exports, drawings and two Cura profiles (`pla_plus`, `overture_petg_coarse_black`).
  All of it is Robert's own work: read for reference, never overwrite. New exports get new names.
- `light_box/` — built by script, started Nov 2026. `light_box_notes.txt` is the record; its last
  entries say where the project stands and which print files are current.

## Convention for scripted projects

Each new project gets its own directory, laid out like `light_box/` (or the squeeze-controller
example the skill points to):

- `<project>/generate/` — `*_params.json` (every dimension, mm), the generator `.ps1`, the section
  and clash check, drawing script.
- `<project>/` — the SLDPRT/SLDASM output and a `*_notes.txt` design-notes file saying what the
  numbers mean, what was checked and what was not.
- `<project>/stl/` — dated print exports. `<project>/check/` — pictures and section drawings.

The JSON and the script are the design; the SLDPRT is output and is rebuilt in place.

## How a scripted project runs

- Robert measures, says how the thing is used, and decides. Claude designs, builds, checks, exports
  and writes it down. Ask him only for what is his: use, bench stock, measurements of real parts.
- Every change goes the whole way round: edit the JSON or script, rebuild, read the report, look at
  the picture, run the clash check on the meshes, export under a new dated name (`_2026-11-25`,
  then `a`, `b`, ...), add a dated entry to the notes (what changed and why, CHECKED, NOT CHECKED,
  which file it supersedes), close the project's documents in SolidWorks. Never close or save his.
- Tell him which print file is current every time one changes. Superseded exports stay on disk.
- A dimension scaled off a photo is good to a couple of millimetres. Mark it as an estimate, give
  the feature float to match, and get the one caliper reading before a long print.
- When his numbers don't close, suspect a misread before inventing geometry to explain it. (A
  channel width that would not close was a handwritten 3.32 read as 3.92.)
- Before using a catalogue figure, work out what it is measured on. (The heat-set insert "hole
  size" was the diameter at the narrow end of a tapered hole, not a drill size for a straight one.)
- Before a long print, go back over every fit and ask what absorbs each uncertainty, in each
  direction. (The handle's screw slots had float up and down but almost none along the channel.)
- When a dry fit misbehaves, find out what is touching what before prescribing. Pinched on its
  thickness, bottomed on an edge and hung up on a corner all feel the same from outside and want
  different fixes.
- He may not be able to reprint (no filament in that colour, no time). Give a fix for the parts in
  hand as well as the corrected file.
- For a set of identical parts, print one and try it before the rest.

## Precision and fits

These are one-off parts, mostly 3D printed, fitted to materials Robert has on the bench. Don't go
crazy with precision.

- The default is a liberal gap. Unless there is a reason for a snug fit, give generous clearance.
  Too much slop means a rattle, which a dab of RTV cures; too little means filing or a reprint.
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

Numbers that came out of the light box, to start from next time:

- A printed slot that something slides into: 0.5 to 0.6 mm of drawn clearance. One drawn at 0.25
  came out at about 0.1 and pinched.
- Stock he cuts to length on the chop saw: allow +/-2 mm. He calls +/-1 a fairly tight tolerance for
  that saw, and one channel in four was 1 mm short. A cut length must not be the only thing that
  sets a clearance; where two pieces must match, they are cut clamped together.
- Screw slots: at least +/-1 mm of float in every direction the parts could be off, not only the
  obvious one. Say which washer covers the slot.
- Count what locates each part. If it is located twice (a land and a screw, a foot and a bracket),
  all the error lands on one float: know which one and how much of it is left.
- A pocket that takes a square corner gets a relief at its inside corner, not a fillet. The sharp
  tip rides up on a fillet and stops the part short.
- Different materials grow differently: acrylic about three times as fast as aluminium. Leave room
  and don't bond rigidly all round.

## 3D printing: things that have bitten

- Everything closes in. Walls come out a little fat, inside corners bulge, and a face on the bed
  spreads. Chamfer hole mouths and edges that sit on the bed.
- Heat-set inserts: the hole prints to size, tapered to match the insert, with a short straight
  pocket below for the melt and a small chamfer on the mouth. No finish drilling. (M3 tapered,
  6.4 long: 5.6 at the mouth to 4.7 at 6.4 deep, 8 degrees included; from the catalogue, not yet
  confirmed against a measured insert.) Set the insert flush or a hair proud, never below the
  face, so the mating part clamps on the brass and the screw cannot jack the insert out.
- Print orientation is a strength decision: put bending along the strands. No snap fits or sprung
  legs that would bend across the layers; use flat legs and spacer washers instead.
- Screws and inserts run along the build direction where the part allows it.
- Supports: say where they are needed and where not, and ask for interface filament on faces that
  matter (the underside of a hand grip, faces that seat on another part).
- Walls count for more than infill in bending: 6 walls and about 25% infill for load-bearing parts.

## Bench

- Printer: Bambu X1C, with support-interface filament available. PETG for most parts (plain PETG
  where toughness matters, and anywhere warm); carbon-fibre PLA is on hand.
- Holes for thread-forming screws are modelled slightly undersize and finished with a drill and
  stop bushing. That is not his practice for heat-set inserts (see above).
- Fasteners he has used here: M3 tapered brass heat-set inserts, M3 and M6 socket head cap screws,
  1/4 in flat washers (a standard M6 washer is only 12 OD).
- Reference on hand: `3D print/Self-tapping screws for thermoplastics.pdf`.
