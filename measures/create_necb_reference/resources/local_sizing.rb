# Local execution fixes for OpenStudio 3.11 / EnergyPlus 25.2 and Windows.
# The upstream standards code and NECB calculations remain unmodified.
module LocalNECBSizing
  def model_run_simulation_and_log_errors(model, run_dir = "#{Dir.pwd}/Run")
    # Early autozoning uses ideal loads without plant loops. EnergyPlus 25.2
    # rejects plant sizing + HVAC sizing when there is no Sizing:Plant object.
    model.getSimulationControl.setDoPlantSizingCalculation(false) if model.getPlantLoops.empty?
    # Windows cannot overwrite an SQL file while any sizing-stage reference
    # still holds it. Give each simulation its own output directory.
    @local_sizing_counter = (@local_sizing_counter || 0) + 1
    local_dir = File.join(@local_sizing_root, format('sizing_%02d_%s', @local_sizing_counter, File.basename(run_dir)))
    super(model, local_dir)
  end
end
