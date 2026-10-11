require 'openstudio'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../measure'

class NECBSpaceTypeMappingTest < Minitest::Test
  def setup
    @resources = File.expand_path('../resources', __dir__)
    @catalog = JSON.parse(File.read(File.join(@resources, 'space_type_catalog.json')))
    @presets = JSON.parse(File.read(File.join(@resources, 'mapping_presets.json')))
  end

  def restaurant
    OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(File.join(@resources, 'openstudio-standards/data/geometry/ASHRAEFullServiceRestaurant.osm'))).get
  end

  def custom_model
    model = OpenStudio::Model::Model.new
    type = OpenStudio::Model::SpaceType.new(model)
    type.setName('My prep room')
    OpenStudio::Model::Space.new(model).setSpaceType(type)
    [model, type]
  end

  def csv(directory, rows, headers = NECBSpaceTypeMapping::HEADERS)
    path = File.join(directory, 'assignments.csv')
    CSV.open(path, 'w') { |file| file << headers; rows.each { |row| file << row } }
    path
  end

  def valid_row(name = 'My prep room')
    [name, '', '', 'NECB2011', 'Space Function', 'Food preparation', '']
  end

  def test_preset_matches_public_nrc_restaurant
    source = restaurant
    before = NECBExistingModelChecks.geometry_hash(source)
    audit = NECBSpaceTypeMapping.apply(source, @catalog, 'ASHRAEFullServiceRestaurant', @presets, '')
    assert_equal 3, audit.size
    assert_equal before, NECBExistingModelChecks.geometry_hash(source)
    assert_empty NECBExistingModelChecks.classification_errors(source, @catalog)
    assert audit.all? { |row| row['source_space_type'].start_with?('FullServiceRestaurant ') }
    assert_includes NECBSpaceTypeMapping.used_types(source).map { |type| NECBSpaceTypeMapping.pair(type) }, ['Space Function', '- undefined -']
  end

  def test_custom_missing_metadata_can_be_explicitly_mapped
    model, type = custom_model
    Dir.mktmpdir do |directory|
      audit = NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [valid_row]))
      assert_equal ['Space Function', 'Food preparation'], NECBSpaceTypeMapping.pair(type)
      assert_equal 'csv', audit.first['method']
      assert_empty NECBExistingModelChecks.classification_errors(model, @catalog)
    end
  end

  def test_invalid_target_is_rejected_without_changes
    model, type = custom_model
    Dir.mktmpdir do |directory|
      row = valid_row
      row[5] = 'Guess from room name'
      error = assert_raises(NECBSpaceTypeMapping::MappingError) do
        NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [row]))
      end
      assert_match(/Invalid NECB mapping/, error.message)
      assert_equal ['', ''], NECBSpaceTypeMapping.pair(type)
    end
  end

  def test_duplicate_and_unknown_source_rows_are_rejected
    model, = custom_model
    Dir.mktmpdir do |directory|
      error = assert_raises(NECBSpaceTypeMapping::MappingError) do
        NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [valid_row, valid_row]))
      end
      assert_match(/Duplicate mapping/, error.message)
      error = assert_raises(NECBSpaceTypeMapping::MappingError) do
        NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [valid_row('Wrong model type')]))
      end
      assert_match(/not a used Space Type/, error.message)
    end
  end

  def test_incomplete_mapping_is_rejected_without_partial_assignment
    model, type = custom_model
    other = OpenStudio::Model::SpaceType.new(model)
    other.setName('My other custom room')
    OpenStudio::Model::Space.new(model).setSpaceType(other)
    Dir.mktmpdir do |directory|
      error = assert_raises(NECBSpaceTypeMapping::MappingError) do
        NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [valid_row]))
      end
      assert_match(/Incomplete mapping/, error.message)
      assert_equal ['', ''], NECBSpaceTypeMapping.pair(type)
    end
  end

  def test_csv_overrides_a_preset
    model = restaurant
    dining = NECBSpaceTypeMapping.used_types(model).find { |type| NECBSpaceTypeMapping.pair(type)[1] == 'Dining' }
    Dir.mktmpdir do |directory|
      row = [dining.nameString, 'FullServiceRestaurant', 'Dining', 'NECB2011', 'Space Function', 'Food preparation', '']
      audit = NECBSpaceTypeMapping.apply(model, @catalog, 'ASHRAEFullServiceRestaurant', @presets, csv(directory, [row]))
      assert_equal ['Space Function', 'Food preparation'], NECBSpaceTypeMapping.pair(dining)
      assert_equal 1, audit.count { |entry| entry['method'] == 'csv' }
      assert_equal 2, audit.count { |entry| entry['method'].start_with?('preset:') }
    end
  end

  def test_stale_source_columns_are_rejected
    model, = custom_model
    Dir.mktmpdir do |directory|
      row = valid_row
      row[1] = 'A different source classification'
      error = assert_raises(NECBSpaceTypeMapping::MappingError) do
        NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [row]))
      end
      assert_match(/source classifications changed/, error.message)
    end
  end

  def test_template_round_trip_with_preset_and_no_overwrite
    model = restaurant
    before = model.toIdfFile.to_s
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'template.csv')
      assert_equal 3, NECBSpaceTypeMapping.export_template(model, @catalog, 'ASHRAEFullServiceRestaurant', @presets, path, 'NECB2020')
      assert_equal before, model.toIdfFile.to_s
      contents = File.read(path)
      assert_raises(NECBSpaceTypeMapping::MappingError) { NECBSpaceTypeMapping.export_template(model, @catalog, 'None', @presets, path, 'NECB2020') }
      assert_equal contents, File.read(path)
      audit = NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, path)
      assert_equal 3, audit.size
      assert_empty NECBExistingModelChecks.classification_errors(model, @catalog)
    end
  end

  def test_missing_mapping_automatically_exports_template_without_changing_model
    model, = custom_model
    type = model.getSpaceTypes.first
    model.getSpaces.each(&:remove)
    points = OpenStudio::Point3dVector.new
    [[0,0,0], [0,10,0], [10,10,0], [10,0,0]].each { |p| points << OpenStudio::Point3d.new(*p) }
    OpenStudio::Model::Space.fromFloorPrint(points, 3, model).get.setSpaceType(type)
    before = model.toIdfFile.to_s
    directory = Dir.mktmpdir('mapping_export_', File.expand_path('../../../test-output', __dir__))
    begin # OpenStudio can hold native directory handles until this CLI exits.
      measure = CreateNECBReference.new
      args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
      strict = args['mapping_preset'].clone
      strict.setValue('None')
      args['mapping_preset'] = strict
      runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
      Dir.chdir(directory) { refute measure.run(model, runner, args) }
      assert_equal before, model.toIdfFile.to_s
      message = runner.result.errors.map(&:logMessage).find { |text| text.include?('space_use_mapping.csv') }
      refute_nil message
      path = message.match(/assignments in (.+\.csv), then/)[1]
      rows = CSV.read(path, headers: true)
      assert_equal 'My prep room', rows.first['source_space_type']
      assert_equal '', rows.first['necb_building_type'].to_s
      assert_equal 'NECB2020', rows.first['necb_vintage']
    end
  end

  def test_individually_valid_mapping_vintages_are_accepted
    model, type = custom_model
    other = OpenStudio::Model::SpaceType.new(model)
    other.setName('Other custom area')
    OpenStudio::Model::Space.new(model).setSpaceType(other)
    Dir.mktmpdir do |directory|
      second = valid_row('Other custom area')
      second[3] = 'NECB2020'
      second[4], second[5] = @catalog.fetch('NECB2020').first
      audit = NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, csv(directory, [valid_row, second]))
      assert_equal 2, audit.size
      assert_empty NECBExistingModelChecks.classification_errors(model, @catalog)
    end
  end

  def test_missing_headers_and_malformed_csv_are_rejected
    model, = custom_model
    Dir.mktmpdir do |directory|
      path = csv(directory, [['My prep room']], ['source_space_type'])
      error = assert_raises(NECBSpaceTypeMapping::MappingError) { NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, path) }
      assert_match(/requires headers/, error.message)
      File.write(path, "source_space_type,necb_vintage,necb_building_type,necb_space_type\n\"unfinished")
      error = assert_raises(NECBSpaceTypeMapping::MappingError) { NECBSpaceTypeMapping.apply(model, @catalog, 'None', @presets, path) }
      assert_match(/Could not parse mapping CSV/, error.message)
    end
  end

  def test_automatic_translation_combines_presets_and_retains_compatible_types
    model = restaurant
    extra = OpenStudio::Model::SpaceType.new(model)
    extra.setName('Warehouse stock room')
    extra.setStandardsBuildingType('Warehouse')
    entry = @presets.fetch('ASHRAEWarehouse').fetch('mappings').first
    extra.setStandardsSpaceType(entry.fetch('source_space_type'))
    OpenStudio::Model::Space.new(model).setSpaceType(extra)
    compatible = OpenStudio::Model::SpaceType.new(model)
    compatible.setName('Already reviewed')
    compatible.setStandardsBuildingType('Space Function')
    compatible.setStandardsSpaceType('Food preparation')
    OpenStudio::Model::Space.new(model).setSpaceType(compatible)
    audit = NECBSpaceTypeMapping.apply(model, @catalog, 'AutoReviewed', @presets, '')
    assert_equal 4, audit.size
    assert_equal entry.values_at('necb_building_type', 'necb_space_type'), NECBSpaceTypeMapping.pair(extra)
    assert_equal ['Space Function', 'Food preparation'], NECBSpaceTypeMapping.pair(compatible)
    refute audit.any? { |row| row['source_space_type'] == compatible.nameString }
    assert_empty NECBSpaceTypeMapping.plans(model, @catalog, 'AutoReviewed', @presets)
  end

  def test_unmatched_and_conflicting_uses_get_explicit_undefined_fallback
    model, type = custom_model
    audit = NECBSpaceTypeMapping.apply(model, @catalog, 'AutoReviewed', @presets, '')
    assert_equal ['Space Function', '- undefined -'], NECBSpaceTypeMapping.pair(type)
    assert_equal 'fallback:unmapped', audit.first['method']
    model = restaurant
    presets = Marshal.load(Marshal.dump(@presets))
    conflict = presets.fetch('ASHRAEFullServiceRestaurant').fetch('mappings').find { |row| row['source_space_type'] == 'Dining' }.dup
    conflict['necb_space_type'] = 'Food preparation'
    presets['Conflicting reviewed use'] = {'mappings' => [conflict]}
    audit = NECBSpaceTypeMapping.apply(model, @catalog, 'AutoReviewed', presets, '')
    row = audit.find { |item| item['source_space_type_code'] == 'Dining' }
    assert_equal 'fallback:ambiguous', row['method']
    assert_equal '- undefined -', row['necb_space_type']
  end

  def test_exported_csv_can_correct_original_or_already_translated_models
    model, type = custom_model
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'space_use_mapping.csv')
      NECBSpaceTypeMapping.export_template(model, @catalog, 'AutoReviewed', @presets, path, 'NECB2020')
      rows = CSV.read(path, headers: true)
      assert_equal '- undefined -', rows.first['necb_space_type']
      NECBSpaceTypeMapping.apply(model, @catalog, 'AutoReviewed', @presets, '')
      rows.first['necb_space_type'] = 'Food preparation'
      File.write(path, rows.to_csv)
      audit = NECBSpaceTypeMapping.apply(model, @catalog, 'AutoReviewed', @presets, path)
      assert_equal 'csv', audit.first['method']
      assert_equal ['Space Function', 'Food preparation'], NECBSpaceTypeMapping.pair(type)
      original, original_type = custom_model
      NECBSpaceTypeMapping.apply(original, @catalog, 'AutoReviewed', @presets, path)
      assert_equal NECBSpaceTypeMapping.pair(type), NECBSpaceTypeMapping.pair(original_type)
      type.setStandardsSpaceType('Dining - family space')
      assert_raises(NECBSpaceTypeMapping::MappingError) { NECBSpaceTypeMapping.apply(model, @catalog, 'AutoReviewed', @presets, path) }
    end
  end

  def test_all_reviewed_targets_are_in_the_bundled_catalog
    assert_operator @presets.size, :>=, 10
    @presets.each_value do |preset|
      assert preset.fetch('mappings').all? { |row| @catalog.fetch(row['necb_vintage']).include?(row.values_at('necb_building_type', 'necb_space_type')) }
    end
  end
end
