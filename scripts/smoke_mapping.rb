require 'openstudio'
require 'fileutils'
require 'json'
require 'digest'
require 'csv'

root = File.expand_path('..', __dir__)
measure_file = ENV.fetch('NECB_REFERENCE_MEASURE', File.join(root, 'measures/create_necb_reference/measure.rb'))
require measure_file
mode = ENV.fetch('NECB_MAPPING_TEST_MODE', 'preset')
output = File.join(root, 'test-output', "mapping_#{mode}")
FileUtils.mkdir_p(output)
Dir.chdir(output) do
  resources = File.join(File.dirname(measure_file), 'resources')
  input = File.join(resources, 'openstudio-standards/data/geometry/ASHRAEFullServiceRestaurant.osm')
  input_sha = Digest::SHA256.file(input).hexdigest
  model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(input)).get
  original_geometry = NECBExistingModelChecks.geometry_hash(model)
  expected = JSON.parse(File.read(File.join(resources, 'mapping_presets.json'))).fetch('ASHRAEFullServiceRestaurant').fetch('mappings')
  csv_path = File.join(output, 'custom_mapping.csv')
  if mode == 'csv'
    # Simulate custom names with no standards metadata, using the same geometry.
    rows = NECBSpaceTypeMapping.used_types(model).map do |type|
      row = expected.find { |entry| NECBSpaceTypeMapping.pair(type) == entry.values_at('source_building_type', 'source_space_type') }
      raise 'Unexpected public source type' unless row
      type.setName("Custom #{row.fetch('source_space_type')}")
      type.resetStandardsBuildingType
      type.resetStandardsSpaceType
      [type.nameString, *NECBSpaceTypeMapping.pair(type), row.fetch('necb_vintage'), row.fetch('necb_building_type'), row.fetch('necb_space_type'), '']
    end
    CSV.open(csv_path, 'w') { |csv| csv << NECBSpaceTypeMapping::HEADERS; rows.each { |row| csv << row } }
  end
  model.save(OpenStudio::Path.new('proposed.osm'), true)
  before_sha = Digest::SHA256.file('proposed.osm').hexdigest
  require 'openstudio-standards'
  measure = CreateNECBReference.new
  args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
  selections = {'mapping_preset' => mode == 'csv' ? 'None' : 'AutoReviewed',
                'operating_inputs' => 'ReplaceWithNECB',
                'weather_file' => 'CAN_ON_Toronto.Intl.AP.716240_CWEC2020.epw',
                'hvac_fuel' => 'NaturalGas', 'necb_template' => 'NECB2020'}
  selections['mapping_csv_path'] = csv_path if mode == 'csv'
  selections.each do |key, value|
    argument = args[key].clone
    raise 'Invalid test selection' unless argument.setValue(value)
    args[key] = argument
  end
  workflow = OpenStudio::WorkflowJSON.new
  steps = OpenStudio::WorkflowStepVector.new
  steps << OpenStudio::MeasureStep.new('create_necb_reference')
  workflow.setWorkflowSteps(steps)
  runner = OpenStudio::Measure::OSRunner.new(workflow)
  success = measure.run(model, runner, args)
  summary = {'success' => success, 'result' => runner.result.value.valueName,
             'sdk' => OpenStudio.openStudioVersion, 'mode' => mode,
             'errors' => runner.result.errors.map(&:logMessage), 'warnings' => runner.result.warnings.map(&:logMessage),
             'spaces' => model.getSpaces.size, 'zones' => model.getThermalZones.size,
             'air_loops' => model.getAirLoopHVACs.size, 'floor_area_m2' => model.getBuilding.floorArea}
  File.write('summary.json', JSON.pretty_generate(summary))
  puts JSON.pretty_generate(summary)
  raise 'Mapped reference generation failed' unless success && runner.result.value.valueName == 'Success'
  raise 'Changed public input' unless Digest::SHA256.file(input).hexdigest == input_sha
  raise 'Changed staged proposed input' unless Digest::SHA256.file('proposed.osm').hexdigest == before_sha
  raise 'Changed source geometry' unless NECBExistingModelChecks.geometry_hash(model) == original_geometry
  audit = JSON.parse(model.getBuilding.additionalProperties.getFeatureAsString('necb_space_type_mapping_audit').get)
  raise 'Missing mapping audit' unless audit.size == 3 && audit.all? { |entry| entry['method'] == (mode == 'csv' ? 'csv' : 'preset:ASHRAEFullServiceRestaurant') }
  raise 'Wrong output edition' unless model.getBuilding.standardsTemplate.get == 'NECB2020'
  translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  translated = translator.translateModel(model)
  raise 'Forward translation errors' unless translator.errors.empty?
  translated.save(OpenStudio::Path.new('reference.idf'), true)
  model.save(OpenStudio::Path.new('reference.osm'), true)
  restored = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new('reference.osm')).get
  raise 'Reload changed geometry' unless NECBExistingModelChecks.geometry_hash(restored) == original_geometry
  raise 'Weather file missing after reload' unless File.file?(restored.weatherFile.get.path.get.to_s)
  catalog = JSON.parse(File.read(File.join(resources, 'space_type_catalog.json')))
  presets = JSON.parse(File.read(File.join(resources, 'mapping_presets.json')))
  review_path = runner.result.info.map(&:logMessage).filter_map { |message| message.match(/Review or edit (.+\.csv) and select/)&.[](1) }.first
  raise 'Missing exported review CSV' unless review_path && File.file?(review_path)
  corrections = NECBSpaceTypeMapping.plans(restored, catalog, 'AutoReviewed', presets, review_path)
  raise 'Exported CSV cannot be used on the saved reference' unless corrections.size == 3
  summary.merge!('geometry_preserved' => true, 'mapping_audit' => audit,
                 'forward_translation' => 'passed', 'save_reload' => 'passed', 'source_unchanged' => true,
                 'exported_csv_reapplication' => 'passed')
  File.write('summary.json', JSON.pretty_generate(summary))
end
