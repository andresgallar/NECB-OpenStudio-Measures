require 'openstudio'
require 'json'
require 'digest'
require_relative '../measures/create_necb_reference/resources/space_type_mapping'

# Rebuild only from pinned, public ASHRAE and NRC prototype shells. A mapping
# requires matching Space names and vertices, and one consistent NRC use for
# every Space with that source classification. No room-name/use inference.
resources = File.expand_path('../measures/create_necb_reference/resources', __dir__)
library = File.join(resources, 'openstudio-standards')
catalog = JSON.parse(File.read(File.join(resources, 'space_type_catalog.json')))
fixtures = {
  'FullServiceRestaurant' => 'ASHRAEFullServiceRestaurant',
  'QuickServiceRestaurant' => 'ASHRAEQuickServiceRestaurant',
  'SmallOffice' => 'ASHRAESmallOffice', 'MediumOffice' => 'ASHRAEMediumOffice',
  'LargeOffice' => 'ASHRAELargeOffice', 'Warehouse' => 'ASHRAE90120102013Warehouse',
  'RetailStandalone' => 'ASHRAE9012013RetailStandalone', 'RetailStripmall' => 'ASHRAERetailStripmall',
  'PrimarySchool' => 'ASHRAEPrimarySchool', 'SecondarySchool' => 'ASHRAESecondarySchool',
  'SmallHotel' => 'ASHRAESmallHotel', 'LargeHotel' => 'ASHRAELargeHotel',
  'MidriseApartment' => 'ASHRAEMidriseApartment', 'HighriseApartment' => 'ASHRAEHighriseApartment',
  'Hospital' => 'ASHRAEHospital', 'Outpatient' => 'ASHRAEOutpatient'
}
def shell_vertices(space)
  space.surfaces.map do |surface|
    surface.vertices.map do |vertex|
      point = space.transformation * vertex
      [point.x, point.y, point.z].map { |value| value.round(4) }
    end.sort
  end.sort
end
translator = OpenStudio::OSVersion::VersionTranslator.new
presets = fixtures.filter_map do |building, fixture|
  ashrae = "data/geometry/#{fixture}.osm"
  nrc = "lib/openstudio-standards/standards/necb/NECB2011/data/geometry/#{building}.osm"
  source = translator.loadModel(OpenStudio::Path.new(File.join(library, ashrae))).get
  target = translator.loadModel(OpenStudio::Path.new(File.join(library, nrc))).get
  targets = target.getSpaces.to_h { |space| [space.nameString, space] }
  skipped = []
  entries = source.getSpaces.group_by do |space|
    space.spaceType.empty? ? ['', ''] : NECBSpaceTypeMapping.pair(space.spaceType.get)
  end.filter_map do |source_pair, spaces|
    pairs = spaces.map do |space|
      match = targets[space.nameString]
      next unless match && shell_vertices(space) == shell_vertices(match) && !match.spaceType.empty?
      NECBSpaceTypeMapping.pair(match.spaceType.get)
    end
    if pairs.include?(nil) || pairs.uniq.size != 1 || !catalog.fetch('NECB2011').include?(pairs.first)
      skipped << source_pair
      next
    end
    {'source_building_type' => source_pair[0], 'source_space_type' => source_pair[1],
     'necb_vintage' => 'NECB2011', 'necb_building_type' => pairs.first[0], 'necb_space_type' => pairs.first[1]}
  end
  puts "#{fixture}: #{entries.size} reviewed pairs; #{skipped.size} unmatched/ambiguous pairs"
  next if entries.empty?
  ["ASHRAE#{building}", {
    'description' => "Exact public #{building} classifications. Review applicability and wildcard uses for the project.",
    'source' => 'openstudio-standards/' + nrc,
    'fixture' => 'openstudio-standards/' + ashrae,
    'source_sha256' => Digest::SHA256.file(File.join(library, nrc)).hexdigest,
    'fixture_sha256' => Digest::SHA256.file(File.join(library, ashrae)).hexdigest,
    'unmatched_source_pairs' => skipped, 'mappings' => entries.sort_by { |entry| entry.values_at('source_building_type', 'source_space_type') }
  }]
end.to_h
File.write(File.join(resources, 'mapping_presets.json'), JSON.pretty_generate(presets) + "\n")
