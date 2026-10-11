# osut

General purpose Ruby utilities for [OpenStudio](https://openstudio.net) [Measures](https://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/) or other OpenStudio [SDK](https://openstudio-sdk-documentation.s3.amazonaws.com/index.html) applications. They provide key inputs to _Measures_ (or gems) such as _Thermal Bridging & Derating_ (or [TBD](https://github.com/rd2/tbd)). Compatible with SDK v3.0.0 (or newer) and OpenStudio Application [releases](https://github.com/openstudiocoalition/OpenStudioApplication/releases) distributed by the [OpenStudio Coalition](https://openstudiocoalition.org).

Add:

```
gem "osut", git: "https://github.com/rd2/osut", branch: "main"
```

... in a v2.1 [bundled](https://bundler.io) _Measure_ development environment "Gemfile" (or instead as a _gemspec_ dependency), and then run:

```
bundle install (or 'bundle update')
```

### Recommended use

As a Ruby module, one can access __osut__ by extending a _Measure_ module or class:

```
require osut

module M
  extend OSut
  ...
end
```
The logger module [oslg](https://github.com/rd2/oslg) is an __osut__ dependency: DEBUG, WARN and/or ERROR messages may be logged by __osut__, usually as a result of invalid method calls or bad OpenStudio input. _Measure_ developers can (optionally) choose to continue logging messages from within an __osut__-extended module or class, e.g.:

```
M.log(OSut::WARN, "Calculated material thickness > 1m")
```
... and then decide (at any given stage in the _Measure_) what to log to the OpenStudio runner, vs an automatically-generated results report (e.g. for code compliance), vs a bug report.

### Features

Most of the __osut__ methods deal with OpenStudio geometry (e.g. add & auto-position a front entrance with sidelights and transoms), or with constructions & materials:

- what is the calculated R-value of a construction?
- are any layered materials in a construction MASSLESS?
- which one of these layered materials is considered the most insulating?

The remainder extract useful _zoning_ information from OpenStudio models, e.g.:  

- is a given space part of a CONDITIONED thermal zone?
- if CONDITIONED or INDIRECTLY UNCONDITIONED, what are its MIN/MAX heating/cooling setpoint temperatures?
- is it instead a _plenum_? or otherwise UNCONDITIONED?

Many of these _zoning_ queries are adapted from [OpenStudio Standards](https://github.com/NREL/openstudio-standards/blob/master/lib/openstudio-standards/standards/Standards.ThermalZone.rb).

Look up the full __osut__ API [here](https://www.rubydoc.info/gems/osut/OSut).

OpenStudio-related questions can be posted on [UnmetHours](https://unmethours.com/questions/).
