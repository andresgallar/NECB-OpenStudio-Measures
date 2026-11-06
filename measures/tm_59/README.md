# CIBSE TM59 Overheating Metrics

Version 1.0.0 is an OpenStudio reporting measure for thermal-zone overheating results from an annual EnergyPlus simulation.

| Edition | Scope |
| --- | --- |
| **2017** (default) | Criteria A and B for predominantly naturally ventilated dwellings. A uses simulated People schedules. B counts annual hours above 26 °C from 22:00 to 07:00. |
| **2026** | Criteria A, B, C and D at their base temperature thresholds. A, C and D use the prescribed occupancy windows. B counts nights above the category-specific mean temperature limit. |

This independent implementation reports metrics for one simulation and its selected rooms. The modeller is responsible for defining assessment stages, selecting compliant weather, setting up schedules, loads and ventilation, and completing the applicable compliance documentation. CIBSE currently identifies the 2017 edition for Approved Document O and recommends the 2026 edition for current design practice. [CIBSE TM59:2026](https://www.cibse.org/knowledge-research/knowledge-portal/tm59-overheating-risk-in-dwellings-a-design-stage-methodology-2026)

## Install and run

1. Copy the entire **tm_59** folder into your OpenStudio Measures directory. Keep both files in **resources** alongside the measure.
2. Add **CIBSE TM59 Overheating Metrics** as a **Reporting Measure** before running the workflow. Use one weather run period from January 1 through December 31. The measure requests the EnergyPlus zone timestep outputs it needs.
3. Set the edition and comfort category. Use Category II for typical occupants or Category I for vulnerable occupants. Then fill the room fields for this simulation.

## Select rooms in OpenStudio

1. Open **Thermal Zones** in the OpenStudio Application and copy the **Name** of each zone you want to assess. You can check the zone assigned to a room on the **Spaces** tab. Use a separate thermal zone for rooms that need different criteria.
2. Return to the measure and paste each name into the field for its room use and ventilation strategy. Separate multiple names with commas. Put double quotes around an entire name that contains a comma, for example `Bedroom 1, "Unit 2, Bedroom"`. Copy names as shown, including capitalisation.
3. Fill at least one room field and put each selected zone in one group. Leave fields blank for room groups outside this run. The mechanical and communal fields apply in 2026 mode. For 2017, use the first two fields for naturally ventilated living rooms, kitchens and bedrooms.

| Measure field | Example entry | Criteria |
| --- | --- | --- |
| Naturally ventilated living rooms, kitchens and home offices | `Living Room, Kitchen` | A. Home offices apply in 2026. |
| Naturally ventilated bedrooms | `Bedroom 1, Bedroom 2` | A and B |
| Mechanical or cooled living rooms, kitchens and home offices (2026) | `Cooled Lounge` | C |
| Mechanical or cooled bedrooms (2026) | `Bedroom 3` | B and C |
| Shared corridors, stairs and lobbies (2026) | `Shared Corridor` | D |

**Reuse a Space Type across models.** If several rooms use a dedicated Space Type, enter `type=Bedrooms` in the relevant bedroom field, replacing `Bedrooms` with the exact Space Type name shown in **Spaces**. This selects every thermal zone whose spaces all use that Space Type. Use a type dedicated to the same room use and ventilation strategy for this run. You can combine selectors and names, for example `type=Bedrooms, Guest Bedroom`. For a literal zone name starting with `type=` or `zone=`, prefix it with `zone=`.

**Saved workflows that use JSON.** Keep the existing `zone_types` value in **Existing JSON room map (optional)** and leave all room fields blank. Its keys are exact thermal zone names. Allowed values are `living_kitchen` and `bedroom`, plus `living_kitchen_mechanical`, `bedroom_mechanical`, and `communal` in 2026. New workflows can use the room fields directly.

The 2017 bedroom hours use the simulation clock.

In 2026 mode, use **Local** if the simulation output clock already represents local summer time. Use **GMT** if UK output timestamps are in GMT. The report then adds one hour for the summer assessment and the April outdoor temperatures used to seed it. Confirm the timestamp convention against your model and weather setup. The report records the offset, and the CSV records interval starts on the original simulation clock.

## How results are calculated

- **A** counts occupied May–September timesteps whose operative temperature difference from the adaptive upper limit rounds to at least 1 K. The limit is 3% of occupied time. 2026 mode bounds the outdoor running mean used in the threshold formula to 10–30 °C and uses the TM59:2026 April seed. In 2017 mode, a positive simulated zone occupant count defines occupancy, and January–April provides spin-up.
- **B in 2017** uses the strict >26 °C comparison and the exact 1% limit on annual bedroom time from 22:00 to 07:00. In a 365-day year this is 32.85 hours, so 33 hours fails.
- **B in 2026** uses the mean temperature from 23:00 through 08:00 the next day. Each night is assigned to its start date from May 1 through September 30. A bedroom passes with up to four nights above 26 °C in Category I or 27 °C in Category II.
- **C and D in 2026** count occupied May–September time strictly above 26 °C and 28 °C respectively, with a limit of 3%. For A, C and D, the 2026 occupancy windows are 09:00–22:00 for living rooms, kitchens and home offices and 24 hours for bedrooms and communal circulation. A and C use zero ceiling-fan uplift.

See [TM59:2017](https://www.cibse.org/knowledge-research/knowledge-portal/technical-memorandum-59-design-methodology-for-the-assessment-of-overheating-risk-in-homes), [TM59:2026, section 2.4 and Table 2](https://www.cibse.org/knowledge-research/knowledge-portal/tm59-overheating-risk-in-dwellings-a-design-stage-methodology-2026), [CIBSE weather guidance](https://www.cibse.org/weatherdata).

## Outputs

- **report.html** contains a per-zone table and an offline scatter plot of occupied Criterion A timesteps from May 1 through September 30. **report_tm59_timesteps.csv** contains the full annual timestep data. The OpenStudio CLI also collects the reports with a measure-name prefix. In 2026 mode, each nightly mean and its Criterion B flag appear on the first timestep of the night.
- The HTML report runs its chart offline and escapes zone labels. The CSV quotes zone labels, and names that could be read as spreadsheet formulas get a `TM59 text: ` prefix. The audit checker resolves those labels back to their SQL names. Review generated reports before sharing them, as they contain zone names and simulation results.
- For **A, C and D**, `tm_crit_<letter>_hours` and `tm_crit_<letter>_pct` represent the room with the highest exceedance percentage. Hours break ties. For **B**, `tm_crit_b_hours` in 2017 or `tm_crit_b_nights` in 2026 represents the bedroom with the most exceedance.
- `tm_crit_<letter>_pass` reports **Fail** if any applicable selected room fails, **Pass** if all applicable selected rooms pass, and **N/A** if the criterion has no applicable selected room. Numeric values for an inapplicable criterion are omitted.
- `tm_hours_over_twenty_six_c`, `tm_hours_over_twenty_seven_c` and `tm_hours_over_twenty_eight_c` are the maximum May–September hours across selected zones above each temperature, including unoccupied time. They are diagnostics.

## Validation

The supported release configuration is OpenStudio SDK 3.11.0 with EnergyPlus 25.2 on Windows. Run the following commands from this folder with the OpenStudio CLI on your path.

~~~powershell
openstudio tests/TM59Metrics_Test.rb
openstudio tests/ExampleReport_Test.rb
~~~

The calculation tests use controlled hourly and ten-minute sequences to check thresholds, time windows and overnight means. The workflow tests generate small models and run the complete OpenStudio/EnergyPlus workflow for both editions. The bundled Golden, Colorado TMY3 file (station 724666) is a test fixture from the [NREL weather data collection](https://data.nlr.gov/submissions/128).

See the [validation record](VALIDATION.md) for the independent EnergyPlus SQL audit, the published reference comparison and instructions to audit your own results. The package includes the measure's [license](LICENSE.md).
