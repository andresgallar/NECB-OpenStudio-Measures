# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license

require 'openstudio'
require 'csv'
require 'json'
require 'set'
require 'tmpdir'
require_relative '../measure'
require 'minitest/autorun'

class TM59ReportTest < Minitest::Test
  WEATHER = 'USA_CO_Golden-NREL.724666_TMY3.epw'.freeze
  ZONES = { 'Living Room' => 'living_kitchen', 'Bedroom' => 'bedroom',
            'Cooled Bedroom' => 'bedroom_mechanical', 'Corridor' => 'communal' }.freeze

  def test_2017_annual_reporting_workflow
    zones = ZONES.select { |_, type| ['living_kitchen', 'bedroom'].include?(type) }
    run_workflow('2017', zones) do |counts, outputs|
      assert_equal(1_989 * 6, counts['Living Room']['OccupiedCriterionApplies'])
      assert_equal(3_672 * 6, counts['Bedroom']['OccupiedCriterionApplies'])
      assert_equal(0, counts['Living Room']['CriterionBSample'])
      assert_equal(365 * 9 * 6, counts['Bedroom']['CriterionBSample'])
      assert_in_delta(counts['Bedroom']['CriterionBExceeds'].fdiv(6), outputs.fetch('tm_crit_b_hours'))
      assert_equal('N/A', outputs.fetch('tm_crit_c_pass'))
      assert_equal('N/A', outputs.fetch('tm_crit_d_pass'))
      refute(outputs.key?('tm_crit_b_nights'))
    end
  end

  def test_2026_annual_reporting_workflow
    fields = { living_kitchen_zones: 'type=Living Spaces', bedroom_zones: 'Bedroom',
               bedroom_mechanical_zones: 'type=Mechanical Bedrooms', communal_zones: 'Corridor' }
    run_workflow('2026', ZONES, 'GMT', fields) do |counts, outputs|
      assert_equal(1_989 * 6, counts['Living Room']['OccupiedCriterionApplies'])
      assert_equal(3_672 * 6, counts['Corridor']['OccupiedCriterionApplies'])
      assert_equal(0, counts['Living Room']['CriterionBSample'])
      ['Bedroom', 'Cooled Bedroom'].each do |zone|
        assert_equal(153, counts[zone]['CriterionBSample'])
        assert_equal(153, counts[zone][:night_means])
        assert_equal('May-01 22:00:00', counts[zone][:first_night])
        assert_equal('Sep-30 22:00:00', counts[zone][:last_night])
      end
      assert_equal([counts['Bedroom']['CriterionBExceeds'], counts['Cooled Bedroom']['CriterionBExceeds']].max,
                   outputs.fetch('tm_crit_b_nights'))
      assert_in_delta(counts['Cooled Bedroom']['OccupiedCriterionExceeds'].fdiv(6), outputs.fetch('tm_crit_c_hours'))
      assert_in_delta(counts['Corridor']['OccupiedCriterionExceeds'].fdiv(6), outputs.fetch('tm_crit_d_hours'))
      refute(outputs.key?('tm_crit_b_hours'))
    end
  end

  def test_invalid_and_unknown_zone_types
    model = OpenStudio::Model::Model.new
    measure = TM59Report.new
    assert_raises(ArgumentError) { measure.send(:selected_zones, model, 'not json', '2026') }
    assert_raises(ArgumentError) { measure.send(:selected_zones, model, '{"Room":"bedroom"}', '2026') }
    assert_raises(ArgumentError) { measure.send(:selected_zones, model, '{"Room":"communal"}', '2017') }
  end

  def test_room_fields_expand_space_types_and_accept_quoted_zone_names
    model = OpenStudio::Model::Model.new
    bedrooms = OpenStudio::Model::SpaceType.new(model)
    bedrooms.setName('Bedrooms')
    ['Bedroom 1', 'Bedroom 2'].each { |name| add_named_zone(model, name, bedrooms) }
    add_named_zone(model, 'Living, Apt 2')
    fields = { 'bedroom' => 'type=Bedrooms, Bedroom 2', 'living_kitchen' => '"Living, Apt 2"' }
    expected = [['Bedroom 1', 'bedroom'], ['Bedroom 2', 'bedroom'], ['Living, Apt 2', 'living_kitchen']]

    assert_equal(expected, TM59Report.new.send(:selected_zones, model, '', '2026', fields))
  end

  def test_room_fields_reject_overlapping_or_ambiguous_assignments
    model = OpenStudio::Model::Model.new
    bedrooms = OpenStudio::Model::SpaceType.new(model)
    bedrooms.setName('Bedrooms')
    bedroom = add_named_zone(model, 'Bedroom 1', bedrooms)
    measure = TM59Report.new
    fields = { 'bedroom' => 'type=Bedrooms', 'living_kitchen' => 'Bedroom 1' }
    error = assert_raises(ArgumentError) { measure.send(:selected_zones, model, '', '2026', fields) }
    assert_includes(error.message, 'assigned to both')

    OpenStudio::Model::Space.new(model).setThermalZone(bedroom)
    error = assert_raises(ArgumentError) do
      measure.send(:selected_zones, model, '', '2026', { 'bedroom' => 'type=Bedrooms' })
    end
    assert_includes(error.message, 'different Space Types')
  end

  def test_room_fields_require_a_valid_selection_and_edition
    model = OpenStudio::Model::Model.new
    add_named_zone(model, 'Room')
    measure = TM59Report.new
    assert_raises(ArgumentError) { measure.send(:selected_zones, model, '', '2017') }
    assert_raises(ArgumentError) do
      measure.send(:selected_zones, model, '', '2017', { 'communal' => 'Room' })
    end
    assert_raises(ArgumentError) do
      measure.send(:selected_zones, model, '{"Room":"bedroom"}', '2026', { 'bedroom' => 'Room' })
    end
    assert_raises(ArgumentError) do
      measure.send(:selected_zones, model, '', '2026', { 'bedroom' => 'Room,' })
    end
  end

  def test_incomplete_annual_data_is_rejected
    timestamp = OpenStudio::DateTime.new(OpenStudio::Date.new('Jan'.to_MonthOfYear, 1, 2019), OpenStudio::Time.new(0, 1, 0))
    assert_raises(ArgumentError) { TM59Report.new.send(:annual_interval_starts, [timestamp], 1) }
  end

  def test_csv_zone_names_remain_text
    measure = TM59Report.new
    formula_like = ['=1+1', '  +1', '-1', '@SUM(A1)', "\tName", "\rName", "\nName", "\uFEFF＝1", '＋1', '－1', '＠SUM(A1)']
    formula_like.each do |name|
      assert_equal("TM59 text: #{name}", measure.send(:csv_zone_label, name))
    end
    assert_equal('TM59 text: TM59 text: Office', measure.send(:csv_zone_label, 'TM59 text: Office'))
    assert_equal('Living, Kitchen', measure.send(:csv_zone_label, 'Living, Kitchen'))
  end

  def test_report_escapes_zone_names
    zone = '<img src=x onerror="alert(1)">'
    rows = [{ zone: zone, type: 'bedroom', criterion: 'A', occupied_hours: 3672, exceeded_hours: 0,
              percentage: 0, pass: true, b_pass: nil, bins: { 26 => 0, 27 => 0, 28 => 0 } }]
    edition, category, current, offset = '2026', 'II', true, 0
    report_nonce, csv_name, points = 'test-nonce', 'report_tm59_timesteps.csv', []
    template = File.join(__dir__, '..', 'resources', 'report.html.erb')
    html = ERB.new(File.read(template, encoding: 'UTF-8')).result(binding)

    assert_includes(html, '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;')
    refute_includes(html, zone)
  end

  private

  def run_workflow(edition, zones, clock = 'Local', fields = { zone_types: zones.to_json })
    measure_dir = File.expand_path('..', __dir__)
    Dir.mktmpdir('tm59-workflow-') do |dir|
      model = File.join(dir, 'test model.osm')
      build_model(zones).save(OpenStudio::Path.new(model), true)
      workflow = {
        seed_file: model,
        weather_file: File.join(__dir__, WEATHER),
        measure_paths: [File.dirname(measure_dir)],
        steps: [{ measure_dir_name: File.basename(measure_dir),
                  arguments: { tm59_edition: edition, tm59_2026_clock: clock }.merge(fields) }]
      }
      osw = File.join(dir, 'in.osw')
      File.write(osw, JSON.pretty_generate(workflow))
      log = File.join(dir, 'workflow.log')
      ok = system(OpenStudio.getOpenStudioCLI.to_s, 'run', '-w', osw, out: log, err: [:child, :out])
      output = File.join(dir, 'out.osw')
      result = JSON.parse(File.read(output)) if File.file?(output)
      assert(ok && result && result['completed_status'] == 'Success',
             [File.read(log), result && result.dig('steps', 0, 'result')].compact.join("\n"))

      run_dir = File.join(dir, 'run', "000_#{File.basename(measure_dir)}")
      html = File.read(File.join(run_dir, 'report.html'), encoding: 'UTF-8')
      assert_includes(html, "TM59:#{edition}")
      zones.each_key { |name| assert_includes(html, name) }
      assert_includes(html, 'N/A')
      nonce = html[/<script nonce="([^"]+)">/, 1]
      assert_match(/\A[A-Za-z0-9+\/]{24}\z/, nonce.to_s)
      assert_includes(html, "default-src 'none'; script-src 'nonce-#{nonce}'; style-src 'nonce-#{nonce}'")
      assert_includes(html, %(<style nonce="#{nonce}">))
      assert_includes(File.read(File.join(dir, 'run', 'eplusout.err')), '0 Severe Errors')

      collected = File.join(dir, 'reports')
      assert(File.file?(File.join(collected, "#{File.basename(measure_dir)}_report.html")))
      assert(File.file?(File.join(collected, "#{File.basename(measure_dir)}_report_tm59_timesteps.csv")))

      counts = Hash.new { |hash, zone| hash[zone] = Hash.new(0) }
      eligible_points = Set.new
      timestep_csv = File.join(run_dir, 'report_tm59_timesteps.csv')
      assert(File.open(timestep_csv, &:readline).start_with?('"Zone",RoomType,'))
      CSV.foreach(timestep_csv, headers: true) do |row|
        zone = counts[row['Zone']]
        zone[:timesteps] += 1
        ['OccupiedCriterionApplies', 'OccupiedCriterionExceeds', 'CriterionBSample', 'CriterionBExceeds'].each do |key|
          zone[key] += 1 if row[key] == 'true'
        end
        if row['OccupiedCriterion'] == 'A' && row['OccupiedCriterionApplies'] == 'true'
          eligible_points.add([Float(row['RunningMeanOutdoorTemp_C']).round(3), Float(row['ZoneOperativeTemp_C']).round(3)])
        end
        if row['BedroomNightMean_C']
          date = row['SimulationIntervalStart'].split('-', 2).last
          zone[:first_night] = date if zone[:night_means].zero?
          zone[:last_night] = date
          zone[:night_means] += 1
        end
      end

      points = JSON.parse(html[/const points = (\[.*?\]);/, 1])
      assert_includes(html, 'Sampled occupied timesteps assessed under Criterion A from May 1 through September 30')
      assert(points.size.between?(1, 10_000))
      assert(points.all? { |point| eligible_points.include?(point) }, 'The scatter plot includes points outside the Criterion A assessment.')

      assert_equal(zones.keys.sort, counts.keys.sort)
      assert(counts.values.all? { |zone| zone[:timesteps] == 52_560 })
      outputs = result.dig('steps', 0, 'result', 'step_values').to_h do |value|
        [value.fetch('name'), value.fetch('value')]
      end
      a_zones = counts.values_at('Living Room', 'Bedroom')
      worst_a = a_zones.max_by do |zone|
        [zone['OccupiedCriterionExceeds'].fdiv(zone['OccupiedCriterionApplies']), zone['OccupiedCriterionExceeds']]
      end
      assert_in_delta(worst_a['OccupiedCriterionExceeds'].fdiv(6), outputs.fetch('tm_crit_a_hours'))
      assert_in_delta(100.0 * worst_a['OccupiedCriterionExceeds'] / worst_a['OccupiedCriterionApplies'], outputs.fetch('tm_crit_a_pct'))
      yield(counts, outputs)

      python = ENV['TM59_AUDIT_PYTHON']
      if python && !python.empty?
        checker = File.join(__dir__, 'audit_energyplus_sql.py')
        assert(system(python, checker, File.join(dir, 'run', 'eplusout.sql'),
                      File.join(run_dir, 'report_tm59_timesteps.csv'), '--edition', edition,
                      '--clock', clock, '--out-osw', output),
               'Independent EnergyPlus SQL audit failed.')
      end
    end
  end

  def add_named_zone(model, name, space_type = nil)
    zone = OpenStudio::Model::ThermalZone.new(model)
    zone.setName(name)
    space = OpenStudio::Model::Space.new(model)
    space.setThermalZone(zone)
    space.setSpaceType(space_type) if space_type
    zone
  end

  def build_model(zones)
    model = OpenStudio::Model::Model.new
    model.getTimestep.setNumberOfTimestepsPerHour(6)
    simulation = model.getSimulationControl
    simulation.setRunSimulationforSizingPeriods(false)
    simulation.setRunSimulationforWeatherFileRunPeriods(true)
    material = OpenStudio::Model::MasslessOpaqueMaterial.new(model)
    material.setThermalResistance(2.0)
    construction = OpenStudio::Model::Construction.new(model)
    construction.insertLayer(0, material)

    living_schedule = OpenStudio::Model::ScheduleRuleset.new(model)
    living_schedule.defaultDaySchedule.addValue(OpenStudio::Time.new(0, 9, 0), 0.0)
    living_schedule.defaultDaySchedule.addValue(OpenStudio::Time.new(0, 22, 0), 1.0)
    living_schedule.defaultDaySchedule.addValue(OpenStudio::Time.new(1, 0, 0), 0.0)
    activity = OpenStudio::Model::ScheduleConstant.new(model)
    activity.setValue(110.0)

    space_types = { 'living_kitchen' => 'Living Spaces', 'bedroom_mechanical' => 'Mechanical Bedrooms' }.transform_values do |name|
      space_type = OpenStudio::Model::SpaceType.new(model)
      space_type.setName(name)
      space_type
    end

    zones.each_with_index do |(name, type), index|
      polygon = OpenStudio::Point3dVector.new
      x = 20.0 * index
      [[x, 0], [x, 5], [x + 5, 5], [x + 5, 0]].each { |px, py| polygon << OpenStudio::Point3d.new(px, py, 0) }
      space = OpenStudio::Model::Space.fromFloorPrint(polygon, 3.0, model).get
      space.setName("#{name} space")
      space.setSpaceType(space_types.fetch(type)) if space_types.key?(type)
      space.surfaces.each { |surface| surface.setConstruction(construction) }
      zone = OpenStudio::Model::ThermalZone.new(model)
      zone.setName(name)
      space.setThermalZone(zone)

      next if type == 'communal'

      definition = OpenStudio::Model::PeopleDefinition.new(model)
      definition.setNumberofPeople(1.0)
      people = OpenStudio::Model::People.new(definition)
      people.setSpace(space)
      people.setNumberofPeopleSchedule(type == 'living_kitchen' ? living_schedule : model.alwaysOnDiscreteSchedule)
      people.setActivityLevelSchedule(activity)
    end
    model
  end
end
