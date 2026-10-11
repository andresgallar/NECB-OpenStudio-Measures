# NECB measures

**NECB measures 1.0.0-rc.2**, prepared for public evaluation on OpenStudio
Application 1.11.1 / SDK 3.11.0. See [RELEASE.md](RELEASE.md) for source/install
assets and reproducible validation, and [CONTRIBUTING.md](CONTRIBUTING.md) for
reporting problems. This is an independent adaptation, not an official NRC/NREL
release or a verified complete implementation of NECB Part 8.

## Download and install

Download the complete measure ZIPs from the
[1.0.0-rc.2 release](https://github.com/andresgallar/NECB-OpenStudio-Measures/releases/tag/v1.0.0-rc.2):

- [Create NECB Prototype Building](https://github.com/andresgallar/NECB-OpenStudio-Measures/releases/download/v1.0.0-rc.2/create_necb_archetype_openstudio_3.11.zip)
- [Create NECB Reference From OSM](https://github.com/andresgallar/NECB-OpenStudio-Measures/releases/download/v1.0.0-rc.2/create_necb_reference_openstudio_3.11.zip)

Extract each complete measure folder into My Measures, typically
`%USERPROFILE%\OpenStudio\Measures` on Windows, then restart OpenStudio. Preserve
all bundled `resources` files; `measure.rb` alone is insufficient. SHA-256 files
accompany the ZIPs. No custom OpenStudio Server or private project files are needed.

This prerelease focuses on NECB2020 with OpenStudio Application 1.11.1 / SDK 3.11.0
on Windows. See the reference measure's [validation report](measures/create_necb_reference/VALIDATION.md)
for supported workflows, energy comparisons and remaining limitations, including
the warmup-convergence errors shared by the medium-office prototype/reference.

## Measures

The existing-model measure is in
[`measures/create_necb_reference`](measures/create_necb_reference/README.md).
It uses your OSM's geometry and applies the NRC NECB standards routine to create
a reference-model starting point. Existing NECB classifications are accepted;
automatic reviewed mappings from 15 ASHRAE prototype families and explicit CSVs
support other Space Types. Unmatched uses receive a reported undefined fallback
and an editable review CSV. See the measure's MAPPINGS.md for partial coverage.
Missing types, zones, stories and operating profiles can be supplied.
Unclassified plenums/excluded-floor-area Spaces avoid occupied default gains;
plenum levels do not inflate inferred occupied story counts. Unique complete
reviewed public-shell matches can recover missing uses without relying on names.
The simplified workflow has independent choices to keep/replace operating
inputs and to keep/replace HVAC, water heating equipment and infiltration.
It returns one modified model; no prepared-proposed deliverable is generated.
Valid source classifications are retained. Selecting Replace for both choices
performs a complete NRC NECB prototype rebuild from the supplied Space geometry,
including window layout, automatic zoning, operating profiles and systems.
Keep choices retain source zone assignments and apply proportional FDWR changes.
Mapping templates are exported automatically when needed.
The measure's README lists supported cases and remaining Part 8 limitations.
Install it from the reference ZIP linked above.

The ready-to-use measure is in
[`measures/create_necb_archetype`](measures/create_necb_archetype/README.md).
It bundles the public nrcan_nrc standards branch and its supporting files for
OpenStudio Application 1.11.1 / SDK 3.11.0. No OpenStudio Server or private work
files are needed.

Extract the prototype ZIP linked above and copy its entire
`create_necb_archetype` folder into My Measures. See the measure's README for
arguments and installation, and its VALIDATION.md for test coverage.

`dependencies.lock.json` records the public source commits and gem checksums.
Both measures include their pinned runtime source. To package the verified
resources already included in the public source archive:

```powershell
$cli = 'C:\openstudioapplication-1.11.1\bin\openstudio.exe'
& $cli scripts/package_measure.rb

# Package the existing-model measure:
& $cli scripts/package_measure.rb create_necb_reference
```

The package script verifies bundled dependency hashes and refreshes measure
metadata. Runtime generation uses only the installed measure's resources and
the standard OpenStudio installation. Tests and sizing outputs are outside the
release package.
