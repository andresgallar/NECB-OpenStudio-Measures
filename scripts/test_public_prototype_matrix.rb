# Public fixtures only. Test mappings follow the matching spaces in the pinned
# NRC shells, not room-name inference in the released measure.
require 'openstudio'
require 'json'
require 'csv'
require 'fileutils'
root = File.expand_path('..', __dir__)
require File.join(root, 'measures/create_necb_reference/measure')
require File.join(root, 'measures/create_necb_reference/resources/skylight_checks')
require File.join(root, 'measures/create_necb_archetype/measure')
require_relative 'reference_benchmark_support'
resources = File.join(root, 'measures/create_necb_reference/resources')
library = File.join(resources, 'openstudio-standards')
output = File.join(root, 'test-output/public-prototype-matrix')
FileUtils.mkdir_p(output)
engine = File.expand_path('../../EnergyPlus/energyplus.exe', OpenStudio.getOpenStudioCLI.to_s)
raise "Missing EnergyPlus: #{engine}" unless File.file?(engine)
cases = [
  ['Warehouse', 'ASHRAE90120102013Warehouse.osm', 'NECB2020', 'Toronto'],
  ['RetailStandalone', 'ASHRAE9012013RetailStandalone.osm', 'NECB2020', 'Toronto'],
  ['SmallOffice', 'ASHRAESmallOffice.osm', 'NECB2020', 'Toronto'],
  ['QuickServiceRestaurant', 'ASHRAEQuickServiceRestaurant.osm', 'NECB2020', 'Toronto'],
  ['Warehouse', 'ASHRAE90120102013Warehouse.osm', 'NECB2020', 'Calgary']
]
results = if ENV['NECB_BENCHMARK_CASE'] && File.file?(File.join(output, 'summary.json'))
            JSON.parse(File.read(File.join(output, 'summary.json'))).reject { |row| row['case'] == ENV['NECB_BENCHMARK_CASE'] }
          else
            []
          end
cases.each do |building, fixture, edition, city|
  name = [building, edition, city].join('_')
  next if ENV['NECB_BENCHMARK_CASE'] && name != ENV['NECB_BENCHMARK_CASE']
  directory = File.join(output, name)
  FileUtils.mkdir_p(directory)
  record = {'case' => name, 'fixture' => fixture, 'mapping_provenance' => "Pinned NECB2011/data/geometry/#{building}.osm matched public spaces"}
  begin
    weather = Dir[File.join(library, 'data/weather', "*#{city}*CWEC2020.epw")].first
    raise "No bundled #{city} weather" unless weather
    selections = {'necb_template' => edition, 'hvac_fuel' => 'NaturalGas', 'swh_fuel' => 'DefaultFuel', 'weather_file' => File.basename(weather)}
    source = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(File.join(library, 'data/geometry', fixture))).get
    shell = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(File.join(library, 'lib/openstudio-standards/standards/necb/NECB2011/data/geometry', building + '.osm'))).get
    raise 'Public fixture and NRC shell geometry differ; energy equivalence is not a valid assertion.' unless NECBExistingModelChecks.geometry_hash(source) == NECBExistingModelChecks.geometry_hash(shell)
    assignments = source.getSpaces.group_by { |space| space.spaceType.get.nameString }.to_h do |type_name, spaces|
      pairs = spaces.map { |space| NECBSpaceTypeMapping.pair(shell.getSpaceByName(space.nameString).get.spaceType.get) }.uniq
      raise "Ambiguous test mapping: #{type_name}" unless pairs.size == 1
      [type_name, [NECBSpaceTypeMapping.pair(spaces.first.spaceType.get), pairs.first]]
    end
    mapping = File.join(directory, 'reviewed_public_fixture_mapping.csv')
    CSV.open(mapping, 'w') do |csv|
      csv << NECBSpaceTypeMapping::HEADERS
      assignments.each { |name, (source_pair, target_pair)| csv << [name, *source_pair, 'NECB2011', *target_pair, ''] }
    end
    # Independent prototype generation; no geometry is substituted into source.
    prototype = apply_measure(CreateNECBArchetype.new, OpenStudio::Model::Model.new, selections.merge('building_type' => building), File.join(directory, 'prototype_generation'))
    reference = apply_measure(CreateNECBReference.new, source, selections.merge('operating_inputs' => 'ReplaceWithNECB', 'building_systems' => 'ReplaceWithNECB', 'mapping_preset' => 'None', 'mapping_csv_path' => mapping), File.join(directory, 'reference_generation'))
    [prototype, reference].zip(%w[prototype reference]).each { |model, label| model.save(OpenStudio::Path.new(File.join(directory, label + '.osm')), true) }
    record['prototype'] = simulate(prototype, weather, engine, File.join(directory, 'prototype_annual'))
    record['reference'] = simulate(reference, weather, engine, File.join(directory, 'reference_annual'))
    record['audit'] = JSON.parse(reference.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit').get)
    prototype_sky = NECBSkylightChecks.summary(NECBSkylightChecks.roofs(prototype))
    record['prototype_skylights'] = prototype_sky
    reference_sky = record.dig('audit', 'fenestration', 'srr', 'all_exterior_roofs_after')
    raise 'Skylight area differs from independent prototype.' unless (reference_sky['skylight_area_m2'] - prototype_sky['skylight_area_m2']).abs < 0.0001
    failures = record['prototype'].filter_map do |key, expected|
      tolerance = [0.02, expected * (key.include?(':') ? 0.005 : 0.001)].max
      "#{key}: #{record['reference'][key]} vs #{expected} (tolerance #{tolerance})" if (record['reference'].fetch(key) - expected).abs > tolerance
    end
    record['site_energy_difference_percent'] = 100 * (record['reference']['total_site_GJ'] / record['prototype']['total_site_GJ'] - 1)
    record['failures'] = failures
    record['passed'] = failures.empty?
  rescue StandardError => error
    record['passed'] = false
    record['error'] = "#{error.class}: #{error.message}"
  end
  results << record
  File.write(File.join(directory, 'result.json'), JSON.pretty_generate(record))
  File.write(File.join(output, 'summary.json'), JSON.pretty_generate(results))
  puts "#{name}: #{record['passed'] ? 'PASS' : 'FAIL'}; site difference #{record['site_energy_difference_percent']}%; #{record['error']}"
  STDOUT.flush
end
raise 'One or more public prototype benchmarks failed; inspect summary.json.' unless results.all? { |r| r['passed'] }
