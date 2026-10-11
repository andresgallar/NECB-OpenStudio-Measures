Place JSON files here to override the bundled standards database, then enable
the measure's sideload argument. This is the same tables/formulas mechanism
used by the original NRC measure; constants are also supported.

Each file must contain an object with one or more of `tables`, `formulas`, or
`constants`. Entries replace the corresponding named database entries.
Keep sideload disabled to use the pinned public standards unchanged.
