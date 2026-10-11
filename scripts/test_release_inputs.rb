# Focused checks for the release's input/mapping changes. No sizing or annual
# simulation matrix. Clear the OpenStudio CLI's script flags for Minitest.
ARGV.clear
require_relative '../measures/create_necb_reference/tests/test_space_type_mapping'
require_relative '../measures/create_necb_reference/tests/test_measure'
require_relative '../measures/create_necb_archetype/tests/test_measure'
