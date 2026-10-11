require 'openstudio'
require 'minitest/autorun'
require_relative '../resources/ground_boundary_conversion'

class NECBGroundBoundaryConversionTest < Minitest::Test
  def setup
    @model = OpenStudio::Model::Model.new
    polygons = [ [[0,0],[10,0],[8,2],[2,2]], [[10,0],[10,10],[8,8],[8,2]],
                 [[10,10],[0,10],[2,8],[8,8]], [[0,10],[0,0],[2,2],[2,8]],
                 [[2,2],[8,2],[8,8],[2,8]] ]
    @floors = polygons.each_with_index.map do |polygon, index|
      points = OpenStudio::Point3dVector.new
      polygon.each { |x, y| points << OpenStudio::Point3d.new(x, y, 0) }
      floor = OpenStudio::Model::Surface.new(points, @model)
      floor.setName("Arbitrary floor #{index}")
      floor.setSpace(OpenStudio::Model::Space.new(@model))
      floor.setSurfaceType('Floor')
      floor.setOutsideBoundaryCondition(index == 4 ? 'Adiabatic' : 'GroundFCfactorMethod')
      floor
    end
  end

  def test_enclosed_core_is_identified_without_names_or_building_types
    assert_equal [@floors.last.nameString], NECBGroundBoundaryConversion.adiabatic_slab_cores(@model)
    assert_equal 'Adiabatic', @floors.last.outsideBoundaryCondition
  end

  def test_partial_contact_or_no_f_factor_context_retains_adiabatic_floor
    @floors.first.setOutsideBoundaryCondition('Adiabatic')
    assert_empty NECBGroundBoundaryConversion.adiabatic_slab_cores(@model)
    @floors[0..3].each { |floor| floor.setOutsideBoundaryCondition('Ground') }
    assert_empty NECBGroundBoundaryConversion.adiabatic_slab_cores(@model)
  end

  def test_previous_measure_conversion_retains_f_factor_provenance
    rows = @floors[0..3].map { |floor| {'surface' => floor.nameString, 'source_boundary' => 'GroundFCfactorMethod'} }
    @floors[0..3].each { |floor| floor.setOutsideBoundaryCondition('Foundation') }
    @model.getBuilding.additionalProperties.setFeature('necb_part8_audit', JSON.generate('ground_boundary_conversions' => rows))
    assert_equal [@floors.last.nameString], NECBGroundBoundaryConversion.adiabatic_slab_cores(@model)
  end
end
