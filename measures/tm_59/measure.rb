require 'openstudio'
require 'csv'
require 'date'
require 'erb'
require 'json'
require 'securerandom'
require_relative 'resources/tm59_metrics'

class TM59Report < OpenStudio::Measure::ReportingMeasure
  def name
    'CIBSE TM59 Overheating Metrics'
  end

  def description
    'Reports selected zone overheating metrics for TM59:2017 (A and B) or TM59:2026 (A, B, C and D without fan uplift).'
  end

  def modeler_description
    'Use one annual EnergyPlus run. In the room fields, copy each zone name from the Thermal Zones tab, or use type= followed by a Space Type name to select matching zones. Assign each assessed zone to one group based on its use and modeled ventilation.'
  end

  def arguments(_model = nil)
    args = OpenStudio::Measure::OSArgumentVector.new
    args << choice_argument('tm59_edition', 'TM59 edition', 'Select the methodology to report.', ['2017', '2026'], '2017')
    args << choice_argument('bs_en_15251_category', 'Adaptive comfort category',
                            'Use II for typical occupants or I for vulnerable occupants.', ['I', 'II'], 'II')

    room_fields.each do |type, (label, help)|
      zones = OpenStudio::Measure::OSArgument.makeStringArgument("#{type}_zones", false)
      zones.setDisplayName(label)
      zones.setDescription("#{help} Enter names from Thermal Zones separated by commas. Quote names that contain commas. Use type= to select by Space Type. Leave empty if unused.")
      args << zones
    end
    args << choice_argument('tm59_2026_clock', '2026 summer clock',
                            'Choose Local if the simulation clock already represents local summer time. Choose GMT for UK weather on GMT to shift assessment times one hour forward.',
                            ['Local', 'GMT'], 'Local')

    legacy = OpenStudio::Measure::OSArgument.makeStringArgument('zone_types', false)
    legacy.setDisplayName('Existing JSON room map (optional)')
    legacy.setDescription('For saved workflows that already use a JSON room map. Leave all room fields empty when using this input.')
    args << legacy
    args
  end

  def outputs
    outs = OpenStudio::Measure::OSOutputVector.new
    ['a', 'c', 'd'].each do |criterion|
      ['hours', 'pct'].each do |metric|
        outs << OpenStudio::Measure::OSOutput.makeDoubleOutput("tm_crit_#{criterion}_#{metric}")
      end
    end
    ['tm_crit_b_hours', 'tm_crit_b_nights'].concat(TM59Metrics::TEMPERATURE_BINS.values).each do |key|
      outs << OpenStudio::Measure::OSOutput.makeDoubleOutput(key)
    end
    ['a', 'b', 'c', 'd'].each do |criterion|
      outs << OpenStudio::Measure::OSOutput.makeStringOutput("tm_crit_#{criterion}_pass")
    end
    outs
  end

  def energyPlusOutputRequests(_runner, _user_arguments) # rubocop:disable Naming/MethodName
    requests = OpenStudio::IdfObjectVector.new
    ['Zone Operative Temperature', 'Site Outdoor Air Drybulb Temperature', 'Zone People Occupant Count'].each do |variable|
      requests << OpenStudio::IdfObject.load("Output:Variable,*,#{variable},Timestep;").get
    end
    requests
  end

  def run(runner, user_arguments)
    super(runner, user_arguments)
    return false unless runner.validateUserArguments(arguments, user_arguments)

    model = runner.lastOpenStudioModel
    sql = runner.lastEnergyPlusSqlFile
    raise ArgumentError, 'The completed OpenStudio model and EnergyPlus SQL file are required.' unless model.is_initialized && sql.is_initialized

    model = model.get
    sql = sql.get
    edition = runner.getStringArgumentValue('tm59_edition', user_arguments)
    current = edition == '2026'
    category = runner.getStringArgumentValue('bs_en_15251_category', user_arguments)
    clock = runner.getStringArgumentValue('tm59_2026_clock', user_arguments)
    offset = current && clock == 'GMT' ? 1 : 0
    fields = room_fields.keys.to_h do |type|
      [type, optional_text(runner, user_arguments, "#{type}_zones")]
    end
    zones = selected_zones(model, optional_text(runner, user_arguments, 'zone_types'), edition, fields)
    runner.registerInitialCondition("Assessing #{zones.size} selected thermal zones under TM59:#{edition}, Category #{category}.")

    steps_per_hour = model.getTimestep.numberOfTimestepsPerHour
    environment = annual_environment(sql)
    timestamps, outdoor = read_series(sql, environment, 'Site Outdoor Air Drybulb Temperature', 'Environment')
    starts = annual_interval_starts(timestamps, steps_per_hour)
    year = starts.first.date.year
    first_summer_day = Date.new(year, 5, 1).yday - 1
    summer_steps = 153 * 24 * steps_per_hour
    metrics = TM59Metrics.new(edition: edition, category: category, steps_per_hour: steps_per_hour,
                              summer_start_day: first_summer_day, outdoor: outdoor, clock_offset: offset)

    # Check every selected zone before opening output files.
    series = zones.map do |zone, type|
      top = aligned_values(sql, environment, 'Zone Operative Temperature', zone, timestamps)
      unless current
        occupants = aligned_values(sql, environment, 'Zone People Occupant Count', zone, timestamps)
        summer = occupants.slice(first_summer_day * 24 * steps_per_hour, summer_steps)
        unless summer.any?(&:positive?)
          raise ArgumentError, "Thermal zone #{zone.inspect} has no occupied timesteps from May through September."
        end
      end
      [zone, type, top, occupants]
    end

    csv_name = 'report_tm59_timesteps.csv'
    points = []
    adaptive_zones = zones.count { |_, type| TM59Metrics::TYPES.fetch(type) == 'A' }
    sample_every = [1, (summer_steps * adaptive_zones / 10_000.0).ceil].max
    adaptive_steps = 0
    labels = starts.map(&:toString)
    rows = CSV.open(csv_name, 'wb', force_quotes: [0]) do |csv|
      csv << ['Zone', 'RoomType', 'SimulationIntervalStart', 'ZoneOperativeTemp_C', 'ZonePeopleOccupantCount',
              'RunningMeanOutdoorTemp_C', 'OccupiedCriterion', 'OccupiedCriterionLimit_C', 'DeltaT_C',
              'OccupiedCriterionApplies', 'OccupiedCriterionExceeds', 'BedroomNightMean_C', 'CriterionBSample', 'CriterionBExceeds']
      series.map do |zone, type, top, occupants|
        criterion = TM59Metrics::TYPES.fetch(type)
        zone_cell = csv_zone_label(zone)
        row = metrics.assess(type, top, occupants) do |index, trm, threshold, delta, occupied, exceeds, night_mean, b_sample, b_exceeds|
          if criterion == 'A' && occupied
            points << [trm.round(3), top[index].round(3)] if (adaptive_steps % sample_every).zero?
            adaptive_steps += 1
          end
          csv << [zone_cell, type, labels[index], top[index], occupants&.fetch(index), trm, criterion, threshold, delta,
                  occupied, exceeds, night_mean, b_sample, b_exceeds]
        end
        row.merge(zone: zone, type: type)
      end
    end

    report_template = File.join(__dir__, 'resources', 'report.html.erb')
    report_nonce = SecureRandom.base64(18)
    html = ERB.new(File.read(report_template, encoding: 'UTF-8')).result(binding)
    File.write('report.html', html, encoding: 'UTF-8')
    register_results(runner, rows, current)
    runner.registerFinalCondition("Reported #{rows.size} thermal zones in report.html and #{csv_name}.")
    true
  rescue ArgumentError => e
    runner.registerError(e.message)
    false
  rescue SystemCallError => e
    runner.registerError("Could not read or write TM59 report files. #{e.message}")
    false
  end

  private

  def csv_zone_label(zone)
    prefix = 'TM59 text: '
    # Keep formula-like names as text even when a spreadsheet drops CSV quoting.
    return "#{prefix}#{zone}" if zone.start_with?(prefix) || zone.match?(/\A(?:[[:space:]\uFEFF]*[=+@＝＋－＠-]|[\t\r\n])/)

    zone
  end

  def choice_argument(name, label, description, choices, default)
    values = OpenStudio::StringVector.new
    choices.each { |choice| values << choice }
    argument = OpenStudio::Measure::OSArgument.makeChoiceArgument(name, values, true)
    argument.setDisplayName(label)
    argument.setDescription(description)
    argument.setDefaultValue(default)
    argument
  end

  def room_fields
    {
      'living_kitchen' => ['Naturally ventilated living rooms, kitchens and home offices', 'Criterion A. Example: Living Room, Kitchen. Home offices apply in 2026.'],
      'bedroom' => ['Naturally ventilated bedrooms', 'Criteria A and B. Example: Bedroom 1, Bedroom 2.'],
      'living_kitchen_mechanical' => ['Mechanical or cooled living rooms, kitchens and home offices (2026)', 'Criterion C. Example: Cooled Lounge.'],
      'bedroom_mechanical' => ['Mechanical or cooled bedrooms (2026)', 'Criteria B and C. Example: type=Mechanical Bedrooms.'],
      'communal' => ['Shared corridors, stairs and lobbies (2026)', 'Criterion D. Example: Shared Corridor.']
    }
  end

  def optional_text(runner, user_arguments, name)
    argument = runner.getOptionalStringArgumentValue(name, user_arguments)
    argument.is_initialized ? argument.get.strip : ''
  end

  def selected_zones(model, selection, edition, fields = {})
    model_zones = model.getThermalZones.sort_by(&:nameString)
    filled_fields = fields.reject { |_, value| value.empty? }
    if selection.empty?
      zones = zones_from_fields(model_zones, filled_fields)
    else
      unless filled_fields.empty?
        raise ArgumentError, 'Use either the room fields or the existing JSON room map. Clear one before running the measure.'
      end

      zones = JSON.parse(selection)
      unless zones.is_a?(Hash) && !zones.empty?
        raise ArgumentError, 'The existing JSON room map must be an object with at least one thermal zone.'
      end
    end

    types = edition == '2026' ? TM59Metrics::TYPES.keys : ['living_kitchen', 'bedroom']
    invalid_types = zones.values.uniq - types
    unless invalid_types.empty?
      raise ArgumentError, "TM59:#{edition} accepts these room groups: #{types.join(', ')}. Check the selected edition and room fields."
    end

    model_names = model_zones.map(&:nameString)
    unknown_names = zones.keys - model_names
    unless unknown_names.empty?
      examples = model_names.first(8).map(&:inspect).join(', ')
      raise ArgumentError, "Unknown thermal zone names: #{unknown_names.map(&:inspect).join(', ')}. Copy names from the Thermal Zones tab. Model zones include: #{examples}."
    end

    zones.sort_by(&:first)
  rescue JSON::ParserError
    raise ArgumentError, 'The existing JSON room map must map thermal zone names to room types. The room fields also accept plain zone names.'
  end

  def zones_from_fields(model_zones, fields)
    if fields.empty?
      raise ArgumentError, 'Enter at least one zone name from the Thermal Zones tab in the applicable room field. Use commas between multiple zones.'
    end

    zones = {}
    fields.each do |type, value|
      label = room_fields.fetch(type).first
      selectors = CSV.parse(value, strip: true, skip_blanks: true).flatten(1)
      if selectors.empty? || selectors.any? { |selector| selector.nil? || selector.empty? }
        raise ArgumentError, "#{label} contains an empty name. Use commas only between names."
      end

      selectors.flat_map { |selector| zone_names_for_selector(model_zones, selector) }.each do |name|
        if zones.key?(name) && zones[name] != type
          previous_label = room_fields.fetch(zones[name]).first
          raise ArgumentError, "Thermal zone #{name.inspect} is assigned to both #{previous_label} and #{label}. Choose one room group per zone."
        end

        zones[name] = type
      end
    rescue CSV::MalformedCSVError
      raise ArgumentError, "Check the list in #{label}. Put double quotes around an entire name that contains a comma."
    end
    zones
  end

  def zone_names_for_selector(model_zones, selector)
    return [selector.delete_prefix('zone=')] unless selector.start_with?('type=')

    name = selector.delete_prefix('type=').strip
    raise ArgumentError, 'Enter a Space Type name after type=.' if name.empty?

    matches = model_zones.filter_map do |zone|
      types = zone.spaces.map do |space|
        space_type = space.spaceType
        space_type.get.nameString if space_type.is_initialized
      end.uniq
      next unless types.include?(name)

      if types.size > 1
        raise ArgumentError, "Zone #{zone.nameString.inspect} has spaces with different Space Types. Review the room use and enter the zone name directly if one criterion applies to the whole zone."
      end

      zone.nameString
    end
    if matches.empty?
      raise ArgumentError, "No thermal zones use Space Type #{name.inspect}. Check the Space Type assignments on the Spaces tab."
    end

    matches
  end

  def annual_environment(sql)
    environments = sql.availableEnvPeriods.select do |environment|
      type = sql.environmentType(environment)
      type.is_initialized && type.get.valueName == 'WeatherRunPeriod'
    end
    raise ArgumentError, 'Run exactly one annual weather period from January 1 to December 31.' unless environments.size == 1

    environments.first
  end

  def read_series(sql, environment, variable, key)
    result = sql.timeSeries(environment, 'Zone Timestep', variable, key)
    unless result.is_initialized
      raise ArgumentError, "Missing zone timestep output #{variable.inspect} for #{key.inspect}. Include this measure before running EnergyPlus and check People assignments for 2017 mode."
    end


    series = result.get
    times = series.dateTimes.to_a
    values = series.values.to_a
    unless !times.empty? && times.size == values.size && values.all?(&:finite?)
      raise ArgumentError, "Invalid time series for #{variable.inspect} and #{key.inspect}."
    end
    [times, values]
  end

  def aligned_values(sql, environment, variable, zone, timestamps)
    times, values = read_series(sql, environment, variable, zone)
    unless times == timestamps
      raise ArgumentError, "#{variable} timestamps for #{zone.inspect} do not align with outdoor temperatures."
    end

    values
  end

  def annual_interval_starts(timestamps, steps_per_hour)
    # EnergyPlus timestamps mark interval ends, including midnight of the following day.
    interval = OpenStudio::Time.new(0, 0, 0, 3600 / steps_per_hour)
    starts = timestamps.map { |timestamp| timestamp - interval }
    day = Date.new(starts.first.date.year, 1, 1)
    steps_per_day = 24 * steps_per_hour
    expected_size = (day.leap? ? 366 : 365) * steps_per_day
    complete = starts.size == expected_size && starts.each_with_index.all? do |start, index|
      day += 1 if index.positive? && (index % steps_per_day).zero?
      date = start.date
      date.year == day.year && date.monthOfYear.value == day.month && date.dayOfMonth == day.day &&
        start.time.totalSeconds == (index % steps_per_day) * interval.totalSeconds
    end
    raise ArgumentError, 'Outdoor temperature data must cover one complete calendar year at a consistent zone timestep.' unless complete

    starts
  end

  def register_results(runner, rows, current)
    ['A', 'C', 'D'].each do |criterion|
      worst = rows.select { |row| row[:criterion] == criterion }.max_by { |row| [row[:percentage], row[:exceeded_hours]] }
      key = "tm_crit_#{criterion.downcase}"
      if worst
        runner.registerValue("#{key}_hours", worst[:exceeded_hours])
        runner.registerValue("#{key}_pct", worst[:percentage])
      end
      runner.registerValue("#{key}_pass", result_label(worst&.fetch(:pass)))
    end
    worst_b = rows.reject { |row| row[:b_pass].nil? }.max_by { |row| row[:b_value] }
    if worst_b
      key = current ? 'tm_crit_b_nights' : 'tm_crit_b_hours'
      runner.registerValue(key, worst_b[:b_value].to_f)
    end
    runner.registerValue('tm_crit_b_pass', result_label(worst_b&.fetch(:b_pass)))
    TM59Metrics::TEMPERATURE_BINS.each do |threshold, output|
      runner.registerValue(output, rows.map { |row| row[:bins][threshold] }.max)
    end
  end

  def result_label(pass)
    return 'N/A' if pass.nil?

    pass ? 'Pass' : 'Fail'
  end
end

TM59Report.new.registerWithApplication
