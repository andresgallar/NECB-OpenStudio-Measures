require 'openstudio'
require 'json'
require 'fileutils'
root = File.expand_path('..', __dir__)
measure_file = ENV.fetch('NECB_REFERENCE_MEASURE', File.join(root, 'measures/create_necb_reference/measure.rb'))
require measure_file
resources = File.join(File.dirname(measure_file), 'resources')
manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
manifest['gems'].each { |gem| $LOAD_PATH.unshift(File.join(resources, 'gems', "#{gem['name']}-#{gem['version']}", 'lib')) }
require File.join(resources, 'openstudio-standards/lib/openstudio-standards.rb')
require File.join(resources, 'reference_options')
mode = ENV.fetch('NECB_OPTIONS_CASE', 'missing')
if %w[missing defaults_only replace_all].include?(mode)
  model = OpenStudio::Model::Model.new
  points = OpenStudio::Point3dVector.new
  [[0,0,0], [0,10,0], [10,10,0], [10,0,0]].each { |p| points << OpenStudio::Point3d.new(*p) }
  space = OpenStudio::Model::Space.fromFloorPrint(points, 3, model).get
  space.setName('Design room with no classifications or zone')
  selections = {'default_building_use' => 'Office', 'operating_inputs' => mode == 'replace_all' ? 'ReplaceWithNECB' : 'KeepExisting', 'building_systems' => mode == 'defaults_only' ? 'KeepExisting' : 'ReplaceWithNECB'}
else
  source = File.join(root, 'test-output/part8_swh/reference.osm')
  raise 'Run smoke_part8 with NECB_PART8_SWH_TEST=true first.' unless File.file?(source)
  model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(source)).get
  model.getWaterHeaterMixeds.each { |heater| heater.setHeaterMaximumCapacity(12345); heater.setTankVolume(0.234) }
  model.getSpaceInfiltrationDesignFlowRates.each { |item| item.setDesignFlowRate(0.0123); item.setVelocityTermCoefficient(0.123) }
  process = model.getElectricEquipmentByName('Proposed custom process load').get
  selections = {'operating_inputs' => mode == 'retain' ? 'KeepExisting' : 'ReplaceWithNECB', 'building_systems' => 'KeepExisting'}
  inspector = Object.new.extend(NECBReferenceOptions)
  inspector.instance_variable_set(:@keep_operating, mode == 'retain')
  before_systems = NECBExistingModelChecks.system_signature(model, include_water_demand: mode == 'retain')
end
before = NECBExistingModelChecks.geometry_hash(model)
zones = model.getSpaces.to_h { |space| [space.nameString, space.thermalZone.empty? ? nil : space.thermalZone.get.nameString] }
types = model.getSpaces.to_h { |space| [space.nameString, space.spaceType.empty? ? nil : [space.spaceType.get.nameString, NECBSpaceTypeMapping.pair(space.spaceType.get)]] }
output = File.join(root, 'test-output', "options_#{mode}")
FileUtils.mkdir_p(output)
Dir.chdir(output) do
  measure = CreateNECBReference.new
  args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
  selections.merge('weather_file' => 'CAN_ON_Toronto.Intl.AP.716240_CWEC2020.epw', 'hvac_fuel' => 'NaturalGas').each do |name, value|
    argument = args[name].clone
    raise "Invalid #{name}" unless argument.setValue(value)
    args[name] = argument
  end
  runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
  success = measure.run(model, runner, args)
  summary = {success: success, errors: runner.result.errors.map(&:logMessage), warnings: runner.result.warnings.map(&:logMessage)}
  File.write('summary.json', JSON.pretty_generate(summary))
  raise summary[:errors].join('; ') unless success
  raise 'Space geometry changed' unless before == NECBExistingModelChecks.geometry_hash(model)
  zones.each { |name, zone| raise 'Existing zone changed' if zone && model.getSpaceByName(name).get.thermalZone.get.nameString != zone }
  types.each { |name, type| raise 'Compatible classification changed' if type && type != [model.getSpaceByName(name).get.spaceType.get.nameString, NECBSpaceTypeMapping.pair(model.getSpaceByName(name).get.spaceType.get)] }
  if %w[missing defaults_only replace_all].include?(mode)
    raise 'Missing zone/type not supplied' if model.getSpaces.any? { |space| space.spaceType.empty? || space.thermalZone.empty? }
    raise 'Missing default occupancy' if model.getPeoples.empty?
    raise 'Missing generated HVAC' if mode != 'defaults_only' && model.getAirLoopHVACs.empty?
    raise 'Keep systems unexpectedly added HVAC' if mode == 'defaults_only' && !model.getAirLoopHVACs.empty?
    raise 'Missing default windows' if model.getSubSurfaces.empty?
  else
    actual = NECBExistingModelChecks.system_signature(model, include_water_demand: mode == 'retain')
    before_systems.each do |handle, value|
      next if actual[handle] == value
      File.write('retained_system_diff.json', JSON.pretty_generate(key: handle, expected: value, actual: actual[handle]))
      raise "Existing system changed #{handle}"
    end
    if mode == 'retain'
      retained = model.getElectricEquipmentByName('Proposed custom process load').get
      raise 'Retained process load changed' unless retained.electricEquipmentDefinition.designLevel.get == 1234
    else
      raise 'Custom process load was not replaced' unless model.getElectricEquipmentByName('Proposed custom process load').empty?
    end
  end
  translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  translator.translateModel(model)
  raise 'Translation failed' unless translator.errors.empty?
  model.save(OpenStudio::Path.new('result.osm'), true)
  audit = JSON.parse(model.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit').get)
  summary.merge!(mode: mode, geometry_preserved: true, existing_assignments_retained: true, audit: audit)
  File.write('summary.json', JSON.pretty_generate(summary))
  puts "Reference input choices passed: #{mode}"
end
