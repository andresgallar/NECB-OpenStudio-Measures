# Public release — 1.0.0-rc.2

Use a GitHub repository for reviewable source and a **GitHub Release marked
prerelease** for the complete install ZIP and SHA-256 file. Keep the bundled
resources with the measure; a single `measure.rb` download will not work.
Publish the prepared source archive's contents, not this development folder's
test output, installation backups or private project models.

Recommended release title: **NECB Measures 1.0.0-rc.2 — OpenStudio 3.11**.
The OpenStudio Application version tested is 1.11.1; its SDK version is 3.11.0.

The Application display names are **Create NECB Reference From OSM** and
**Create NECB Prototype Building**. Folder names, Ruby classes and measure
UIDs are retained for upgrades. Existing workflows selecting the former individual
restaurant preset must reselect the default Automatic space-use translation.

## Install assets

- `create_necb_reference_openstudio_3.11.zip`
- `create_necb_reference_openstudio_3.11.zip.sha256`
- `create_necb_archetype_openstudio_3.11.zip`
- `create_necb_archetype_openstudio_3.11.zip.sha256`
- Optional `repair_reference_installation.ps1` for incomplete Windows extraction.

The repair tool fills missing files; it does not upgrade existing code. Users
must back up local changes before copying a newer release. Deep bundled paths
need a short extraction/install destination on Windows.

## Source and license

`create_necb_reference_public_source.zip` is an explicit allowlist of the two
public measures, pinned runtime dependencies, license texts, public tests and
release scripts. Both measures are installable and documented. No generated
model, work model, installation backup, user-specific
simulation result or development checkout is included. Dependency hash checks
are performed before packaging. A separate SHA-256 file accompanies this archive.

The standalone adaptations retain the upstream NRC LGPL v3 licensing. Preserve
`COPYING`, `COPYING.LESSER`, `LICENSE-NRC.txt` and all bundled dependency notices.
See each measure's notices for the separately licensed upstream files. Do not
describe the measure as an official NRC/NREL product or a Part 8 certification.
Code text is linked rather than redistributed as a PDF in this release.

## Reproduce validation on Windows

Extract the public source archive into a short path and run from its root:

```powershell
$cli = 'C:\openstudioapplication-1.11.1\bin\openstudio.exe'
& $cli scripts/test_release_inputs.rb
& $cli scripts/test_reviewed_inputs.rb
& $cli scripts/package_measure.rb create_necb_reference
& $cli scripts/package_measure.rb create_necb_archetype
& $cli scripts/verify_reference_archive.rb create_necb_reference create_necb_archetype
& $cli scripts/check_packaged_measures.rb
```

These focused rc.2 checks cover mapping/inputs and one NECB2020 generation from
each packaged measure, including local sizing, translation and save/reload. The
rc.1 annual results remain the baseline. A targeted full-replacement fix converts
proposed F/C-factor ground boundaries to the NECB ground treatment; the prior
annual fixtures did not require that repair. The annual matrix is not repeated.
An additional targeted NECB2020 medium-office annual comparison verifies plenum
defaults, occupied story counts, reviewed missing-input recovery and enclosed
F-factor slab-core conversion: 2041.20 versus 2041.94 GJ/year (0.036%). These
fixes use geometry/floor-area participation rather than room names; supplied
classifications and unrelated adiabatic boundaries remain intact.
The medium-office prototype and reference both retain three warmup-convergence
severe errors; the energy comparison passes with that documented shared limitation.
Its scripts (`test_reference_equivalence.rb` and
`test_public_prototype_matrix.rb`) remain available for future generation changes.
See each measure's VALIDATION.md for dates, scope, tolerances and results.

After changes to code/resources, rerun affected tests and package from the final
source. `package_measure.rb` refreshes SDK metadata and checks dependency hashes;
`verify_reference_archive.rb` checks both complete archives against source, and
`check_packaged_measures.rb` exercises both measures from a relocated path
containing spaces. `check_reference_release.rb` retains the broader reference
workflow suite for future relevant changes. Build/package needs no private files.

Automatic translation uses reviewed exact pairs from 15 public ASHRAE/NRC
prototype families. Some families have partial coverage; unmatched/conflicting
uses receive the explicit undefined fallback and review CSV. See MAPPINGS.md.
This is not a claim of full mapping or annual validation of every family.

## Release boundaries

The candidate is for generating and evaluating prototype-derived NECB baselines
and the documented preservation workflows. Do not claim automatic compliance
with all Part 8 clauses. Unverified daylighting, skylight wells, legacy
one-to-many classifications, SWH correspondence, fuel/conditioning exceptions,
shading and complex systems remain explicit review items. Near-identical energy
to an NRC prototype is a regression test, not an independent validation of the
NRC rules against the Code. Other operating systems/SDKs are not validated.

Use repository issues to request the SDK/Application version, selected choices,
the first meaningful error and a minimal reproducible public model. Ask reporters
to redact private file paths, proprietary models, credentials and unrelated logs.
For longer-term discoverability, a BCL submission can follow the public candidate
feedback cycle; keep a versioned standalone ZIP available for complete resources.
