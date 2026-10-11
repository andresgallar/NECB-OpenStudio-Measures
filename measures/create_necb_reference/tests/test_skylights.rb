require 'openstudio'
require 'minitest/autorun'
require_relative '../resources/skylight_checks'

class NECBSkylightTest < Minitest::Test
  def setup
    @model = OpenStudio::Model::Model.new
    points = OpenStudio::Point3dVector.new
    [[0, 0, 0], [0, 10, 0], [10, 10, 0], [10, 0, 0]].each { |p| points << OpenStudio::Point3d.new(*p) }
    @space = OpenStudio::Model::Space.fromFloorPrint(points, 3, @model).get
    zone = OpenStudio::Model::ThermalZone.new(@model)
    zone.setMultiplier(3)
    @space.setThermalZone(zone)
    @roof = @space.surfaces.find { |s| s.surfaceType == 'RoofCeiling' }
    @standard = Object.new
    @standard.define_singleton_method(:get_standards_constant) { |_key| 0.02 }
    eligible = @roof
    @standard.define_singleton_method(:find_exposed_conditioned_roof_surfaces) do |_model|
      {'exp_nonplenum_roofs' => [eligible], 'exp_plenum_roofs' => [], 'exp_nonplenum_roof_area_m2' => 300.0}
    end
  end

  def add_sky(ratio)
    points = OpenStudio::Point3dVector.new
    @roof.vertices.each { |p| points << OpenStudio::Point3d.new(5 + (p.x - 5) * Math.sqrt(ratio), 5 + (p.y - 5) * Math.sqrt(ratio), 3) }
    sky = OpenStudio::Model::SubSurface.new(points, @model)
    sky.setSurface(@roof)
    sky.setSubSurfaceType('Skylight')
    glass = OpenStudio::Model::SimpleGlazing.new(@model)
    construction = OpenStudio::Model::Construction.new(@model)
    construction.insertLayer(0, glass)
    sky.setConstruction(construction)
    sky
  end

  def test_audit_weights_multiplier_once_and_verifies_generated_area
    add_sky(0.02)
    audit = NECBSkylightChecks.audit(@model, @model, @standard, complete: true)
    areas = audit['exposed_conditioned_nonplenum_roofs_after']
    assert_in_delta 300, areas['gross_roof_area_m2'], 1e-7
    assert_in_delta 6, areas['skylight_area_m2'], 1e-7
    assert_in_delta 0.02, areas['srr'], 1e-8
  end

  def test_silent_generator_omission_is_rejected
    error = assert_raises(RuntimeError) { NECBSkylightChecks.audit(@model, @model, @standard, complete: true) }
    assert_match(/skylight generation did not achieve/, error.message)
  end

  def test_preservation_does_not_require_new_thermal_skylights
    audit = NECBSkylightChecks.audit(@model, @model, @standard, complete: false)
    assert_equal 0, audit['all_exterior_roofs_after']['skylight_count']
    assert_equal 'CapExistingSkylights', audit['mode']
  end

  def test_existing_skylight_is_reduced_without_resizing_opaque_roof_hatch
    sky = add_sky(0.08)
    hatch = add_sky(0.001)
    points = OpenStudio::Point3dVector.new
    hatch.vertices.each { |p| points << OpenStudio::Point3d.new(p.x - 4, p.y - 4, p.z) }
    hatch.setVertices(points)
    hatch.setSubSurfaceType('Door')
    hatch_area = hatch.grossArea
    adapter = Object.new.extend(NECBPart8Reference)
    adapter.instance_variable_set(:@part8_audit, {'fenestration' => {}})
    adapter.resize_openings([@roof], 0.02, 'srr', increase: false, types: ['Skylight'])
    assert_in_delta hatch_area, hatch.grossArea, 1e-7
    assert_in_delta 2, sky.grossArea, 1e-7
  end
end
