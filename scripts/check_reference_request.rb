require 'openstudio'
require 'json'
require 'fileutils'
require 'digest'
require_relative '../measures/create_necb_reference/measure'

# Replay one failed generation request through the measure. Input OSM/request
# files stay outside public packages; only local test-output receives results.
request = JSON.parse(File.read(ARGV.fetch(0)))
root = File.expand_path('..', __dir__)
directory = File.join(root, 'test-output/ground-boundary-regression')
FileUtils.mkdir_p(directory)
input = request.fetch('input_model')
before = Digest::SHA256.file(input).hexdigest
model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(input)).get
geometry = NECBExistingModelChecks.geometry_hash(model)
special_ground = model.getSurfaces.select { |surface| surface.outsideBoundaryCondition == 'GroundFCfactorMethod' }.map(&:nameString)
measure = CreateNECBReference.new
args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
measure.arguments(model).each do |argument|
  next unless request.key?(argument.name)
  value = argument.name == 'osm_file_path' ? '' : request.fetch(argument.name)
  selected = argument.clone
  raise "Invalid argument #{argument.name}" unless selected.setValue(value)
  args[argument.name] = selected
end
runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
success = Dir.chdir(directory) { measure.run(model, runner, args) }
summary = {'success' => success, 'edition' => request['necb_template'],
           'errors' => runner.result.errors.map(&:logMessage), 'warnings' => runner.result.warnings.map(&:logMessage),
           'spaces' => model.getSpaces.size, 'air_loops' => model.getAirLoopHVACs.size,
           'source_f_factor_surfaces' => special_ground.size}
File.write(File.join(directory, 'summary.json'), JSON.pretty_generate(summary))
raise summary['errors'].join("\n") unless success
raise 'Input file changed.' unless Digest::SHA256.file(input).hexdigest == before
raise 'Space geometry changed.' unless NECBExistingModelChecks.geometry_hash(model) == geometry
raise 'Proposed ground method survived complete replacement.' if model.getSurfaces.any? { |surface| surface.outsideBoundaryCondition == 'GroundFCfactorMethod' }
missing = model.getSurfaces.select { |surface| surface.construction.empty? }.map(&:nameString)
raise "Missing constructions: #{missing.join(', ')}" unless missing.empty?
audit = JSON.parse(model.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit').get)
converted = audit.fetch('ground_boundary_conversions').select { |row| row['source_boundary'] == 'GroundFCfactorMethod' }.map { |row| row['surface'] }
raise 'Incomplete ground conversion audit.' unless (special_ground - converted).empty?
translator = OpenStudio::EnergyPlus::ForwardTranslator.new
idf = translator.translateModel(model)
raise translator.errors.map(&:logMessage).join("\n") unless translator.errors.empty?
idf.save(OpenStudio::Path.new(File.join(directory, 'reference.idf')), true)
saved = File.join(directory, 'reference.osm')
raise 'Could not save reference.' unless model.save(OpenStudio::Path.new(saved), true)
restored = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(saved)).get
raise 'Reload changed geometry.' unless NECBExistingModelChecks.geometry_hash(restored) == geometry
raise 'Reload lost constructions.' if restored.getSurfaces.any? { |surface| surface.construction.empty? }
summary.merge!('geometry_preserved' => true, 'source_unchanged' => true,
               'ground_conversions' => converted.size, 'all_surfaces_have_constructions' => true,
               'forward_translation' => 'passed', 'save_reload' => 'passed')
File.write(File.join(directory, 'summary.json'), JSON.pretty_generate(summary))
puts JSON.pretty_generate(summary)
