# Keep the pinned library isolated from standards already loaded by the GUI.
require 'openstudio'
require 'json'
require_relative 'model_checks'

begin
  request = JSON.parse(File.read(ARGV.fetch(0)))
  manifest = JSON.parse(File.read(File.join(__dir__, 'dependency_manifest.json')))
  manifest.fetch('gems').each do |gem|
    $LOAD_PATH.unshift(File.join(__dir__, 'gems', "#{gem['name']}-#{gem['version']}", 'lib'))
  end
  require File.join(__dir__, 'openstudio-standards/lib/openstudio-standards.rb')
  require_relative 'local_sizing'
  standard = Standard.build(request.fetch('necb_template'))
  standard.singleton_class.prepend(LocalNECBSizing)
  standard.instance_variable_set(:@local_sizing_root, request.fetch('run_directory'))
  loaded = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(request.fetch('input_model')))
  raise 'Could not load the staged OSM.' if loaded.empty?
  model = loaded.get
  raise NECBExistingModelChecks.errors(model).join("\n") unless NECBExistingModelChecks.errors(model).empty?
  catalog = JSON.parse(File.read(File.join(__dir__, 'space_type_catalog.json')))
  classification_errors = NECBExistingModelChecks.classification_errors(model, catalog)
  raise classification_errors.join("\n") unless classification_errors.empty?
  original_geometry = NECBExistingModelChecks.geometry_hash(model)
  complete_rebuild = request['operating_inputs'] == 'ReplaceWithNECB' && request['building_systems'] == 'ReplaceWithNECB'
  source = model.clone.to_Model if complete_rebuild
  # Proposed EMS controls refer to HVAC/schedules that upstream will delete.
  # Remove the old EMS set; upstream creates its own reference controls.
  ems = model.objects.select { |object| object.iddObject.name.start_with?('OS:EnergyManagementSystem:') }
  removed_ems = ems.size
  model.removeObjects(ems.map(&:handle)) unless request['building_systems'] == 'KeepExisting'
  removed_ems = 0 if request['building_systems'] == 'KeepExisting'
  # A completed proposed model may already use Kiva. Upstream rebuilds envelope
  # constructions for Ground surfaces, then creates its own Kiva foundation.
  model.getSurfaces.select { |surface| surface.outsideBoundaryCondition == 'Foundation' }.each do |surface|
    surface.resetAdjacentFoundation
    surface.setOutsideBoundaryCondition('Ground')
  end
  model.getSurfacePropertyExposedFoundationPerimeters.each(&:remove)
  model.getFoundationKivas.each(&:remove)
  # Unused imported types must not prevent identification of the used vintage.
  used_types = model.getSpaces.map { |space| space.spaceType.get.handle.to_s }.uniq
  model.getSpaceTypes.each { |type| type.remove unless used_types.include?(type.handle.to_s) }
  require_relative 'reference_options'
  if complete_rebuild
    require_relative 'complete_rebuild'
    model, settings_source = NECBCompleteRebuild.prepare(source, standard, __dir__)
  else
    standard.singleton_class.prepend(NECBPart8Reference)
    standard.singleton_class.prepend(NECBReferenceOptions)
    standard.configure_reference(model, request)
  end
  # Upstream updates Space Type loads but leaves loads directly on Spaces.
  # Remove those instances to avoid adding a second set of reference loads.
  removed_direct_loads = 0
  weather_path = request.fetch('weather_path')
  keep_systems = request['building_systems'] == 'KeepExisting'
  standard.define_singleton_method(:apply_weather_data) do |model:, **_options|
    model_temp_fix_ems_references(model) unless keep_systems
    model.getYearDescription.setDayofWeekforStartDay('Sunday') if complete_rebuild
    result = OpenstudioStandards::Weather.model_set_building_location(model, weather_file_path: weather_path)
    raise 'Could not set local weather and design days.' unless result
  end
  generated = standard.model_apply_standard(
    model: model, epw_file: File.basename(weather_path), sizing_run_dir: request.fetch('run_directory'),
    primary_heating_fuel: request.fetch('hvac_fuel'),
    swh_fuel: request.fetch('swh_fuel') == 'DefaultFuel' ? nil : request.fetch('swh_fuel')
  )
  audit = complete_rebuild ? NECBCompleteRebuild.finish(generated, source, standard, settings_source) : standard.finish_part8(generated)
  require_relative 'skylight_checks'
  skylight_source = complete_rebuild ? source : standard.instance_variable_get(:@part8_source)
  audit['fenestration']['srr'] = NECBSkylightChecks.audit(generated, skylight_source, standard, complete: complete_rebuild)
  generated.getBuilding.additionalProperties.setFeature('necb_part8_audit', JSON.generate(audit))
  File.write(File.join(request.fetch('run_directory'), 'part8_audit.json'), JSON.pretty_generate(audit))
  raise 'The standards routine did not return a model.' unless generated.is_a?(OpenStudio::Model::Model)
  raise 'Upstream generation changed source space geometry or multipliers.' unless NECBExistingModelChecks.geometry_hash(generated) == original_geometry
  raise 'Missing generated spaces or design days.' if generated.getSpaces.empty? || generated.getDesignDays.empty?
  generated.resetSqlFile
  building = generated.getBuilding
  building.setName("#{building.nameString} - #{request.fetch('necb_template')} Reference")
  properties = building.additionalProperties
  properties.setFeature('necb_standards_commit', request.fetch('standards_commit'))
  properties.setFeature('necb_template', request.fetch('necb_template'))
  properties.setFeature('necb_primary_heating_fuel', request.fetch('hvac_fuel'))
  properties.setFeature('necb_model_role', 'reference_starting_point')
  properties.setFeature('necb_source_geometry_sha256', original_geometry)
  properties.setFeature('necb_removed_direct_loads', removed_direct_loads)
  properties.setFeature('necb_removed_proposed_ems', removed_ems)
  translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  translator.translateModel(generated)
  raise "Forward translation failed: #{translator.errors.map(&:logMessage).join('; ')}" unless translator.errors.empty?
  raise 'Could not save the reference model.' unless generated.save(OpenStudio::Path.new(request.fetch('output_model')), true)
  File.write(request.fetch('status_file'), JSON.pretty_generate({
    'success' => true, 'sdk' => OpenStudio.openStudioVersion,
    'standards_version' => OpenstudioStandards::VERSION,
    'spaces' => generated.getSpaces.size, 'zones' => generated.getThermalZones.size,
    'air_loops' => generated.getAirLoopHVACs.size,
    'floor_area_m2' => building.floorArea, 'geometry_verified' => true,
    'removed_direct_loads' => removed_direct_loads, 'removed_proposed_ems' => removed_ems
  }))
rescue StandardError, LoadError => e
  if defined?(request) && request
    # The NRC sizing exception can mention DX coils even for invalid input.
    # Include the actual first EnergyPlus severe error and the real local path.
    diagnostic = nil
    if e.message.include?('sizing run failed')
      error_file = Dir[File.join(request.fetch('run_directory'), 'sizing_*', 'run/eplusout.err')].sort.last
      if error_file
        first_severe = File.foreach(error_file).find { |line| line.include?('** Severe') }
        diagnostic = "EnergyPlus: #{first_severe.strip}. See #{error_file}" if first_severe
      end
    end
    File.write(request.fetch('status_file'), JSON.pretty_generate({
      'success' => false, 'error' => ["#{e.class}: #{e.message}", diagnostic].compact.join(' '), 'backtrace' => e.backtrace.first(12)
    }))
  end
  warn "#{e.class}: #{e.message}"
  exit 1
end
