require 'openstudio'
require 'zip'
require 'fileutils'
require 'json'
require 'digest'

# Two NECB2020 generation checks from relocated install ZIPs. Sizing, forward
# translation and save/reload only; no repeat of the annual energy matrix.
root = File.expand_path('..', __dir__)
destination = File.join(root, 'qa copy')
FileUtils.mkdir_p(destination)
%w[create_necb_reference create_necb_archetype].each do |name|
  archive = File.join(root, "dist/#{name}_openstudio_3.11.zip")
  Zip::File.open(archive) do |zip|
    zip.each do |entry|
      target = File.expand_path(entry.name, destination)
      raise "Unexpected archive path: #{entry.name}" unless target.start_with?(destination + '/' + name + '/')
      FileUtils.mkdir_p(File.dirname(target))
      entry.extract(target) { true }
    end
  end
  resources = File.join(destination, name, 'resources')
  manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
  manifest.fetch('files').each do |path, expected|
    raise "Extracted dependency mismatch: #{name}/#{path}" unless Digest::SHA256.file(File.join(resources, path)).hexdigest == expected
  end
  puts "#{name}: relocated #{manifest.fetch('files').size} verified dependency files."
end
cli = OpenStudio.getOpenStudioCLI.to_s
env = {'NECB_REFERENCE_MEASURE' => File.join(destination, 'create_necb_reference/measure.rb'), 'NECB_MAPPING_TEST_MODE' => 'preset'}
raise 'Packaged automatic ASHRAE reference conversion failed.' unless system(env, cli, File.join(root, 'scripts/smoke_mapping.rb'))
env = {'NECB_MEASURE_PATH' => File.join(destination, 'create_necb_archetype/measure.rb'), 'NECB_BUILDING' => 'Warehouse',
       'NECB_TEMPLATE' => 'NECB2020', 'NECB_FUEL' => 'NaturalGas', 'NECB_TEST_NAME' => 'release_rc2_archetype'}
raise 'Packaged NECB2020 archetype generation failed.' unless system(env, cli, File.join(root, 'scripts/smoke_test.rb'))
puts 'Both packaged NECB2020 measures passed sizing, forward translation and save/reload.'
