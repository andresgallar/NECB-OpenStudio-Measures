require 'openstudio'
require 'json'
require 'digest'
require 'zip'
require 'fileutils'
root = File.expand_path('..', __dir__)
top = %w[README.md RELEASE.md CONTRIBUTING.md COPYING COPYING.LESSER .gitignore dependencies.lock.json]
scripts = %w[package_public_source.rb package_measure.rb verify_reference_archive.rb check_reference_release.rb
  check_packaged_measures.rb test_release_inputs.rb build_reviewed_mapping_presets.rb smoke_test.rb
  test_ground_boundary.rb test_reviewed_inputs.rb compare_medium_office.rb check_reference_request.rb
  test_reference_equivalence.rb test_public_prototype_matrix.rb reference_benchmark_support.rb collect_public_validation.rb
  smoke_mapping.rb smoke_part8.rb smoke_reference_options.rb repair_reference_installation.ps1]
files = top + scripts.map { |name| 'scripts/' + name }
%w[create_necb_reference create_necb_archetype].each do |name|
  resources = File.join(root, 'measures', name, 'resources')
  manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
  manifest.fetch('files').each do |path, expected|
    raise "Dependency changed: #{name}/#{path}" unless Digest::SHA256.file(File.join(resources, path)).hexdigest == expected
  end
  files.concat(Dir[File.join(root, 'measures', name, '**/*')].select { |file| File.file?(file) }.map { |file| file.delete_prefix(root + '/') })
end
files.sort!.uniq!
raise 'Public archive includes an unexpected development path.' if files.any? { |path| path.match?(%r{(?:^|/)(?:test-output|downloads|vendor-src|installation-backups|qa copy)(?:/|$)}) }
files.each do |relative|
  next if relative.match?(%r{/resources/(?:openstudio-standards|gems)/})
  next unless relative.match?(/\.(?:md|rb|json|xml|ps1|txt)\z/i)
  text = File.read(File.join(root, relative))
  raise "Personal development path in public source: #{relative}" if text.match?(/C:[\\\/]Users[\\\/]galla[\\\/]|OneDrive[\\\/]Documents[\\\/]openstudio_developments/i)
end
FileUtils.mkdir_p(File.join(root, 'dist'))
archive = File.join(root, 'dist/create_necb_reference_public_source.zip')
Zip::OutputStream.open(archive) do |zip|
  files.each do |relative|
    file = File.join(root, relative)
    raise "Missing public source file: #{relative}" unless File.file?(file)
    zip.put_next_entry('standalone-necb-measures/' + relative)
    zip.write(File.binread(file))
  end
end
Zip::File.open(archive) do |zip|
  raise 'Public source inventory mismatch.' unless zip.entries.map(&:name).sort == files.map { |path| 'standalone-necb-measures/' + path }
  zip.each do |entry|
    relative = entry.name.delete_prefix('standalone-necb-measures/')
    raise "Public archive hash mismatch: #{relative}" unless Digest::SHA256.hexdigest(entry.get_input_stream.read) == Digest::SHA256.file(File.join(root, relative)).hexdigest
  end
end
File.write(archive + '.sha256', "#{Digest::SHA256.file(archive).hexdigest}  #{File.basename(archive)}\n")
File.write(File.join(root, 'dist/public_source_inventory.txt'), files.join("\n") + "\n")
puts "Public source: #{files.size} verified files; #{(File.size(archive) / 1024.0 / 1024).round(1)} MB; #{archive}"
