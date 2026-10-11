lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "oslg/version"

Gem::Specification.new do |s|
  # Specify which files should be added to the gem when it is released.
  # "git ls-files -z" loads files in the RubyGem that have been added into git.
  s.files                 = Dir.chdir(File.expand_path("..", __FILE__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{^(test|spec|features)/})
    end
  end

  s.name                  = "oslg"
  s.version               = OSlg::VERSION
  s.license               = "BSD-3-Clause"
  s.summary               = "OpenStudio SDK logger"
  s.description           = "For OpenStudio SDK users (or others) who wish "\
                            "to select what gets logged to which target."
  s.authors               = ["Denis Bourgeois"]
  s.email                 = ["denis@rd2.ca"]
  s.platform              = Gem::Platform::RUBY
  s.homepage              = "https://github.com/rd2/oslg"
  s.bindir                = "exe"
  s.require_paths         = ["lib"]
  s.executables           = s.files.grep(%r{^exe/}) { |f| File.basename(f) }
  s.required_ruby_version = [">= 2.5.0", "< 4"]
  s.metadata              = {}

  s.add_development_dependency "bundler", "~> 2.1"
  s.add_development_dependency "rake",    "~> 13.0"
  s.add_development_dependency "rspec",   "~> 3.11"

  s.metadata["homepage_uri"   ] = s.homepage
  s.metadata["source_code_uri"] = "#{s.homepage}/tree/v#{s.version}"
  s.metadata["bug_tracker_uri"] = "#{s.homepage}/issues"
end
