# Changelog

## 1.0.0-rc.2 — 2026-10-10

- Remove the individual restaurant selector. Automatic translation combines exact
  reviewed classifications across 15 public prototype families, per Space Type.
- Assign unmatched/conflicting uses to `Space Function / - undefined -` with a
  warning and exported review CSV. Keep a strict compatible-types/CSV alternative.
- Allow explicit CSV corrections to translated or compatible assignments; retain
  source provenance so an exported CSV also works on the returned model.
- Document partial mapping coverage and wildcard limitations. Remove Standalone
  from both measure display names while preserving folder names, classes and UIDs.
- Reuse the NECB2020 annual baseline; perform focused input/mapping and packaged
  generation checks rather than repeating the annual matrix. Bundled standards
  dependencies are unchanged.
- Fix full replacement of proposed GroundFCfactorMethod surfaces: reset their
  shell boundary to Ground so NECB constructions/foundation treatment can be
  assigned before sizing. Audit the conversion and preserve geometry.
- Include the underlying EnergyPlus severe error and actual sizing output path
  when the upstream exception misleadingly reports a DX-coil sizing failure.
- Avoid occupied default gains in unclassified excluded-floor-area Spaces;
  exclude explicitly designated unclassified HVAC plenums and omit separate
  plenum levels when inferring occupied story counts.
- Recover missing uses/stories from unique complete reviewed public-shell
  geometry matches, independent of room names. Repair documented measure-owned
  defaults during full replacement while retaining supplied classifications.
- Replace enclosed adiabatic F-factor slab-core approximations using coplanar
  edge contact and recorded F-factor context; retain unrelated adiabatic floors.
- Verify the reported NECB2020 medium-office case against its prototype annual
  run: 2041.20 versus 2041.94 GJ/year (0.036%); fuel totals and end uses pass.
  Record the three warmup-convergence severe errors shared by both models;
  recognize EnergyPlus severity labels with variable whitespace in test logs.

## 1.0.0-rc.1 — 2026-10-09

Initial public release candidate for OpenStudio Application 1.11.1 / SDK 3.11.0.

- Bundle the pinned public NRC standards runtime, supporting gems and 15 Canadian
  weather sets; remove the custom OpenStudio Server dependency.
- Return one model; support independent Keep/Replace choices for operating inputs
  and HVAC/SWH/infiltration. Preserve selected existing data and supply absent
  defaults without stacking loads.
- Require existing Spaces; prepare missing types, zones and stories. Retain valid
  NECB/BTAP classifications and accept exact reviewed presets or custom CSVs.
- Rebuild both groups from a clean shell when complete replacement is selected;
  retain source geometry, not stock prototype geometry. Restore compatible labels
  after canonical library/SWH lookups. Follow and disclose legacy NRC upgrade
  choices, including one-to-many office/storage classifications.
- Repair reversed shell faces without moving vertices, avoiding erroneous SDK
  fallback volumes in the public ASHRAE warehouse fixture.
- Preserve proportional facade shares in Keep workflows; include opaque doors
  in FDWR. Separate prototype infiltration from NECB2020 preservation leakage.
- Audit physical skylights by roof and multiplier; verify full-rebuild creation,
  constructions and valid polygons. Reject silent creation failures. Exclude
  opaque roof hatches from skylight caps. Document attic/plenum/sloped-roof and
  Part 8 daylighting limitations.
- Add public-fixture annual comparisons, portable release checks, license texts,
  third-party notices and release instructions. Retain measure UID for upgrades.

This candidate is suitable for public evaluation. It is not a verified complete
implementation of NECB Part 8; see README and VALIDATION for supported scope.
