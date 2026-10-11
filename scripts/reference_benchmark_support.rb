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

def simulate(model, weather, engine, directory, allowed_warmup_severes: 0)
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
  severe = errors.lines.grep(/\*\*\s*Severe\s*\*\*/)
  warmup = severe.grep(/CheckWarmupConvergence: Loads Initialization/)
  raise 'Annual simulation reported severe/fatal errors.' if errors.match?(/\*\*\s*Fatal\s*\*\*/) || severe.size != warmup.size || warmup.size > allowed_warmup_severes
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


