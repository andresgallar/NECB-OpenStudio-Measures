require_relative 'space_type_mapping'
require_relative 'reviewed_prototype_inputs'

# SDK-only preparation: no standards gem is loaded in the Application process.
module NECBInputPreparation
  def self.apply(model, catalog, default_use, reviewed_resources: nil, repair_defaults: false)
    raise 'The model must already contain Spaces with building surfaces.' if model.getSpaces.empty?
    audit = []
    model.getSpaces.select { |space| space.spaceType.empty? && space.isPlenum && space.partofTotalFloorArea }.each do |space|
      space.setPartofTotalFloorArea(false)
      audit << "Excluded explicitly designated HVAC plenum '#{space.nameString}' from occupied floor area before assigning defaults."
    end
    if reviewed_resources
      use = default_use == 'UseExisting' && !model.getBuilding.standardsBuildingType.empty? ? model.getBuilding.standardsBuildingType.get : default_use
      audit.concat(NECBReviewedPrototypeInputs.apply(model, catalog, use, reviewed_resources, repair_defaults: repair_defaults))
    end
    previous = NECBReviewedPrototypeInputs.previous_audit(model)
    missing = model.getSpaces.select { |space| space.spaceType.empty? || (repair_defaults && !space.partofTotalFloorArea && NECBReviewedPrototypeInputs.owned_default?(space, previous)) }
    unless missing.empty?
      occupied = missing.select(&:partofTotalFloorArea)
      unless occupied.empty?
        use = default_use.to_s
        if use == 'UseExisting'
          building_use = model.getBuilding.standardsBuildingType
          use = building_use.get unless building_use.empty?
        end
        pair = [use, 'WholeBuilding']
        unless catalog.values.any? { |entries| entries.include?(pair) }
          raise 'Select Default building use for spaces without Space Types. Geometry cannot determine their use; existing classified spaces will not be changed.'
        end
        type = OpenStudio::Model::SpaceType.new(model)
        type.setName("NECB default #{use}")
        type.setStandardsBuildingType(use)
        type.setStandardsSpaceType('WholeBuilding')
        type.additionalProperties.setFeature(NECBReviewedPrototypeInputs::DEFAULT_PROPERTY, use)
        occupied.each { |space| space.setSpaceType(type) }
        audit << "Assigned #{use} / WholeBuilding to #{occupied.size} spaces without a Space Type (user/building default)."
      end
      excluded = missing - occupied
      unless excluded.empty?
        undefined = OpenStudio::Model::SpaceType.new(model)
        undefined.setName('NECB default excluded floor-area spaces')
        undefined.setStandardsBuildingType('Space Function')
        undefined.setStandardsSpaceType('- undefined -')
        excluded.each { |space| space.setSpaceType(undefined) }
        audit << "Assigned Space Function / - undefined - to #{excluded.size} unclassified spaces excluded from total floor area; no occupied default loads assumed. Review plenum/attic use and conditioning with the mapping CSV."
      end
    end
    model.getSpaces.each do |space|
      next unless space.thermalZone.empty?
      zone = OpenStudio::Model::ThermalZone.new(model)
      zone.setName("#{space.nameString} NECB Zone")
      space.setThermalZone(zone)
      audit << "Created one thermal zone for unzoned space '#{space.nameString}'; existing zones were retained."
    end
    # Missing story assignments are inferred only from actual floor elevations.
    model.getSpaces.each do |space|
      next unless space.buildingStory.empty?
      points = space.surfaces.select { |surface| surface.surfaceType == 'Floor' }.flat_map do |surface|
        surface.vertices.map { |point| (space.transformation * point).z }
      end
      raise "#{space.nameString}: no floor geometry available to assign a Building Story." if points.empty?
      elevation = points.min.round(2)
      story = model.getBuildingStorys.find { |item| !item.nominalZCoordinate.empty? && (item.nominalZCoordinate.get - elevation).abs < 0.05 }
      unless story
        story = OpenStudio::Model::BuildingStory.new(model)
        story.setName("NECB Story at #{elevation} m")
        story.setNominalZCoordinate(elevation)
      end
      space.setBuildingStory(story)
      audit << "Assigned '#{space.nameString}' to a story using floor elevation #{elevation} m."
    end
    counted_spaces = model.getSpaces.select(&:partofTotalFloorArea)
    counted_spaces = model.getSpaces if counted_spaces.empty?
    used = counted_spaces.map { |space| space.buildingStory.get }.uniq(&:handle)
    building = model.getBuilding
    building.setStandardsNumberOfStories(used.size) if building.standardsNumberOfStories.empty?
    if building.standardsNumberOfAboveGroundStories.empty?
      above = used.count { |story| story.nominalZCoordinate.empty? || story.nominalZCoordinate.get >= -0.05 }
      building.setStandardsNumberOfAboveGroundStories([above, 1].max)
      audit << 'Missing story counts inferred from assigned stories; review ground elevation for basement models.'
    end
    audit
  end
end
