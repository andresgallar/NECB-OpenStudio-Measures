require 'openstudio'
require 'minitest/autorun'
require_relative '../measure'

class StandaloneNECBMeasureTest < Minitest::Test
  def test_missing_custom_weather_preserves_existing_model
    model = OpenStudio::Model::Model.new
    space = OpenStudio::Model::Space.new(model)
    space.setName('Existing input space')
    measure = CreateNECBArchetype.new
    args = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
    custom = args['custom_epw_path'].clone
    custom.setValue(File.join(__dir__, 'missing.epw'))
    args['custom_epw_path'] = custom
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    assert_equal false, measure.run(model, runner, args)
    assert_equal 'Fail', runner.result.value.valueName
    assert_equal 1, model.getSpaces.size
    assert_equal 'Existing input space', model.getSpaces.first.nameString
    assert_match(/matching .ddy and .stat/, runner.result.errors.first.logMessage)
  end

  def test_nrc_arguments_are_exposed
    assert_equal 'Create NECB Prototype Building', CreateNECBArchetype.new.name
    args = CreateNECBArchetype.new.arguments(OpenStudio::Model::Model.new).to_h { |arg| [arg.name, arg] }
    assert_equal 16, args.fetch('building_type').choiceValues.size
    assert_includes args.fetch('necb_template').choiceValues.to_a, 'NECB2020'
    assert_includes args.fetch('hvac_fuel').choiceValues.to_a, 'FuelOilNo2'
    assert_equal 'NECB2020', args.fetch('necb_template').defaultValueAsString
    assert_equal false, args.fetch('sideload').defaultValueAsBool
  end
end
