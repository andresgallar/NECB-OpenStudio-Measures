# Validation — 1.0.0-rc.2

This candidate focuses on **NECB2020**, Windows, OpenStudio Application 1.11.1 /
SDK 3.11.0 / EnergyPlus 25.2. The standards runtime is pinned at
327689b0fe76331d781120ebc81d0f444f2546ba (nrcan_nrc, 0.8.4).
All 2,284 bundled dependency files are verified against their SHA-256 manifest.
Other offered NECB editions, operating systems and SDK versions are outside the
release's validation scope. These are regression checks, not Code certification.

## Annual energy comparison

The following annual results were obtained for **1.0.0-rc.1 on 2026-10-09** and
are reused as the baseline for rc.2. The pinned standards library is unchanged.
rc.2 changes translation, CSV review, missing-input/plenum preparation and display
names, and normalizes proposed F/C-factor ground boundaries during full replacement.
The earlier annual cases did not require the new boundary repairs. One targeted
medium-office annual comparison and focused checks are recorded below; the full
annual matrix was not rerun.

Each pair uses an independently generated `create_necb_archetype` model and a
`create_necb_reference` conversion of the pinned public ASHRAE geometry. Both
input groups are set to Replace, with identical edition, weather and fuels
(natural-gas primary heating and the same NRC default SWH fuel). No private OSM
or work files are used. The conversion retains the source space geometry; it
does not substitute the NECB prototype model or calibrate equipment to annual
results. Additional mappings follow the corresponding public NRC shell's space
uses and were supplied through the CSV interface. rc.2's automatic mappings for
these fixtures follow those same public classifications; uses are not guessed.

| NECB2020 case | Archetype site energy (GJ/year) | Converted reference (GJ/year) | Absolute difference |
|---|---:|---:|---:|
| Full-service restaurant, Toronto | 591.48 | 591.53 | 0.0085% |
| Quick-service restaurant, Toronto | 248.78 | 248.78 | 0.0000% |
| Small office, Toronto | 245.18 | 245.18 | 0.0000% |
| Standalone retail, Toronto | 1249.04 | 1249.15 | 0.0088% |
| Warehouse, Toronto | 2402.85 | 2403.08 | 0.0096% |
| Warehouse, Calgary | 2206.07 | 2205.91 | 0.0073% |

Acceptance tolerances are max(0.02 GJ, 0.1%) on site and fuel totals and
max(0.02 GJ, 0.5%) on each reported end use. All pairs pass these tolerances;
site-energy differences are below 0.01%. Totals are rounded independently in
the EnergyPlus tabular SQL output. Bitwise identity is not expected: generated
loop names/order and plant iterations can produce small numerical differences.

The full-service restaurant also passes clean, deliberately contaminated and
reapplied-model tests. The contaminated case adds a 100-kW process load, 3 m3/s
infiltration, proposed boiler/water-heater inputs and arbitrary Space Type labels;
it removes windows and changes optics, terrain, calendar, sizing settings, ground
temperatures and exterior sun/wind exposure. All three final references produce
591.53 GJ/year. In addition to the prototype tolerances, these cases are compared
to each other within max(0.02 GJ, 0.02%), allowing observed solver/order variation
while detecting retained proposed loads. No efficiencies are adjusted to force
agreement. Geometry, 40% FDWR and SWH pump lookup are checked independently.

Detailed fuel/end-use results, skylight areas, warnings and unmet-setpoint reports
are included in [VALIDATION_RESULTS.json](VALIDATION_RESULTS.json). The public
source archive includes the scripts to reproduce these results.

## Targeted medium-office comparison — 2026-10-10

A reported 18-Space medium-office conversion was compared with the supplied NECB
prototype run using NECB2020, Toronto CWEC2020 weather, natural-gas HVAC/SWH and
both groups set to Replace. Its vertices matched the public MediumOffice shell,
although Space names differed and Space Types were missing. The earlier reference
used 3363.48 GJ/year: occupied WholeBuilding defaults had also been assigned to
three excluded-floor-area plenums, plenum levels inflated the inferred story
count, and an adiabatic F-factor slab core omitted ground contact.

The corrected conversion recovers missing reviewed uses/stories from the unique
whole-shell match, retains three occupied storeys, creates three air loops and
has no People/electric-equipment gains in the three plenums. Geometric F-factor
core conversion restores ground contact and the corresponding infiltration
envelope area; no equipment efficiency is adjusted to fit energy results.

| Annual metric | NECB prototype | Corrected reference |
|---|---:|---:|
| Site energy (GJ) | 2041.94 | 2041.20 |
| Electricity (GJ) | 1396.01 | 1395.84 |
| Natural gas (GJ) | 645.93 | 645.36 |
| Lighting (GJ) | 347.32 | 347.32 |
| Interior equipment (GJ) | 498.17 | 498.17 |
| Cooling (GJ) | 208.42 | 208.42 |
| Gas heating (GJ) | 406.67 | 406.10 |
| Service-water heating (GJ) | 239.25 | 239.26 |

The site difference is **0.036%**. Site/fuel totals and every checked end use
pass the same 0.1%/0.5% tolerances above. Sizing and forward translation complete;
the annual run finishes but reports **three warmup-convergence severe errors**,
also present in the supplied prototype. This is a numerical energy regression
with a shared upstream initialization limitation, not a clean annual validation.
The targeted comparator permits only this existing warmup error class up to the
prototype's count, rejecting other severe/fatal errors. This verifies the
reported energy discrepancy, not annual equivalence for every geometry/plenum.
User-supplied models/results remain local and are excluded from public assets.
`scripts/compare_medium_office.rb source.osm prototype_run_directory` reproduces
the targeted comparison with a same-geometry medium-office prototype run that
contains `in.osm` and `eplusout.sql`. Only the sanitized numerical summary appears
in the public validation report.

## Skylights and geometry

The warehouse and standalone retail tests exercise physical skylight generation:

| Case | Prototype skylight area (m2) | Reference skylight area (m2) | Library SRR |
|---|---:|---:|---:|
| Warehouse, Toronto and Calgary | 91.9650 | 91.9650 | 2% of eligible exposed conditioned non-plenum roof area |
| Standalone retail, Toronto | 45.8799 | 45.8799 | 2% of eligible exposed conditioned non-plenum roof area |
| Small office and full-service restaurant | 0 | 0 | Roofs over unconditioned attics; no wells generated |
| Quick-service restaurant | 0 | 0 | No roof eligible for the default generator |

The release checks roof-by-roof achieved area, construction presence, containment
and non-overlap. A missing expected skylight now causes a clear failure rather
than an unnoticed upstream omission. Unit tests also cover multiplier accounting,
no mandatory thermal skylights in preservation mode, reducing existing skylights
and excluding opaque hatches. The default generator supports exposed flat roofs;
sloped roofs and wells through attics/plenums require separate modelling.

The public ASHRAE warehouse has a reversed internal face. Correcting orientation
on the fresh shell, without moving vertices, restores the Fine Storage volume
from an SDK fallback of 9513.07 m3 to 10880.57 m3, matching the NRC shell. The
uncorrected Toronto conversion differed by 0.55% in site energy; the corrected
conversion differs by 0.0096%. Repairs are recorded in the model audit.

NECB2020 8.4.4.5.(7) specifies a skylight assumption for **daylighted-area
calculations**; physical skylights alone do not implement that calculation.
The library's nominal 2% ratio, its eligible-roof denominator and its lack of
skylight wells are explicitly documented. See README for the distinction from
3.1.1.6.(5), 3.2.1.4.(2) and the unverified full Part 8 daylighting calculation.

## Focused regression and release checks

The rc.1 baseline passed **46 tests / 244 assertions**, zero failures, errors or
skips. Coverage includes
argument/default behavior, safe failure, exact reviewed mappings and stale CSVs,
missing type/zone/story preparation, geometry, FDWR/doors/orientations, preserved
loads/zero values and systems, no duplicate defaults, clean replacement,
legacy classification upgrades, reversed warehouse faces and skylight auditing.

The rc.2 input/mapping checks passed **25 tests / 143 assertions**, zero failures,
errors or skips (including the archetype's two focused tests). They cover exact
automatic mappings, mixed uses, unchanged compatible types, unmatched/conflicting
fallback, reviewed CSV overrides, corrections to returned models, stale-source
guards, atomic failure and the two simplified translation choices. All reviewed
targets are checked against the bundled NECB vocabulary. Mapping coverage for
the 15 prototype families does not imply annual validation of every family.

The install ZIPs for both measures are checked against the complete source
inventory and dependency hashes. Focused NECB2020 generation checks run from a
relocated folder containing spaces: automatic full-service restaurant conversion
and Warehouse archetype creation, including sizing, EnergyPlus forward translation
and save/reload. The reference check also verifies that its exported CSV is usable
on the saved returned model. Preservation and the broader annual matrix retain
their rc.1 results; those unaffected workflows are not repeated for rc.2.

An additional targeted NECB2020 repair check on 2026-10-10 passes **1 test /
7 assertions** (`scripts/test_ground_boundary.rb`). It verifies that a proposed
GroundFCfactorMethod surface becomes Ground on the clean shell, leaves the source
unchanged, preserves geometry and records the conversion. The reported failing
18-Space model was replayed locally with the same Toronto weather and natural-gas
HVAC/SWH settings, with both groups set to Replace. All four F/C-factor surfaces
were converted; all five sizing simulations completed with zero severe errors.
Every resulting surface had a construction, and forward translation and
save/reload passed. This reported model is not included in public packages.
No annual simulation matrix was repeated for the repair.

The missing-input/ground-core checks pass **11 tests / 42 assertions**, zero
failures, errors or skips (`scripts/test_reviewed_inputs.rb`). They include
renamed Spaces, retaining supplied types, repairing only recorded defaults,
rejecting a modified-shell match, excluded-area fallback without an occupied use,
enclosed F-factor cores, partial-contact rejection and prior-conversion provenance.
The input/mapping suite was rerun after these changes and passes **26 tests /
148 assertions**, including exported CSV review for recovered missing uses.
No broad argument/edition or annual matrix was repeated.

## Practical limits

The earlier annual baseline runs complete without severe/fatal errors; the
targeted medium-office case has the shared warmup limitation described above.
The pinned upstream models
still report warnings, including SWH target temperatures, DX operating/rating
conditions and heat-recovery flows. Some geometry logs identify collinear points.
Unmet-setpoint hours and warning examples are preserved in the JSON report;
passing an energy equivalence tolerance is not a statement that these systems
are ideal or that their sizing/comfort behavior is fully validated.

Complete replacement follows the NRC prototype's assumptions, including default
window layout, automatic zoning, wind-dependent infiltration and first-match
legacy classifications. Older enclosed-office/storage types can have multiple
NECB2020 choices. The library's choice is disclosed; review size and operating
schedule before using it for a project. Preservation modes reject ambiguous
cross-edition translations and retain selected proposed inputs by design.

Remaining improvements include verified Part 8 daylight-area/control calculations,
skylight wells, detailed glazing preservation, SWH equipment correspondence,
heating-only/cooling-only replacement exceptions and special HVAC/shading cases.
The measure is released for public evaluation as a prototype-derived baseline
and documented preservation tool, not as a complete automatic compliance engine.

## Reproduce

From the public source archive root in PowerShell:

```powershell
$cli = 'C:\openstudioapplication-1.11.1\bin\openstudio.exe'
& $cli scripts/test_release_inputs.rb
& $cli scripts/test_reviewed_inputs.rb
& $cli scripts/package_measure.rb create_necb_reference
& $cli scripts/package_measure.rb create_necb_archetype
& $cli scripts/verify_reference_archive.rb create_necb_reference create_necb_archetype
& $cli scripts/check_packaged_measures.rb
```

The optional `test_reference_equivalence.rb`, `test_public_prototype_matrix.rb`
and `collect_public_validation.rb` scripts reproduce the annual baseline.
These longer annual comparisons need rerunning after relevant calculation changes,
not for every documentation or argument-label edit. Test outputs remain under the
ignored `test-output` directory. See the repository RELEASE.md for publishing the
complete ZIP, checksum, source and licenses.
