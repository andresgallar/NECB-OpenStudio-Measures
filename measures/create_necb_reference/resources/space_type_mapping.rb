require 'csv'
require 'fileutils'
require 'json'

module NECBSpaceTypeMapping
  class MappingError < StandardError; end
  HEADERS = %w[source_space_type source_building_type source_space_type_code necb_vintage necb_building_type necb_space_type spaces].freeze
  REQUIRED = %w[source_space_type necb_vintage necb_building_type necb_space_type].freeze
  ORIGIN_PROPERTY = 'necb_space_use_translation'.freeze

  def self.used_types(model)
    model.getSpaces.filter_map { |space| space.spaceType.get unless space.spaceType.empty? }
         .uniq { |type| type.handle.to_s }.sort_by(&:nameString)
  end

  def self.pair(type)
    [type.standardsBuildingType.empty? ? '' : type.standardsBuildingType.get,
     type.standardsSpaceType.empty? ? '' : type.standardsSpaceType.get]
  end

  def self.plans(model, catalog, preset, presets, csv_path = '')
    types = used_types(model).to_h { |type| [type.nameString, type] }
    planned = {}
    if preset == 'AutoReviewed'
      types.each do |name, type|
        next if catalog.values.any? { |entries| entries.include?(pair(type)) }
        matches = presets.flat_map do |key, definition|
          definition.fetch('mappings').filter_map do |entry|
            entry.slice('necb_vintage', 'necb_building_type', 'necb_space_type').merge('method' => "preset:#{key}") if pair(type) == entry.values_at('source_building_type', 'source_space_type')
          end
        end
        targets = matches.map { |row| row.values_at('necb_vintage', 'necb_building_type', 'necb_space_type') }.uniq
        planned[name] = if targets.size == 1
                          matches.first
                        else
                          {'necb_vintage' => 'NECB2011', 'necb_building_type' => 'Space Function',
                           'necb_space_type' => '- undefined -', 'method' => "fallback:#{matches.empty? ? 'unmapped' : 'ambiguous'}"}
                        end
      end
    elsif preset != 'None'
      definition = presets.fetch(preset) { raise MappingError, "Unknown mapping preset: #{preset}" }
      types.each do |name, type|
        entry = definition.fetch('mappings').find { |row| pair(type) == row.values_at('source_building_type', 'source_space_type') }
        planned[name] = entry.slice('necb_vintage', 'necb_building_type', 'necb_space_type').merge('method' => "preset:#{preset}") if entry
      end
      raise MappingError, "Preset #{preset} matches none of the used source classifications. Use automatic translation or supply a reviewed CSV." if planned.empty?
    end
    unless csv_path.empty?
      raise MappingError, "Mapping CSV not found: #{csv_path}" unless File.file?(csv_path)
      rows = CSV.read(csv_path, headers: true, encoding: 'bom|utf-8')
      headers = rows.headers || []
      raise MappingError, "Mapping CSV requires headers: #{REQUIRED.join(', ')}" unless (REQUIRED - headers).empty?
      raise MappingError, 'Mapping CSV contains duplicate headers.' unless headers.uniq.size == headers.size
      seen = []
      rows.each_with_index do |row, index|
        next if row.fields.all? { |value| value.to_s.strip.empty? }
        name = row['source_space_type'].to_s
        raise MappingError, "CSV row #{index + 2}: source_space_type is not a used Space Type name: #{name.inspect}" unless types.key?(name)
        raise MappingError, "Duplicate mapping CSV row for #{name}." if seen.include?(name)
        seen << name
        # Source columns guard against accidentally reusing a CSV on another model.
        expected = row.values_at('source_building_type', 'source_space_type_code').map(&:to_s)
        if headers.include?('source_building_type') && headers.include?('source_space_type_code') && !accepted_source_pairs(types.fetch(name)).include?(expected)
          raise MappingError, "CSV source classifications changed for #{name}: CSV #{expected.inspect}, model #{pair(types.fetch(name)).inspect}. Export a fresh template for this model."
        end
        target = row.values_at('necb_building_type', 'necb_space_type').map { |value| value.to_s.strip }
        next if target.all?(&:empty?) # Keep any preset assignment, otherwise leave unmapped.
        planned[name] = {'necb_vintage' => row['necb_vintage'].to_s.strip,
                         'necb_building_type' => target[0], 'necb_space_type' => target[1], 'method' => 'csv'}
      end
    end
    planned.each do |name, row|
      entries = catalog[row['necb_vintage']]
      unless entries && entries.include?(row.values_at('necb_building_type', 'necb_space_type'))
        raise MappingError, "Invalid NECB mapping for #{name}: #{row['necb_vintage']} / #{row['necb_building_type']} / #{row['necb_space_type']}. Use an exact pair from space_type_catalog.json."
      end
    end
    planned
  rescue CSV::MalformedCSVError => e
    raise MappingError, "Could not parse mapping CSV: #{e.message}"
  end

  # An exported CSV can also correct a model returned by this measure. Accept
  # its recorded original pair only while the assigned classification is intact.
  def self.accepted_source_pairs(type)
    current = pair(type)
    saved = type.additionalProperties.getFeatureAsString(ORIGIN_PROPERTY)
    return [current] if saved.empty?
    origin = JSON.parse(saved.get)
    current == origin['assigned_pair'] ? [current, origin['source_pair']].uniq : [current]
  rescue JSON::ParserError
    [current]
  end

  def self.copy_origins(source, generated)
    origins = source.getSpaces.to_h do |space|
      value = space.spaceType.empty? ? nil : space.spaceType.get.additionalProperties.getFeatureAsString(ORIGIN_PROPERTY)
      [space.nameString, value && !value.empty? ? value.get : nil]
    end
    generated.getSpaces.each do |space|
      value = origins[space.nameString]
      space.spaceType.get.additionalProperties.setFeature(ORIGIN_PROPERTY, value) if value && !space.spaceType.empty?
    end
  end

  def self.apply(model, catalog, preset, presets, csv_path)
    planned = plans(model, catalog, preset, presets, csv_path)
    types = used_types(model)
    unless planned.empty?
      missing = types.reject do |type|
        row = planned[type.nameString]
        target = row ? row.values_at('necb_building_type', 'necb_space_type') : pair(type)
        catalog.values.any? { |entries| entries.include?(target) }
      end
      unless missing.empty?
        raise MappingError, "Incomplete mapping: #{missing.map(&:nameString).join(', ')}. Fill the CSV for every incompatible used Space Type."
      end
    end
    # Validate the entire plan before assigning anything, even on the staged copy.
    types.filter_map do |type|
      row = planned[type.nameString]
      next unless row
      original = pair(type)
      accepted = accepted_source_pairs(type)
      raise MappingError, "Could not assign mapping to #{type.nameString}." unless type.setStandardsBuildingType(row['necb_building_type']) && type.setStandardsSpaceType(row['necb_space_type'])
      type.additionalProperties.setFeature(ORIGIN_PROPERTY, JSON.generate('source_pair' => accepted.last, 'assigned_pair' => pair(type)))
      {'source_space_type' => type.nameString, 'source_building_type' => original[0],
       'source_space_type_code' => original[1]}.merge(row)
    end
  end

  def self.export_template(model, catalog, preset, presets, path, preferred_vintage, csv_path = '')
    raise MappingError, 'Template output path must end in .csv.' unless path.downcase.end_with?('.csv')
    raise MappingError, "Refusing to overwrite an existing CSV: #{path}" if File.exist?(path)
    planned = plans(model, catalog, preset, presets, csv_path)
    types = used_types(model)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'wx', encoding: 'utf-8') do |file|
      csv = CSV.new(file)
      csv << HEADERS
      types.each do |type|
        original = pair(type)
        row = planned[type.nameString]
        vintage = ([preferred_vintage] + catalog.keys).uniq.find { |candidate| catalog.fetch(candidate).include?(original) } || preferred_vintage
        target = row ? row.values_at('necb_building_type', 'necb_space_type') : (catalog.fetch(vintage).include?(original) ? original : ['', ''])
        spaces = model.getSpaces.select { |space| !space.spaceType.empty? && space.spaceType.get.handle == type.handle }.map(&:nameString).sort.join('; ')
        csv << [type.nameString, *original, row ? row['necb_vintage'] : vintage, *target, spaces]
      end
    end
    types.size
  end
end
