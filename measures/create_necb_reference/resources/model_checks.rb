require 'json'
require 'digest'

module NECBExistingModelChecks
  def self.errors(model)
    errors = []
    errors << 'The source model has no spaces.' if model.getSpaces.empty?
    building = model.getBuilding
    errors << 'Set the building Standards Number of Stories.' if building.standardsNumberOfStories.empty?
    errors << 'Set the building Standards Number of Above Ground Stories.' if building.standardsNumberOfAboveGroundStories.empty?
    model.getSpaces.sort.each do |space|
      label = space.nameString
      errors << "#{label}: assign a Building Story." if space.buildingStory.empty?
      errors << "#{label}: assign a Thermal Zone." if space.thermalZone.empty?
      errors << "#{label}: no surfaces were found." if space.surfaces.empty?
      if space.spaceType.empty?
        errors << "#{label}: assign an NECB Space Type."
      else
        type = space.spaceType.get
        errors << "#{label}: set the Space Type's Standards Building Type." if type.standardsBuildingType.empty?
        errors << "#{label}: set the Space Type's Standards Space Type." if type.standardsSpaceType.empty?
      end
    end
    errors
  end

  def self.classification_errors(model, catalog)
    used_types = model.getSpaces.filter_map do |space|
      space.spaceType.get unless space.spaceType.empty?
    end.uniq { |type| type.handle.to_s }
    # Missing fields are reported by errors(model).
    complete = used_types.reject { |type| type.standardsBuildingType.empty? || type.standardsSpaceType.empty? }
    pairs = complete.map { |type| [type.standardsBuildingType.get, type.standardsSpaceType.get] }
    unknown = complete.zip(pairs).reject { |_type, pair| catalog.values.any? { |entries| entries.include?(pair) } }
    unless unknown.empty?
      return unknown.map do |type, pair|
        "Unsupported Space Type '#{type.nameString}': Standards Building Type='#{pair[0]}', Standards Space Type='#{pair[1]}'. ASHRAE classifications and custom labels require a reviewed preset or mapping CSV. A mapping template will be exported automatically."
      end
    end
    [] # Each supported pair is translated independently in the isolated worker.
  end

  # Surface intersections may split polygons. Compare aggregate space geometry,
  # orientation and effective multipliers; fenestration is intentionally excluded.
  def self.geometry(model)
    spaces = model.getSpaces.sort_by(&:nameString).map do |space|
      points = space.surfaces.flat_map { |surface| surface.vertices.map { |point| space.transformation * point } }
      areas = space.surfaces.group_by(&:surfaceType).sort.to_h do |type, surfaces|
        [type, surfaces.sum(&:grossArea).round(4)]
      end
      bounds = %i[x y z].map do |coordinate|
        values = points.map { |point| point.public_send(coordinate) }
        values.empty? ? [] : [values.min.round(4), values.max.round(4)]
      end
      [space.nameString, space.floorArea.round(4), space.multiplier, areas, bounds]
    end
    {'north_axis' => model.getBuilding.northAxis.round(4), 'spaces' => spaces}
  end

  def self.geometry_hash(model)
    Digest::SHA256.hexdigest(JSON.generate(geometry(model)))
  end

  def self.system_signature(model, include_water_demand: true)
    # SDK clone/save/load can recreate Connection UUIDs. Compare their actual
    # endpoints and ports, and normalize references to those connection IDs.
    # Connected HVAC components and nodes can also receive fresh UUIDs when
    # the SDK clones their parent graph. Names are unique within object type.
    aliases = model.objects.filter_map do |object|
      [object.handle.to_s, "#{object.iddObject.name}:#{object.nameString}"] unless object.name.empty?
    end.to_h
    model.objects.select { |object| object.iddObject.name == 'OS:PortList' }.each do |object|
      owner = object.getTarget(1)
      next if owner.empty?
      roles = owner.get.to_s.lines.select { |line| line.include?(object.handle.to_s) }.map { |line| line.split('!-').last.strip }.sort
      owner_key = aliases.fetch(owner.get.handle.to_s, owner.get.handle.to_s)
      aliases[object.handle.to_s] = "ports:#{owner_key}:#{roles.join('/')}" unless roles.empty?
    end
    model.objects.select { |object| object.iddObject.name == 'OS:Connection' }.each do |object|
      source = object.getTarget(1)
      target = object.getTarget(3)
      next if source.empty? || target.empty?
      from = aliases.fetch(source.get.handle.to_s, source.get.handle.to_s)
      to = aliases.fetch(target.get.handle.to_s, target.get.handle.to_s)
      aliases[object.handle.to_s] = "connection:#{from}:#{object.getInt(2).get}:#{to}:#{object.getInt(4).get}"
    end
    model.objects.select do |object|
      next false if object.to_ThermalZone.is_initialized
      # Old OSMs can contain orphan Connection records. SDK cloning discards
      # them; they have no complete equipment connection to preserve.
      next false if object.iddObject.name == 'OS:Connection' && (object.getTarget(1).empty? || object.getTarget(3).empty?)
      next false if !include_water_demand && object.iddObject.name.start_with?('OS:WaterUse:')
      object.to_HVACComponent.is_initialized || object.iddObject.name.match?(/OS:(?:AirLoopHVAC|PlantLoop|WaterUse:|SpaceInfiltration|EnergyManagementSystem:|Connection$|PortList$)/)
    end.to_h do |object|
      fields = (1...object.numFields).map do |index|
        value = object.getString(index)
        text = value.empty? ? '' : value.get
        text.gsub(/\{[0-9a-fA-F-]{36}\}/) { |handle| aliases.fetch(handle, handle) }
      end
      fields.pop while fields.last == ''
      [aliases.fetch(object.handle.to_s, object.handle.to_s), JSON.generate([object.iddObject.name, *fields])]
    end
  end
end
