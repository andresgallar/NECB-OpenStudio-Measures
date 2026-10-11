# Create NECB Reference From OSM

**1.0.0-rc.2 — public release candidate.** An independent adaptation of the
public NRC measures, not an official NRC/NREL release or a compliance certificate.

Updates the model open in **OpenStudio Application 1.11.1 / SDK 3.11.0**.
The model must already contain Spaces with usable building surfaces. The
measure returns **one modified model**. It does not create a separate prepared
proposed-model deliverable. Local staging and EnergyPlus diagnostics are kept
in a run directory; the source file and open model remain unchanged on failure.

The pinned public NRC `nrcan_nrc` library, supporting gems and Canadian weather
sets are bundled. No custom OpenStudio Server, private files, separate Ruby
installation or runtime downloads are required.

## Apply

1. Open the OSM and apply **Create NECB Reference From OSM**.
2. Select the **Reference NECB edition**.
3. If Spaces have no Space Type, select **Default building use for spaces
   without Space Types**. Existing building standards metadata can supply this
   default. Automatic translation can recover reviewed uses from an exact,
   whole-model match to a public prototype shell; otherwise the selected default
   applies. Room names are not used to guess a use.
4. Choose independently whether to keep or replace **operating inputs** and
   **building systems**. Select **Replace for both** for a complete NECB rebuild
   comparable to the NECB prototype measure, as described below.
5. Retain the model weather, select bundled weather, or provide a local EPW
   with matching DDY and STAT. Select heating/SWH fuels when replacing systems.
6. Apply and save the resulting model under the desired filename.

There is no Action or Reference input mode selector. Mapping CSV is input only.
Source OSM path is optional; blank uses the open model. Supplying another OSM
uses that model as the source and replaces the current open model on success.

## Classifications, zones and stories

- Compatible NECB/BTAP Space Type names, standards metadata and assignments are
  retained unless explicitly overridden by a reviewed CSV. Internal lookups temporarily translate supported types to the
  target edition; source classifications are restored afterwards.
- With Automatic translation and no mapping CSV, missing uses can be recovered
  from a unique, complete geometry match to a pinned reviewed prototype shell
  consistent with the selected building use. Every Space's world-coordinate
  surface vertices, multiplier and floor-area participation must match; names
  can differ. This recovers distinct occupied/plenum uses and missing stories
  without copying geometry or systems. Complete replacement can also correct
  the measure's own recorded WholeBuilding defaults from an earlier application;
  explicitly supplied compatible/custom types remain unchanged.
- Otherwise, unclassified Spaces included in total floor area receive the
  selected default use / WholeBuilding. Unclassified Spaces excluded from total
  floor area receive `Space Function / - undefined -`, avoiding occupied default
  gains in plenums/attics. Explicitly designated HVAC plenums without a Space
  Type are first excluded from total floor area. Review excluded-space use and
  conditioning with the CSV; exclusion alone does not prove a space is a plenum.
  Mixed-use occupied Spaces need appropriate types/mappings.
- The default **Automatic** space-use translation applies exact reviewed
  classifications from 15 public ASHRAE/NRC prototype families, per Space Type,
  including mixed uses. No individual restaurant preset needs to be selected.
  Unmatched or ambiguous types receive `Space Function / - undefined -`, with
  a warning and editable `space_use_mapping.csv`. Undefined can omit loads or
  conditioning; correct those uses before relying on energy results. Some
  prototype families have partial coverage. See [MAPPINGS.md](MAPPINGS.md).
- Missing zones are created one per Space. Keep workflows retain existing zone
  names and Space assignments; replacing both groups uses NRC automatic zoning.
  Effective Space multipliers are retained in every workflow. Zones have no NECB space-use
  classifications; their Spaces supply that information.
- Missing stories are assigned using floor elevations; existing stories are
  retained. Missing story counts use Spaces included in total floor area, so
  separate plenum levels do not add occupied storeys. Exact reviewed-shell
  recovery can restore the measure's earlier inferred stories/counts. Review
  basement/ground elevation.

Whenever translations are made, the measure exports `space_use_mapping.csv` and
reports its path. Copy/edit it using `resources/space_type_catalog.csv`, then
select it under **Optional reviewed space-use mapping CSV** to override assignments.
Rows name Space Type objects exactly, not individual Spaces. Source columns
protect against stale CSVs; the file can also correct a returned model while its
recorded assignments are intact. The `necb_vintage` column identifies the input
classification vocabulary, independent of the selected output NECB edition.
**Strict** translation instead requires compatible NECB types or complete reviewed
CSV mappings; unmapped types export a template and stop before sizing. Automatic
fallback does not guarantee downstream generation for an all-undefined model.

## The two independent choices

**Replace both groups = complete NRC NECB rebuild.** This retains the supplied
Space/surface geometry, orientation, effective multipliers, story information,
floor-area participation and reviewed use classifications. It discards proposed
windows/doors, constructions, glazing optics, internal mass, shading/EMS controls,
loads, schedules, thermostats, HVAC/SWH, infiltration and simulation settings.
The same pinned `model_apply_standard` routine used by the NECB prototype measure
then supplies new windows, envelope, operating inputs, automatic zones, systems,
sizing and efficiencies. No stock prototype geometry or energy results replace
your geometry. Original compatible Space Type labels/metadata are restored after
temporary canonical NECB lookup names have been used for sizing.

Reversed surface normals are corrected on the fresh shell, without moving any
vertices; repairs are listed in the audit. This avoids incorrect SDK fallback
volumes in some public ASHRAE fixtures. Existing volume overrides are discarded.
Proposed `GroundFCfactorMethod` surfaces and existing Kiva foundations are reset
to `Ground` on the fresh shell so the NRC routine supplies NECB ground assemblies
and foundation treatment. Proposed F/C-factor construction methods do not survive
complete replacement. Conversions are listed in `ground_boundary_conversions` in
the audit; surface vertices and ground-contact intent are retained.
An adiabatic floor representing an F-factor slab core is also converted when
every edge is enclosed by coplanar ground-contact floors and F-factor context
exists on that plane. This geometric check works without room names and accepts
F-factor provenance recorded by an earlier application. Partial contact or
unrelated adiabatic floors do not trigger conversion. Review the recorded core
conversions when replacing a proposed ground approximation.
Uniform legacy NECB classifications follow the same NRC upgrade routine as the
prototype. Where one legacy type maps to multiple target types (for example,
enclosed offices or storage rooms), the prototype's first-match choice is
reported for review. This is a library convention, not an area/schedule decision
verified against every project. Assign reviewed target-edition classifications
before generation when those distinctions matter. Mixed editions use only
unambiguous translations; preservation workflows reject ambiguous translations.

For a recognized Building Standards Building Type, simulation settings, terrain
and ground-temperature defaults come from that public NRC prototype shell.
For other types, clean SDK defaults are used. Proposed calendar/sizing settings
never carry over; the NRC calendar starts on Sunday. Weather and selected fuels
still follow the measure arguments. Use the same weather, edition, fuels, space
uses and geometry when testing against a prototype.

This complete rebuild intentionally uses **NRC prototype assumptions**, including
the prototype's wind-dependent infiltration and default window distribution.
It is useful for the requested prototype-equivalence test and initial modelling.
Project Part 8 rules that require common proposed/reference inputs still need
review. Choosing Keep for either group uses the preservation workflow below.

| Input | Keep existing | Replace |
|---|---|---|
| Occupancy, equipment loads, lighting and operating schedules | Keep existing People, Lights/Luminaires, electric/gas/other equipment, schedules, outdoor air and thermostat inputs; fill absent load categories/schedules from NRC NECB profiles | Remove those existing load instances and populate NECB library loads/schedules, outdoor air and thermostat profiles without stacking loads |
| HVAC, water heating equipment and infiltration | Retain equipment, plant/air-loop connections, capacities, efficiencies, availability schedules, EMS and all infiltration definitions | Rebuild HVAC/SWH using the NRC NECB selection/sizing/efficiency workflow and replace infiltration with the edition's reference default |

In preservation workflows, an existing zero-valued load counts as present; Keep does not add another load
of that category. Reapplying Keep does not stack default loads. A missing
thermostat is populated from the assigned space-use profile. Explicit disabled
heating/cooling schedules are preserved when replacing thermostat profiles.
A zone tagged with `necb_conditioning=Unconditioned` is also respected.
Review assumed conditioning for incomplete design models.

Water-use **demand and its schedules** follow the operating-input choice;
water heaters, tanks, pumps and plant topology follow the building-systems
choice. Replacing demand while retaining systems supports a single SWH loop;
multiple loops need an explicit distribution decision. Existing HVAC availability
schedules remain unchanged when equipment is retained. Keeping systems does
not add absent HVAC, heaters or infiltration; the run reports unserved zones.

In preservation workflows, internal mass is preserved under either operating choice. Existing schedules
are not globally deleted, because retained equipment can still reference them.

## Envelope and Part 8 scope

The remainder of this section describes **preservation workflows**, where at
least one group is set to Keep. Complete replacement uses the NRC prototype
envelope, window generation and infiltration routine described above.

Reference envelope U-values and proportional FDWR adjustments apply in
preservation workflows. Existing opening types, centres and proportional areas are retained
where feasible; thin openings can change aspect ratio to fit. Invalid or
infeasible overlap/out-of-wall layouts stop generation. If no wall openings
exist, the library supplies default windows and records that assumption.
Existing skylight SRR is reduced to the library limit when necessary; opaque
roof hatches are excluded from skylight area. Supported SimpleGlazing
SHGC and visible transmittance are retained while U-factor changes. Missing
constructions are supplied. Interior/adiabatic constructions and internal mass
are retained where supplied; the exterior envelope/foundation is rebuilt.

FDWR includes vertical glazing **and opaque doors**. The runner reports these
areas, gross wall area and glazing-only WWR separately. The audit also records
the opening-area share at every orientation before/after adjustment. The code
FDWR target is no longer rounded to three decimal places. A stock prototype
with windows spread over every wall can have the same FDWR and different energy
results from a reference preserving a proposed building's opening distribution.

For NECB2020 replacement infiltration, the 1.50 L/(s m2) default at 75 Pa is
converted to 5 Pa with exponent 0.60 using the conditioned envelope area, then
allocated to conditioned above-ground exterior walls. Ground/Kiva floors and
ceilings adjoining unconditioned spaces count toward the air-barrier area;
unconditioned attic roofs do not. Flow is constant without an additional
prototype wind multiplier. Areas, total flow and per-Space allocation are
recorded in the audit. Other editions retain their existing leakage treatment.

**This creates a reference-model starting point, with recorded assumptions.**
Keeping proposed lighting power or existing equipment/infiltration does not
convert those items to reference requirements. Replacing occupancy, process
loads and schedules requires consistent assumptions in the proposed model for
an energy-performance comparison. Code defaults and NRC library assumptions
are identified as such; library defaults are not all mandatory code values.

Preservation-workflow limitations requiring project review:

- Replacement HVAC supports heated-and-cooled and unconditioned zones; an
  explicitly heating-only/cooling-only zone is rejected rather than converted
  to a different conditioning type. Retained systems can keep those zones.
- A zone with different NECB HVAC-selection categories cannot be rebuilt as a
  single reference system automatically; retaining the existing system is allowed.
- Existing exterior glazing must use one-layer SimpleGlazing for preserving
  optics. Detailed glazing is rejected; missing glazing constructions are filled.
- SWH reference heater capacity, tank sizing and distribution still use NRC
  assumptions. Existing demand can be preserved, but complete Part 8 SWH
  equipment correspondence is not established by this measure.
- Annual restaurant tests show recurring upstream SWH temperature and DX-coil
  operating/rating warnings in both prototype and reference models. A completed
  sizing/annual run is not validation of those system assumptions.
- The targeted medium-office prototype and corrected reference both report three
  annual warmup-convergence severe errors despite finishing. Their energy totals
  agree within tolerance; this shared upstream initialization issue remains an
  explicit limitation, as recorded in VALIDATION.md.
- Fuels, ventilation, shading/daylight controls, special systems, EMS exceptions,
  assembly thermal mass/absorptance and other project-specific requirements
need review. DefaultFuel is a regional library choice, not inferred proposed fuel.
- Existing unsupported thermostat schedules and ambiguous HVAC availability
  transfer are reported before accepting a replacement result.

`part8_audit.json`, `mapping_audit.json` and Building additional properties record
choices, completion, reference changes and limitations. Only the final modified
model is returned to the Application. Inspect warnings before using it for
compliance. A successful simulation does not establish full Part 8 compliance.

## Skylights and Part 8 daylighting

NECB2020 8.4.4.5.(7) specifies an idealized central square skylight for determining
daylighted area. That lighting calculation should not be interpreted as a blanket
requirement to insert thermal skylights into every reference roof. The complete
daylighting calculation also involves Sentences (5)-(12) and required controls.
See the [official NECB2020, second printing](https://nrc-publications.canada.ca/eng/view/ft/?dp=2&dsl=en&id=af36747e-3eee-4024-a1b4-73833555c7fa),
Division B, printed pages 8-9 to 8-10 (PDF pages 214-215).

- **Replace both groups:** the same NRC generator as the archetype measure creates
  physical skylights on exposed, conditioned, non-plenum flat roofs. Its nominal
  SRR targets are 5% for NECB2011/2015 and 2% for NECB2017/2020. Concave flat roofs
  are decomposed by the library. Each eligible roof's achieved area, construction,
  containment and non-overlap are checked; a silent omission stops generation.
- **Keep either group:** existing thermal skylights are retained or reduced to the
  edition's library SRR limit. New thermal openings are not assumed where absent.
  Roof hatches are not resized as skylights.
- **Attics/plenums:** the default NRC path does not make skylight wells through
  them. The ASHRAE restaurant and small-office fixtures therefore have no physical
  skylights after complete replacement, matching the NRC prototypes. Sloped
  conditioned exposed roofs are unsupported by the default creation routine and
  are reported as an error if its expected skylight area cannot be generated.

The SRR audit reports multiplier-weighted skylight areas/counts, all exterior roof
area, eligible roof area, and treatment for every exterior roof. Neither diagnostic
denominator replaces the **gross insulated roof area** definition in 3.1.1.6.(5).
NECB2020 3.2.1.4.(2) uses *less than* 2%; the library uses a nominal 0.02 boundary.
An exact 2% library output is not presented as proof of literal prescriptive
compliance. The Part 8 lighting-area assumption and a thermal SRR cap are separate
issues. Skylight wells and the full Part 8 daylighting calculation are not
implemented/validated by this adaptation; review is explicitly reported.

## Validation

Annual simulations compare independently generated NECB archetypes with converted
public ASHRAE fixtures using identical weather, edition and fuels, with both input
groups set to Replace. Tests compare total site energy, fuel totals, individual
end uses and skylight area, rather than calibrating efficiencies to annual results.
Restaurant tests also add deliberately incompatible proposed physical inputs and
reapply the measure. See [VALIDATION.md](VALIDATION.md) for results, tolerances,
reproduction commands and known warnings. Prototype agreement does not establish
compliance with every Part 8 clause.

## Install / repair

Copy the complete `create_necb_reference` folder from
`create_necb_reference_openstudio_3.11.zip` into My Measures, for example
`%USERPROFILE%\OpenStudio\Measures` on Windows. Restart OpenStudio after updating.
Use a short extraction path; the bundled library has deeply nested filenames.

Verify the ZIP's SHA-256 against its adjacent `.zip.sha256` file. Back up an older
installation and any locally changed bundled examples before upgrading. Keep the
installed resources in a stable location: generated models reference their EPW.
When sharing a model, supply its weather file separately. macOS/Linux and other
Application/SDK versions have not been validated for this release.

If library files are missing after copying/extraction, keep the ZIP, checksum
and `repair_reference_installation.ps1` together and run that script. It checks
the archive and restores missing dependency files without overwriting existing
files. It repairs an incomplete installation; it does not upgrade old measure
code. For an upgrade, copy the updated first-party files/full release deliberately.

See VALIDATION.md for the tests performed with this version.

## Sources and redistribution

The standalone measure adaptations are distributed under LGPL-3.0-only, following
the [original NRC repository](https://github.com/nrc-cnrc/OpenStudio-Measures/tree/e247ba1dddef1933dc99f894594f5203f28cb4e9).
See `COPYING`, `COPYING.LESSER`, `LICENSE-NRC.txt` and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Bundled dependencies retain their
own licenses. The [pinned standards source](https://github.com/NatLabRockies/openstudio-standards/tree/327689b0fe76331d781120ebc81d0f444f2546ba)
and `resources/dependency_manifest.json` identify the exact public inputs; the
upstream runtime tree is unmodified. No proprietary work models are included.
