# Run in a fresh CLI process so other measures cannot alter the pinned library.
require 'openstudio'
require 'json'
require 'fileutils'

begin
  request = JSON.parse(File.read(ARGV.fetch(0)))
  data = JSON.parse(File.read(File.join(__dir__, 'dependency_manifest.json')))
  data.fetch('gems').each do |gem|
    $LOAD_PATH.unshift(File.join(__dir__, 'gems', "#{gem['name']}-#{gem['version']}", 'lib'))
  end
  require File.join(__dir__, 'openstudio-standards/lib/openstudio-standards.rb')
  require_relative 'local_sizing'
  standard = Standard.build(request.fetch('template'))
  standard.singleton_class.prepend(LocalNECBSizing)
  standard.instance_variable_set(:@local_sizing_root, request.fetch('run_directory'))
  if request['sideload']
    Dir[File.join(__dir__, 'data_sideload/*.json')].sort.each do |file|
      override = JSON.parse(File.read(file))
      sections = override.keys & %w[tables formulas constants]
      raise "No tables, formulas or constants in #{File.basename(file)}" if sections.empty?
      sections.each do |section|
        raise "#{section} must be an object in #{File.basename(file)}" unless override[section].is_a?(Hash)
        standard.standards_data[section].merge!(override.fetch(section))
      end
      standard.corrupt_standards_database
    end
  end
  weather_path = request.fetch('weather_path')
  # Upstream copies custom weather into its library. Keep the bundle read-only
  # by using weather staged in the generation directory instead.
  standard.define_singleton_method(:apply_weather_data) do |model:, **_options|
    model_temp_fix_ems_references(model)
    model.getYearDescription.setDayofWeekforStartDay('Sunday')
    result = OpenstudioStandards::Weather.model_set_building_location(model, weather_file_path: weather_path)
    raise 'Could not set model weather and design days' unless result
  end
  generated = standard.model_create_prototype_model(
    template: request.fetch('template'), building_type: request.fetch('building_type'),
    epw_file: File.basename(weather_path), sizing_run_dir: request.fetch('run_directory'),
    primary_heating_fuel: request.fetch('primary_heating_fuel'),
    swh_fuel: request.fetch('swh_fuel') == 'DefaultFuel' ? nil : request.fetch('swh_fuel')
  )
  raise 'Standards generation returned no model' unless generated.is_a?(OpenStudio::Model::Model)
  raise 'Generated model has no spaces or HVAC' if generated.getSpaces.empty? || generated.getAirLoopHVACs.empty?
  generated.resetSqlFile
  generated.getBuilding.additionalProperties.setFeature('necb_standards_commit', request.fetch('standards_commit'))
  generated.getBuilding.additionalProperties.setFeature('necb_building_type', request.fetch('building_type'))
  generated.getBuilding.additionalProperties.setFeature('necb_template', request.fetch('template'))
  generated.getBuilding.additionalProperties.setFeature('necb_primary_heating_fuel', request.fetch('primary_heating_fuel'))
  raise 'Could not save generated model' unless generated.save(OpenStudio::Path.new(request.fetch('output_model')), true)
  File.write(request.fetch('status_file'), JSON.pretty_generate({
    'success' => true, 'sdk' => OpenStudio.openStudioVersion,
    'spaces' => generated.getSpaces.size, 'thermal_zones' => generated.getThermalZones.size,
    'air_loops' => generated.getAirLoopHVACs.size, 'plant_loops' => generated.getPlantLoops.size,
    'floor_area_m2' => generated.getBuilding.floorArea,
    'standards_commit' => request.fetch('standards_commit')
  }))
rescue StandardError, LoadError => e
  if defined?(request) && request
    File.write(request.fetch('status_file'), JSON.pretty_generate({
      'success' => false, 'error' => "#{e.class}: #{e.message}", 'backtrace' => e.backtrace.first(12)
    }))
  end
  warn "#{e.class}: #{e.message}"
  exit 1
end
