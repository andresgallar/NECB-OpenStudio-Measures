require 'openstudio'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'

class CreateNECBArchetype < OpenStudio::Measure::ModelMeasure
  def name
    'Create NECB Prototype Building'
  end

  def description
    'Creates a Canadian NECB prototype using bundled public geometry, weather and nrcan_nrc standards. Replaces the current model after successful local sizing. No OpenStudio Server required.'
  end

  def modeler_description
    'Adapted from NRC nrc_create_necb_prototype_building. Uses Standard.build and model_create_prototype_model in an isolated local CLI process. All extra library files are under resources. Supports OpenStudio 3.11 / Application 1.11.1.'
  end

  def manifest
    JSON.parse(File.read(File.join(__dir__, 'resources/dependency_manifest.json')))
  end

  def choice(name, values, display, default)
    choices = OpenStudio::StringVector.new
    values.each { |value| choices << value }
    argument = OpenStudio::Measure::OSArgument.makeChoiceArgument(name, choices, true)
    argument.setDisplayName(display)
    argument.setDefaultValue(default)
    argument
  end

  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new
    data = manifest
    buildings = %w[SecondarySchool PrimarySchool SmallOffice MediumOffice LargeOffice SmallHotel LargeHotel Warehouse RetailStandalone RetailStripmall QuickServiceRestaurant FullServiceRestaurant MidriseApartment HighriseApartment Hospital Outpatient]
    args << choice('building_type', buildings, 'Building type', 'Warehouse')
    args << choice('necb_template', %w[NECB2011 NECB2015 NECB2017 NECB2020 BTAPPRE1980 BTAP1980TO2010], 'Building vintage / NECB edition', 'NECB2020')
    args << choice('weather_file', data.fetch('weather_files'), 'Bundled weather location', 'CAN_ON_Toronto.Intl.AP.716240_CWEC2020.epw')
    args << choice('hvac_fuel', %w[DefaultFuel NaturalGas Electricity FuelOilNo2], 'Primary heating fuel', 'DefaultFuel')
    args << choice('swh_fuel', %w[DefaultFuel NaturalGas Electricity], 'Service water heating fuel', 'DefaultFuel')
    custom = OpenStudio::Measure::OSArgument.makeStringArgument('custom_epw_path', false)
    custom.setDisplayName('Optional local EPW path (matching DDY and STAT required)')
    custom.setDefaultValue('')
    args << custom
    sideload = OpenStudio::Measure::OSArgument.makeBoolArgument('sideload', true)
    sideload.setDisplayName('Apply standards overrides from resources/data_sideload')
    sideload.setDefaultValue(false)
    args << sideload
    args
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    return false unless runner.validateUserArguments(arguments(model), user_arguments)
    initial_spaces = model.getSpaces.size
    data = manifest
    resources = File.join(__dir__, 'resources')
    selection = %w[building_type necb_template weather_file hvac_fuel swh_fuel custom_epw_path].to_h do |key|
      [key, runner.getStringArgumentValue(key, user_arguments)]
    end
    selection['template'] = selection.fetch('necb_template')
    selection['primary_heating_fuel'] = selection.fetch('hvac_fuel')
    selection['sideload'] = runner.getBoolArgumentValue('sideload', user_arguments)
    overrides = Dir[File.join(resources, 'data_sideload/*.json')].sort
    runner.registerWarning('Sideload is enabled but resources/data_sideload contains no JSON files.') if selection['sideload'] && overrides.empty?
    weather = selection['custom_epw_path'].strip
    weather = File.join(resources, 'openstudio-standards/data/weather', selection.fetch('weather_file')) if weather.empty?
    weather = File.expand_path(weather)
    unless weather.downcase.end_with?('.epw') && %w[.epw .ddy .stat].all? { |ext| File.file?(weather.sub(/\.epw$/i, ext)) }
      runner.registerError('Weather requires a local .epw file and matching .ddy and .stat files.')
      return false
    end
    cli = OpenStudio.getOpenStudioCLI.to_s
    unless File.file?(cli)
      runner.registerError('Could not find the local OpenStudio CLI supplied with the SDK/Application.')
      return false
    end
    run_directory = Dir.mktmpdir('necb_archetype_', Dir.pwd)
    weather_directory = File.join(run_directory, 'weather')
    FileUtils.mkdir_p(weather_directory)
    %w[.epw .ddy .stat].each do |ext|
      FileUtils.cp(weather.sub(/\.epw$/i, ext), weather_directory)
    end
    staged_weather = File.join(weather_directory, File.basename(weather))
    output_model = File.join(run_directory, 'generated.osm')
    status_file = File.join(run_directory, 'generation_status.json')
    request_file = File.join(run_directory, 'request.json')
    File.write(request_file, JSON.pretty_generate(selection.merge(
      'weather_path' => staged_weather, 'run_directory' => run_directory,
      'output_model' => output_model, 'status_file' => status_file,
      'standards_commit' => data.fetch('commit')
    )))
    runner.registerInitialCondition("The input has #{initial_spaces} spaces. Creating #{selection['template']} #{selection['building_type']} with local sizing runs.")
    runner.registerInfo("Using public standards commit #{data['commit']}. Generation files: #{run_directory}")
    env = %w[RUBYLIB RUBYOPT GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLER_VERSION].to_h { |key| [key, nil] }
    stdout, stderr, process = Open3.capture3(env, cli, File.join(resources, 'generate.rb'), request_file, chdir: run_directory)
    File.write(File.join(run_directory, 'generation.log'), stdout + "\n" + stderr)
    status = File.file?(status_file) ? JSON.parse(File.read(status_file)) : {}
    unless process.success? && status['success'] && File.file?(output_model)
      runner.registerError("Archetype generation failed: #{status['error'] || 'no completed model returned'}. See #{File.join(run_directory, 'generation.log')}")
      return false
    end
    translated = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(output_model))
    if translated.empty?
      runner.registerError('Could not load the generated model.')
      return false
    end
    generated = translated.get
    if generated.getSpaces.empty? || generated.getDesignDays.empty?
      runner.registerError('Generated model is missing spaces or design days.')
      return false
    end
    model.removeObjects(model.objects.map(&:handle))
    model.addObjects(generated.toIdfFile.objects)
    # Reference the installed bundle (or the user's EPW), rather than a
    # disposable Application sizing directory, in the model returned to the GUI.
    OpenStudio::Model::WeatherFile.setWeatherFile(model, OpenStudio::EpwFile.new(OpenStudio::Path.new(weather)))
    runner.registerValue('spaces', model.getSpaces.size)
    runner.registerValue('floor_area_m2', model.getBuilding.floorArea)
    runner.registerFinalCondition("Created #{model.getSpaces.size} spaces, #{model.getThermalZones.size} zones and #{model.getAirLoopHVACs.size} air loops. Weather and sizing outputs are in #{run_directory}.")
    true
  rescue StandardError => e
    runner.registerError("#{e.class}: #{e.message}")
    false
  end
end

CreateNECBArchetype.new.registerWithApplication
