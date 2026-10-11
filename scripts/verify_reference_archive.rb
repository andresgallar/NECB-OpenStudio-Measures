require 'openstudio'
require 'zip'
require 'digest'

root = File.expand_path('..', __dir__)
names = ARGV.empty? ? ['create_necb_reference'] : ARGV
names.each do |name|
  raise 'Unknown measure' unless %w[create_necb_reference create_necb_archetype].include?(name)
  measure = File.join(root, 'measures', name)
  expected = Dir[File.join(measure, '**/*')].select { |file| File.file?(file) }.to_h do |file|
    [name + '/' + file.delete_prefix(measure + '/'), Digest::SHA256.file(file).hexdigest]
  end
  Zip::File.open(File.join(root, "dist/#{name}_openstudio_3.11.zip")) do |zip|
    raise 'Release file inventory differs from the measure.' unless zip.entries.map(&:name).sort == expected.keys.sort
    zip.each do |entry|
      raise "Release contents differ: #{entry.name}" unless Digest::SHA256.hexdigest(entry.get_input_stream.read) == expected.fetch(entry.name)
    end
  end
  puts "#{name}: verified #{expected.size} release files against the complete measure."
end
