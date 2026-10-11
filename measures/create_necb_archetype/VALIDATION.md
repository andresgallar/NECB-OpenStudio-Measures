# Validation

For **1.0.0-rc.2 (2026-10-10)**, generation rules are unchanged. The focused
release-input suite passes 25 tests / 143 assertions across both measures; the
archetype's two tests account for 14 assertions, including its clean display name.
The packaged Warehouse NECB2020 natural-gas case is checked from a relocated
folder containing spaces, including local sizing, forward translation and
save/reload. The annual comparisons below are the rc.1 baseline, not repeated
for this naming/input release.

Additional NECB2020 annual comparisons against converted public ASHRAE models
are reported in `../create_necb_reference/VALIDATION.md` and its accompanying
`VALIDATION_RESULTS.json`. The checks below describe the original archetype
generation validation.

Tested on Windows with the CLI bundled in OpenStudio Application 1.11.1:
OpenStudio SDK **3.11.0+241b8abb4d**, EnergyPlus **25.2**.

All cases used the bundled Toronto International Airport CWEC2020 weather.

| Prototype | Edition | Heating | Spaces / zones | Air loops | Plant loops | Floor area (m²) |
|---|---|---|---|---|---|---|
| Warehouse | NECB2020 | Natural gas | 3 / 3 | 3 | 2 | 4,835.13 |
| Warehouse | NECB2011 | Natural gas | 3 / 3 | 3 | 2 | 4,835.13 |
| SmallOffice | NECB2020 | Electricity | 6 / 6 | 5 | 1 | 511.16 |

Each case completed the upstream local EnergyPlus sizing stages and returned
an OSRunner Success result without registered errors or warnings. The smoke
test checked the selected prototype, edition and heating fuel in the generated
model's provenance properties, model components and weather path. Each model
was saved, reloaded and translated to EnergyPlus without translation errors.

The parent CLI deliberately loaded its installed openstudio-standards 0.8.5
before applying the measure. Generation used the bundled nrcan_nrc 0.8.4
implementation in a separate local CLI process.

Two focused tests passed (13 assertions): the argument choices and defaults,
and failure on a missing custom weather set while preserving the input model.

The release ZIP is also checked by extracting it into a separate directory
whose path contains a space and running the Warehouse NECB2020 natural-gas
case from that copy. This checks that runtime resources resolve relative to
the installed measure, without needing the development source checkout.

The Application's CLI refreshed the measure metadata, including all choices.
Interactive application use and other operating systems have not been tested.
The other offered prototypes, editions, fuels and weather combinations have
not all been exercised. These checks cover prototype generation and sizing;
they do not establish annual simulation results or code compliance.

## Re-run

From the development project directory in PowerShell:

```powershell
$cli = 'C:\openstudioapplication-1.11.1\bin\openstudio.exe'
& $cli measures/create_necb_archetype/tests/test_measure.rb
& $cli scripts/smoke_test.rb

$env:NECB_TEST_NAME = 'smalloffice_necb2020_electric'
$env:NECB_BUILDING = 'SmallOffice'
$env:NECB_FUEL = 'Electricity'
& $cli scripts/smoke_test.rb
```

Results and generated OSM/IDF files are under `test-output`. Run the unit test
and smoke test with the CLI belonging to the Application version being checked.
