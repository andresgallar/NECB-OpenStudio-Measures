require 'json'

# Local overrides; the pinned public standards library remains unchanged.
module NECBPart8Reference
  LOADS = %i[people electricEquipment gasEquipment otherEquipment internalMass].freeze

  def prepare_part8(model)
    @part8_source = model.clone.to_Model
    @part8_audit = {'mode' => 'PreserveProposedInputs', 'limitations' => [], 'fenestration' => {}}
    @part8_conditioning = {}
    @part8_source.getThermalZones.each do |zone|
      next if zone.spaces.empty?
      thermostat = zone.thermostatSetpointDualSetpoint
      heated = false
      cooled = false
      unless thermostat.empty?
        heating = thermostat.get.heatingSetpointTemperatureSchedule
        cooling = thermostat.get.coolingSetpointTemperatureSchedule
        unless heating.empty?
          maximum = OpenstudioStandards::Schedules.schedule_get_min_max(heating.get)['max']
          raise "Unsupported heating schedule in '#{zone.nameString}'; use Constant, Ruleset or Compact schedules." if maximum.nil?
          heated = maximum > 5.0
        end
        unless cooling.empty?
          minimum = OpenstudioStandards::Schedules.schedule_get_min_max(cooling.get)['min']
          raise "Unsupported cooling schedule in '#{zone.nameString}'; use Constant, Ruleset or Compact schedules." if minimum.nil?
          cooled = minimum < 33.0
        end
      end
      if heated != cooled && !@keep_systems
        raise "Part 8 preservation currently supports heated-and-cooled or unconditioned zones. '#{zone.nameString}' is heating-only or cooling-only; its conditioning will not be silently changed."
      end
      if !heated && !cooled && (!zone.equipment.empty? || zone.airLoopHVAC.is_initialized || zone.useIdealAirLoads)
        raise "Cannot establish conditioning from the thermostat for '#{zone.nameString}'. Supply supported dual-setpoint schedules."
      end
      @part8_conditioning[zone.nameString] = heated || cooled
    end
    unless @part8_conditioning.values.any? || @keep_systems
      raise 'No conditioned zones were found after NECB default preparation. Check the space-use assignments or choose Keep existing systems for an unconditioned model.'
    end
    vintage = determine_spacetype_vintage(model)
    source_types = Standard.build(vintage).standards_data['space_types']
    model.getThermalZones.each do |zone|
      categories = zone.spaces.map do |space|
        type = space.spaceType.get
        data = source_types.find { |row| row['space_type'] == type.standardsSpaceType.get && row['building_type'] == type.standardsBuildingType.get }
        raise "Cannot find NECB HVAC selection data for '#{space.nameString}'." unless data
        data['necb_hvac_system_selection_type']
      end.uniq
      if categories.size > 1 && !@keep_systems
        raise "Preserved zone '#{zone.nameString}' contains different NECB HVAC selection categories. Separate those thermal blocks in the proposed model before applying this measure."
      end
    end
    @part8_source.getSubSurfaces.each do |opening|
      next unless %w[FixedWindow OperableWindow GlassDoor Skylight].include?(opening.subSurfaceType)
      next unless opening.surface.is_initialized && opening.surface.get.outsideBoundaryCondition == 'Outdoors'
      construction = opening.construction
      next if construction.empty? # Missing envelope is supplied by the reference rules.
      if construction.get.to_Construction.empty? || construction.get.to_Construction.get.layers.size != 1 || construction.get.to_Construction.get.layers.first.to_SimpleGlazing.empty?
        raise "Preserving glazing optics currently requires a one-layer SimpleGlazing construction: '#{opening.nameString}'. Detailed glazing is not silently replaced."
      end
    end
  end

  def part8_conditioned?(space)
    @part8_conditioning.fetch(space.thermalZone.get.nameString, false)
  end

  def clean_and_scale_model(model:, **_options)
    # Keep schedules, thermostats, outdoor air and all original load instances.
    OpenstudioStandards::HVAC.remove_all_hvac(model)
    model.getWaterUseConnectionss.each(&:remove)
    model.getWaterUseEquipments.each(&:remove)
    model.getWaterUseEquipmentDefinitions.each(&:remove)
    model.getDaylightingControls.each(&:remove)
    BTAP::Resources::Envelope.remove_all_envelope_information(model)
    model.getThermalZones.each { |zone| zone.setUseIdealAirLoads(@part8_conditioning.fetch(zone.nameString, false)) }
  end

  def apply_loads(model:, lights_type: 'NECB_Default', lights_scale: 1.0, **_options)
    old_handles = model.getLightss.map { |light| light.handle.to_s }
    raise 'Could not validate NECB Space Types.' unless validate_and_upate_space_types(model)
    model.getBuilding.setStandardsTemplate(self.class.name)
    # Calculate reference lighting on a disposable full-geometry copy. Do not
    # replace occupancy, process equipment, OA or schedules in the real model.
    lighting_model = model.clone.to_Model
    set_occ_sensor_spacetypes(lighting_model, @space_type_map)
    model_add_loads(lighting_model, lights_type, 1.0)
    reference = lighting_model.getSpaces.to_h do |space|
      [space.nameString, space.spaceType.get.lights.map { |light| [light, light.getLightingPower(space.floorArea, space.numberOfPeople) * light.multiplier] }]
    end
    model.getSpaces.each do |space|
      original = @part8_source.getSpaceByName(space.nameString).get
      original_lights = original.lights.to_a + original.spaceType.get.lights.to_a
      raise "Luminaires are not yet supported in preservation mode: '#{space.nameString}'. Convert them to Lights first." unless original.luminaires.empty? && original.spaceType.get.luminaires.empty?
      power = reference.fetch(space.nameString).sum { |_light, watts| watts }
      prototype = reference.fetch(space.nameString).first&.first
      weights = original_lights.map { |light| light.getLightingPower(space.floorArea, original.numberOfPeople) * light.multiplier }
      if weights.sum > 0 && power > 0
        original_lights.zip(weights).each do |light, weight|
          next if weight <= 0
          definition = light.lightsDefinition.clone(model).to_LightsDefinition.get
          definition.setLightingLevel(power * weight / weights.sum)
          instance = OpenStudio::Model::Lights.new(definition)
          instance.setName("#{space.nameString} Reference #{light.nameString}")
          instance.setSpace(space)
          instance.setSchedule(light.schedule.get.clone(model).to_Schedule.get) unless light.schedule.empty?
          instance.setEndUseSubcategory(light.endUseSubcategory)
        end
      elsif prototype && power > 0
        definition = prototype.lightsDefinition.clone(model).to_LightsDefinition.get
        definition.setLightingLevel(power)
        instance = OpenStudio::Model::Lights.new(definition)
        instance.setSpace(space)
        instance.setSchedule(prototype.schedule.get.clone(model).to_Schedule.get) unless prototype.schedule.empty?
        @part8_audit['limitations'] << "#{space.nameString}: no proposed lighting power; reference lighting uses the library schedule."
      end
    end
    # Delete only the old lighting instances; newly created reference lights
    # have new handles and are assigned directly to Spaces.
    model.getLightss.each { |light| light.remove if old_handles.include?(light.handle.to_s) }
  end

  def model_create_thermal_zones(model, _multipliers = nil)
    # apply_envelope calls this too; preserving zones must cover both entry points.
    model.getThermalZones.each { |zone| zone.setUseIdealAirLoads(@part8_conditioning.fetch(zone.nameString, false)) }
  end

  def apply_auto_zoning(model:, **_options)
    model_create_thermal_zones(model)
  end

  def store_space_sizing_loads(model)
    @stored_space_heating_sizing_loads = {}
    @stored_space_cooling_sizing_loads = {}
    model.getSpaces.each do |space|
      zone = space.thermalZone.get
      area = zone.spaces.sum(&:floorArea)
      raise "Zone '#{zone.nameString}' has zero floor area." if area <= 0
      @stored_space_heating_sizing_loads[space] = zone.autosizedHeatingDesignLoad.get / area if part8_conditioned?(space)
      @stored_space_cooling_sizing_loads[space] = zone.autosizedCoolingDesignLoad.get / area if part8_conditioned?(space)
      @stored_space_heating_sizing_loads[space] ||= 0.0
      @stored_space_cooling_sizing_loads[space] ||= 0.0
    end
  end

  %i[is_a_necb_dwelling_unit? is_an_necb_wet_space? is_an_necb_wildcard_space? is_an_necb_storage_space?].each do |method|
    define_method(method) { |space| part8_conditioned?(space) && super(space) }
  end

  def create_necb_system(**options)
    options[:zones] = options.fetch(:zones).select { |zone| @part8_conditioning.fetch(zone.nameString, false) }
    return if options[:zones].empty?
    super(**options)
  end

  def apply_fdwr_srr_daylighting(model:, necb_hdd: true, **_options)
    walls = model.getSurfaces.select do |surface|
      surface.surfaceType == 'Wall' && surface.outsideBoundaryCondition == 'Outdoors' && part8_conditioned?(surface.space.get)
    end
    target = max_fwdr(get_necb_hdd18(model: model, necb_hdd: necb_hdd))
    if walls.any? && walls.all? { |wall| wall.subSurfaces.empty? }
      # There is no proposed facade distribution to preserve. Use the bundled
      # NECB window generator, and disclose this design-stage assumption.
      apply_standard_window_to_wall_ratio(model: model, fdwr_set: target, necb_hdd: necb_hdd)
      @part8_audit['limitations'] << 'No exterior wall openings existed; NECB default windows were generated. Review this assumed fenestration layout.'
    end
    before = wall_opening_summary(walls)
    resize_openings(walls, target, 'fdwr', increase: true)
    after = wall_opening_summary(walls)
    fdwr_audit = @part8_audit['fenestration']['fdwr']
    if fdwr_audit
      fdwr_audit['definition'] = '(vertical fenestration + opaque doors) / gross above-ground wall area'
      fdwr_audit['areas_before'] = before
      fdwr_audit['areas_after'] = after
      # NECB 8.4.4.3.(3): preserve each orientation's share of openings.
      before['orientations'].each do |direction, data|
        expected = data['opening_area_m2'] * fdwr_audit['area_factor']
        actual = after['orientations'].fetch(direction)['opening_area_m2']
        raise "FDWR adjustment changed the opening-area share at #{direction} degrees." if (actual - expected).abs > 1e-5
      end
    end
    roofs = model.getSurfaces.select do |surface|
      surface.surfaceType == 'RoofCeiling' && surface.outsideBoundaryCondition == 'Outdoors' && part8_conditioned?(surface.space.get)
    end
    resize_openings(roofs, get_standards_constant('skylight_to_roof_ratio_max_value'), 'srr', increase: false, types: ['Skylight'])
  end

  def wall_opening_summary(walls)
    result = {'gross_wall_area_m2' => 0.0, 'vertical_fenestration_area_m2' => 0.0, 'opaque_door_area_m2' => 0.0, 'orientations' => {}}
    walls.each do |wall|
      space = wall.space.get
      normal = space.transformation * wall.outwardNormal
      azimuth = (Math.atan2(normal.x, normal.y) * 180.0 / Math::PI + space.model.getBuilding.northAxis) % 360.0
      direction = format('%.3f', azimuth)
      facade = (result['orientations'][direction] ||= {'gross_wall_area_m2' => 0.0, 'vertical_fenestration_area_m2' => 0.0, 'opaque_door_area_m2' => 0.0})
      area = wall.grossArea * space.multiplier
      result['gross_wall_area_m2'] += area
      facade['gross_wall_area_m2'] += area
      wall.subSurfaces.each do |opening|
        key = %w[Door OverheadDoor].include?(opening.subSurfaceType) ? 'opaque_door_area_m2' : 'vertical_fenestration_area_m2'
        area = opening.grossArea * opening.multiplier * space.multiplier
        result[key] += area
        facade[key] += area
      end
    end
    (result['orientations'].values + [result]).each do |data|
      data['opening_area_m2'] = data['vertical_fenestration_area_m2'] + data['opaque_door_area_m2']
      wall_area = data['gross_wall_area_m2']
      data['fdwr'] = wall_area > 0 ? data['opening_area_m2'] / wall_area : 0.0
      data['glazing_only_wwr'] = wall_area > 0 ? data['vertical_fenestration_area_m2'] / wall_area : 0.0
    end
    result
  end

  def resize_openings(surfaces, target, label, increase:, types: nil)
    gross = surfaces.sum { |surface| surface.grossArea * surface.space.get.multiplier }
    openings = surfaces.flat_map(&:subSurfaces)
    openings = openings.select { |opening| types.include?(opening.subSurfaceType) } if types
    area = openings.sum { |opening| opening.grossArea * opening.surface.get.space.get.multiplier * opening.multiplier }
    return if gross <= 0
    before = area / gross
    desired = increase ? target : [before, target].min
    if area <= 0
      raise 'Cannot proportionally adjust FDWR without existing exterior openings.' if desired > 0
      return
    end
    factor = desired * gross / area
    # One common area factor preserves every facade's share of total openings,
    # retaining opening types and locations rather than replacing doors.
    openings.each do |opening|
      vertices = opening.vertices.to_a
      center = OpenStudio::Point3d.new(vertices.sum(&:x) / vertices.size, vertices.sum(&:y) / vertices.size, vertices.sum(&:z) / vertices.size)
      scale = Math.sqrt(factor)
      # A thin window can exceed wall height under isotropic expansion even
      # though its target area fits. Change its aspect ratio, retaining centre
      # and area share, before rejecting genuinely infeasible layouts.
      scales = [scale, scale, scale]
      parent = opening.surface.get
      normal = parent.outwardNormal
      drop = [normal.x.abs, normal.y.abs, normal.z.abs].each_with_index.max.last
      axes = [0, 1, 2] - [drop]
      coordinates = vertices.map { |point| [point.x, point.y, point.z] }
      boundary = parent.vertices.map { |point| [point.x, point.y, point.z] }
      midpoint = [center.x, center.y, center.z]
      limits = axes.map do |axis|
        negative = midpoint[axis] - coordinates.map { |p| p[axis] }.min
        positive = coordinates.map { |p| p[axis] }.max - midpoint[axis]
        [(midpoint[axis] - boundary.map { |p| p[axis] }.min) / [negative, 1e-10].max,
         (boundary.map { |p| p[axis] }.max - midpoint[axis]) / [positive, 1e-10].max].min
      end
      axis_aligned = [normal.x.abs, normal.y.abs, normal.z.abs].max > 0.999999
      if (axis_aligned || normal.z.abs < 1e-7) && limits.any? { |limit| scale > limit } && factor <= limits.inject(:*)
        first = [scale, limits[0]].min
        second = factor / first
        if second > limits[1]
          second = limits[1]
          first = factor / second
        end
        scales[axes[0]], scales[axes[1]] = first, second
        scales[drop] = scales[([0, 1] - [drop]).first] if normal.z.abs < 1e-7
      end
      points = OpenStudio::Point3dVector.new
      vertices.each { |point| points << OpenStudio::Point3d.new(center.x + (point.x - center.x) * scales[0], center.y + (point.y - center.y) * scales[1], center.z + (point.z - center.z) * scales[2]) }
      raise "Cannot resize '#{opening.nameString}'." unless opening.setVertices(points)
    end
    surfaces.each { |surface| validate_opening_geometry(surface) }
    after = openings.sum { |opening| opening.grossArea * opening.surface.get.space.get.multiplier * opening.multiplier } / gross
    raise "#{label.upcase} target was not achieved." if (after - desired).abs > 0.00001
    @part8_audit['fenestration'][label] = {'before' => before, 'after' => after, 'target' => desired, 'area_factor' => factor}
  end

  def projected_polygon(surface, vertices)
    normal = surface.outwardNormal
    drop = [normal.x.abs, normal.y.abs, normal.z.abs].each_with_index.max.last
    vertices.map { |point| [point.x, point.y, point.z].each_with_index.reject { |_v, i| i == drop }.map(&:first) }
  end

  def source_availability(zone)
    original = @part8_source.getThermalZoneByName(zone.nameString).get
    return original.airLoopHVAC.get.availabilitySchedule unless original.airLoopHVAC.empty?
    schedules = original.equipment.filter_map do |object|
      equipment = concrete_equipment(object)
      if equipment.respond_to?(:availabilitySchedule)
        schedule = equipment.availabilitySchedule
        schedule = schedule.empty? ? nil : schedule.get if schedule.respond_to?(:get)
        schedule
      end
    end
    raise "Proposed zone '#{zone.nameString}' has different equipment availability schedules; automatic transfer is ambiguous." if schedules.map { |s| availability_key(s) }.uniq.size > 1
    schedules.first
  end

  def concrete_equipment(object)
    type = object.iddObjectType.valueName.delete_prefix('OS_').delete('_').sub('LowTemperatureRadiant', 'LowTempRadiant')
    conversion = "to_#{type}"
    return object unless object.respond_to?(conversion)
    converted = object.public_send(conversion)
    converted.empty? ? object : converted.get
  end

  def availability_key(schedule)
    constant = schedule.to_ScheduleConstant
    constant.empty? ? ['shared_schedule', schedule.handle.to_s] : ['constant', constant.get.value]
  end

  def inside_polygon?(point, polygon)
    inside = false
    polygon.each_with_index do |a, i|
      b = polygon[(i + 1) % polygon.size]
      cross = (point[0] - a[0]) * (b[1] - a[1]) - (point[1] - a[1]) * (b[0] - a[0])
      return true if cross.abs < 1e-7 && point[0].between?(*[a[0], b[0]].minmax) && point[1].between?(*[a[1], b[1]].minmax)
      if (a[1] > point[1]) != (b[1] > point[1]) && point[0] < (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0]
        inside = !inside
      end
    end
    inside
  end

  def validate_opening_geometry(surface)
    wall = projected_polygon(surface, surface.vertices)
    polygons = surface.subSurfaces.map { |opening| [opening.nameString, projected_polygon(surface, opening.vertices)] }
    polygons.each do |name, polygon|
      turns = polygon.each_with_index.map do |a, i|
        b = polygon[(i + 1) % polygon.size]
        c = polygon[(i + 2) % polygon.size]
        (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
      end.reject { |turn| turn.abs < 1e-7 }
      raise "Concave opening '#{name}' is not supported for proportional resizing." if turns.any?(&:positive?) && turns.any?(&:negative?)
      samples = polygon + polygon.each_with_index.map { |a, i| b = polygon[(i + 1) % polygon.size]; [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2] }
      raise "Proportional FDWR adjustment moves '#{name}' beyond its parent surface. Revise the proposed opening layout; no uniform-window fallback is applied." unless samples.all? { |point| inside_polygon?(point, wall) }
    end
    polygons.combination(2).each do |(name_a, a), (name_b, b)|
      # Separating-axis check for convex openings, including touching edges.
      axes = [a, b].flat_map { |poly| poly.each_with_index.map { |p, i| q = poly[(i + 1) % poly.size]; [q[1] - p[1], p[0] - q[0]] } }
      separated = axes.any? do |axis|
        pa = a.map { |p| p[0] * axis[0] + p[1] * axis[1] }.minmax
        pb = b.map { |p| p[0] * axis[0] + p[1] * axis[1] }.minmax
        pa[1] <= pb[0] + 1e-7 || pb[1] <= pa[0] + 1e-7
      end
      raise "Proportional FDWR adjustment overlaps '#{name_a}' and '#{name_b}'. Revise the proposed opening layout." unless separated
    end
  end

  def apply_envelope(model:, **options)
    super
    @part8_source.getSurfaces.each do |original|
      current = model.getSurfaceByName(original.nameString)
      next if current.empty? || original.construction.empty?
      if %w[Surface Adiabatic].include?(original.outsideBoundaryCondition)
        current.get.setConstruction(original.construction.get.clone(model).to_ConstructionBase.get)
      end
    end
    @part8_source.getSubSurfaces.each do |original|
      current = model.getSubSurfaceByName(original.nameString)
      next if current.empty? || original.construction.empty?
      next unless %w[FixedWindow OperableWindow GlassDoor Skylight].include?(original.subSurfaceType)
      ref = current.get.construction.get
      glazing = original.construction.get.to_Construction.get.layers.first.to_SimpleGlazing.get.clone(model).to_SimpleGlazing.get
      layer = ref.to_Construction.get.layers.first.to_SimpleGlazing
      raise "Reference glazing for '#{original.nameString}' is not SimpleGlazing." if layer.empty?
      glazing.setUFactor(layer.get.uFactor)
      construction = OpenStudio::Model::Construction.new(model)
      construction.setName("#{original.nameString} Reference U / Proposed Optics")
      materials = OpenStudio::Model::MaterialVector.new
      materials << glazing
      construction.setLayers(materials)
      current.get.setConstruction(construction)
    end
    # Envelope cleanup can remove internal-mass constructions. Restore their
    # definitions and instances from the proposed snapshot before sizing.
    model.getInternalMasss.each(&:remove)
    @part8_source.getInternalMasss.each do |mass|
      copy = mass.clone(model).to_InternalMass.get
      copy.setSpace(model.getSpaceByName(mass.space.get.nameString).get) unless mass.space.empty?
      copy.setSpaceType(reference_space_type(model, mass.spaceType.get)) unless mass.spaceType.empty?
    end
  end

  def reference_space_type(model, original)
    # Vintage upgrades rename Space Types. Find the same assignment through an
    # unchanged Space name, rather than assuming the proposed type name survives.
    space = original.spaces.first
    raise "Unused proposed Space Type '#{original.nameString}' cannot receive a restored load." unless space
    model.getSpaceByName(space.nameString).get.spaceType.get
  end

  def model_add_swh(model:, **options)
    return true if @part8_source.getWaterUseEquipments.empty?
    super
    connection = model.getWaterUseConnectionss.find { |item| item.plantLoop.is_initialized }
    raise 'Cannot create a reference SWH loop for the proposed water-use loads.' unless connection
    loop = connection.plantLoop.get
    model.getWaterUseEquipments.each(&:remove)
    model.getWaterUseConnectionss.each(&:remove)
    connection = OpenStudio::Model::WaterUseConnections.new(model)
    loop.addDemandBranchForComponent(connection)
    @part8_source.getWaterUseEquipments.each do |equipment|
      copy = equipment.clone(model).to_WaterUseEquipment.get
      copy.setSpace(model.getSpaceByName(equipment.space.get.nameString).get) unless equipment.space.empty?
      copy.setSpaceType(reference_space_type(model, equipment.spaceType.get)) unless equipment.spaceType.empty?
      connection.addWaterUseEquipment(copy)
    end
    @part8_audit['limitations'] << 'SWH demand and schedules preserved; heater capacity, tank size and distribution still use NRC sizing assumptions and require project review.'
    true
  end

  def model_apply_infiltration_standard(model)
    return apply_part8_2020_infiltration(model) if self.class.name == 'NECB2020'
    model.getSpaceInfiltrationEffectiveLeakageAreas.each(&:remove)
    model.getSpaceInfiltrationFlowCoefficients.each(&:remove)
    super
    # Part 8 uses leakage at a typical pressure differential, rather than
    # multiplying that converted design flow by the prototype wind coefficient.
    model.getSpaceInfiltrationDesignFlowRates.each do |infiltration|
      infiltration.setConstantTermCoefficient(1.0)
      infiltration.setTemperatureTermCoefficient(0.0)
      infiltration.setVelocityTermCoefficient(0.0)
      infiltration.setVelocitySquaredTermCoefficient(0.0)
      infiltration.setSchedule(model.alwaysOnDiscreteSchedule)
    end
    @part8_audit['infiltration'] = 'NECB edition default, constant at typical pressure; prototype wind modulation disabled.'
  end

  def apply_part8_2020_infiltration(model)
    # NECB2020 8.4.2.9.(2), 8.4.3.3.(3), 8.4.4.3.(6):
    # I_AGW = I_75 * (5/75)^0.60 * A_envelope / A_above_ground_wall.
    # The air barrier bounds conditioned space, including ground/foundation
    # floors and ceilings adjoining unconditioned spaces. An attic roof is not
    # that conditioned boundary. Allocate the converted flow to above-grade
    # walls, rather than distributing it to all exterior surfaces/attic roofs.
    envelope = 0.0
    walls_by_space = {}
    model.getSpaces.each do |space|
      next unless part8_conditioned?(space)
      wall_area = 0.0
      space.surfaces.each do |surface|
        boundary = surface.outsideBoundaryCondition
        boundary_surface = %w[Outdoors Ground Foundation GroundFCfactorMethod].include?(boundary) || boundary.start_with?('Ground')
        if boundary == 'Surface' && !surface.adjacentSurface.empty?
          adjacent = surface.adjacentSurface.get.space
          boundary_surface = !adjacent.empty? && !part8_conditioned?(adjacent.get)
        end
        envelope += surface.grossArea * space.multiplier if boundary_surface
        wall_area += surface.grossArea * space.multiplier if boundary == 'Outdoors' && surface.surfaceType == 'Wall'
      end
      walls_by_space[space] = wall_area if wall_area > 0
    end
    wall_area = walls_by_space.values.sum
    raise 'NECB2020 Part 8 air-leakage allocation requires conditioned above-ground exterior walls.' if wall_area <= 0 || envelope <= 0
    rate_75 = get_standards_constant('infiltration_rate_m3_per_s_per_m2')
    rate_5_wall = rate_75 * (5.0 / 75.0) ** 0.60 * envelope / wall_area
    model.getSpaceInfiltrationDesignFlowRates.each(&:remove)
    model.getSpaceInfiltrationEffectiveLeakageAreas.each(&:remove)
    model.getSpaceInfiltrationFlowCoefficients.each(&:remove)
    walls_by_space.each do |space, effective_area|
      infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
      infiltration.setName("#{space.nameString} Part 8 Infiltration")
      # DesignFlowRate is per physical Space; EnergyPlus applies its multiplier.
      infiltration.setDesignFlowRate(rate_5_wall * effective_area / space.multiplier)
      infiltration.setSchedule(model.alwaysOnDiscreteSchedule)
      infiltration.setConstantTermCoefficient(1.0)
      infiltration.setTemperatureTermCoefficient(0.0)
      infiltration.setVelocityTermCoefficient(0.0)
      infiltration.setVelocitySquaredTermCoefficient(0.0)
      infiltration.setSpace(space)
    end
    @part8_audit['infiltration'] = 'NECB2020 default converted from 75 Pa to 5 Pa and allocated to conditioned above-ground walls; constant, without prototype wind modulation.'
    @part8_audit['air_leakage'] = {'normalized_rate_75_pa_m3_s_m2' => rate_75, 'flow_exponent' => 0.60,
      'conditioned_envelope_area_m2' => envelope, 'above_ground_wall_area_m2' => wall_area,
      'rate_5_pa_per_wall_area_m3_s_m2' => rate_5_wall, 'total_design_flow_m3_s' => rate_5_wall * wall_area,
      'allocation_by_space_m3_s' => walls_by_space.to_h { |space, area| [space.nameString, rate_5_wall * area] }}
    true
  end

  def finish_part8(model)
    actual = model.getThermalZones.to_h { |zone| [zone.nameString, [zone.multiplier, zone.spaces.map(&:nameString).sort]] }
    expected = @part8_source.getThermalZones.to_h { |zone| [zone.nameString, [zone.multiplier, zone.spaces.map(&:nameString).sort]] }
    raise 'Reference generation changed proposed thermal-block assignments.' unless actual == expected
    model.getThermalZones.each do |zone|
      conditioned = @part8_conditioning.fetch(zone.nameString, false)
      if !conditioned && (!zone.equipment.empty? || zone.airLoopHVAC.is_initialized)
        raise "Unconditioned zone '#{zone.nameString}' acquired HVAC."
      end
      zone.setUseIdealAirLoads(false)
      schedule = source_availability(zone)
      unless schedule.nil?
        zone.equipment.each do |object|
          equipment = concrete_equipment(object)
          equipment.setAvailabilitySchedule(schedule.clone(model).to_Schedule.get) if equipment.respond_to?(:setAvailabilitySchedule)
        end
      end
    end
    model.getAirLoopHVACs.each do |loop|
      schedules = loop.thermalZones.filter_map { |zone| source_availability(zone) }
      raise "Reference air loop '#{loop.nameString}' combines different proposed availability schedules." if schedules.map { |s| availability_key(s) }.uniq.size > 1
      loop.setAvailabilitySchedule(schedules.first.clone(model).to_Schedule.get) unless schedules.empty?
    end
    @part8_audit['thermal_blocks_preserved'] = true
    @part8_audit['occupancy_process_loads_and_schedules_preserved'] = true
    @part8_audit['limitations'] << 'NRC HVAC selection and efficiencies applied. Review fuel selection, custom availability managers/EMS, daylight controls, shading treatment and other project-specific Part 8 exceptions.'
    model.getBuilding.additionalProperties.setFeature('necb_part8_audit', JSON.generate(@part8_audit))
    @part8_audit
  end
end
