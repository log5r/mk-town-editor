# Production launcher

`./start.sh` builds and runs `MKTownEditor` using Swift Package Manager's
`release` configuration. Builds are incremental by default.
`./start.sh rebuild` runs `swift package clean` before building and launching;
this also removes cached debug build products for this package.

The launcher switches to its own directory so it can be invoked from another
working directory. A failed clean stops execution. `exec swift run` preserves
the command's exit status and allows terminal signals to reach it directly.

Run `python3 Tools/test_start.py` to verify command order, Release selection,
working directories containing spaces, argument validation, and failure handling
using a stub Swift command. Run `swift test` for the application unit tests.
