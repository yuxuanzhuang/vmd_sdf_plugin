# VMD SDF Loader

This repository adds SDF support to VMD in two modes:

- `Structure Data File SDF (trajectory)`:
  Loads one SDF record as the topology and treats later compatible records as trajectory frames.
- `sdfload` / `Load SDF As Molecules`:
  Loads each SDF record as a separate VMD molecule.

## 1. Add It To `~/.vmdrc`

To make VMD see the plugin and Tcl loader at startup, add this to `~/.vmdrc`:

```tcl
set sdfplugin_dir /absolute/path/to/vmd_sdf_plugin/molfile
if {[llength [info commands vmd_plugin_scandirectory]] && [file isdirectory $sdfplugin_dir]} {
    catch {vmd_plugin_scandirectory $sdfplugin_dir *.so}
}
unset -nocomplain sdfplugin_dir

source /absolute/path/to/vmd_sdf_plugin/sdfloader1.0/sdfloader.tcl
```

Restart VMD after changing `~/.vmdrc`.

If you start VMD directly with an SDF file, for example `vmd example.sdf`, the initial built-in SDF load may still print a Babel-related error before `~/.vmdrc` is sourced. Once `sdfloader.tcl` loads, it recovers the startup import and, by default, uses split-record mode so each SDF record becomes a separate VMD molecule.

## 2. Use It With The GUI

### Trajectory Mode

Use this when you want one VMD molecule.

Choose:

- `Structure Data File SDF (trajectory)`

This uses the compiled plugin and will:

- load the first record as structure
- load later records as frames only if atom sequence and bond topology match
- skip incompatible records

Equivalent console command:

```tcl
molecule new file.sdf type {Structure Data File SDF (trajectory)} waitfor all
```

or:

```tcl
mol new file.sdf type SDF waitfor all
```

### Multiple-Molecule Mode

Use this when one SDF file contains many ligands and you want one VMD molecule per record.

GUI:

- `Extensions -> Data -> Load SDF As Molecules`

## 3. Use It With Tcl

### Load Every SDF Record As A Separate Molecule

```tcl
set molids [sdfload file.sdf]
```

This returns a list of VMD molecule ids.

Because the Tcl wrapper is installed, these also default to multi-molecule loading:

```tcl
mol new file.sdf
molecule new file.sdf
```

### Force Trajectory Mode

```tcl
set molid [sdfload -mode trajectory file.sdf]
```

or:

```tcl
set molid [sdftrajload file.sdf]
```

### Explicit Trajectory Load Through The Molfile Plugin

```tcl
mol new file.sdf type SDF waitfor all
```

or:

```tcl
molecule new file.sdf type {Structure Data File SDF (trajectory)} waitfor all
```

## Additional Notes

The project uses two pieces:

- [src/sdfplugin.cpp](src/sdfplugin.cpp): a compiled molfile plugin for the single-molecule / trajectory path
- [sdfloader1.0/sdfloader.tcl](sdfloader1.0/sdfloader.tcl): a Tcl loader for multi-record split loading


### Build

You do not need to run `make` if [molfile/sdfplugin.so](molfile/sdfplugin.so) already exists for your machine and VMD build.

Build only if needed:

- `molfile/sdfplugin.so` is missing
- you changed [src/sdfplugin.cpp](src/sdfplugin.cpp)
- you are moving to a different OS / architecture / VMD build

Build command:

```sh
make
```

The build now uses the vendored VMD plugin headers in [include](include), so GitHub Actions and Linux/macOS local builds do not depend on a hardcoded VMD app path.

This creates:

```text
molfile/sdfplugin.so
```

To package a runtime bundle like the release assets:

```sh
make package PACKAGE_VERSION=dev
```

This creates a tarball under `dist/`.

### GitHub Actions / Releases

GitHub Actions now builds the plugin on:

- Linux
- macOS

CI runs on every push and pull request through [.github/workflows/ci.yml](.github/workflows/ci.yml) and uploads per-platform tarballs as workflow artifacts.

Tagged releases are handled by [.github/workflows/release.yml](.github/workflows/release.yml):

- create and push a tag like `v1.0.0`
- GitHub Actions builds the Linux and macOS bundles
- the workflow creates or updates the matching GitHub Release
- the release assets include both tarballs and `SHA256SUMS.txt`

For supported Linux and macOS targets, users can install from the release bundles without running `make`.

### Caveat / Limitation

`File -> New Molecule` cannot create multiple VMD molecules from one file through the molfile plugin API.

That is a VMD limitation, not an SDF parsing limitation. The molfile interface is designed for:

- one molecule
- optional multiple frames

So:

- use `File -> New Molecule` for trajectory-style SDF loading
- use `sdfload` or `Extensions -> Data -> Load SDF As Molecules` for split-record loading

### Test Files

Example SDFs are provided in [examples](examples):

- [examples/example.sdf](examples/example.sdf):
  mixed small records
- [examples/ligand_with_charge.sdf](examples/ligand_with_charge.sdf):
  Open Babel-style `atom.dprop.PartialCharge` property with one partial charge per atom
- [examples/multi_ligands_frames.sdf](examples/multi_ligands_frames.sdf):
  multiple compatible records for trajectory mode
- [examples/multi_ligands_mixed.sdf](examples/multi_ligands_mixed.sdf):
  mixed topology / atom counts for split-molecule tests

Try:

```tcl
mol new examples/multi_ligands_frames.sdf type SDF
```

and:

```tcl
set molids [sdfload examples/multi_ligands_mixed.sdf]
```

### Notes

- The multi-molecule Tcl path uses TopoTools inside VMD.
- V2000 SDF is supported.
- Common V3000 atom and bond blocks are supported.
- SD properties such as Open Babel `atom.dprop.PartialCharge` are used to populate per-atom partial charges when present.
- Bond orders are loaded from the SDF records instead of relying only on VMD bond guessing.

### License

The original code in this repository is licensed under the MIT License in [LICENSE](LICENSE).

Vendored VMD plugin headers in [include](include) retain their original UIUC Open Source License terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [LICENSES/UIUC-Open-Source-License.txt](LICENSES/UIUC-Open-Source-License.txt).
