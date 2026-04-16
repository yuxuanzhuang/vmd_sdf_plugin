# Example SDF Files

This directory contains small test fixtures for exercising different SDF variants supported by the loader and the compiled VMD plugin.

## Files

- [example.sdf](example.sdf):
  mixed small records
- [benzene_2d_v2000.sdf](benzene_2d_v2000.sdf):
  simple 2D V2000 aromatic ring
- [ammonium_legacy_mdl.sdf](ammonium_legacy_mdl.sdf):
  legacy MDL-style mol block without an explicit `V2000` marker, plus `M  CHG`
- [acetate_v3000.sdf](acetate_v3000.sdf):
  compact V3000 example with formal charge
- [ligand_with_charge.sdf](ligand_with_charge.sdf):
  Open Babel-style `atom.dprop.PartialCharge` property with one partial charge per atom
- [multi_ligands_frames.sdf](multi_ligands_frames.sdf):
  multiple compatible records for trajectory mode
- [multi_ligands_mixed.sdf](multi_ligands_mixed.sdf):
  mixed topology / atom counts for split-molecule tests

## Quick Checks

Trajectory-compatible multi-record example:

```tcl
mol new examples/multi_ligands_frames.sdf type SDF
```

Split-record multi-molecule example:

```tcl
set molids [sdfload examples/multi_ligands_mixed.sdf]
```
