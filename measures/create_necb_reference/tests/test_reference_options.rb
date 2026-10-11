require 'openstudio'
require 'json'
require 'minitest/autorun'
require_relative '../measure'
resources = File.expand_path('../resources', __dir__)
manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
manifest['gems'].each { |gem| $LOAD_PATH.unshift(File.join(resources, 'gems', "#{gem['name']}-#{gem['version']}", 'lib')) }
require File.join(resources, 'openstudio-standards/lib/openstudio-standards.rb')
require_relative '../resources/reference_options'

class NECBReferenceOptionsTest < Minitest::Test
  def setup
    @resources = File.expand_path('../resources', __dir__)
    @model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(File.join(@resources, 'openstudio-standards/data/geometry/ASHRAEFullServiceRestaurant.osm'))).get
    catalog = JSON.parse(File.read(File.join(@resources, 'space_type_catalog.json')))
    presets = JSON.parse(File.read(File.join(@resources, 'mapping_presets.json')))
    NECBSpaceTypeMapping.apply(@model, catalog, 'ASHRAEFullServiceRestaurant', presets, '')
    NECBInputPreparation.apply(@model, catalog, 'UseExisting')
    @standard = Standard.build('NECB2020')
    @standard.singleton_class.prepend(NECBPart8Reference)
    @standard.singleton_class.prepend(NECBReferenceOptions)
    @space = @model.getSpaces.find { |space| space.spaceType.get.standardsSpaceType.get.include?('Dining') }
  end

  def custom_load
    definition = OpenStudio::Model::ElectricEquipmentDefinition.new(@model)
    definition.setDesignLevel(0)
    load = OpenStudio::Model::ElectricEquipment.new(definition)
    load.setName('Intentional zero process load')
    load.setSpace(@space)
    schedule = OpenStudio::Model::ScheduleConstant.new(@model)
    schedule.setValue(0.31)
    load.setSchedule(schedule)
    load
  end

  def configure(operating, systems = 'KeepExisting')
    @standard.configure_reference(@model, {'operating_inputs' => operating, 'building_systems' => systems})
  end

  def test_keep_preserves_zero_load_and_fills_missing_profiles
    load = custom_load
    configure('KeepExisting')
    assert_equal 0, load.electricEquipmentDefinition.designLevel.get
    assert_in_delta 0.31, load.schedule.get.to_ScheduleConstant.get.value
    assert_equal 1, @standard.effective_loads(@space, :electricEquipment).size
    refute_empty @standard.effective_loads(@space, :people)
    refute_empty @standard.effective_loads(@space, :lights)
    assert @space.thermalZone.get.thermostatSetpointDualSetpoint.is_initialized
  end

  def test_replace_removes_custom_load_without_duplicating_default_loads
    load = custom_load
    handle = load.handle
    configure('ReplaceWithNECB')
    assert @model.getModelObject(handle).empty?
    loads = @standard.effective_loads(@space, :electricEquipment)
    assert_equal 1, loads.size
    assert loads.first.electricEquipmentDefinition.wattsperSpaceFloorArea.get > 0
    assert_empty @space.spaceType.get.electricEquipment
  end

  def test_keep_systems_preserves_heater_infiltration_and_ideal_equipment
    heater = OpenStudio::Model::WaterHeaterMixed.new(@model)
    heater.setHeaterMaximumCapacity(12345)
    infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(@model)
    infiltration.setDesignFlowRate(0.0123)
    infiltration.setSpace(@space)
    ideal = OpenStudio::Model::ZoneHVACIdealLoadsAirSystem.new(@model)
    ideal.addToThermalZone(@space.thermalZone.get)
    before = [heater.to_s, infiltration.to_s, ideal.to_s]
    configure('KeepExisting')
    @standard.clean_and_scale_model(model: @model)
    @standard.apply_loads(model: @model)
    @standard.model_apply_infiltration_standard(@model)
    @standard.apply_systems_and_efficiencies(model: @model)
    assert_equal before, [heater.to_s, infiltration.to_s, ideal.to_s]
    audit = @standard.finish_part8(@model)
    assert audit['existing_system_objects_verified'] >= 3
  end

  def test_compatible_classification_and_zone_names_survive_internal_upgrade
    names = @model.getSpaces.to_h { |space| [space.nameString, [space.spaceType.get.nameString, NECBSpaceTypeMapping.pair(space.spaceType.get), space.thermalZone.get.nameString]] }
    configure('KeepExisting')
    @standard.apply_loads(model: @model)
    @standard.finish_part8(@model)
    assert_equal names, @model.getSpaces.to_h { |space| [space.nameString, [space.spaceType.get.nameString, NECBSpaceTypeMapping.pair(space.spaceType.get), space.thermalZone.get.nameString]] }
  end

  def test_transfer_signature_compares_topology_and_detects_equipment_changes
    heater = OpenStudio::Model::WaterHeaterMixed.new(@model)
    heater.setHeaterMaximumCapacity(7800)
    ideal = OpenStudio::Model::ZoneHVACIdealLoadsAirSystem.new(@model)
    ideal.addToThermalZone(@space.thermalZone.get)
    expected = NECBExistingModelChecks.system_signature(@model)
    copy = @model.clone.to_Model
    actual = NECBExistingModelChecks.system_signature(copy)
    expected.each { |key, value| assert_equal value, actual[key], "Equipment/topology changed: #{key}" }
    copy.getWaterHeaterMixeds.first.setHeaterMaximumCapacity(7900)
    refute_equal expected, NECBExistingModelChecks.system_signature(copy)
  end
end
