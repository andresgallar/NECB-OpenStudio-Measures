# oslg

A logger, initially for _picky_ [OpenStudio](https://openstudio.net) [Measure](https://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/) developers who wish to select what gets logged to which target (e.g. OpenStudio _runner_ vs custom JSON files). Yet __oslg__ has no OpenStudio dependency; it can be integrated within any other environment. Just add:

```
gem "oslg", git: "https://github.com/rd2/oslg", branch: "main"
```

... in a v2.x [bundled](https://bundler.io) development environment "Gemfile" (or instead as a _gemspec_ dependency), and then run:

```
bundle install (or 'bundle update')
```

### OpenStudio & EnergyPlus

In most cases, critical (and many non-critical) OpenStudio anomalies will be caught by EnergyPlus at the start of a simulation. Standalone applications (e.g. _Apply Measures Now_) or [SDK](https://openstudio-sdk-documentation.s3.amazonaws.com/index.html) based iterative solutions can't rely on EnergyPlus to catch such errors - and somehow warn users of potentially invalid results. __oslg__ provides developers a means to log warnings, as well as non-fatal & fatal errors, that may eventually put OpenStudio's (or EnergyPlus') internal processes at risk. Developers are free to decide how to harness __oslg__ as they see fit, e.g. output logged WARNING messages to the OpenStudio _runner_, while writing out DEBUG messages to a bug report file.

### Recommended use

As a Ruby module, one can access __oslg__ by _extending_ a Measure module or class:

```
module M
  extend OSlg
  ...
end
```

Ordered __oslg__ levels (or CONSTANTS), from benign to severe:

```
DEBUG
INFO
WARN
ERROR
FATAL
```

DEBUG messages aren't benign at all, but are certainly less informative for the typical Measure user.

Initially, __oslg__ sets 2 _global_ internal attributes: `level` (INFO) and `status` (< DEBUG). The `level` attribute is a user-set threshold below which less severe logs (e.g. DEBUG) are ignored. For instance, if `level` were _reset_ to DEBUG (e.g. `M.reset(M::DEBUG)`), then all DEBUG messages would also be logged. The `status` attribute is reset with each new log entry when the latter's log level is more severe than its predecessors (e.g. `status == M::FATAL` if there is a single log entry registered as FATAL). To check the curent __oslg__ `status` (true or false):  

```
M.debug?
M.warn?
M.error?
M.fatal?
```

It's sometimes not a bad idea to rely on a _clean_ slate (e.g. within RSpecs). The following purges all previous logs and resets `level` (INFO) and `status` (< DEBUG) - use with caution in production code!

```
M.clean!
```

EnergyPlus will run with e.g. out-of-range material or fluid properties, while logging ERROR messages in the process. It remains up to users to decide what to do with simulation results. We recommend something similar with __oslg__. For instance, we suggest logging as __FATAL__ any error that should halt Measure processes and prevent OpenStudio from launching an EnergyPlus simulation. This could be missing or poorly formatted files.

```
M.log(M::FATAL, "Missing input JSON file")
```

Consider logging non-fatal __ERROR__ messages when encountering invalid OpenStudio file entries, i.e. well-defined, yet invalid vis-à-vis EnergyPlus limitations. The invalid object could be simply ignored, while the Measure pursues its (otherwise valid) calculations ... with OpenStudio ultimately launching an EnergyPlus simulation. If a simulation indeed ran (ultimately a go/no-go decision made by the EnergyPlus simulation engine), it would be up to users to decide if simulation results were valid or useful, given the context - maybe based on __oslg__ logged messages. In short, non-fatal ERROR logs should ideally point to bad input (that users can fix).

```
M.log(M::ERROR, "Measure won't process MASSLESS materials")
```

A __WARNING__ could be triggered from inherit limitations of the underlying Measure scope or methodology (something users may have little knowledge of beforehand). For instance, surfaces the size of dinner plates are often artifacts of poor 3D modelling. It's usually not a good idea to have such small surfaces in an OpenStudio model, but neither OpenStudio nor EnergyPlus will necessarily warn users of such occurrences. It's up to users to decide on the suitable course of action.

```
M.log(M::WARN, "Surface area < 100cm2")
```

There's also the possibility of logging __INFO__-rmative messages for users, e.g. the final state of a Measure variable before exiting.

```
M.log(M::INFO, "Envelope compliant to prescriptive code requirements")
```

Finally, a number of sanity checks are likely warranted to ensure Ruby doesn't crash (e.g., invalid access to uninitialized variables), especially for lower-level functions. We suggest implementing safe fallbacks when this occurs, but __DEBUG__ errors could nonetheless be logged to signal buggy code.

```
M.log(M::DEBUG, "Hash? expecting Array (method)")
```

All log entries are stored in a single Ruby _Array_, with each individual log entry as a Ruby _Hash_ with 2 _keys_ ```:level``` and ```:message```, e.g.:

```
M.logs.each do |log|
  puts "Uh-oh: #{log[:message]}" if log[:level] > M::INFO
end
```

These logs can be first _mapped_ to other structures (then edited), depending on output targets.

### Preset log templates

Typically, developers would first catch bad input, log an error message and possibly exit by returning an object (e.g. __false__, __nil__), such as:  

```
unless var.is_a?(Array)
  M.log(M::DEBUG, "#{var.class}? expecting Array (method)")
  return false
end
```

The following are __oslg__ one-liner methods that _log & return_ in one go. These are for some of the most common checks OpenStudio SDK Ruby developers are likely to need. The methods require _valid_ arguments for __oslg__ to actually log. Although often expecting either strings or integers as arguments, the methods will try to convert other types to strings (e.g. classes, numbers, even entire arrays) or integers if possible.

---

__invalid__: for logging e.g. nilled objects or out-of-scope variables:

```
return M.invalid("area", "sum", 0, M::FATAL, false) if area > 1000000
```

This logs a FATAL error message informing users that an out-of-scope argument, 'area', was caught while running method 'sum', and then exits by returning _false_. The logged message would be:

```
"Invalid 'area' (sum)"
```

The 3rd parameter (e.g. _0_) is ignored unless `> 0` - a useful option when asserting method arguments:

```
def sum(areas, units)
  return M.invalid("areas", "sum", 1) unless areas.respond_to?(:to_f)
  return M.invalid("units", "sum", 2) unless units.respond_to?(:to_s)
  ...
end
```

... would generate the following if both `areas` and `units` arguments were, for instance, _nilled_:
```
"Invalid 'areas' arg #1 (sum)"
"Invalid 'units' arg #2 (sum)"
```

The first 2 __invalid__ method parameters (faulty object ID, calling method ID) are required. The remaining 3 parameters are optional; in such cases, __invalid__ `level` defaults to DEBUG, and __invalid__ returns _nil_.

---

__mismatch__: for logging incompatible instances vs classes:

```
return M.mismatch("area", area, Float, "sum") unless area.is_a?(Numeric)
```

If 'area' were for example a _String_, __mismatch__ would generate the following DEBUG log message (before returning _nil_):

```
"'area' String? expecting Float (sum)"
```

These 4 __mismatch__ parameters are required (an object ID, a valid Ruby object, the mismatched Ruby class, and the calling method ID). As a safeguard, __oslg__ will NOT log a _mismatch_ if the object is an actual instance of the class. As with __invalid__, there are 2 optional _terminal_ parameters (e.g. `M::FATAL`, `false`).

---

__hashkey__: for logging missing _Hash_ keys:

```
return M.hashkey("floor area", floor, :area, "sum") unless floor.key?(:area)
```

If the _Hash_ `floor` does not hold `:area` as one of its keys, then __hashkey__ would generate the following DEBUG log message (before returning _nil_):

```
"Missing 'area' key in 'floor' Hash (sum)"
```

Similar to __mismatch__, the method __hashkey__ requires 4 parameters (a _Hash_ ID, a valid Ruby _Hash_, the missing _key_, and the calling method ID). There are also 2 optional _terminal_ parameters (e.g. `M::FATAL`, `false`).

---

__empty__: for logging empty _Enumerable_ (e.g. _Array_, _Hash_) instances or uninitialized _Boost_ optionals (e.g. an uninitialized _ThermalZone_ object of an _OpenStudio Space_):

```
return M.empty("zone", "conditioned?", M::FATAL, false) if space.thermalZone.empty?
```

An empty (i.e. uninitialized) `thermalZone` would generate the following FATAL error log message (before returning _false_):

```
"Empty 'zone' (conditioned?)"
```

Again, the first 2 parameters are required; the last 2 are optional.

---

__zero__: for logging zero'ed (or nearly-zero'ed) values:

```
M.zero("floor area", "sum", M::FATAL, false) if floor[:area].abs < TOL
```
... generating the following FATAL error log message (before returning _false_):

```
"Zero 'floor area' (sum)"
```

And again, the first 2 parameters are required; the last 2 are optional.

---

__negative__: for logging negative (< 0) values:

```
M.negative("floor area", "sum", M::FATAL, false) if floor[:area] < 0
```
... generating this FATAL log message (before returning _false_):

```
"Negative 'floor area' (sum)"
```

You guessed it: the first 2 parameters are required; the last 2 as optionals.

---

Look up the full __oslg__ API [here](https://www.rubydoc.info/gems/oslg).
