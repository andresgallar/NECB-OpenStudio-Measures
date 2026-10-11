require 'openstudio'
require 'fileutils'
require 'json'
root = File.expand_path('..', __dir__)
measure_file = ENV.fetch('NECB_MEASURE_PATH', File.join(root, 'measures/create_necb_archetype/measure.rb'))
require measure_file
output = File.join(root, 'test-output', ENV.fetch('NECB_TEST_NAME', 'warehouse_necb2020'))
FileUtils.mkdir_p(output)
Dir.chdir(output) do
  # Prove isolation even when a different standards version is loaded by a
  # previous measure in the parent process.
  require 'openstudio-standards'
  model = OpenStudio::Model::Model.new
  measure = CreateNECBArchetype.new
  args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
  selections = {
    'building_type' => ENV.fetch('NECB_BUILDING', 'Warehouse'),
    'necb_template' => ENV.fetch('NECB_TEMPLATE', 'NECB2020'),
    'hvac_fuel' => ENV.fetch('NECB_FUEL', 'NaturalGas')
  }
  selections.each do |key, value|
    argument = args[key].clone
    raise "Invalid test selection #{key}=#{value}" unless argument.setValue(value)
    args[key] = argument
  end
  workflow = OpenStudio::WorkflowJSON.new
  steps = OpenStudio::WorkflowStepVector.new
  steps << OpenStudio::MeasureStep.new('create_necb_archetype')
  workflow.setWorkflowSteps(steps)
  runner = OpenStudio::Measure::OSRunner.new(workflow)
  succeeded = measure.run(model, runner, args)
  result = runner.result
  summary = {
    'success' => succeeded, 'result' => result.value.valueName,
    'sdk' => OpenStudio.openStudioVersion,
    'template' => ENV.fetch('NECB_TEMPLATE', 'NECB2020'),
    'building_type' => ENV.fetch('NECB_BUILDING', 'Warehouse'),
    'heating_fuel' => ENV.fetch('NECB_FUEL', 'NaturalGas'),
    'parent_standards_version' => OpenstudioStandards::VERSION,
    'errors' => result.errors.map(&:logMessage), 'warnings' => result.warnings.map(&:logMessage),
    'spaces' => model.getSpaces.size, 'zones' => model.getThermalZones.size,
    'air_loops' => model.getAirLoopHVACs.size, 'plant_loops' => model.getPlantLoops.size,
    'design_days' => model.getDesignDays.size, 'floor_area_m2' => model.getBuilding.floorArea
  }
  File.write('summary.json', JSON.pretty_generate(summary))
  puts JSON.pretty_generate(summary)
  raise 'Measure smoke test failed' unless succeeded && result.value.valueName == 'Success'
  raise 'Missing model components' unless summary.values_at('spaces', 'zones', 'air_loops', 'design_days').all?(&:positive?)
  raise 'Weather missing' unless model.weatherFile.is_initialized && File.file?(model.weatherFile.get.path.get.to_s)
  properties = model.getBuilding.additionalProperties
  assert_selection = {
    'necb_building_type' => selections.fetch('building_type'),
    'necb_template' => selections.fetch('necb_template'),
    'necb_primary_heating_fuel' => selections.fetch('hvac_fuel')
  }
  assert_selection.each do |key, value|
    raise "Generated model does not match #{key}=#{value}" unless properties.getFeatureAsString(key).get == value
  end
  translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  workspace = translator.translateModel(model)
  raise "Forward translation failed: #{translator.errors.map(&:logMessage)}" unless translator.errors.empty?
  workspace.save(OpenStudio::Path.new('archetype.idf'), true)
  model.save(OpenStudio::Path.new('archetype.osm'), true)
  restored = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new('archetype.osm')).get
  raise 'Saved model lost spaces' unless restored.getSpaces.size == model.getSpaces.size
  raise 'Saved model lost weather' unless File.file?(restored.weatherFile.get.path.get.to_s)
  summary['forward_translation'] = 'passed'
  summary['save_reload'] = 'passed'
  File.write('summary.json', JSON.pretty_generate(summary))
end
