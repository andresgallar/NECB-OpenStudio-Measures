require 'openstudio'
require 'json'
require 'digest'
require 'zip'
require 'fileutils'

root = File.expand_path('..', __dir__)
measure_name = ARGV.fetch(0, 'create_necb_archetype')
raise 'Unknown measure' unless %w[create_necb_archetype create_necb_reference].include?(measure_name)
measure = File.join(root, 'measures', measure_name)
resources = File.join(measure, 'resources')
manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
manifest.fetch('files').each do |path, expected|
  raise "Bundled dependency changed: #{path}" unless Digest::SHA256.file(File.join(resources, path)).hexdigest == expected
end
FileUtils.mkdir_p(File.join(root, 'dist'))
metadata_log = File.join(root, 'dist', "#{measure_name}-metadata-update.log")
raise 'Measure metadata update failed' unless system(OpenStudio.getOpenStudioCLI.to_s, 'measure', '-u', measure, out: metadata_log, err: metadata_log)
zip_path = File.join(root, 'dist', "#{measure_name}_openstudio_3.11.zip")
Zip::OutputStream.open(zip_path) do |zip|
  Dir[File.join(measure, '**/*')].sort.each do |file|
    next unless File.file?(file)
    zip.put_next_entry(measure_name + '/' + file.delete_prefix(measure + '/'))
    zip.write(File.binread(file))
  end
end
checksum = Digest::SHA256.file(zip_path).hexdigest
File.write(zip_path + '.sha256', "#{checksum}  #{File.basename(zip_path)}\n")
if measure_name == 'create_necb_reference'
  FileUtils.cp(File.join(root, 'scripts/repair_reference_installation.ps1'), File.join(root, 'dist/repair_reference_installation.ps1'))
end
puts "Package: #{zip_path} (#{(File.size(zip_path) / 1024.0 / 1024).round(1)} MB)"
puts "SHA256: #{checksum}"
