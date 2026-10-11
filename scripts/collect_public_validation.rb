require 'openstudio'
require 'json'
root = File.expand_path('..', __dir__)
matrix = JSON.parse(File.read(File.join(root, 'test-output/public-prototype-matrix/summary.json')))
matrix.select! { |row| row['case'].include?('_NECB2020_') }
raise 'Five passing NECB2020 matrix cases required.' unless matrix.size == 5 && matrix.all? { |row| row['passed'] }
restaurant = JSON.parse(File.read(File.join(root, 'test-output/reference-equivalence/summary.json')))
raise 'Restaurant clean, contaminated and reapplied cases required.' unless %w[prototype clean contaminated reapplied].all? { |key| restaurant.key?(key) }

def diagnostics(directory, allow_warmup: false)
  log = File.read(File.join(directory, 'eplusout.err'))
  sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(File.join(directory, 'eplusout.sql')))
  rows = sql.execAndReturnVectorOfString("SELECT TableName || ' | ' || RowName || ' | ' || ColumnName || ' = ' || Value || ' ' || Units FROM TabularDataWithStrings WHERE lower(TableName) LIKE '%setpoint%not%met%'")
  severe = log.lines.grep(/\*\*\s*Severe\s*\*\*/)
  warmup = severe.grep(/CheckWarmupConvergence: Loads Initialization/)
  data = {'severe_errors' => severe.size, 'warmup_convergence_errors' => warmup.size,
    'severe_error_examples' => severe.map(&:strip),
    'completion' => log.lines.grep(/EnergyPlus Completed Successfully/).map(&:strip),
    'warning_examples' => log.lines.grep(/\*\* Warning \*\*/).map(&:strip).uniq.first(12),
    'setpoint_not_met' => rows.empty? ? [] : rows.get.to_a}
  sql.close
  raise 'Simulation severe/fatal error in release report.' if log.match?(/\*\*\s*Fatal\s*\*\*/) || severe.size != (allow_warmup ? warmup.size : 0)
  data
end

report = {'release' => '1.0.0-rc.1', 'date' => '2026-10-09',
  'environment' => {'os' => 'Windows', 'application' => '1.11.1', 'sdk' => OpenStudio.openStudioVersion, 'energyplus' => '25.2'},
  'standards_commit' => '327689b0fe76331d781120ebc81d0f444f2546ba',
  'tolerances' => {'site_and_fuel_totals' => 'max(0.02 GJ, 0.1%)', 'end_uses' => 'max(0.02 GJ, 0.5%)',
    'restaurant_contamination_and_reapplication' => 'max(0.02 GJ, 0.02%); loop/name-order solver variation is not bitwise reproducible'},
  'matrix' => matrix.sort_by { |row| row['case'] }.map do |row|
    directory = File.join(root, 'test-output/public-prototype-matrix', row['case'])
    row.slice('case', 'fixture', 'mapping_provenance', 'prototype', 'reference', 'passed', 'failures', 'site_energy_difference_percent', 'prototype_skylights').merge(
      'reference_skylights' => row.dig('audit', 'fenestration', 'srr'),
      'reoriented_surfaces' => row.dig('audit', 'reoriented_surfaces'),
      'prototype_diagnostics' => diagnostics(File.join(directory, 'prototype_annual')),
      'reference_diagnostics' => diagnostics(File.join(directory, 'reference_annual')))
  end,
  'restaurant' => restaurant.to_h do |label, values|
    [label, {'energy' => values, 'diagnostics' => diagnostics(File.join(root, 'test-output/reference-equivalence', label + '_annual'))}]
  end}
path = File.join(root, 'measures/create_necb_reference/VALIDATION_RESULTS.json')
medium_path = File.join(root, 'test-output/medium-office-equivalence/summary.json')
if File.file?(medium_path)
  medium = JSON.parse(File.read(medium_path))
  raise 'Targeted medium-office comparison did not pass.' unless medium['passed']
  report['targeted_medium_office_rc2'] = medium.slice('passed', 'prototype', 'reference', 'site_difference_percent', 'spaces', 'air_loops', 'stories', 'plenum_equipment_W', 'known_shared_warmup_errors').merge(
    'date' => '2026-10-10', 'edition' => 'NECB2020', 'weather' => 'Toronto CWEC2020',
    'heating_and_swh_fuel' => 'NaturalGas', 'source' => 'User-provided public-prototype geometry; local model files excluded from release',
    'reference_diagnostics' => diagnostics(File.join(root, 'test-output/medium-office-equivalence/reference_annual'), allow_warmup: true))
end
File.write(path, JSON.pretty_generate(report))
puts "Public validation data: #{path}"
puts report['matrix'].map { |row| [row['case'], row['site_energy_difference_percent']].to_json }
