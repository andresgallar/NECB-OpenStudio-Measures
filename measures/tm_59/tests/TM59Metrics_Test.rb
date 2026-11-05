require 'csv'
require_relative '../resources/tm59_metrics'
require 'minitest/autorun'

class TM59MetricsTest < Minitest::Test
  MAY_1 = 120
  SEPTEMBER_30 = 272

  def test_2017_adaptive_limits_match_published_bath_data
    reference = CSV.read(File.join(__dir__, 'bath_reference_daily.csv'), headers: true)
    assert_equal(153, reference.size)
    # A constant pre-season outdoor series reproduces the published May 1 seed.
    outdoor = annual_values(reference.first.fetch('RunningMean_C'))
    reference.each_with_index do |row, day|
      outdoor.fill(Float(row.fetch('OutdoorMean_C')), (MAY_1 + day) * 24, 24)
    end

    daily_errors = []
    metrics = build_metrics('2017', outdoor: outdoor)
    result = metrics.assess('bedroom', annual_values(27), annual_values(1)) do |index, running_mean, limit|
      day, hour = index.divmod(24)
      next unless hour.zero? && (MAY_1..SEPTEMBER_30).cover?(day)

      expected = reference[day - MAY_1]
      daily_errors << [(running_mean - Float(expected.fetch('RunningMean_C'))).abs,
                       (limit - Float(expected.fetch('AdaptiveLimit_C'))).abs]
    end
    assert_equal(153, daily_errors.size)
    assert_operator(daily_errors.flatten.max, :<=, 1e-6)
    assert_equal(3_672, result[:occupied_hours])
    assert_equal(1_248, result[:exceeded_hours])
  end

  def test_2017_a_uses_occupied_time_and_rounded_delta
    top = annual_values(20)
    people = annual_values(0)
    start = MAY_1 * 24
    people.fill(0.5, start, 100)
    top[start - 1] = top[start + 100] = 40
    top.fill(28.9, start, 3) # 0.5 K above the 28.4 °C Category II limit.
    top[start + 3] = 28.89
    metrics = build_metrics('2017')
    result = metrics.assess('living_kitchen', top, people)
    assert_equal(100, result[:occupied_hours])
    assert_equal(3, result[:exceeded_hours])
    assert_equal(3, result[:percentage])
    assert_equal(true, result[:pass])
    assert_nil(result[:b_pass])
    top[start + 3] = 29
    assert_equal(false, metrics.assess('living_kitchen', top, people)[:pass])
  end

  def test_2017_b_counts_exact_night_hours_including_subhourly_intervals
    steps = 6
    top = annual_values(26, steps)
    people = annual_values(1, steps)
    4.times { |day| top.fill(27, (day * 24 + 22) * steps, 2 * steps) }
    3.times { |day| top.fill(27, (day + 1) * 24 * steps, 7 * steps) }
    top.fill(27, (4 * 24 + 22) * steps, 23) # 32 hours, 50 minutes total.
    top[(5 * 24 + 7) * steps] = 40
    top[(5 * 24 + 22) * steps - 1] = 40
    metrics = build_metrics('2017', steps: steps)
    pass = metrics.assess('bedroom', top, people)
    assert_in_delta(32 + 50.0 / 60, pass[:b_value])
    assert_in_delta(32.85, pass[:b_limit])
    assert_equal(true, pass[:b_pass])
    top[(4 * 24 + 22) * steps + 23] = 27
    fail_result = metrics.assess('bedroom', top, people)
    assert_equal(33, fail_result[:b_value])
    assert_equal(false, fail_result[:b_pass])
  end

  def test_2026_b_uses_night_start_date_and_mean_across_midnight
    top = annual_values(27)
    3.times { |day| top[(MAY_1 + day) * 24 + 23] = 28 }
    top[(SEPTEMBER_30 + 1) * 24 + 7] = 28
    top[(SEPTEMBER_30 + 1) * 24 + 8] = 40
    top[(MAY_1 - 1) * 24 + 23] = 40
    # An individual hour above 27 °C is balanced by a cooler hour.
    top[(MAY_1 + 3) * 24 + 23] = 30
    top[(MAY_1 + 4) * 24] = 24

    metrics = build_metrics('2026')
    result = metrics.assess('bedroom_mechanical', top, nil)
    assert_equal(4, result[:b_value])
    assert_equal(true, result[:b_pass])
    top[(MAY_1 + 4) * 24] = 25
    assert_equal(5, metrics.assess('bedroom', top, nil)[:b_value])
    assert_equal(false, metrics.assess('bedroom', top, nil)[:b_pass])

    category_i = build_metrics('2026', category: 'I')
    assert_equal(153, category_i.assess('bedroom', annual_values(26.5), nil)[:b_value])
  end

  def test_2026_a_april_seed_and_adaptive_clamps
    outdoor = annual_values(10)
    (1..7).each { |i| outdoor.fill(10 + i, (MAY_1 - 1 - i) * 24, 24) }
    outdoor.fill(20, (MAY_1 - 1) * 24, 24)
    metrics = build_metrics('2026', outdoor: outdoor)
    metrics.assess('bedroom', annual_values(25), nil) do |index, trm, threshold|
      next unless index == MAY_1 * 24

      expected = 0.8 * (10 + 11.6 / 3.8) + 0.2 * 20
      assert_in_delta(expected, trm)
      assert_in_delta(0.33 * expected + 21.8, threshold)
    end
    [[5, 24.1], [35, 30.7]].each do |outdoor_temp, expected|
      metrics = build_metrics('2026', category: 'I', outdoor: annual_values(outdoor_temp))
      metrics.assess('bedroom', annual_values(25), nil) do |index, _, threshold|
        assert_in_delta(expected, threshold) if index == MAY_1 * 24
      end
    end
  end

  def test_2026_c_and_d_fixed_thresholds_and_prescribed_occupancy
    start = MAY_1 * 24
    top = annual_values(26)
    top[start + 8] = top[start + 22] = 40
    top[start + 9] = top[start + 21] = 26.01
    metrics = build_metrics('2026')
    mechanical = metrics.assess('living_kitchen_mechanical', top, nil)
    assert_equal('C', mechanical[:criterion])
    assert_equal(1_989, mechanical[:occupied_hours])
    assert_equal(2, mechanical[:exceeded_hours])

    corridor = metrics.assess('communal', top, nil)
    assert_equal('D', corridor[:criterion])
    assert_equal(3_672, corridor[:occupied_hours])
    assert_equal(2, corridor[:exceeded_hours])
    assert_nil(corridor[:b_pass])
  end

  def test_2026_gmt_clock_shift
    top = annual_values(26)
    top[MAY_1 * 24 + 8] = 28
    top[MAY_1 * 24 + 20] = 28
    top[MAY_1 * 24 + 21] = 40
    top[MAY_1 * 24 + 22] = 40
    metrics = build_metrics('2026', clock_offset: 1)
    assert_equal(2, metrics.assess('living_kitchen_mechanical', top, nil)[:exceeded_hours])
    assert_equal(1, metrics.assess('bedroom', top, nil)[:b_value])
  end

  private

  def build_metrics(edition, category: 'II', steps: 1, outdoor: annual_values(20, steps), clock_offset: 0)
    TM59Metrics.new(edition: edition, category: category, steps_per_hour: steps, summer_start_day: MAY_1,
                    outdoor: outdoor, clock_offset: clock_offset)
  end

  def annual_values(value, steps = 1)
    Array.new(365 * 24 * steps, value.to_f)
  end
end
