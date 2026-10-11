# Contributing

Report bugs through the [repository issue tracker](https://github.com/andresgallar/NECB-OpenStudio-Measures/issues). Include the
release version, OpenStudio Application/SDK version, operating system, NECB
edition, weather, mapping choice and both Keep/Replace choices. Include the first
generation error and a small public/synthetic reproduction where possible.
Redact confidential models, paths and credentials before sharing diagnostics.

Keep `resources/openstudio-standards` and `resources/gems` pinned and unmodified.
Put local adaptations outside these trees. Dependency changes must update the
manifest and notices deliberately. Avoid implicit classification guesses or
calibrating equipment to match annual totals. Cite the applicable Code clause
and distinguish its requirements from upstream prototype assumptions.

Run the focused unit tests and relevant workflows from RELEASE.md. Changes to
complete replacement, envelope, loads or systems need the annual public-fixture
comparisons, with unchanged documented tolerances. Update README, CHANGELOG and
VALIDATION, rebuild metadata and check the final ZIP. Contributions to standalone
source are under the repository's LGPL v3 terms; dependencies retain their own
licenses.
