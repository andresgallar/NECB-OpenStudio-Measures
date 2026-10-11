# Third-party notices

This is an independent standalone adaptation. NRC, NRCan, NREL and the upstream
authors have not endorsed this release. Their names identify source provenance.

| Component | Pinned source/version | License retained in this distribution |
|---|---|---|
| NRC measures | nrc-cnrc/OpenStudio-Measures, e247ba1dddef1933dc99f894594f5203f28cb4e9 | LGPL v3; `LICENSE-NRC.txt`, `COPYING.LESSER`, accompanying GPL v3 `COPYING` |
| openstudio-standards | nrcan_nrc, 327689b0fe76331d781120ebc81d0f444f2546ba, 0.8.4 | NREL BSD-style terms, copyright, disclaimers and non-endorsement terms in `resources/openstudio-standards/LICENSE.md` |
| git-revision | 1.0.0, Nihad Abbasov | BSD-2-Clause, `resources/gems/git-revision-1.0.0/LICENSE.txt` |
| TBD | 3.6.1, Denis Bourgeois and Dan Macumber | MIT, `resources/gems/tbd-3.6.1/LICENSE.md` |
| OSUT | 0.9.1, Denis Bourgeois | BSD-3-Clause, `resources/gems/osut-0.9.1/LICENSE` |
| Topolys | 0.6.2, Dan Macumber and Denis Bourgeois | MIT, `resources/gems/topolys-0.6.2/LICENSE.md` |
| OSLG | 0.4.0, Denis Bourgeois | BSD-3-Clause, `resources/gems/oslg-0.4.0/LICENSE` |

All bundled library, model geometry, JSON and Canadian EPW/DDY/STAT files are
redistributed from the pinned public standards source, with its existing notices
and file headers. The data are not measurements from a private project.
Hashes and download origins are recorded in `resources/dependency_manifest.json`.
OpenStudio, EnergyPlus and SDK-supplied Ruby dependencies are prerequisites;
their executables are not redistributed in this measure.

Changes relative to the upstream NRC measure include GUI arguments, local
dependency/weather loading, isolated generation and local sizing, reviewed CSV
mapping/default preparation, preservation adapters, complete replacement from
source geometry, canonical SWH lookup names, geometry/orientation checks and
skylight auditing. See `CHANGELOG.md`. The Ruby source for these modifications
is included, and bundled library source remains editable. No additional
restrictions are imposed on rights granted by the included licenses.
