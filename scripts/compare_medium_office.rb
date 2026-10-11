require 'openstudio'
require 'json'
require 'fileutils'
require_relative '../measures/create_necb_reference/measure'
require_relative 'reference_benchmark_support'

# One targeted annual comparison against an existing prototype run. Inputs and
# generated models remain in local test-output, outside public release assets.
root = File.expand_path('..', __dir__)
source_path, baseline_directory = ARGV
raise 'Usage: compare_medium_office.rb source.osm prototype_run_directory' unless source_path && baseline_directory
output = File.join(root, 'test-output/medium-office-equivalence')
FileUtils.mkdir_p(output)
translator = OpenStudio::OSVersion::VersionTranslator.new
baseline = translator.loadModel(OpenStudio::Path.new(File.join(baseline_directory, 'in.osm'))).get
baseline_log = File.read(File.join(baseline_directory, 'eplusout.err'))
baseline_severe = baseline_log.lines.grep(/\*\*\s*Severe\s*\*\*/)
raise 'Prototype has errors beyond known warmup convergence.' if baseline_log.match?(/\*\*\s*Fatal\s*\*\*/) || baseline_severe.any? { |line| !line.include?('CheckWarmupConvergence: Loads Initialization') }
source = translator.loadModel(OpenStudio::Path.new(source_path)).get
weather_name = File.basename(baseline.weatherFile.get.path.get.to_s.tr('\\', '/'))
weather = File.join(root, 'measures/create_necb_reference/resources/openstudio-standards/data/weather', weather_name)
raise 'Prototype weather is not bundled.' unless File.file?(weather)
baseline_geometry = NECBExistingModelChecks.geometry(baseline)
source_geometry = NECBExistingModelChecks.geometry(source)
# Space names can differ after importing an IDF; compare the geometry entries
# without labels, retaining per-Space volume extents, areas and multipliers.
raise 'Source and prototype geometry differ.' unless baseline_geometry['spaces'].map { |row| row.drop(1) }.sort == source_geometry['spaces'].map { |row| row.drop(1) }.sort && baseline_geometry['north_axis'] == source_geometry['north_axis']
selections = {'necb_template' => 'NECB2020', 'hvac_fuel' => 'NaturalGas', 'swh_fuel' => 'NaturalGas',
              'weather_file' => weather_name, 'default_building_use' => 'Office',
              'operating_inputs' => 'ReplaceWithNECB', 'building_systems' => 'ReplaceWithNECB'}
reference = apply_measure(CreateNECBReference.new, source, selections, File.join(output, 'generation'))
reference.save(OpenStudio::Path.new(File.join(output, 'reference.osm')), true)
raise 'Plenums received occupied equipment loads.' unless reference.getSpaces.reject(&:partofTotalFloorArea).all? { |space| space.electricEquipmentPower.abs < 0.00001 && space.numberOfPeople.abs < 0.00001 }
raise 'Reference air-loop count differs.' unless reference.getAirLoopHVACs.size == baseline.getAirLoopHVACs.size
sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(File.join(baseline_directory, 'eplusout.sql')))
expected = {'total_site_GJ' => sql.totalSiteEnergy.get, 'electricity_GJ' => sql.electricityTotalEndUses.get, 'gas_GJ' => sql.naturalGasTotalEndUses.get}
['Electricity', 'Natural Gas'].each do |fuel|
  ['Heating', 'Cooling', 'Interior Lighting', 'Interior Equipment', 'Fans', 'Pumps', 'Heat Recovery', 'Water Systems'].each do |row|
    value = sql.execAndReturnFirstDouble("SELECT Value FROM TabularDataWithStrings WHERE ReportName='AnnualBuildingUtilityPerformanceSummary' AND TableName='End Uses' AND RowName='#{row}' AND ColumnName='#{fuel}' AND Units='GJ'")
    expected["#{row}:#{fuel}_GJ"] = value.get unless value.empty?
  end
end
sql.close
engine = File.expand_path('../../EnergyPlus/energyplus.exe', OpenStudio.getOpenStudioCLI.to_s)
actual = simulate(reference, weather, engine, File.join(output, 'reference_annual'), allowed_warmup_severes: baseline_severe.size)
reference_severe = File.read(File.join(output, 'reference_annual/eplusout.err')).lines.grep(/\*\*\s*Severe\s*\*\*/)
failures = expected.filter_map do |key, value|
  tolerance = [0.02, value * (key.include?(':') ? 0.005 : 0.001)].max
  "#{key}: #{actual.fetch(key)} vs #{value} (tolerance #{tolerance})" if (actual.fetch(key) - value).abs > tolerance
end
summary = {'passed' => failures.empty?, 'prototype' => expected, 'reference' => actual,
           'site_difference_percent' => 100 * (actual['total_site_GJ'] / expected['total_site_GJ'] - 1),
           'failures' => failures, 'spaces' => reference.getSpaces.size, 'air_loops' => reference.getAirLoopHVACs.size,
           'stories' => reference.getBuilding.standardsNumberOfStories.get,
           'plenum_equipment_W' => reference.getSpaces.reject(&:partofTotalFloorArea).sum(&:electricEquipmentPower),
           'known_shared_warmup_errors' => {'prototype' => baseline_severe.size, 'reference' => reference_severe.size,
             'limitation' => 'Numerical energy comparison passes with shared upstream warmup convergence errors; not a clean annual validation.'}}
File.write(File.join(output, 'summary.json'), JSON.pretty_generate(summary))
puts JSON.pretty_generate(summary)
raise 'Medium office annual comparison failed.' unless failures.empty?
