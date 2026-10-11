require 'openstudio'
require 'zip'
require 'fileutils'
require 'digest'
require 'json'

root = File.expand_path('..', __dir__)
archive = File.join(root, 'dist/create_necb_reference_openstudio_3.11.zip')
destination = File.join(root, 'qa copy')
FileUtils.mkdir_p(destination)
Zip::File.open(archive) do |zip|
  zip.each do |entry|
    target = File.expand_path(entry.name, destination)
    raise "Unexpected archive path: #{entry.name}" unless target.start_with?(destination + '/')
    FileUtils.mkdir_p(File.dirname(target))
    entry.extract(target) { true }
  end
end
resources = File.join(destination, 'create_necb_reference/resources')
manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
manifest.fetch('files').each do |path, expected|
  raise "Extracted dependency mismatch: #{path}" unless Digest::SHA256.file(File.join(resources, path)).hexdigest == expected
end
puts "Relocated release: #{manifest.fetch('files').size} dependency files verified."
mapping_env = {'NECB_REFERENCE_MEASURE' => File.join(destination, 'create_necb_reference/measure.rb'),
               'NECB_MAPPING_TEST_MODE' => 'preset'}
raise 'Relocated mapping preset test failed' unless system(mapping_env, OpenStudio.getOpenStudioCLI.to_s, File.join(root, 'scripts/smoke_mapping.rb'))
puts 'Reference mapping preset passed from the extracted release.'
preservation_env = {'NECB_REFERENCE_MEASURE' => File.join(destination, 'create_necb_reference/measure.rb'),
                    'NECB_PART8_SWH_TEST' => 'true'}
raise 'Relocated proposed-input preservation test failed' unless system(preservation_env, OpenStudio.getOpenStudioCLI.to_s, File.join(root, 'scripts/smoke_part8.rb'))
puts 'Proposed-input preservation passed from the extracted release.'
if ARGV.include?('--quick')
  puts 'Focused release check passed: complete replacement and proposed-input preservation.'
  exit 0
end
%w[missing defaults_only retain replace_operating replace_all].each do |mode|
  env = {'NECB_REFERENCE_MEASURE' => File.join(destination, 'create_necb_reference/measure.rb'), 'NECB_OPTIONS_CASE' => mode}
  raise "Relocated reference input choice failed: #{mode}" unless system(env, OpenStudio.getOpenStudioCLI.to_s, File.join(root, 'scripts/smoke_reference_options.rb'))
end
puts 'All single-model workflow cases passed from the extracted release.'
