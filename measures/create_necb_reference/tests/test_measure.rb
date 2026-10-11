require 'openstudio'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../measure'

class NECBReferenceMeasureTest < Minitest::Test
  def runner
    OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
  end

  def arguments(model, values = {})
    measure = CreateNECBReference.new
    args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
    values.each do |key, value|
      argument = args[key].clone
      argument.setValue(value)
      args[key] = argument
    end
    args
  end

  def test_bad_source_path_preserves_current_model
    model = OpenStudio::Model::Model.new
    space = OpenStudio::Model::Space.new(model)
    space.setName('Keep this proposed space')
    before = model.toIdfFile.to_s
    execution = runner
    refute CreateNECBReference.new.run(model, execution, arguments(model, 'osm_file_path' => File.join(__dir__, 'missing.osm')))
    assert_equal before, model.toIdfFile.to_s
    assert_match(/existing .osm/, execution.result.errors.first.logMessage)
  end

  def test_missing_metadata_preserves_current_model
    model = OpenStudio::Model::Model.new
    space = OpenStudio::Model::Space.new(model)
    space.setName('Unmapped office')
    before = model.toIdfFile.to_s
    execution = runner
    refute CreateNECBReference.new.run(model, execution, arguments(model))
    assert_equal before, model.toIdfFile.to_s
    assert execution.result.errors.any? { |error| error.logMessage.include?('Default building use') }, execution.result.errors.map(&:logMessage).join('; ')
  end

  def test_relative_weather_resolves_against_source_file_folder
    Dir.mktmpdir('necb_weather_test_') do |directory|
      weather = File.join(directory, 'weather')
      Dir.mkdir(weather)
      %w[epw ddy stat].each { |ext| File.write(File.join(weather, "example.#{ext}"), '') }
      model = OpenStudio::Model::Model.new
      model.getWeatherFile.setString(10, 'weather/example.epw')
      # Field 10 is the OSM WeatherFile path; check it before resolving.
      assert_equal 'weather/example.epw', model.weatherFile.get.path.get.to_s
      selection = {'custom_epw_path' => '', 'weather_file' => 'UseModelWeather'}
      resolved = CreateNECBReference.new.resolve_weather(model, selection, File.join(directory, 'source.osm'))
      assert_equal File.join(weather, 'example.epw'), resolved
    end
  end

  def test_arguments_use_current_model_and_weather_by_default
    args = CreateNECBReference.new.arguments(OpenStudio::Model::Model.new).to_h { |argument| [argument.name, argument] }
    assert_equal '', args.fetch('osm_file_path').defaultValueAsString
    assert_equal 'UseModelWeather', args.fetch('weather_file').defaultValueAsString
    assert_equal 'KeepExisting', args.fetch('operating_inputs').defaultValueAsString
    assert_equal 'ReplaceWithNECB', args.fetch('building_systems').defaultValueAsString
    refute args.key?('reference_input_mode')
    refute args.key?('mapping_action')
    assert_equal 4, args.fetch('necb_template').choiceValues.size
    assert_equal 16, args.fetch('weather_file').choiceValues.size
    assert_equal %w[AutoReviewed None], args.fetch('mapping_preset').choiceValues.to_a
    assert_equal 'AutoReviewed', args.fetch('mapping_preset').defaultValueAsString
    assert_equal 'NECB2020', args.fetch('necb_template').defaultValueAsString
    assert_equal 'Create NECB Reference From OSM', CreateNECBReference.new.name
  end

  def test_automatic_fallback_exports_review_and_warns_before_sizing
    geometry = File.expand_path('../resources/openstudio-standards/data/geometry/ASHRAEFullServiceRestaurant.osm', __dir__)
    model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(geometry)).get
    type = NECBSpaceTypeMapping.used_types(model).find { |item| NECBSpaceTypeMapping.pair(item)[1] == 'Dining' }
    type.setStandardsBuildingType('Custom design')
    type.setStandardsSpaceType('Unknown dining use')
    before = model.toIdfFile.to_s
    execution = runner
    refute CreateNECBReference.new.run(model, execution, arguments(model, 'custom_epw_path' => File.join(__dir__, 'missing.epw')))
    assert_equal before, model.toIdfFile.to_s
    assert execution.result.errors.any? { |error| error.logMessage.include?('resolve source weather') }
    warning = execution.result.warnings.map(&:logMessage).find { |text| text.include?('unmatched or ambiguous') }
    refute_nil warning
    assert_includes warning, 'may omit loads or HVAC'
    path = warning.match(/Correct assignments in (.+\.csv) before/)[1]
    rows = CSV.read(path, headers: true)
    row = rows.find { |entry| entry['source_space_type'] == type.nameString }
    assert_equal 'Custom design', row['source_building_type']
    assert_equal 'Space Function', row['necb_building_type']
    assert_equal '- undefined -', row['necb_space_type']
  end

  def test_missing_weather_preserves_a_complete_input
    geometry = File.expand_path('../resources/openstudio-standards/lib/openstudio-standards/standards/necb/NECB2011/data/geometry/Warehouse.osm', __dir__)
    model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(geometry)).get
    before = model.toIdfFile.to_s
    execution = runner
    refute CreateNECBReference.new.run(model, execution, arguments(model, 'custom_epw_path' => File.join(__dir__, 'missing.epw')))
    assert_equal before, model.toIdfFile.to_s
    assert execution.result.errors.any? { |error| error.logMessage.include?('resolve source weather') }, execution.result.errors.map(&:logMessage).join('; ')
  end

  def test_prepared_missing_uses_export_review_without_classification_translation
    geometry = File.expand_path('../resources/openstudio-standards/data/geometry/ASHRAEMediumOffice.osm', __dir__)
    model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(geometry)).get
    model.getSpaces.each { |space| space.resetSpaceType; space.setName("Renamed #{space.handle}") }
    before = model.toIdfFile.to_s
    execution = runner
    refute CreateNECBReference.new.run(model, execution, arguments(model, 'default_building_use' => 'Office', 'custom_epw_path' => File.join(__dir__, 'missing.epw')))
    assert_equal before, model.toIdfFile.to_s
    info = execution.result.info.map(&:logMessage).find { |text| text.include?('Review or edit ') }
    refute_nil info
    path = info.match(/Review or edit (.+\.csv) and select/)[1]
    rows = CSV.read(path, headers: true)
    assert rows.any? { |row| row['necb_space_type'] == '- undefined -' }
    assert rows.any? { |row| row['necb_space_type'] == 'Office - open plan' }
  end

  def test_ashrae_classifications_fail_before_generation_and_preserve_model
    geometry = File.expand_path('../resources/openstudio-standards/data/geometry/ASHRAEFullServiceRestaurant.osm', __dir__)
    model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(geometry)).get
    before = model.toIdfFile.to_s
    execution = runner
    refute CreateNECBReference.new.run(model, execution, arguments(model, 'mapping_preset' => 'None'))
    assert_equal before, model.toIdfFile.to_s
    messages = execution.result.errors.map(&:logMessage).join('; ')
    assert_match(/Unsupported Space Type/, messages)
    assert_match(/ASHRAE classifications/, messages)
    assert_match(/Standards Building Type='[^']+', Standards Space Type='[^']+'/, messages)
    refute_match(/Reference generation failed/, messages)
  end

  def test_necb_catalog_accepts_used_types_and_ignores_unused_custom_type
    geometry = File.expand_path('../resources/openstudio-standards/lib/openstudio-standards/standards/necb/NECB2011/data/geometry/Warehouse.osm', __dir__)
    model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(geometry)).get
    unused = OpenStudio::Model::SpaceType.new(model)
    unused.setStandardsBuildingType('CustomUnused')
    unused.setStandardsSpaceType('CustomUnused')
    catalog = JSON.parse(File.read(File.expand_path('../resources/space_type_catalog.json', __dir__)))
    assert_empty NECBExistingModelChecks.classification_errors(model, catalog)
  end

end
