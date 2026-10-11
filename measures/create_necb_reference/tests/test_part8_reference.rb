require 'openstudio'
require 'minitest/autorun'
require_relative '../resources/part8_reference'

class Part8FenestrationTest < Minitest::Test
  def setup
    @model = OpenStudio::Model::Model.new
    points = OpenStudio::Point3dVector.new
    [[0, 0, 0], [0, 10, 0], [10, 10, 0], [10, 0, 0]].each { |p| points << OpenStudio::Point3d.new(*p) }
    @space = OpenStudio::Model::Space.fromFloorPrint(points, 3, @model).get
    @walls = @space.surfaces.select { |surface| surface.surfaceType == 'Wall' }
    @adapter = Object.new.extend(NECBPart8Reference)
    @adapter.instance_variable_set(:@part8_audit, {'fenestration' => {}})
  end

  def opening(wall, ratio, type = 'FixedWindow', offset = 0)
    vertices = wall.vertices.to_a
    center = [vertices.sum(&:x) / vertices.size, vertices.sum(&:y) / vertices.size, vertices.sum(&:z) / vertices.size]
    # Move along the horizontal direction of the wall for overlap tests.
    horizontal = (vertices.map(&:x).max - vertices.map(&:x).min) > 1 ? 0 : 1
    center[horizontal] += offset
    points = OpenStudio::Point3dVector.new
    vertices.each do |point|
      original = [point.x, point.y, point.z]
      base_center = [vertices.sum(&:x) / vertices.size, vertices.sum(&:y) / vertices.size, vertices.sum(&:z) / vertices.size]
      xyz = original.each_with_index.map { |value, i| center[i] + (value - base_center[i]) * Math.sqrt(ratio) }
      points << OpenStudio::Point3d.new(*xyz)
    end
    result = OpenStudio::Model::SubSurface.new(points, @model)
    result.setSurface(wall)
    result.setSubSurfaceType(type)
    result
  end

  def test_reduction_preserves_unequal_facade_shares_and_door_types
    a = opening(@walls[0], 0.6)
    b = opening(@walls[1], 0.2, 'Door')
    original = [a.grossArea, b.grossArea]
    @adapter.resize_openings(@walls.take(2), 0.3, 'fdwr', increase: true)
    assert_in_delta 3.0, a.grossArea / b.grossArea, 1e-7
    assert_in_delta 0.75, a.grossArea / original[0], 1e-7
    assert_in_delta 0.75, b.grossArea / original[1], 1e-7
    assert_equal 'Door', b.subSurfaceType
    assert_equal 2, @model.getSubSurfaces.size
  end

  def test_increase_preserves_opening_centres
    a = opening(@walls[0], 0.1)
    before = a.vertices.map(&:x).sum / a.vertices.size
    @adapter.resize_openings([@walls[0]], 0.4, 'fdwr', increase: true)
    assert_in_delta 12, a.grossArea, 1e-7
    assert_in_delta before, a.vertices.map(&:x).sum / a.vertices.size, 1e-7
  end

  def test_expansion_outside_wall_is_rejected
    opening(@walls[0], 0.7)
    error = assert_raises(RuntimeError) { @adapter.resize_openings(@walls.take(2), 0.8, 'fdwr', increase: true) }
    assert_match(/beyond its parent surface/, error.message)
  end

  def test_expansion_overlap_is_rejected
    opening(@walls[0], 0.1, 'FixedWindow', -2)
    opening(@walls[0], 0.1, 'Door', 2)
    error = assert_raises(RuntimeError) { @adapter.resize_openings([@walls[0]], 0.6, 'fdwr', increase: true) }
    assert_match(/overlaps/, error.message)
  end

  def test_no_openings_is_rejected_for_positive_fdwr
    error = assert_raises(RuntimeError) { @adapter.resize_openings(@walls, 0.4, 'fdwr', increase: true) }
    assert_match(/without existing exterior openings/, error.message)
  end

  def test_srr_does_not_add_openings_when_below_limit
    roof = @space.surfaces.find { |surface| surface.surfaceType == 'RoofCeiling' }
    sky = opening(roof, 0.01, 'Skylight')
    before = sky.grossArea
    @adapter.resize_openings([roof], 0.02, 'srr', increase: false)
    assert_in_delta before, sky.grossArea, 1e-7
    assert_equal 1, @model.getSubSurfaces.size
  end

  def test_fdwr_counts_opaque_doors_separately_from_glazing
    opening(@walls[0], 0.6)
    opening(@walls[1], 0.2, 'Door')
    @model.getBuilding.setNorthAxis(17)
    @adapter.resize_openings(@walls.take(2), 0.3, 'fdwr', increase: true)
    data = @adapter.wall_opening_summary(@walls.take(2))
    assert_in_delta 0.3, data['fdwr'], 1e-8
    assert_in_delta 0.225, data['glazing_only_wwr'], 1e-8
    assert_in_delta 4.5, data['opaque_door_area_m2'], 1e-8
    assert_in_delta 18, data['opening_area_m2'], 1e-8
    assert_equal 2, data['orientations'].size
  end

  def test_code_fdwr_target_is_not_rounded_to_three_decimals
    zone = OpenStudio::Model::ThermalZone.new(@model)
    @space.setThermalZone(zone)
    @adapter.instance_variable_set(:@part8_conditioning, {zone.nameString => true})
    @adapter.define_singleton_method(:get_necb_hdd18) { |**_| 4500 }
    @adapter.define_singleton_method(:max_fwdr) { |_hdd| 0.3666666666666667 }
    @adapter.define_singleton_method(:get_standards_constant) { |_name| 0.02 }
    opening(@walls[0], 0.4)
    opening(@walls[1], 0.4)
    opening(@walls[2], 0.4)
    opening(@walls[3], 0.4)
    @adapter.apply_fdwr_srr_daylighting(model: @model)
    audit = @adapter.instance_variable_get(:@part8_audit)['fenestration']['fdwr']
    assert_in_delta 0.3666666666666667, audit['after'], 1e-10
    audit['areas_before']['orientations'].each do |direction, data|
      assert_in_delta data['opening_area_m2'] * audit['area_factor'], audit['areas_after']['orientations'][direction]['opening_area_m2'], 1e-8
    end
  end

  def test_2020_leakage_counts_conditioned_boundary_and_excludes_attic_roof
    conditioned = OpenStudio::Model::ThermalZone.new(@model)
    @space.setThermalZone(conditioned)
    points = OpenStudio::Point3dVector.new
    [[0,0,3], [0,10,3], [10,10,3], [10,0,3]].each { |p| points << OpenStudio::Point3d.new(*p) }
    attic = OpenStudio::Model::Space.fromFloorPrint(points, 2, @model).get
    attic.setName('Unconditioned attic')
    attic_zone = OpenStudio::Model::ThermalZone.new(@model)
    attic.setThermalZone(attic_zone)
    roof = @space.surfaces.find { |surface| surface.surfaceType == 'RoofCeiling' }
    floor = attic.surfaces.find { |surface| surface.surfaceType == 'Floor' }
    assert roof.setAdjacentSurface(floor)
    @adapter.instance_variable_set(:@part8_conditioning, {conditioned.nameString => true, attic_zone.nameString => false})
    @adapter.define_singleton_method(:get_standards_constant) { |_name| 0.0015 }
    @adapter.apply_part8_2020_infiltration(@model)
    audit = @adapter.instance_variable_get(:@part8_audit)['air_leakage']
    assert_in_delta 320, audit['conditioned_envelope_area_m2'], 1e-8
    assert_in_delta 120, audit['above_ground_wall_area_m2'], 1e-8
    assert_in_delta 0.0015 * (5.0 / 75) ** 0.60 * 320, audit['total_design_flow_m3_s'], 1e-10
    assert_empty attic.spaceInfiltrationDesignFlowRates
    assert_equal 1, @space.spaceInfiltrationDesignFlowRates.size
    flow = @space.spaceInfiltrationDesignFlowRates.first
    assert_in_delta audit['total_design_flow_m3_s'], flow.designFlowRate.get, 1e-10
    assert_equal 1.0, flow.constantTermCoefficient
    assert_equal 0.0, flow.velocityTermCoefficient
  end

  def test_2020_leakage_applies_zone_multiplier_once_and_counts_foundation_floor
    zone = OpenStudio::Model::ThermalZone.new(@model)
    zone.setMultiplier(3)
    @space.setThermalZone(zone)
    floor = @space.surfaces.find { |surface| surface.surfaceType == 'Floor' }
    kiva = OpenStudio::Model::FoundationKiva.new(@model)
    assert floor.setAdjacentFoundation(kiva)
    @adapter.instance_variable_set(:@part8_conditioning, {zone.nameString => true})
    @adapter.define_singleton_method(:get_standards_constant) { |_name| 0.0015 }
    @adapter.apply_part8_2020_infiltration(@model)
    data = @adapter.instance_variable_get(:@part8_audit)['air_leakage']
    assert_in_delta 960, data['conditioned_envelope_area_m2'], 1e-8
    assert_in_delta 360, data['above_ground_wall_area_m2'], 1e-8
    flow = @space.spaceInfiltrationDesignFlowRates.first.designFlowRate.get
    assert_in_delta 0.0015 * (5.0 / 75) ** 0.60 * 320, flow, 1e-10
    assert_in_delta data['total_design_flow_m3_s'], flow * zone.multiplier, 1e-10
  end
end
