require 'openstudio'
require 'json'
require 'fileutils'
root = File.expand_path('..', __dir__)
measure_file = ENV.fetch('NECB_REFERENCE_MEASURE', File.join(root, 'measures/create_necb_reference/measure.rb'))
require measure_file
require File.join(root, 'measures/create_necb_archetype/measure.rb')
resources = File.join(File.dirname(measure_file), 'resources')
weather = File.join(resources, 'openstudio-standards/data/weather/CAN_ON_Toronto.Intl.AP.716240_CWEC2020.epw')
output = File.join(root, 'test-output/reference-equivalence')
FileUtils.mkdir_p(output)
engine = File.expand_path('../../EnergyPlus/energyplus.exe', OpenStudio.getOpenStudioCLI.to_s)
raise "Missing EnergyPlus: #{engine}" unless File.file?(engine)

def apply_measure(measure, model, values, directory)
  FileUtils.mkdir_p(directory)
  Dir.chdir(directory) do
    args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
    values.each do |key, value|
      argument = args[key].clone
      raise "Invalid argument #{key}" unless argument.setValue(value)
      args[key] = argument
    end
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    raise runner.result.errors.map(&:logMessage).join('; ') unless measure.run(model, runner, args)
  end
  model
end

def simulate(model, weather, engine, directory)
  FileUtils.mkdir_p(directory)
  model.getSimulationControl.setRunSimulationforWeatherFileRunPeriods(true)
  model.getSimulationControl.setRunSimulationforSizingPeriods(false)
  model.getOutputSQLite.setOptionType('SimpleAndTabular')
  translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  translated = translator.translateModel(model)
  raise translator.errors.map(&:logMessage).join('; ') unless translator.errors.empty?
  idf = File.join(directory, 'in.idf')
  translated.save(OpenStudio::Path.new(idf), true)
  raise 'Annual simulation failed.' unless system(engine, '-w', weather, '-d', directory, idf, out: File.join(directory, 'simulation.log'), err: [:child, :out])
  errors = File.read(File.join(directory, 'eplusout.err'))
  raise 'Annual simulation reported severe errors.' if errors.include?('** Severe **') || errors.include?('**  Fatal  **')
  sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(File.join(directory, 'eplusout.sql')))
  values = {'total_site_GJ' => sql.totalSiteEnergy.get, 'electricity_GJ' => sql.electricityTotalEndUses.get, 'gas_GJ' => sql.naturalGasTotalEndUses.get}
  ['Electricity', 'Natural Gas'].each do |fuel|
    ['Heating', 'Cooling', 'Interior Lighting', 'Interior Equipment', 'Fans', 'Pumps', 'Heat Recovery', 'Water Systems'].each do |row|
      value = sql.execAndReturnFirstDouble("SELECT Value FROM TabularDataWithStrings WHERE ReportName='AnnualBuildingUtilityPerformanceSummary' AND TableName='End Uses' AND RowName='#{row}' AND ColumnName='#{fuel}' AND Units='GJ'")
      values["#{row}:#{fuel}_GJ"] = value.get unless value.empty?
    end
  end
  sql.close
  values
end

selections = {'necb_template' => 'NECB2020', 'hvac_fuel' => 'NaturalGas', 'swh_fuel' => 'DefaultFuel', 'weather_file' => File.basename(weather)}
prototype = apply_measure(CreateNECBArchetype.new, OpenStudio::Model::Model.new, selections.merge('building_type' => 'FullServiceRestaurant'), File.join(output, 'prototype_generation'))
prototype.save(OpenStudio::Path.new(File.join(output, 'prototype.osm')), true)
results = {'prototype' => simulate(prototype, weather, engine, File.join(output, 'prototype_annual'))}
fixture = File.join(resources, 'openstudio-standards/data/geometry/ASHRAEFullServiceRestaurant.osm')
reference = nil
%w[clean contaminated reapplied].each do |mode|
  model = mode == 'reapplied' ? reference.clone.to_Model : OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(fixture)).get
  if mode == 'contaminated'
    model.getSpaceTypes.each { |type| type.setName("Arbitrary user label #{type.nameString}") }
    space = model.getSpaceByName('Dining').get
    definition = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
    definition.setDesignLevel(100000)
    load = OpenStudio::Model::ElectricEquipment.new(definition)
    load.setSpace(space)
    constant = OpenStudio::Model::ScheduleConstant.new(model)
    constant.setValue(0.17)
    load.setSchedule(constant)
    infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
    infiltration.setSpace(space)
    infiltration.setDesignFlowRate(3)
    model.getSimpleGlazings.each { |glass| glass.setUFactor(5); glass.setSolarHeatGainCoefficient(0.9) }
    model.getSubSurfaces.each(&:remove)
    model.getSite.setTerrain('Ocean')
    model.getYearDescription.setCalendarYear(2024)
    model.getSizingParameters.setHeatingSizingFactor(7)
    model.getSiteGroundTemperatureBuildingSurface.setJanuaryGroundTemperature(45)
    OpenStudio::Model::WaterHeaterMixed.new(model).setHeaterMaximumCapacity(99999)
    OpenStudio::Model::BoilerHotWater.new(model).setNominalCapacity(1000000)
    model.getSurfaces.select { |surface| surface.outsideBoundaryCondition == 'Outdoors' }.each do |surface|
      surface.setSunExposure('NoSun')
      surface.setWindExposure('NoWind')
    end
    model.getWaterHeaterMixeds.each { |heater| heater.setHeaterMaximumCapacity(99999); heater.setHeaterThermalEfficiency(0.6) }
  end
  NECBInputPreparation.apply(model, JSON.parse(File.read(File.join(resources, 'space_type_catalog.json'))), 'UseExisting')
  geometry = NECBExistingModelChecks.geometry_hash(model)
  reference = apply_measure(CreateNECBReference.new, model, selections.merge('operating_inputs' => 'ReplaceWithNECB', 'building_systems' => 'ReplaceWithNECB'), File.join(output, mode + '_generation'))
  raise 'Source geometry changed.' unless geometry == NECBExistingModelChecks.geometry_hash(reference)
  audit = JSON.parse(reference.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit').get)
  raise 'Wrong generation path.' unless audit['mode'] == 'CompleteNECBRebuild'
  raise 'FDWR mismatch.' unless (audit.dig('fenestration', 'fdwr', 'areas_after', 'fdwr') - 0.4).abs < 1e-8
  raise 'SWH pump lookup fell back to SDK default.' unless (reference.getPumpConstantSpeeds.first.ratedPumpHead - prototype.getPumpConstantSpeeds.first.ratedPumpHead).abs < 1e-4
  reference.save(OpenStudio::Path.new(File.join(output, mode + '.osm')), true)
  results[mode] = simulate(reference, weather, engine, File.join(output, mode + '_annual'))
  results['prototype'].each do |key, expected|
    tolerance = [0.02, expected * (key.include?(':') ? 0.005 : 0.001)].max
    raise "#{mode} differs from prototype: #{key} #{results[mode][key]} vs #{expected}" unless (results[mode].fetch(key) - expected).abs <= tolerance
  end
  if mode != 'clean'
    results['clean'].each do |key, expected|
      # Equivalent NRC loops can acquire different numeric names/order. Annual
      # plant iteration then varies by a few 0.01-GJ SQL reporting increments.
      # Keep this tighter than the independent-prototype 0.1% fuel tolerance.
      raise "Full replacement exceeds contamination/reapplication tolerance: #{mode} #{key}" unless (results[mode].fetch(key) - expected).abs <= [0.02, expected * 0.0002].max
    end
  end
  File.write(File.join(output, 'summary.json'), JSON.pretty_generate(results))
  puts "Annual equivalence passed: #{mode}: #{results[mode]['total_site_GJ']} GJ vs #{results['prototype']['total_site_GJ']} GJ"
end
