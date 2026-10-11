require 'openstudio'
require 'minitest/autorun'
require_relative '../measure'

class NECBInputPreparationTest < Minitest::Test
  def setup
    @catalog = JSON.parse(File.read(File.expand_path('../resources/space_type_catalog.json', __dir__)))
    @model = OpenStudio::Model::Model.new
    points = OpenStudio::Point3dVector.new
    [[0,0,0], [0,10,0], [10,10,0], [10,0,0]].each { |p| points << OpenStudio::Point3d.new(*p) }
    @space = OpenStudio::Model::Space.fromFloorPrint(points, 3, @model).get
  end

  def test_missing_types_zones_stories_are_added_without_changing_geometry
    before = NECBExistingModelChecks.geometry_hash(@model)
    audit = NECBInputPreparation.apply(@model, @catalog, 'Office')
    assert_equal ['Office', 'WholeBuilding'], NECBSpaceTypeMapping.pair(@space.spaceType.get)
    assert @space.thermalZone.is_initialized
    assert @space.buildingStory.is_initialized
    assert_empty NECBExistingModelChecks.errors(@model)
    assert_equal before, NECBExistingModelChecks.geometry_hash(@model)
    assert audit.any?
    type = @space.spaceType.get.handle
    zone = @space.thermalZone.get.handle
    NECBInputPreparation.apply(@model, @catalog, 'Warehouse')
    assert_equal type, @space.spaceType.get.handle
    assert_equal zone, @space.thermalZone.get.handle
    assert_equal 1, @model.getThermalZones.size
  end

  def test_unclassified_spaces_use_explicit_building_metadata
    @model.getBuilding.setStandardsBuildingType('Warehouse')
    NECBInputPreparation.apply(@model, @catalog, 'UseExisting')
    assert_equal ['Warehouse', 'WholeBuilding'], NECBSpaceTypeMapping.pair(@space.spaceType.get)
  end

  def test_existing_custom_type_and_named_zone_are_not_overwritten_by_default
    type = OpenStudio::Model::SpaceType.new(@model)
    type.setName('Reviewed later')
    @space.setSpaceType(type)
    zone = OpenStudio::Model::ThermalZone.new(@model)
    zone.setName('Architect zone A')
    zone.setMultiplier(3)
    @space.setThermalZone(zone)
    NECBInputPreparation.apply(@model, @catalog, 'Office')
    assert_equal type.handle, @space.spaceType.get.handle
    assert_equal ['', ''], NECBSpaceTypeMapping.pair(type)
    assert_equal zone.handle, @space.thermalZone.get.handle
    assert_equal 'Architect zone A', zone.nameString
    assert_equal 3, zone.multiplier
  end

  def test_no_space_use_is_guessed_from_geometry
    assert_raises(RuntimeError) { NECBInputPreparation.apply(@model, @catalog, 'UseExisting') }
    assert @space.spaceType.empty?
    assert @space.thermalZone.empty?
  end

  def medium_office_without_types
    path = File.expand_path('../resources/openstudio-standards/data/geometry/ASHRAEMediumOffice.osm', __dir__)
    model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(path)).get
    model.getSpaces.each { |space| space.resetSpaceType; space.resetBuildingStory; space.setName("#{space.nameString} Space") }
    model.getBuilding.resetStandardsBuildingType
    model.getBuilding.resetStandardsNumberOfStories
    model.getBuilding.resetStandardsNumberOfAboveGroundStories
    model
  end

  def test_exact_reviewed_shell_recovers_missing_office_and_plenum_uses
    model = medium_office_without_types
    before = NECBExistingModelChecks.geometry_hash(model)
    resources = File.expand_path('../resources', __dir__)
    audit = NECBInputPreparation.apply(model, @catalog, 'Office', reviewed_resources: resources)
    assert_equal before, NECBExistingModelChecks.geometry_hash(model)
    assert_equal 'MediumOffice', model.getBuilding.standardsBuildingType.get
    assert_equal 3, model.getBuilding.standardsNumberOfStories.get
    assert_equal 3, model.getSpaces.map { |space| space.buildingStory.get.handle }.uniq.size
    plenums = model.getSpaces.reject(&:partofTotalFloorArea)
    assert_equal 3, plenums.size
    assert plenums.all? { |space| NECBSpaceTypeMapping.pair(space.spaceType.get) == ['Space Function', '- undefined -'] }
    assert model.getSpaces.select(&:partofTotalFloorArea).all? { |space| NECBSpaceTypeMapping.pair(space.spaceType.get) == ['Space Function', 'Office - open plan'] }
    assert audit.any? { |message| message.include?('complete public-shell geometry match') }
  end

  def test_repair_only_documented_measure_defaults_and_keep_supplied_types
    model = medium_office_without_types
    audit = NECBInputPreparation.apply(model, @catalog, 'Office')
    model.getBuilding.additionalProperties.setFeature('necb_input_preparation', JSON.generate(audit))
    occupied = model.getSpaces.find(&:partofTotalFloorArea)
    supplied = OpenStudio::Model::SpaceType.new(model)
    supplied.setName('Explicit reviewed office')
    supplied.setStandardsBuildingType('Office')
    supplied.setStandardsSpaceType('WholeBuilding')
    occupied.setSpaceType(supplied)
    # Emulate the previous version's single default assigned to plenums too.
    default = model.getSpaces.select(&:partofTotalFloorArea).map { |space| space.spaceType.get }.find { |type| type.nameString == 'NECB default Office' }
    model.getSpaces.reject(&:partofTotalFloorArea).each { |space| space.setSpaceType(default) }
    resources = File.expand_path('../resources', __dir__)
    NECBInputPreparation.apply(model, @catalog, 'Office', reviewed_resources: resources, repair_defaults: true)
    assert_equal supplied.handle, occupied.spaceType.get.handle
    assert model.getSpaces.reject(&:partofTotalFloorArea).all? { |space| NECBSpaceTypeMapping.pair(space.spaceType.get) == ['Space Function', '- undefined -'] }
    assert_equal 'MediumOffice', model.getBuilding.standardsBuildingType.get
  end

  def test_generic_excluded_floor_area_does_not_get_occupied_default
    @space.setPartofTotalFloorArea(false)
    audit = NECBInputPreparation.apply(@model, @catalog, 'UseExisting')
    assert_equal ['Space Function', '- undefined -'], NECBSpaceTypeMapping.pair(@space.spaceType.get)
    assert audit.any? { |message| message.include?('excluded from total floor area') }
  end

  def test_modified_geometry_does_not_receive_prototype_classifications
    model = medium_office_without_types
    model.getSpaces.first.setXOrigin(1)
    resources = File.expand_path('../resources', __dir__)
    audit = NECBInputPreparation.apply(model, @catalog, 'Office', reviewed_resources: resources)
    refute audit.any? { |message| message.include?('complete public-shell geometry match') }
    assert model.getBuilding.standardsBuildingType.empty?
    assert model.getSpaces.select(&:partofTotalFloorArea).all? { |space| NECBSpaceTypeMapping.pair(space.spaceType.get) == ['Office', 'WholeBuilding'] }
  end
end
