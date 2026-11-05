class TM59Metrics
  TYPES = {
    'living_kitchen' => 'A',
    'bedroom' => 'A',
    'living_kitchen_mechanical' => 'C',
    'bedroom_mechanical' => 'C',
    'communal' => 'D'
  }.freeze
  BEDROOMS = ['bedroom', 'bedroom_mechanical'].freeze
  TEMPERATURE_BINS = {
    26 => 'tm_hours_over_twenty_six_c',
    27 => 'tm_hours_over_twenty_seven_c',
    28 => 'tm_hours_over_twenty_eight_c'
  }.freeze
  SEED_WEIGHTS = [1, 0.8, 0.6, 0.5, 0.4, 0.3, 0.2].freeze

  def initialize(edition:, category:, steps_per_hour:, summer_start_day:, outdoor:, clock_offset: 0)
    @current = edition == '2026'
    @steps_per_hour = steps_per_hour
    @steps_per_day = 24 * steps_per_hour
    @summer_days = summer_start_day...(summer_start_day + 153)
    @offset_steps = clock_offset * steps_per_hour
    @allowance = category == 'I' ? 2.0 : 3.0
    @sleep_threshold = @current && category == 'II' ? 27.0 : 26.0
    @running_means = running_means(outdoor)
  end

  def assess(type, temperatures, occupants)
    criterion = TYPES.fetch(type)
    bedroom = BEDROOMS.include?(type)
    night_means = bedroom && @current ? mean_night_temperatures(temperatures) : {}
    occupied_steps = exceedance_steps = b_samples = b_exceedances = 0
    bins = TEMPERATURE_BINS.transform_values { 0 }

    temperatures.each_with_index do |temperature, index|
      day, step = (index + @offset_steps).divmod(@steps_per_day)
      summer = @summer_days.cover?(day)
      hour = step / @steps_per_hour
      trm = @running_means[day % @running_means.size]
      threshold = case criterion
                  when 'A' then adaptive_limit(trm)
                  when 'C' then 26.0
                  when 'D' then 28.0
                  end
      occupied = summer && if @current
                             bedroom || type == 'communal' || (9...22).cover?(hour)
                           else
                             occupants[index].positive?
                           end
      delta = temperature - threshold
      # A difference of 0.5 K rounds to 1 K. Remove floating-point noise at that boundary.
      exceeds = occupied && (criterion == 'A' ? delta.round(9) >= 0.5 : delta.positive?)

      night_mean = night_means[index]
      b_sample = if @current
                   !night_mean.nil?
                 else
                   bedroom && (hour >= 22 || hour < 7)
                 end
      b_exceeds = b_sample && (night_mean || temperature) > @sleep_threshold
      occupied_steps += 1 if occupied
      exceedance_steps += 1 if exceeds
      b_samples += 1 if b_sample
      b_exceedances += 1 if b_exceeds
      bins.each_key { |limit| bins[limit] += 1 if temperature > limit } if summer

      yield(index, trm, threshold, delta, occupied, exceeds, night_mean, b_sample, b_exceeds) if block_given?
    end

    {
      criterion: criterion, occupied_hours: hours(occupied_steps), exceeded_hours: hours(exceedance_steps),
      percentage: occupied_steps.positive? ? 100.0 * exceedance_steps / occupied_steps : nil,
      pass: occupied_steps.positive? ? exceedance_steps * 100 <= occupied_steps * 3 : nil,
      b_value: @current ? b_exceedances : hours(b_exceedances),
      b_limit: @current ? 4 : hours(b_samples) * 0.01,
      b_pass: if bedroom
                @current ? b_exceedances <= 4 : b_exceedances * 100 <= b_samples
              end,
      bins: bins.transform_values { |steps| hours(steps) }
    }
  end

  private

  def hours(steps)
    steps.fdiv(@steps_per_hour)
  end

  def adaptive_limit(trm)
    outdoor_basis = @current ? trm.clamp(10, 30) : trm
    0.33 * outdoor_basis + 18.8 + @allowance
  end

  def running_means(outdoor)
    # Use local assessment days. The rotation affects the January seed only at the year boundary.
    daily_means = outdoor.rotate(-@offset_steps).each_slice(@steps_per_day).map { |day| day.sum / day.size }
    last_april_day = @summer_days.begin - 1
    running_mean = daily_means.first
    daily_means.map.with_index do |outdoor_mean, day|
      if @current && day == last_april_day
        running_mean = SEED_WEIGHTS.each_with_index.sum do |weight, i|
          weight * daily_means[last_april_day - i - 1]
        end / 3.8
      end
      today = running_mean
      running_mean = 0.8 * running_mean + 0.2 * outdoor_mean
      today
    end
  end

  def mean_night_temperatures(temperatures)
    @summer_days.to_h do |day|
      first = day * @steps_per_day + 23 * @steps_per_hour - @offset_steps
      length = 9 * @steps_per_hour
      [first, temperatures.slice(first, length).sum.fdiv(length)]
    end
  end
end
