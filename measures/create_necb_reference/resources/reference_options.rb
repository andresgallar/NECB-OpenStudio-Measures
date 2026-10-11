require_relative 'part8_reference'
require_relative 'space_type_mapping'

# User choices are independent of the standards library's destructive prototype
# cleanup. Existing systems are never passed to its efficiency/sizing routines
# when the user has chosen to retain them.
module NECBReferenceOptions
  LOAD_COLLECTIONS = %i[people lights luminaires electricEquipment gasEquipment otherEquipment].freeze
  INFILTRATION_COLLECTIONS = %i[spaceInfiltrationDesignFlowRates spaceInfiltrationEffectiveLeakageAreas spaceInfiltrationFlowCoefficients].freeze

  def configure_reference(model, request)
    @keep_operating = request.fetch('operating_inputs', 'KeepExisting') == 'KeepExisting'
    @keep_systems = request.fetch('building_systems', 'ReplaceWithNECB') == 'KeepExisting'
    @completion = []
    @input_classifications = model.getSpaces.to_h do |space|
      type = space.spaceType.get
      [space.nameString, [type.nameString, type.standardsBuildingType.get, type.standardsSpaceType.get]]
    end
    @retained_system_objects = system_objects(model).to_h { |object| [object.handle.to_s, object.to_s] } if @keep_systems
    normalize_classifications(model)
    # Generate clean load/schedule profiles on a disposable model. Never use the
    # proposed loads as the library's mutable default-profile objects.
    defaults = model.clone.to_Model
    used = defaults.getSpaces.map { |space| space.spaceType.get.handle.to_s }
    defaults.getSpaceTypes.each { |type| type.remove unless used.include?(type.handle.to_s) }
    (defaults.getSpaces.to_a + defaults.getSpaceTypes.to_a).each do |owner|
      LOAD_COLLECTIONS.each { |collection| owner.public_send(collection).each(&:remove) }
    end
    raise 'Could not obtain NECB default profiles.' unless validate_and_upate_space_types(defaults)
    model_add_loads(defaults, 'NECB_Default', 1.0)
    @default_model = defaults
    model.getSpaces.each do |space|
      profile = defaults.getSpaceByName(space.nameString).get.spaceType.get
      LOAD_COLLECTIONS.each do |collection|
        next if collection == :luminaires
        existing = effective_loads(space, collection)
        if !@keep_operating || existing.empty?
          # Deletion of shared type loads is done once below for Replace.
          @completion << "#{space.nameString}: #{collection} #{@keep_operating ? 'filled where absent' : 'replaced'} using NRC NECB profiles."
        else
          existing.each do |load|
            default = profile.public_send(collection).find { |item| !load_schedule(item).empty? }
            if load_schedule(load).empty? && default
              set_load_schedule(load, load_schedule(default).get.clone(model).to_Schedule.get)
            end
            if collection == :people && load.activityLevelSchedule.empty? && default && !default.activityLevelSchedule.empty?
              load.setActivityLevelSchedule(default.activityLevelSchedule.get.clone(model).to_Schedule.get)
            end
          end
        end
      end
    end
    unless @keep_operating
      (model.getSpaces.to_a + model.getSpaceTypes.to_a).each do |owner|
        LOAD_COLLECTIONS.each { |collection| owner.public_send(collection).each(&:remove) }
      end
    end
    model.getSpaces.each do |space|
      profile = defaults.getSpaceByName(space.nameString).get.spaceType.get
      LOAD_COLLECTIONS.reject { |collection| collection == :luminaires }.each do |collection|
        next if @keep_operating && (!effective_loads(space, collection).empty? || (collection == :lights && !effective_loads(space, :luminaires).empty?))
        profile.public_send(collection).each do |load|
          copy = concrete_equipment(load.clone(model))
          copy.setSpace(space)
          # Resolved inherited schedules must become explicit: this instance
          # now belongs to a Space with the user's original Space Type.
          set_load_schedule(copy, load_schedule(load).get.clone(model).to_Schedule.get) unless load_schedule(load).empty?
          if collection == :people && !load.activityLevelSchedule.empty?
            copy.setActivityLevelSchedule(load.activityLevelSchedule.get.clone(model).to_Schedule.get)
          end
        end
      end
      if !@keep_operating || space.designSpecificationOutdoorAir.empty?
        space.setDesignSpecificationOutdoorAir(profile.designSpecificationOutdoorAir.get.clone(model).to_DesignSpecificationOutdoorAir.get) unless profile.designSpecificationOutdoorAir.empty?
      end
    end
    model.getThermalZones.each do |zone|
      next if zone.spaces.empty?
      explicit_unconditioned = zone.additionalProperties.getFeatureAsString('necb_conditioning')
      next if !explicit_unconditioned.empty? && explicit_unconditioned.get == 'Unconditioned'
      profile = defaults.getSpaceByName(zone.spaces.sort_by(&:nameString).first.nameString).get.spaceType.get
      template = defaults.getThermostatSetpointDualSetpointByName("#{profile.nameString} Thermostat")
      next if template.empty?
      old = zone.thermostatSetpointDualSetpoint
      if old.empty? || !@keep_operating
        replacement = template.get.clone(model).to_ThermostatSetpointDualSetpoint.get
        # Replacing profiles must not introduce heating/cooling that the source
        # explicitly disabled (including a completely unconditioned block).
        unless old.empty?
          %w[heating cooling].each do |kind|
            getter = "#{kind}SetpointTemperatureSchedule"
            schedule = old.get.public_send(getter)
            next if schedule.empty?
            limits = OpenstudioStandards::Schedules.schedule_get_min_max(schedule.get)
            disabled = kind == 'heating' ? limits['max'] && limits['max'] <= 5 : limits['min'] && limits['min'] >= 33
            replacement.public_send("set#{kind.capitalize}SetpointTemperatureSchedule", schedule.get) if disabled
          end
        end
        zone.setThermostatSetpointDualSetpoint(replacement)
        @completion << "#{zone.nameString}: #{@keep_operating ? 'missing' : 'reference-default'} thermostat supplied from #{profile.nameString}."
      else
        %w[heating cooling].each do |kind|
          getter = "#{kind}SetpointTemperatureSchedule"
          setter = "set#{kind.capitalize}SetpointTemperatureSchedule"
          value = template.get.public_send(getter)
          old.get.public_send(setter, value.get.clone(model).to_Schedule.get) if old.get.public_send(getter).empty? && !value.empty?
        end
      end
    end
    # Profiles are now on the real model; snapshot them before prototype cleanup.
    prepare_part8(model)
    @part8_audit['mode'] = 'SingleModelReference'
    @part8_audit['operating_inputs'] = @keep_operating ? 'Keep existing; fill absent categories' : 'Replace with NECB library defaults'
    @part8_audit['building_systems'] = @keep_systems ? 'Keep existing HVAC/SWH/infiltration' : 'Replace with NECB reference systems/infiltration'
    @part8_audit['completion'] = @completion
    @part8_audit['limitations'] << 'Retained operating inputs include proposed lighting power. Review lighting allowance/controls for a Part 8 compliance comparison.' if @keep_operating
    @part8_audit['limitations'] << 'Existing HVAC, water heating and infiltration retained by request; these systems have not been converted to Part 8 reference requirements.' if @keep_systems
    @part8_audit['limitations'] << 'Replacement operating profiles are NRC NECB defaults. Use the same occupancy/process-load/schedule assumptions in the proposed model when comparing energy performance.' unless @keep_operating
  end

  def effective_loads(space, collection)
    space.public_send(collection).to_a + space.spaceType.get.public_send(collection).to_a
  end

  def normalize_classifications(model)
    target_pairs = get_all_spacetype_names
    model.getSpaceTypes.each do |type|
      pair = NECBSpaceTypeMapping.pair(type)
      next if target_pairs.include?(pair)
      targets = @standards_data.fetch('space_type_upgrade_map').filter_map do |row|
        matches = %w[NECB2011 NECB2015 NECB2017 NECB2020 BTAPPRE1980 BTAP1980TO2010].any? do |vintage|
          [row["#{vintage}_building_type"].to_s.strip, row["#{vintage}_space_type"].to_s.strip] == pair
        end
        next unless matches
        value = [row["#{self.class.name}_building_type"].to_s.strip, row["#{self.class.name}_space_type"].to_s.strip]
        value if target_pairs.include?(value)
      end.uniq
      raise "No unambiguous #{self.class.name} translation for '#{type.nameString}' (#{pair.join(' / ')}). Set this Space Type's standards metadata to a reviewed #{self.class.name} pair from space_type_catalog.csv before applying the preservation workflow. Complete replacement instead follows the pinned prototype's legacy upgrade choices and reports them for review." unless targets.size == 1
      type.setStandardsBuildingType(targets.first[0])
      type.setStandardsSpaceType(targets.first[1])
    end
  end

  def load_schedule(load)
    load.respond_to?(:numberofPeopleSchedule) ? load.numberofPeopleSchedule : load.schedule
  end

  def source_availability(zone)
    @keep_operating ? super : nil
  end

  def set_load_schedule(load, schedule)
    load.respond_to?(:setNumberofPeopleSchedule) ? load.setNumberofPeopleSchedule(schedule) : load.setSchedule(schedule)
  end

  def system_objects(model)
    # Model graph components, connections and their properties must survive Keep.
    model.objects.select do |object|
      next false if object.to_ThermalZone.is_initialized # Thermostats follow the operating-input choice.
      next false if @keep_operating == false && object.iddObject.name.start_with?('OS:WaterUse:')
      object.to_HVACComponent.is_initialized || object.iddObject.name.match?(/OS:(?:AirLoopHVAC|PlantLoop|WaterUse:|SpaceInfiltration|EnergyManagementSystem:|Connection$|PortList$)/)
    end
  end

  def clean_and_scale_model(model:, **options)
    return super unless @keep_systems
    # Do not delete materials/constructions: retained systems may reference them
    # (e.g. radiant systems). Reference envelope is assigned separately.
    model.getSurfaces.each(&:resetConstruction)
    model.getSubSurfaces.each(&:resetConstruction)
    model.getBuilding.resetDefaultConstructionSet
  end

  def apply_loads(model:, **_options)
    raise 'Could not validate NECB classifications.' unless validate_and_upate_space_types(model)
    model.getBuilding.setStandardsTemplate(self.class.name)
    # configure_reference already populated or retained the requested loads.
  end

  def model_create_thermal_zones(model, multipliers = nil)
    return true if @keep_systems
    super
  end

  def apply_systems_and_efficiencies(model:, **options)
    return super unless @keep_systems
    replace_water_demand_on_retained_systems(model) unless @keep_operating
    unserved = model.getThermalZones.select do |zone|
      @part8_conditioning[zone.nameString] && zone.equipment.empty? && zone.airLoopHVAC.empty? && !zone.useIdealAirLoads
    end
    unless unserved.empty?
      @part8_audit['limitations'] << "Keep systems leaves #{unserved.size} conditioned zones without HVAC. Choose Replace with NECB reference systems to generate equipment."
    end
    true
  end

  def model_apply_infiltration_standard(model)
    return super unless @keep_systems
    @part8_audit['infiltration'] = 'Existing infiltration retained unchanged; absent infiltration is not added in Keep systems.'
    true
  end

  def model_add_swh(model:, **options)
    # Only called in Replace systems. Existing demands follow the operating
    # choice; absent demand uses the NECB library's use-specific defaults.
    if @keep_operating && !@part8_source.getWaterUseEquipments.empty?
      return super
    end
    method = method(:model_add_swh).super_method.super_method
    method.call(model: model, **options)
  end

  def replace_water_demand_on_retained_systems(model)
    existing = model.getWaterUseConnectionss.to_a
    loops = existing.filter_map { |item| item.plantLoop.get unless item.plantLoop.empty? }.uniq(&:handle)
    raise 'Replacing water-use defaults while retaining multiple SWH loops requires an explicit distribution mapping; retain operating inputs or replace systems.' if loops.size > 1
    defaults = model.clone.to_Model
    defaults.getWaterUseEquipments.each(&:remove)
    defaults.getWaterUseConnectionss.each(&:remove)
    library = method(:model_add_swh).super_method.super_method
    library.call(model: defaults, shw_scale: nil)
    model.getWaterUseEquipments.each(&:remove)
    connection = existing.find { |item| !item.plantLoop.empty? } || existing.first
    if connection.nil? && !defaults.getWaterUseEquipments.empty?
      connection = OpenStudio::Model::WaterUseConnections.new(model)
      @part8_audit['limitations'] << 'Default water-use demand added without a heating plant because Keep existing systems was selected and no SWH loop exists.'
    end
    defaults.getWaterUseEquipments.each do |equipment|
      copy = equipment.clone(model).to_WaterUseEquipment.get
      copy.setSpace(model.getSpaceByName(equipment.space.get.nameString).get) unless equipment.space.empty?
      connection.addWaterUseEquipment(copy)
    end
    @part8_audit['water_use_demand'] = 'Replaced with NRC NECB defaults; existing heaters/plant retained unchanged.'
  end

  def finish_part8(model)
    if @keep_systems
      actual_blocks = model.getThermalZones.to_h { |zone| [zone.nameString, [zone.multiplier, zone.spaces.map(&:nameString).sort]] }
      source_blocks = @part8_source.getThermalZones.to_h { |zone| [zone.nameString, [zone.multiplier, zone.spaces.map(&:nameString).sort]] }
      raise 'Existing thermal blocks changed while retaining systems.' unless actual_blocks == source_blocks
      actual_objects = model.objects.to_h { |object| [object.handle.to_s, object] }
      @retained_system_objects.each do |handle, expected|
        object = actual_objects[handle]
        raise "Keep systems changed or removed an existing system object: #{object&.iddObject&.name || handle}." if object.nil? || object.to_s != expected
      end
      @part8_audit['existing_system_objects_verified'] = @retained_system_objects.size
    else
      super
    end
    # Upstream temporarily upgrades metadata for its lookups. Restore the user's
    # valid source names/classifications and assignments after those lookups.
    @input_classifications.each do |space_name, (name, building_type, space_type)|
      current = model.getSpaceByName(space_name).get.spaceType.get
      current.setName(name)
      current.setStandardsBuildingType(building_type)
      current.setStandardsSpaceType(space_type)
    end
    @part8_audit['compatible_classifications_retained'] = true
    @part8_audit['thermal_blocks_preserved'] = true
    @part8_audit['occupancy_process_loads_and_schedules_preserved'] = @keep_operating
    model.getBuilding.additionalProperties.setFeature('necb_part8_audit', JSON.generate(@part8_audit))
    @part8_audit
  end
end
