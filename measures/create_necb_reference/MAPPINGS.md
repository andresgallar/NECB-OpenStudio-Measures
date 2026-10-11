# Reviewed space-use translations

Automatic translation matches **exact Standards Building Type / Standards Space
Type pairs**, independently for every used Space Type. Compatible NECB/BTAP pairs
are retained. Space Type object names can differ; no fuzzy use inference is made.
If several reviewed entries disagree, or none matches, the assignment is
`Space Function / - undefined -`, with a warning and editable CSV.

The mappings follow classifications in the pinned public NRC NECB2011 prototype
shells. They were derived by matching Space names and surface vertices to public
ASHRAE shells and requiring one consistent NECB use for every Space in a source
classification. This establishes a reproducible prototype convention, not a
project-specific code interpretation. Review applicability to the proposed model.

| Prototype family | Reviewed classification pairs | Unmatched pairs in source fixture |
|---|---:|---:|
| FullServiceRestaurant | 3 | 0 |
| QuickServiceRestaurant | 3 | 0 |
| SmallOffice | 2 | 0 |
| MediumOffice | 2 | 0 |
| LargeOffice | 3 | 1 |
| Warehouse | 3 | 0 |
| RetailStandalone | 5 | 0 |
| RetailStripmall | 3 | 0 |
| PrimarySchool | 11 | 0 |
| SecondarySchool | 10 | 2 |
| SmallHotel | 22 | 0 |
| LargeHotel | 12 | 5 |
| MidriseApartment | 1 | 5 |
| HighriseApartment | 6 | 0 |
| Outpatient | 24 | 8 |

This is classification coverage, **not successful NECB2020 generation or annual
validation of every prototype**. In particular, the apartment and several complex
building mappings are partial. The public Hospital shell had no exact matches
under these criteria, so no Hospital preset is supplied. Supermarkets, laboratories,
data centres and other unlisted classifications use fallback or a reviewed CSV.
Other variants can use these entries when their exact source pair matches.

`resources/mapping_presets.json` contains every exact pair, skipped pair, fixture
path and source SHA-256. `scripts/build_reviewed_mapping_presets.rb` in the public
source archive reproduces that file using bundled public inputs. Runtime operation
does not need that script, Git, network access or private files.

## Review and override

For missing Space Types, Automatic translation can also recover uses from a
unique complete match to a reviewed public shell consistent with the selected
building use. The match uses every Space's surface vertices in world coordinates
(rounded to 0.1 mm), multiplier and floor-area participation; Space and Space
Type names need not match. It restores missing story information and identifies
the public family for prototype simulation settings without copying geometry.
Existing supplied classifications are retained. Complete replacement can repair
only the measure's own recorded WholeBuilding defaults from an earlier run.
An altered/partial/ambiguous shell does not receive recovered prototype uses.
This recovery is disabled when a CSV is supplied, so reviewed CSV choices take
precedence. Other unclassified occupied Spaces receive the selected building
default; excluded-floor-area Spaces receive the explicit undefined fallback for
review, rather than occupied default gains.

The measure reports a `space_use_mapping.csv` path whenever assignments are made.
Copy it to a permanent location, review/edit target columns, then select the copy
under **Optional reviewed space-use mapping CSV**. It works on the original model
or a returned model whose recorded assigned classifications are still intact.
Automatic translation need not be disabled. CSV rows take precedence, including
an explicit change to an already compatible NECB assignment. Blank target pairs
leave the automatic/existing assignment in effect. The open model changes only
after successful generation.

- `source_space_type`: exact Space Type **object name**, not a Space name.
- `source_building_type`, `source_space_type_code`: source metadata guards; retain
  them when editing the exported file. Stale or unrelated source pairs are rejected.
- `necb_vintage`: edition of the **classification vocabulary**, not the selected
  output edition. Reviewed prototypes use NECB2011 vocabulary; the generator
  translates it to the selected NECB2020 edition using the documented NRC routine.
- `necb_building_type`, `necb_space_type`: an exact pair in
  `resources/space_type_catalog.csv` for that vocabulary. Do not mix editions' pairs.
- `spaces`: informational list of affected Spaces; does not control assignments.

For example, the restaurant uses `Space Function / Dining - family space`,
`Space Function / Food preparation` and `Space Function / - undefined -` for
Dining, Kitchen and Attic respectively. Undefined is a wildcard and can omit
conditioning or loads; it is **not a generic occupied room**. It keeps unsupported
uses visible for review and cannot supply the missing design intent. An all-undefined
model may still fail downstream HVAC generation. Correct its uses through the CSV.

**Strict** translation is available when fallback is inappropriate: all incompatible
used types then need CSV assignments, otherwise the measure exports a template and
stops before sizing. Invalid targets, duplicate rows and incomplete strict mappings
are rejected before assignment. Existing compatible types need no CSV rows.
