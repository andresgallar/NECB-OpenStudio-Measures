require 'openstudio'
require 'json'
require 'fileutils'
require 'digest'
root = File.expand_path('..', __dir__)
measure_file = ENV.fetch('NECB_REFERENCE_MEASURE', File.join(root, 'measures/create_necb_reference/measure.rb'))
require measure_file
resources = File.join(File.dirname(measure_file), 'resources')
manifest = JSON.parse(File.read(File.join(resources, 'dependency_manifest.json')))
manifest.fetch('gems').each { |gem| $LOAD_PATH.unshift(File.join(resources, 'gems', "#{gem['name']}-#{gem['version']}", 'lib')) }
require File.join(resources, 'openstudio-standards/lib/openstudio-standards.rb')
source = File.join(root, 'test-output/mapping_preset/reference.osm')
model = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new(source)).get
OpenstudioStandards::HVAC.remove_all_hvac(model)
model.getWaterUseEquipments.each(&:remove)
model.getWaterUseConnectionss.each(&:remove)
schedule = OpenStudio::Model::ScheduleConstant.new(model)
schedule.setName('Proposed custom process and lighting schedule')
schedule.setValue(0.47)
model.getLightss.each { |light| light.setSchedule(schedule) }
model.getThermalZones.each do |zone|
  zone.setName("Proposed #{zone.spaces.first.nameString}")
  zone.setUseIdealAirLoads(false)
  zone.resetThermostatSetpointDualSetpoint
  next if zone.spaces.any? { |space| space.nameString.downcase.include?('attic') }
  heating = OpenStudio::Model::ScheduleConstant.new(model)
  heating.setValue(20.3)
  cooling = OpenStudio::Model::ScheduleConstant.new(model)
  cooling.setValue(25.7)
  thermostat = OpenStudio::Model::ThermostatSetpointDualSetpoint.new(model)
  thermostat.setHeatingSetpointTemperatureSchedule(heating)
  thermostat.setCoolingSetpointTemperatureSchedule(cooling)
  zone.setThermostatSetpointDualSetpoint(thermostat)
  zone.setUseIdealAirLoads(true)
  availability = OpenStudio::Model::ScheduleConstant.new(model)
  availability.setName('Proposed HVAC availability')
  availability.setValue(0.63)
  ideal = OpenStudio::Model::ZoneHVACIdealLoadsAirSystem.new(model)
  ideal.setAvailabilitySchedule(availability)
  ideal.addToThermalZone(zone)
end
kitchen = model.getSpaces.find { |space| space.nameString.downcase.include?('kitchen') }
definition = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
definition.setDesignLevel(1234)
process = OpenStudio::Model::ElectricEquipment.new(definition)
process.setName('Proposed custom process load')
process.setSpace(kitchen)
process.setSchedule(schedule)
model.getSubSurfaces.each do |opening|
  next if opening.construction.empty? || opening.construction.get.to_Construction.empty?
  glass = opening.construction.get.to_Construction.get.layers.first.to_SimpleGlazing
  next if glass.empty?
  glass.get.setUFactor(5.0)
  glass.get.setSolarHeatGainCoefficient(0.61)
  glass.get.setVisibleTransmittance(0.72)
end
mass_definition = OpenStudio::Model::InternalMassDefinition.new(model)
mass_definition.setSurfaceArea(12.3)
partition = kitchen.surfaces.find { |surface| surface.outsideBoundaryCondition == 'Surface' && !surface.construction.empty? }
mass_definition.setConstruction(partition.construction.get)
mass = OpenStudio::Model::InternalMass.new(mass_definition)
mass.setName('Proposed thermal mass')
mass.setSpace(kitchen)
typed_mass = OpenStudio::Model::InternalMass.new(mass_definition)
typed_mass.setName('Proposed Space Type thermal mass')
typed_mass.setSpaceType(kitchen.spaceType.get)
unused = OpenStudio::Model::SpaceType.new(model)
unused.setName('Unused imported custom occupancy')
unused.setStandardsBuildingType('CustomUnused')
unused.setStandardsSpaceType('CustomUnused')
swh_test = ENV['NECB_PART8_SWH_TEST'] == 'true'
if swh_test
  water_definition = OpenStudio::Model::WaterUseEquipmentDefinition.new(model)
  water_definition.setPeakFlowRate(0.0002)
  target = OpenStudio::Model::ScheduleConstant.new(model)
  target.setValue(55)
  water_definition.setTargetTemperatureSchedule(target)
  water = OpenStudio::Model::WaterUseEquipment.new(water_definition)
  water.setName('Proposed custom water demand')
  water.setSpace(kitchen)
  water.setFlowRateFractionSchedule(schedule)
end
# Shrink the original windows, so the reference must increase their areas.
model.getSubSurfaces.select { |opening| opening.subSurfaceType == 'FixedWindow' }.each do |opening|
  vertices = opening.vertices.to_a
  center = OpenStudio::Point3d.new(vertices.sum(&:x) / vertices.size, vertices.sum(&:y) / vertices.size, vertices.sum(&:z) / vertices.size)
  points = OpenStudio::Point3dVector.new
  vertices.each { |point| scale = Math.sqrt(0.5); points << OpenStudio::Point3d.new(center.x + (point.x - center.x) * scale, center.y + (point.y - center.y) * scale, center.z + (point.z - center.z) * scale) }
  opening.setVertices(points)
end
before_geometry = NECBExistingModelChecks.geometry_hash(model)
before_loads = [model.getPeoples.size, model.getElectricEquipments.size, model.getGasEquipments.size, model.getOtherEquipments.size]
blocks = model.getThermalZones.to_h { |zone| [zone.nameString, zone.spaces.map(&:nameString).sort] }
original_openings = model.getSubSurfaces.to_h { |opening| [opening.nameString, [opening.subSurfaceType, opening.grossArea]] }
output = File.join(root, swh_test ? 'test-output/part8_swh' : 'test-output/part8_preservation')
FileUtils.mkdir_p(output)
Dir.chdir(output) do
  model.save(OpenStudio::Path.new('proposed.osm'), true)
  source_sha = Digest::SHA256.file('proposed.osm').hexdigest
  measure = CreateNECBReference.new
  args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
  {'operating_inputs' => 'KeepExisting', 'necb_template' => 'NECB2020', 'weather_file' => 'CAN_ON_Toronto.Intl.AP.716240_CWEC2020.epw', 'hvac_fuel' => 'NaturalGas'}.each do |name, value|
    argument = args[name].clone
    raise 'Bad argument' unless argument.setValue(value)
    args[name] = argument
  end
  runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
  success = measure.run(model, runner, args)
  summary = {success: success, errors: runner.result.errors.map(&:logMessage), warnings: runner.result.warnings.map(&:logMessage)}
  File.write('summary.json', JSON.pretty_generate(summary))
  puts JSON.pretty_generate(summary)
  raise 'Part 8 generation failed' unless success
  raise 'Geometry changed' unless NECBExistingModelChecks.geometry_hash(model) == before_geometry
  raise 'Non-lighting load counts changed' unless before_loads == [model.getPeoples.size, model.getElectricEquipments.size, model.getGasEquipments.size, model.getOtherEquipments.size]
  raise 'Thermal blocks changed' unless blocks == model.getThermalZones.to_h { |zone| [zone.nameString, zone.spaces.map(&:nameString).sort] }
  preserved = model.getElectricEquipmentByName('Proposed custom process load').get
  raise 'Process load changed' unless preserved.electricEquipmentDefinition.designLevel.get == 1234 && preserved.schedule.get.to_ScheduleConstant.get.value == 0.47
  attic = model.getThermalZoneByName('Proposed attic').get
  raise 'Attic became conditioned' unless attic.equipment.empty? && attic.airLoopHVAC.empty? && !attic.useIdealAirLoads
  model.getThermalZones.reject { |zone| zone == attic }.each do |zone|
    thermostat = zone.thermostatSetpointDualSetpoint.get
    raise 'Setpoints changed' unless thermostat.heatingSetpointTemperatureSchedule.get.to_ScheduleConstant.get.value == 20.3 && thermostat.coolingSetpointTemperatureSchedule.get.to_ScheduleConstant.get.value == 25.7
  end
  model.getLightss.each { |light| raise 'Lighting schedule changed' unless light.schedule.get.to_ScheduleConstant.get.value == 0.47 }
  model.getAirLoopHVACs.each { |loop| raise 'HVAC availability changed' unless loop.availabilitySchedule.to_ScheduleConstant.get.value == 0.63 }
  preserved_mass = model.getInternalMassByName('Proposed thermal mass').get
  raise 'Thermal mass changed' unless preserved_mass.internalMassDefinition.surfaceArea.get == 12.3
  typed_mass = model.getInternalMassByName('Proposed Space Type thermal mass').get
  raise 'Space Type thermal mass assignment changed' unless typed_mass.spaceType.get == model.getSpaceByName(kitchen.nameString).get.spaceType.get
  model.getSubSurfaces.each do |opening|
    next unless %w[FixedWindow OperableWindow GlassDoor Skylight].include?(opening.subSurfaceType)
    glass = opening.construction.get.to_Construction.get.layers.first.to_SimpleGlazing.get
    raise 'Glazing optics changed' unless (glass.solarHeatGainCoefficient - 0.61).abs < 1e-7 && (glass.visibleTransmittance.get - 0.72).abs < 1e-7
    raise 'Reference U factor not applied' unless glass.uFactor < 5
  end
  model.getSpaceInfiltrationDesignFlowRates.each do |infiltration|
    raise 'Infiltration is not constant' unless infiltration.constantTermCoefficient == 1 && infiltration.temperatureTermCoefficient == 0 && infiltration.velocityTermCoefficient == 0 && infiltration.velocitySquaredTermCoefficient == 0
  end
  if swh_test
    water = model.getWaterUseEquipmentByName('Proposed custom water demand').get
    raise 'SWH demand changed' unless model.getWaterUseEquipments.size == 1 && water.waterUseEquipmentDefinition.peakFlowRate == 0.0002 && water.flowRateFractionSchedule.get.to_ScheduleConstant.get.value == 0.47
    raise 'SWH target temperature changed' unless water.waterUseEquipmentDefinition.targetTemperatureSchedule.get.to_ScheduleConstant.get.value == 55
    raise 'SWH connection missing' if water.waterUseConnections.empty? || water.waterUseConnections.get.plantLoop.empty?
  else
    raise 'Added absent SWH demand' unless model.getWaterUseEquipments.empty?
  end
  original_openings.each do |name, (type, area)|
    opening = model.getSubSurfaceByName(name).get
    raise 'Opening type changed' unless opening.subSurfaceType == type
    if type == 'FixedWindow'
      audit = JSON.parse(model.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit').get)
      factor = audit.fetch('fenestration').fetch('fdwr').fetch('area_factor')
      raise 'Proportional area factor changed' unless (opening.grossArea / area - factor).abs < 0.001
    end
  end
  raise 'Staged proposed file changed' unless source_sha == Digest::SHA256.file('proposed.osm').hexdigest
  translator = OpenStudio::EnergyPlus::ForwardTranslator.new
  translator.translateModel(model)
  raise 'Translation failed' unless translator.errors.empty?
  model.save(OpenStudio::Path.new('reference.osm'), true)
  reloaded = OpenStudio::OSVersion::VersionTranslator.new.loadModel(OpenStudio::Path.new('reference.osm')).get
  raise 'Reload failed' unless NECBExistingModelChecks.geometry_hash(reloaded) == before_geometry
  summary.merge!(geometry_preserved: true, loads_preserved: true, blocks_preserved: true, unconditioned_attic_preserved: true, lighting_schedules_preserved: true, glazing_optics_preserved: true, internal_mass_preserved: true, constant_infiltration: true, swh_test: swh_test, proportional_fdwr: true, save_reload: true, audit: JSON.parse(model.getBuilding.additionalProperties.getFeatureAsString('necb_part8_audit').get))
  File.write('summary.json', JSON.pretty_generate(summary))
  puts 'Part 8 preservation checks passed'
end
