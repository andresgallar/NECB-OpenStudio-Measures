require 'json'

module NECBGroundBoundaryConversion
  TOLERANCE = 0.001 # metres; geometric contact, not an energy calibration

  def self.points(surface)
    surface.vertices.map { |vertex| surface.space.get.transformation * vertex }
  end

  def self.edges(vertices)
    vertices.each_with_index.map { |point, index| [point, vertices[(index + 1) % vertices.size]] }
  end

  def self.covered?(edge, neighbours)
    a, b = edge
    dx, dy = b.x - a.x, b.y - a.y
    length2 = dx * dx + dy * dy
    return false if length2 < TOLERANCE**2
    length = Math.sqrt(length2)
    intervals = neighbours.filter_map do |c, d|
      next unless [c, d].all? { |point| ((point.x - a.x) * dy - (point.y - a.y) * dx).abs / length <= TOLERANCE }
      projected = [c, d].map { |point| ((point.x - a.x) * dx + (point.y - a.y) * dy) / length2 }.sort
      start = [0.0, projected[0]].max
      finish = [1.0, projected[1]].min
      [start, finish] if finish > start
    end.sort
    reached = 0.0
    intervals.each do |start, finish|
      return false if start > reached + TOLERANCE / length
      reached = [reached, finish].max
    end
    reached >= 1.0 - TOLERANCE / length
  end

  def self.adiabatic_slab_cores(model)
    previous = model.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit')
    history = previous.empty? ? {} : JSON.parse(previous.get)
    converted = history.fetch('ground_boundary_conversions', []).select { |row| row['source_boundary'] == 'GroundFCfactorMethod' }.map { |row| row['surface'] }
    floors = model.getSurfaces.select { |surface| surface.surfaceType == 'Floor' && !surface.space.empty? }
    horizontal = floors.filter_map do |surface|
      vertices = points(surface)
      next if vertices.empty? || vertices.map(&:z).minmax.then { |low, high| high - low } > TOLERANCE
      [surface, vertices]
    end
    f_factor = horizontal.select do |surface, _|
      surface.outsideBoundaryCondition == 'GroundFCfactorMethod' || (%w[Ground Foundation].include?(surface.outsideBoundaryCondition) && converted.include?(surface.nameString))
    end
    return [] if f_factor.empty?
    horizontal.filter_map do |surface, vertices|
      next unless surface.outsideBoundaryCondition == 'Adiabatic'
      height = vertices.first.z
      next unless f_factor.any? { |_, other| (other.first.z - height).abs <= TOLERANCE }
      neighbours = horizontal.select do |other, other_points|
        %w[Ground GroundFCfactorMethod Foundation].include?(other.outsideBoundaryCondition) && (other_points.first.z - height).abs <= TOLERANCE
      end.flat_map { |_, other_points| edges(other_points) }
      # A core must be enclosed on EVERY edge by coplanar ground-contact slabs.
      # An unrelated adiabatic floor touching only one slab remains unchanged.
      surface.nameString if edges(vertices).all? { |edge| covered?(edge, neighbours) }
    end
  rescue JSON::ParserError
    []
  end
end
