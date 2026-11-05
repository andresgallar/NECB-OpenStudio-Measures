# TM59 release validation

**Release v1.0.0** · November 4, 2026 · Windows, OpenStudio Application 1.11.1 / SDK 3.11.0 and EnergyPlus 25.2

The measure is an independent post-processor for thermal-zone temperatures. The validation covers the calculations and workflow for 2017 natural-ventilation Criteria A and B and 2026 Criteria A–D at their base thresholds.

## Independent checks

| Reference | Coverage | Result |
| --- | --- | --- |
| University of Bath published daily outdoor, running-mean and adaptive-limit data | 153 dates from May 1 through September 30 | The 2017 Category II running mean and upper limit matched every published value within 0.000001 °C. A constant 27 °C bedroom test signal exceeded the published limits for 1,248 of 3,672 hours under the measure's Criterion A rounding rule. |
| Raw EnergyPlus SQL from a generated annual OpenStudio model, 2017 mode | 105,120 ten-minute records across two rooms | The independent calculation matched timestep flags and all registered metrics. The living room had 1,097 adaptive exceedance hours of 1,989 occupied hours. The bedroom recorded 20 hours 20 minutes above 26 °C overnight. |
| Raw EnergyPlus SQL from a generated annual OpenStudio model, 2026 mode | 210,240 ten-minute records across four zones, with GMT-to-local assessment alignment | The independent calculation matched timestep flags, all bedroom night means and all registered metrics. The mechanical bedroom had 1,441 hours 50 minutes above 26 °C under C. The corridor had 1,201 hours 10 minutes above 28 °C under D. |

The SQL checker reads raw weather, operative temperature and, for 2017, occupancy directly from the EnergyPlus database. It reconstructs interval starts from SQL timestamps and evaluates the adaptive history using a weighted sum. It compares those calculations with the timestep CSV and, when supplied, the OpenStudio workflow outputs. Zone classifications come from the report. The Ruby tests also exercise threshold boundaries, cross-midnight nights, input errors, report collection and scatter plot scope.

The public package is checked against a file allowlist. The security tests cover spreadsheet-formula prefixes, quoted CSV zone labels, HTML escaping and the report's content security policy. The HTML chart runs without network dependencies, and the audit checker opens its EnergyPlus database read-only.

## Reproduce

Run from this folder with OpenStudio 3.11.0 and Python 3.10 or later on your path. Python uses only its standard library and is required only for the optional audit.

~~~powershell
openstudio tests/TM59Metrics_Test.rb
$env:TM59_AUDIT_PYTHON = (Get-Command python.exe).Source
openstudio tests/ExampleReport_Test.rb
Remove-Item Env:TM59_AUDIT_PYTHON
~~~

To audit an existing run, supply its EnergyPlus SQL and the matching TM59 timestep CSV. Match the edition, category and clock to the inputs used to produce the report. Add `--out-osw` to verify the registered summary values.

~~~powershell
python tests/audit_energyplus_sql.py 'path/to/run/eplusout.sql' 'path/to/report_tm59_timesteps.csv' --edition 2026 --category II --clock Local --out-osw 'path/to/out.osw'
~~~

## Reference data and scope

The bundled daily fixture is derived from Rachel Mitchell and Sukumar Natarajan (2020), *Dataset for “Overheating Risk in Passivhaus Dwellings”*, University of Bath Research Data Archive, CC BY 4.0. It retains the date and the three published outdoor/adaptive columns for Site 1, series S01.01L, LR1, May–September 2014. The test anchors the running mean to the published May 1 value by supplying a constant pre-season outdoor series. The 27 °C test signal is synthetic. [Source dataset](https://doi.org/10.15125/BATH-00774) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

The 2026 calculation uses the exact 3% criterion at the simulated timestep resolution. The whole-hour examples in Table 2 are 59 hours for 1,989 occupied hours and 110 hours for 3,672 occupied hours. A comparison against a tool that applies those whole-hour caps to fractional durations can differ near the threshold. [CIBSE TM59:2026, section 2.4 and Table 2](https://www.cibse.org/knowledge-research/knowledge-portal/tm59-overheating-risk-in-dwellings-a-design-stage-methodology-2026)

A matched UK residential model comparison using licensed CIBSE Design Summer Year weather and a separate compliance tool remains open. The tests check the reporting calculations against temperatures supplied to the measure. Assessment stages, weather selection, ventilation assumptions and project compliance documentation remain the modeller's responsibility. [CIBSE weather data](https://www.cibse.org/weatherdata)
