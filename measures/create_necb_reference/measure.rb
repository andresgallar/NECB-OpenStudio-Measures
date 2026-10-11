require 'openstudio'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'
require_relative 'resources/model_checks'
require_relative 'resources/space_type_mapping'
require_relative 'resources/input_preparation'

class CreateNECBReference < OpenStudio::Measure::ModelMeasure
  def name
    'Create NECB Reference From OSM'
  end

  def description
    'Creates an NECB baseline from existing Spaces and reviewed space uses. Select Replace for both operating inputs and building systems for a complete rebuild using the same NRC defaults as the NECB prototype measure, including windows and automatic zoning. Keep options preserve selected proposed inputs for a project reference comparison. No OpenStudio Server or runtime downloads. See README for Part 8 limitations.'
  end

  def modeler_description
    'Stages one source model, supplies missing metadata and applies reviewed mappings in an isolated bundled NRC library. Replace both choices builds a clean geometry-only model and invokes the same model_apply_standard routine as the prototype measure; temporary canonical Space Type names prevent the upstream SWH pump lookup from falling back. Keep choices use the preservation adapters and verify retained systems through serialization. CSVs identify exact Space Type names. Reports assumptions and Part 8 limitations.'
  end

  def manifest
    JSON.parse(File.read(File.join(__dir__, 'resources/dependency_manifest.json')))
  end

  def choice(name, values, display, default, labels: nil)
    vector = OpenStudio::StringVector.new
    values.each { |value| vector << value }
    if labels
      names = OpenStudio::StringVector.new
      labels.each { |label| names << label }
      argument = OpenStudio::Measure::OSArgument.makeChoiceArgument(name, vector, names, true)
    else
      argument = OpenStudio::Measure::OSArgument.makeChoiceArgument(name, vector, true)
    end
    argument.setDisplayName(display)
    argument.setDefaultValue(default)
    argument
  end

  def string(name, display)
    argument = OpenStudio::Measure::OSArgument.makeStringArgument(name, false)
    argument.setDisplayName(display)
    argument.setDefaultValue('')
    argument
  end

  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new
    source_path = string('osm_file_path', 'Source OSM path (blank uses the open model)')
    source_path.setDescription('Requires existing Spaces with surfaces. Compatible NECB classifications are retained; automatic translation uses reviewed public prototype mappings, with undefined fallback for unmatched types. Review or override assignments using the optional CSV.')
    args << source_path
    uses = JSON.parse(File.read(File.join(__dir__, 'resources/space_type_catalog.json'))).values.flatten(1).select { |pair| pair[1] == 'WholeBuilding' }.map(&:first).uniq.sort
    default_use = choice('default_building_use', ['UseExisting'] + uses, 'Default building use for spaces without Space Types', 'UseExisting', labels: ['Use building metadata (otherwise select a use below)'] + uses)
    default_use.setDescription('Used for spaces without Space Types. Automatic translation first recovers reviewed uses from an exact matching public prototype shell consistent with this use. Otherwise occupied spaces receive WholeBuilding defaults and excluded floor-area spaces receive undefined for review. Supplied classified/custom types are retained; only documented defaults from earlier measure runs can be repaired during full replacement.')
    args << default_use
    operating = choice('operating_inputs', %w[KeepExisting ReplaceWithNECB], 'Occupancy, equipment loads, lighting and operating schedules', 'KeepExisting', labels: ['Keep existing inputs; add missing NECB defaults', 'Replace with NECB default operating profiles'])
    operating.setDescription('Select Replace here AND for building systems to discard proposed physical inputs and rebuild an NRC NECB prototype baseline from the existing Space geometry and reviewed uses. This also regenerates windows, zones, envelope, infiltration and simulation settings. Keep preserves existing operating inputs and fills absent categories.')
    args << operating
    systems = choice('building_systems', %w[ReplaceWithNECB KeepExisting], 'HVAC, water heating equipment and infiltration', 'ReplaceWithNECB', labels: ['Replace with NECB systems and infiltration', 'Keep existing systems and infiltration unchanged'])
    systems.setDescription('With Replace operating inputs, performs the complete NRC prototype rebuild. With Keep operating inputs, retains source thermal blocks and window distribution and applies the local Part 8 envelope/leakage rules. Keep systems preserves existing equipment and infiltration.')
    args << systems
    translation = choice('mapping_preset', %w[AutoReviewed None], 'Space-use translation', 'AutoReviewed', labels: ['Automatic: reviewed ASHRAE mappings; undefined for unmatched uses', 'Strict: compatible NECB types or reviewed CSV required'])
    translation.setDescription('Automatic applies exact reviewed classifications per Space Type, including mixed uses. Unmatched or ambiguous types become Space Function / - undefined - and are reported for review. Strict stops on unmapped uses. Compatible NECB types are retained unless explicitly overridden by CSV.')
    args << translation
    mapping_csv = string('mapping_csv_path', 'Optional reviewed space-use mapping CSV')
    mapping_csv.setDescription('Optional input: exact Space Type names and catalog pairs. Explicit rows override automatic or existing assignments. Automatic translations export space_use_mapping.csv for review; select an edited copy here to correct uses. Blank target columns keep the automatic/existing assignment.')
    args << mapping_csv
    args << choice('necb_template', %w[NECB2011 NECB2015 NECB2017 NECB2020], 'Reference NECB edition', 'NECB2020')
    args << choice('weather_file', ['UseModelWeather'] + manifest.fetch('weather_files'), 'Weather (source model by default)', 'UseModelWeather')
    args << string('custom_epw_path', 'Optional local EPW override (matching DDY and STAT required)')
    args << choice('hvac_fuel', %w[DefaultFuel NaturalGas Electricity FuelOilNo2], 'Reference primary heating fuel (select for your project)', 'DefaultFuel')
    args << choice('swh_fuel', %w[DefaultFuel NaturalGas Electricity], 'Reference service water heating fuel', 'DefaultFuel')
    args
  end

  def mapping_presets
    JSON.parse(File.read(File.join(__dir__, 'resources/mapping_presets.json')))
  end

  def resolve_weather(source, selection, source_path)
    custom = selection.fetch('custom_epw_path').strip
    return File.expand_path(custom) unless custom.empty?
    bundle = File.join(__dir__, 'resources/openstudio-standards/data/weather')
    selected = selection.fetch('weather_file')
    return File.join(bundle, selected) unless selected == 'UseModelWeather'
    return nil if source.weatherFile.empty? || source.weatherFile.get.path.empty?
    raw = source.weatherFile.get.path.get.to_s.tr('\\', '/')
    bases = [source_path.empty? ? Dir.pwd : File.dirname(source_path), Dir.pwd]
    candidates = bases.map { |base| File.expand_path(raw, base) }
    candidates << File.join(bundle, File.basename(raw))
    candidates.find { |path| weather_set_exists?(path) }
  end

  def weather_set_exists?(path)
    path && path.downcase.end_with?('.epw') && %w[.epw .ddy .stat].all? { |ext| File.file?(path.sub(/\.epw$/i, ext)) }
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    return false unless runner.validateUserArguments(arguments(model), user_arguments)
    selection = %w[osm_file_path necb_template weather_file custom_epw_path hvac_fuel swh_fuel mapping_preset mapping_csv_path default_building_use operating_inputs building_systems].to_h do |key|
      [key, runner.getStringArgumentValue(key, user_arguments)]
    end
    source_path = selection.fetch('osm_file_path').strip
    source_path = File.expand_path(source_path) unless source_path.empty?
    # Validation getters can create singleton objects. Work on a clone so even
    # an invalid input leaves the current model byte-for-byte unchanged.
    source = model.clone.to_Model
    unless source_path.empty?
      unless source_path.downcase.end_with?('.osm') && File.file?(source_path)
        runner.registerError('The source OSM path must point to an existing .osm file.')
        return false
      end
      loaded = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(source_path))
      if loaded.empty?
        runner.registerError('Could not load or translate the source OSM.')
        return false
      end
      source = loaded.get
    end
    catalog = JSON.parse(File.read(File.join(__dir__, 'resources/space_type_catalog.json')))
    original_type_assignments = source.getSpaces.map { |space| [space.handle.to_s, space.spaceType.empty? ? nil : space.spaceType.get.handle.to_s] }.sort
    reviewed_resources = selection['mapping_preset'] == 'AutoReviewed' && selection['mapping_csv_path'].strip.empty? ? File.join(__dir__, 'resources') : nil
    repair_defaults = selection['operating_inputs'] == 'ReplaceWithNECB' && selection['building_systems'] == 'ReplaceWithNECB'
    preparation = NECBInputPreparation.apply(source, catalog, selection['default_building_use'], reviewed_resources: reviewed_resources, repair_defaults: repair_defaults)
    prepared_types = original_type_assignments != source.getSpaces.map { |space| [space.handle.to_s, space.spaceType.empty? ? nil : space.spaceType.get.handle.to_s] }.sort
    preparation.each { |message| runner.registerInfo(message) }
    preparation.grep(/excluded from total floor area/).each { |message| runner.registerWarning(message) }
    source.getBuilding.additionalProperties.setFeature('necb_input_preparation', JSON.generate(preparation))
    csv_path = selection.fetch('mapping_csv_path').strip
    csv_path = File.expand_path(csv_path) unless csv_path.empty?
    mapping_source = source.clone.to_Model
    begin
      mapping_audit = NECBSpaceTypeMapping.apply(source, catalog, selection['mapping_preset'], mapping_presets, csv_path)
    rescue NECBSpaceTypeMapping::MappingError => e
      runner.registerError(e.message)
      export_mapping_review(source, catalog, selection, runner)
      return false
    end
    run_directory = Dir.mktmpdir('necb_reference_', Dir.pwd)
    File.write(File.join(run_directory, 'mapping_audit.json'), JSON.pretty_generate(mapping_audit))
    if prepared_types || !mapping_audit.empty?
      review_path = File.join(run_directory, 'space_use_mapping.csv')
      NECBSpaceTypeMapping.export_template(mapping_source, catalog, selection['mapping_preset'], mapping_presets, review_path, selection['necb_template'], csv_path)
      runner.registerInfo("Prepared Space uses and applied #{mapping_audit.size} classification translations. Review or edit #{review_path} and select the edited file under Optional reviewed space-use mapping CSV. Audit: #{File.join(run_directory, 'mapping_audit.json')}")
      fallbacks = mapping_audit.select { |row| row['method'].start_with?('fallback:') }
      unless fallbacks.empty?
        runner.registerWarning("#{fallbacks.size} unmatched or ambiguous Space Types assigned Space Function / - undefined -: #{fallbacks.map { |row| row['source_space_type'] }.join('; ')}. This wildcard does not infer actual use or conditioning and may omit loads or HVAC. Correct assignments in #{review_path} before relying on energy results.")
      end
      if mapping_audit.any? { |row| row['necb_space_type'] == '- undefined -' && !row['method'].start_with?('fallback:') }
        runner.registerWarning("Reviewed assignments include - undefined - (for example, prototype attics). Review use and conditioning for this project; override with #{review_path} if needed.")
      end
    end
    errors = NECBExistingModelChecks.errors(source)
    errors.concat(NECBExistingModelChecks.classification_errors(source, catalog))
    unless errors.empty?
      errors.first(20).each { |message| runner.registerError(message) }
      runner.registerError("#{errors.size} input issues found. See README.md for required NECB metadata.")
      needs_mapping = NECBSpaceTypeMapping.used_types(source).any? { |type| !catalog.values.any? { |entries| entries.include?(NECBSpaceTypeMapping.pair(type)) } }
      export_mapping_review(source, catalog, selection, runner) if needs_mapping
      return false
    end
    weather = resolve_weather(source, selection, source_path)
    unless weather_set_exists?(weather)
      runner.registerError('Could not resolve source weather with matching .ddy and .stat files. Select bundled weather or supply a local EPW override.')
      return false
    end
    cli = OpenStudio.getOpenStudioCLI.to_s
    raise 'Could not find the local OpenStudio CLI.' unless File.file?(cli)
    source.getBuilding.additionalProperties.setFeature('necb_space_type_mapping_audit', JSON.generate(mapping_audit))
    source.getBuilding.additionalProperties.setFeature('necb_mapping_preset', selection['mapping_preset'])
    input = File.join(run_directory, 'source.osm')
    raise 'Could not stage the source model.' unless source.save(OpenStudio::Path.new(input), true)
    weather_directory = File.join(run_directory, 'weather')
    FileUtils.mkdir_p(weather_directory)
    %w[.epw .ddy .stat].each { |ext| FileUtils.cp(weather.sub(/\.epw$/i, ext), weather_directory) }
    request = selection.merge(
      'input_model' => input, 'weather_path' => File.join(weather_directory, File.basename(weather)),
      'run_directory' => run_directory, 'output_model' => File.join(run_directory, 'reference.osm'),
      'status_file' => File.join(run_directory, 'generation_status.json'),
      'standards_commit' => manifest.fetch('commit')
    )
    request_file = File.join(run_directory, 'request.json')
    File.write(request_file, JSON.pretty_generate(request))
    runner.registerInitialCondition("Creating a #{selection['necb_template']} reference starting point from #{source.getSpaces.size} source spaces.")
    complete_rebuild = selection['operating_inputs'] == 'ReplaceWithNECB' && selection['building_systems'] == 'ReplaceWithNECB'
    runner.registerInfo(complete_rebuild ? 'Complete NECB rebuild: source Space geometry, effective multipliers and reviewed uses retained; all proposed physical inputs discarded. Windows, zones, loads, HVAC, SWH, infiltration and simulation settings use NRC prototype defaults.' : "Operating inputs: #{selection['operating_inputs']}; building systems: #{selection['building_systems']}. Missing operating categories use NRC NECB defaults; existing zones are retained.")
    runner.registerInfo("Local sizing files and diagnostics: #{run_directory}")
    env = %w[RUBYLIB RUBYOPT GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLER_VERSION].to_h { |key| [key, nil] }
    stdout, stderr, process = Open3.capture3(env, cli, File.join(__dir__, 'resources/generate.rb'), request_file, chdir: run_directory)
    File.write(File.join(run_directory, 'generation.log'), stdout + "\n" + stderr)
    status = File.file?(request['status_file']) ? JSON.parse(File.read(request['status_file'])) : {}
    unless process.success? && status['success'] && File.file?(request['output_model'])
      runner.registerError("Reference generation failed: #{status['error'] || 'no completed model returned'}. See #{File.join(run_directory, 'generation.log')}")
      return false
    end
    loaded = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(request['output_model']))
    raise 'Could not load the generated reference model.' if loaded.empty?
    generated = loaded.get
    NECBSpaceTypeMapping.copy_origins(source, generated)
    if selection['building_systems'] == 'KeepExisting'
      include_demand = selection['operating_inputs'] == 'KeepExisting'
      original_systems = NECBExistingModelChecks.system_signature(source, include_water_demand: include_demand)
      result_systems = NECBExistingModelChecks.system_signature(generated, include_water_demand: include_demand)
      original_systems.each do |key, value|
        raise "A retained system or connection changed during model transfer: #{key}." unless result_systems[key] == value
      end
    end
    audit_path = File.join(run_directory, 'part8_audit.json')
    if File.file?(audit_path)
      audit = JSON.parse(File.read(audit_path))
      runner.registerInfo("Reference generation, FDWR and skylight audit: #{audit_path}")
      areas = audit.dig('fenestration', 'fdwr', 'areas_after')
      if areas
        runner.registerInfo(format('Reference FDWR %.3f%% = (%.3f m2 vertical fenestration + %.3f m2 opaque doors) / %.3f m2 gross walls. Glazing-only WWR %.3f%%.',
          areas['fdwr'] * 100, areas['vertical_fenestration_area_m2'], areas['opaque_door_area_m2'], areas['gross_wall_area_m2'], areas['glazing_only_wwr'] * 100))
        runner.registerInfo(complete_rebuild ? 'Window layout regenerated using the NRC prototype routine.' : 'Opening-area shares by orientation are preserved.')
      end
      skylights = audit.dig('fenestration', 'srr')
      if skylights
        areas = skylights.fetch('exposed_conditioned_nonplenum_roofs_after')
        runner.registerInfo(format('Skylights: %d openings, %.3f m2; SRR %.3f%% over %.3f m2 exposed conditioned non-plenum roofs. Treatment: %s. See roof-by-roof audit for excluded attics/plenums.', areas['skylight_count'], areas['skylight_area_m2'], areas['srr'] * 100, areas['gross_roof_area_m2'], skylights['mode']))
        runner.registerWarning('Part 8 daylighting calculations require project review; prototype skylights and daylight controls alone do not verify NECB 8.4.4.5 compliance.')
      end
      audit.fetch('limitations', []).each { |limitation| runner.registerWarning(limitation) }
    end
    raise 'Generated space geometry differs from the source.' unless NECBExistingModelChecks.geometry_hash(generated) == NECBExistingModelChecks.geometry_hash(source)
    raise 'Generated model is missing spaces or design days.' if generated.getSpaces.empty? || generated.getDesignDays.empty?
    # Prepare persistent weather before importing the completed model.
    OpenStudio::Model::WeatherFile.setWeatherFile(generated, OpenStudio::EpwFile.new(OpenStudio::Path.new(weather)))
    model.removeObjects(model.objects.map(&:handle))
    model.addObjects(generated.toIdfFile.objects)
    runner.registerValue('spaces', model.getSpaces.size)
    runner.registerValue('floor_area_m2', model.getBuilding.floorArea)
    runner.registerFinalCondition("Created a #{selection['necb_template']} reference starting point with #{model.getSpaces.size} spaces and #{model.getAirLoopHVACs.size} air loops. Source space geometry verified. Save this model under a new reference filename.")
    true
  rescue StandardError => e
    runner.registerError("#{e.class}: #{e.message}")
    false
  end

  def export_mapping_review(source, catalog, selection, runner)
    directory = Dir.mktmpdir('necb_mapping_review_', Dir.pwd)
    path = File.join(directory, 'space_use_mapping.csv')
    # Export independently of a failed/incomplete preset so unknown rows remain
    # blank and existing supported pairs are visible for review.
    NECBSpaceTypeMapping.export_template(source, catalog, 'None', mapping_presets, path, selection['necb_template'])
    runner.registerError("Review the NECB assignments in #{path}, then select that file under Optional reviewed space-use mapping CSV. The open model was not changed.")
  end
end

CreateNECBReference.new.registerWithApplication
