require_relative 'reference_options'
require_relative 'model_checks'
require_relative 'ground_boundary_conversion'
require_relative 'reviewed_prototype_inputs'

# Full replacement starts from geometry, not a clone of the proposed model.
# No stock geometry, equipment or energy results are substituted for the input.
module NECBCompleteRebuild
  SETTINGS = %w[OS:SimulationControl OS:Timestep OS:ConvergenceLimits OS:HeatBalanceAlgorithm
                OS:Site:GroundTemperature:BuildingSurface OS:RunPeriod OS:YearDescription
                OS:Sizing:Parameters].freeze

  def self.prepare(source, standard, resources)
    model = OpenStudio::Model::Model.new
    building = model.getBuilding
    original = source.getBuilding
    building.setName(original.nameString)
    building.setNorthAxis(original.northAxis)
    building.setStandardsNumberOfStories(original.standardsNumberOfStories.get)
    building.setStandardsNumberOfAboveGroundStories(original.standardsNumberOfAboveGroundStories.get)
    building.setStandardsBuildingType(original.standardsBuildingType.get) unless original.standardsBuildingType.empty?
    # Only measure provenance crosses over; arbitrary proposed simulation inputs
    # and additional properties can influence upstream HVAC selection.
    original.additionalProperties.featureNames.grep(/^necb_(?:input_preparation|space_type_mapping_audit|mapping_preset|reviewed_prototype_inputs)$/).each do |key|
      building.additionalProperties.setFeature(key, original.additionalProperties.getFeatureAsString(key).get)
    end
    settings_source = 'OpenStudio SDK defaults'
    unless original.standardsBuildingType.empty?
      use = original.standardsBuildingType.get
      # Restrict lookup to a literal filename inside the pinned public library.
      if use.match?(/\A[A-Za-z0-9_]+\z/)
        shell_path = File.join(resources, 'openstudio-standards/lib/openstudio-standards/standards/necb/NECB2011/data/geometry', "#{use}.osm")
        if File.file?(shell_path)
          shell = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(shell_path)).get
          shell.objects.select { |object| SETTINGS.include?(object.iddObject.name) }.each { |object| shell.getModelObject(object.handle).get.clone(model) }
          model.getSite.setTerrain(shell.getSite.terrain)
          settings_source = "Pinned NRC #{use} prototype simulation settings (no geometry copied)"
        end
      end
    end
    model.getYearDescription.setDayofWeekforStartDay('Sunday')
    stories = source.getBuildingStorys.to_h do |old|
      story = OpenStudio::Model::BuildingStory.new(model)
      story.setName(old.nameString)
      story.setNominalZCoordinate(old.nominalZCoordinate.get) unless old.nominalZCoordinate.empty?
      story.setNominalFloortoFloorHeight(old.nominalFloortoFloorHeight.get) unless old.nominalFloortoFloorHeight.empty?
      [old.handle.to_s, story]
    end
    types = {}
    surfaces = {}
    ground_conversions = []
    slab_cores = NECBGroundBoundaryConversion.adiabatic_slab_cores(source)
    source.getSpaces.sort_by(&:nameString).each do |old|
      space = OpenStudio::Model::Space.new(model)
      space.setName(old.nameString)
      space.setTransformation(old.transformation)
      space.setPartofTotalFloorArea(old.partofTotalFloorArea)
      space.setBuildingStory(stories.fetch(old.buildingStory.get.handle.to_s))
      old_type = old.spaceType.get
      type = types[old_type.handle.to_s] ||= begin
        clean_type = OpenStudio::Model::SpaceType.new(model)
        clean_type.setName(old_type.nameString)
        clean_type.setStandardsBuildingType(old_type.standardsBuildingType.get)
        clean_type.setStandardsSpaceType(old_type.standardsSpaceType.get)
        default_use = old_type.additionalProperties.getFeatureAsString(NECBReviewedPrototypeInputs::DEFAULT_PROPERTY)
        clean_type.additionalProperties.setFeature(NECBReviewedPrototypeInputs::DEFAULT_PROPERTY, default_use.get) unless default_use.empty?
        clean_type
      end
      space.setSpaceType(type)
      zone = OpenStudio::Model::ThermalZone.new(model)
      zone.setMultiplier(old.multiplier)
      space.setThermalZone(zone)
      old.surfaces.each do |surface|
        copy = OpenStudio::Model::Surface.new(surface.vertices, model)
        copy.setName(surface.nameString)
        copy.setSpace(space)
        copy.setSurfaceType(surface.surfaceType)
        boundary = surface.outsideBoundaryCondition
        # Proposed F/C-factor constructions are discarded in a full rebuild.
        # Their special boundary condition cannot inherit an ordinary NECB
        # ground construction. Use Ground so the NRC envelope/Kiva routine
        # supplies the replacement assembly and foundation model.
        if %w[Foundation GroundFCfactorMethod].include?(boundary) || slab_cores.include?(surface.nameString)
          conversion = {'surface' => surface.nameString, 'source_boundary' => boundary, 'rebuilt_shell_boundary' => 'Ground'}
          conversion['reason'] = 'F-factor slab core enclosed on every edge by coplanar ground-contact floors' if slab_cores.include?(surface.nameString)
          ground_conversions << conversion
          boundary = 'Ground'
        end
        copy.setOutsideBoundaryCondition(boundary) unless boundary == 'Surface'
        copy.setSunExposure(boundary == 'Outdoors' ? 'SunExposed' : 'NoSun')
        copy.setWindExposure(boundary == 'Outdoors' ? 'WindExposed' : 'NoWind')
        surfaces[surface.handle.to_s] = copy
      end
    end
    source.getSurfaces.each do |surface|
      next if surface.adjacentSurface.empty?
      surfaces.fetch(surface.handle.to_s).setAdjacentSurface(surfaces.fetch(surface.adjacentSurface.get.handle.to_s))
    end
    # Some public ASHRAE fixtures have reversed faces. The SDK otherwise falls
    # back to an approximate ceiling-height volume, affecting sizing and OA.
    # Reorient the fresh shell, verifying that no vertex position is changed.
    repaired = []
    model.getSpaces.each do |space|
      before_faces = space.surfaces.to_h { |s| [s.nameString, s.vertices.map { |p| [p.x, p.y, p.z] }] }
      space.fixSurfacesWithIncorrectOrientation
      space.surfaces.each do |surface|
        before = before_faces.fetch(surface.nameString)
        after = surface.vertices.map { |p| [p.x, p.y, p.z] }
        raise "Surface orientation repair changed vertex positions: #{surface.nameString}." unless before.sort == after.sort
        repaired << "#{space.nameString}: #{surface.nameString}" unless before == after
      end
    end
    standard.instance_variable_set(:@necb_reoriented_surfaces, repaired)
    standard.instance_variable_set(:@necb_ground_boundary_conversions, ground_conversions)
    # Use the same reviewed cross-edition lookup as the preservation workflow,
    # without installing its envelope/HVAC overrides on the prototype routine.
    vintage = standard.determine_spacetype_vintage(model)
    if vintage.nil?
      # Mixed source editions need the conservative, unambiguous per-type
      # lookup. Uniform vintages must follow the prototype's own upgrade path.
      NECBReferenceOptions.instance_method(:normalize_classifications).bind(standard).call(model)
    elsif vintage != standard.class.name
      reviews = model.getSpaceTypes.filter_map do |type|
        rows = standard.standards_data.fetch('space_type_upgrade_map').select do |row|
          [row["#{vintage}_building_type"].to_s.strip, row["#{vintage}_space_type"].to_s.strip] == NECBSpaceTypeMapping.pair(type)
        end
        candidates = rows.map { |row| [row["#{standard.class.name}_building_type"].to_s.strip, row["#{standard.class.name}_space_type"].to_s.strip] }.uniq
        next if candidates.size <= 1
        "#{type.nameString}: #{vintage} classification has #{candidates.size} target-edition choices. Complete replacement follows the pinned NRC prototype's first-match upgrade (#{candidates.first.join(' / ')}); review area/schedule-specific classification for a project model."
      end
      standard.instance_variable_set(:@necb_legacy_classification_reviews, reviews)
      NECBReferenceOptions.instance_method(:normalize_classifications).bind(standard).call(model) if reviews.empty?
    end
    # The pinned SWH pipe-head routine parses the display name after character
    # 15 instead of reading standards metadata. Give it canonical NRC names
    # during generation so custom/ASHRAE names cannot silently select a default
    # pump. Restore the user's labels after every sizing stage has finished.
    model.getSpaceTypes.each do |type|
      type.setName("#{type.standardsBuildingType.get} #{type.standardsSpaceType.get}")
    end
    raise 'Clean rebuilding changed source geometry.' unless NECBExistingModelChecks.geometry_hash(model) == NECBExistingModelChecks.geometry_hash(source)
    [model, settings_source]
  end

  def self.finish(model, source, standard, settings_source)
    helper = Object.new.extend(NECBPart8Reference)
    walls = model.getSurfaces.select { |s| s.surfaceType == 'Wall' && s.outsideBoundaryCondition == 'Outdoors' }
    before = source.getSurfaces.select { |s| s.surfaceType == 'Wall' && s.outsideBoundaryCondition == 'Outdoors' }
    audit = {
      'mode' => 'CompleteNECBRebuild', 'simulation_settings' => settings_source,
      'operating_inputs' => 'Replace all operating inputs with pinned NRC NECB prototype defaults',
      'building_systems' => 'Rebuild zones, HVAC, SWH and infiltration with the NRC prototype routine',
      'reoriented_surfaces' => standard.instance_variable_get(:@necb_reoriented_surfaces) || [],
      'ground_boundary_conversions' => standard.instance_variable_get(:@necb_ground_boundary_conversions) || [],
      'fenestration' => {'fdwr' => {'areas_before' => helper.wall_opening_summary(before),
        'areas_after' => helper.wall_opening_summary(walls), 'layout' => 'NRC prototype default windows on exterior walls'}},
      'limitations' => ['Complete replacement uses NRC NECB prototype assumptions, including window layout, automatic zoning and wind-dependent infiltration. This is a prototype-derived baseline; a project Part 8 comparison still requires review of proposed/reference common inputs.'] + (standard.instance_variable_get(:@necb_legacy_classification_reviews) || [])
    }
    if audit['ground_boundary_conversions'].any? { |row| row['source_boundary'] == 'Adiabatic' }
      audit['limitations'] << 'Replaced enclosed adiabatic slab-core approximations associated with proposed F/C-factor ground modelling with NECB ground contact. Review the recorded surfaces; unrelated adiabatic boundaries are retained.'
    end
    # Preserve the supplied compatible labels after temporary edition lookup.
    source.getSpaces.each do |space|
      old = space.spaceType.get
      type = model.getSpaceByName(space.nameString).get.spaceType.get
      type.setName(old.nameString)
      type.setStandardsBuildingType(old.standardsBuildingType.get)
      type.setStandardsSpaceType(old.standardsSpaceType.get)
    end
    model.getBuilding.additionalProperties.setFeature('necb_part8_audit', JSON.generate(audit))
    audit
  end
end
