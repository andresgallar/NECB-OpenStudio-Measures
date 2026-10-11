# Create NECB Prototype Building

**1.0.0-rc.2 — public release candidate.** See VALIDATION.md and THIRD_PARTY_NOTICES.md.

An adaptation of NRC's `nrc_create_necb_prototype_building` for **OpenStudio
Application 1.11.1 / SDK 3.11.0**. Generates the geometry, loads, constructions,
schedules, zones, HVAC and service water heating using the public `nrcan_nrc`
standards implementation. OpenStudio Server is not required.

## Use in OpenStudio Application

1. Copy this entire `create_necb_archetype` folder into your **My Measures**
   directory. Alternatively, set My Measures to the project's `measures` folder.
   Use a short destination path, such as `%USERPROFILE%\OpenStudio\Measures`,
   because some bundled library filenames reach Windows' path-length limit
   when extracted into deeply nested folders.
2. Open a model and choose **Apply Measure**. Find
   **Create NECB Prototype Building** under Whole Building.
3. Choose building type, edition, weather and heating fuel. Click **Apply**.
4. Wait for the local sizing runs, then save the resulting model.

Like the original NRC measure, this creates a new prototype and replaces the
input model. It imports the new model only after generation succeeds. Generation
files and a diagnostic log are retained in a `necb_archetype_*` folder under
the working directory.

Keep the installed measure in a stable location: the returned model references
its bundled weather file. When sharing a generated model, include its EPW too.

## Arguments

| Argument | Meaning |
|---|---|
| Building type | The original NRC measure's 16 prototype types |
| Building vintage / NECB edition | NECB 2011, 2015, 2017, 2020; BTAP pre-1980 and 1980–2010 |
| Bundled weather location | 15 Canadian EPW/DDY/STAT sets included in the public standards source |
| Primary heating fuel | Regional default, natural gas, electricity or fuel oil |
| Service water heating fuel | Standards default, natural gas or electricity |
| Optional local EPW path | Override bundled weather; matching `.ddy` and `.stat` files must be alongside it |
| Sideload | Optional JSON overrides in `resources/data_sideload`; disabled by default |

The location/weather-type/global-warming menus from the server-oriented NRC
measure are replaced with actual bundled weather choices. This avoids exposing
weather combinations that require downloads or server-provided files. Additional
locations or future weather can be supplied through the local EPW argument.

## What is bundled

`resources/openstudio-standards` contains the pinned branch's complete runtime
`lib` and `data` folders, including NECB JSON tables and prototype geometry.
`resources/gems` contains pinned git-revision, TBD, OSUT, Topolys and OSLG.
Ruby, OpenStudio, EnergyPlus, rubyzip, json-schema and matrix are provided by the
standard Application/SDK installation. No separate Ruby or gem installation,
Git executable, server, private files or runtime downloads are required.

The measure runs its library in a fresh local OpenStudio CLI process, so another
measure's installed `openstudio-standards` cannot override the pinned branch.
The local adapter disables plant sizing for the initial ideal-loads stages
without plant loops (required by EnergyPlus 25.2) and gives repeated sizing runs
separate directories to avoid Windows SQL file locks. NECB calculations are not
changed.

## Public sources and versions

- [Original NRC measure](https://github.com/nrc-cnrc/OpenStudio-Measures/tree/e247ba1dddef1933dc99f894594f5203f28cb4e9/measures/nrc_create_necb_prototype_building)
- [Pinned nrcan_nrc standards](https://github.com/NatLabRockies/openstudio-standards/tree/327689b0fe76331d781120ebc81d0f444f2546ba)
- `resources/dependency_manifest.json` records versions and dependency SHA-256 hashes.

This is a local adaptation, not an official NRC release or a certification of
code compliance. See `VALIDATION.md` for the tested configurations. Other offered
combinations use the upstream implementation and need validation for their use.

The NRC source license is in `LICENSE-NRC.txt`. Bundled upstream files retain
their copyright notices and licenses; see `resources/openstudio-standards/LICENSE.md`
and each gem's license files.
