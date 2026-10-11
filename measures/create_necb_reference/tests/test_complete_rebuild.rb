require_relative 'test_reference_options'
require_relative '../resources/complete_rebuild'

class NECBCompleteRebuildTest < NECBReferenceOptionsTest
  # Use the existing public fixture setup without inheriting its test cases.
  NECBReferenceOptionsTest.instance_methods(false).grep(/^test_/).each { |name| undef_method(name) }

  def prepare
    NECBCompleteRebuild.prepare(@model, Standard.build('NECB2020'), @resources)
  end

  def test_discards_proposed_physical_inputs_and_canonicalizes_lookup_names
    custom_load
    @model.getSite.setTerrain('Ocean')
    @model.getYearDescription.setCalendarYear(2024)
    @model.getSizingParameters.setHeatingSizingFactor(7)
    @model.getSiteGroundTemperatureBuildingSurface.setJanuaryGroundTemperature(45)
    infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(@model)
    infiltration.setSpace(@space)
    infiltration.setDesignFlowRate(2)
    OpenStudio::Model::BoilerHotWater.new(@model).setNominalCapacity(1000000)
    OpenStudio::Model::WaterHeaterMixed.new(@model).setHeaterMaximumCapacity(100000)
    @model.getSurfaces.select { |surface| surface.outsideBoundaryCondition == 'Outdoors' }.each do |surface|
      surface.setSunExposure('NoSun')
      surface.setWindExposure('NoWind')
    end
    geometry = NECBExistingModelChecks.geometry_hash(@model)
    clean, settings = prepare
    assert_equal geometry, NECBExistingModelChecks.geometry_hash(clean)
    assert_empty clean.getElectricEquipments
    assert_empty clean.getPeoples
    refute clean.objects.any? { |object| object.iddObject.name == 'OS:Lights' }
    assert_empty clean.getSpaceInfiltrationDesignFlowRates
    assert_empty clean.getSubSurfaces
    assert_empty clean.getConstructions
    assert_empty clean.getThermostatSetpointDualSetpoints
    assert_empty clean.getBoilerHotWaters
    assert_empty clean.getWaterHeaterMixeds
    assert clean.getSurfaces.select { |s| s.outsideBoundaryCondition == 'Outdoors' }.all? { |s| s.sunExposure == 'SunExposed' && s.windExposure == 'WindExposed' }
    assert clean.getSpaceTypes.all? { |type| type.nameString == "#{type.standardsBuildingType.get} #{type.standardsSpaceType.get}" }
    assert_equal 'Sunday', clean.getYearDescription.dayofWeekforStartDay
    refute_equal 'Ocean', clean.getSite.terrain
    refute_equal 7, clean.getSizingParameters.heatingSizingFactor
    refute_equal 45, clean.getSiteGroundTemperatureBuildingSurface.januaryGroundTemperature
    assert_match(/NRC FullServiceRestaurant/, settings)
  end

  def test_uses_actual_modified_geometry_and_effective_multiplier
    @space.thermalZone.get.setMultiplier(3)
    @space.setXOrigin(12)
    @space.setYOrigin(-3)
    @space.setZOrigin(4)
    @model.getBuilding.setNorthAxis(37)
    clean, = prepare
    assert_equal NECBExistingModelChecks.geometry_hash(@model), NECBExistingModelChecks.geometry_hash(clean)
    assert_equal 3, clean.getSpaceByName(@space.nameString).get.multiplier
    assert_equal 37, clean.getBuilding.northAxis
    @model.getSurfaces.each do |surface|
      next if surface.adjacentSurface.empty?
      copy = clean.getSurfaceByName(surface.nameString).get
      assert_equal surface.adjacentSurface.get.nameString, copy.adjacentSurface.get.nameString
    end
  end

  def test_unknown_building_type_uses_clean_sdk_settings
    @model.getBuilding.setStandardsBuildingType('Custom Building')
    @model.getSite.setTerrain('Ocean')
    clean, settings = prepare
    assert_equal 'OpenStudio SDK defaults', settings
    refute_equal 'Ocean', clean.getSite.terrain
    assert_equal NECBExistingModelChecks.geometry_hash(@model), NECBExistingModelChecks.geometry_hash(clean)
  end

  def test_uniform_legacy_office_uses_prototype_upgrade_and_discloses_ambiguity
    @model.getSpaceTypes.each do |type|
      type.setStandardsBuildingType('Space Function')
      type.setStandardsSpaceType('Office - enclosed')
    end
    standard = Standard.build('NECB2020')
    clean, = NECBCompleteRebuild.prepare(@model, standard, @resources)
    assert clean.getSpaceTypes.all? { |type| type.standardsSpaceType.get == 'Office - enclosed' }
    assert_match(/first-match upgrade/, standard.instance_variable_get(:@necb_legacy_classification_reviews).first)
    assert standard.validate_and_upate_space_types(clean)
    assert clean.getSpaceTypes.all? { |type| type.standardsSpaceType.get == 'Office enclosed <= 25 m2' }
  end

  def test_reversed_public_warehouse_surface_is_repaired_without_reshaping
    path = File.join(@resources, 'openstudio-standards/data/geometry/ASHRAE90120102013Warehouse.osm')
    @model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(path)).get
    @model.getSpaceTypes.each do |type|
      type.setStandardsBuildingType('Space Function')
      type.setStandardsSpaceType('Warehouse - fine')
    end
    standard = Standard.build('NECB2020')
    clean, = NECBCompleteRebuild.prepare(@model, standard, @resources)
    assert_equal NECBExistingModelChecks.geometry_hash(@model), NECBExistingModelChecks.geometry_hash(clean)
    assert_in_delta 10880.57215766, clean.getSpaceByName('Zone2 Fine Storage').get.volume, 1e-6
    refute_empty standard.instance_variable_get(:@necb_reoriented_surfaces)
  end

  def test_f_factor_ground_receives_necb_ground_boundary_on_clean_shell
    floor = @model.getSurfaces.find { |surface| surface.surfaceType == 'Floor' && surface.outsideBoundaryCondition == 'Ground' }
    refute_nil floor
    assert floor.setOutsideBoundaryCondition('GroundFCfactorMethod')
    before = NECBExistingModelChecks.geometry_hash(@model)
    standard = Standard.build('NECB2020')
    clean, = NECBCompleteRebuild.prepare(@model, standard, @resources)
    assert_equal 'Ground', clean.getSurfaceByName(floor.nameString).get.outsideBoundaryCondition
    assert_equal 'GroundFCfactorMethod', floor.outsideBoundaryCondition
    assert_equal before, NECBExistingModelChecks.geometry_hash(clean)
    conversions = standard.instance_variable_get(:@necb_ground_boundary_conversions)
    assert_includes conversions, {'surface' => floor.nameString, 'source_boundary' => 'GroundFCfactorMethod', 'rebuilt_shell_boundary' => 'Ground'}
  end
end
