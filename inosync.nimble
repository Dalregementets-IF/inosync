# Package
version       = "1.3.0"
author        = "Tobias Dély"
description   = "monitor pairs of in/out files and sync data according to given action"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["inosync"]

# Dependencies
requires "nim >= 2.0.2"
requires "seccomp >= 0.2.1"
requires "nmark >= 0.1.10"
requires "cligen >= 1.7.0 & < 2.0.0"

# Tasks
task debug, "Create a debug build":
  exec "mkdir -p bin"
  exec "nim c --lineDir:on --debuginfo:on --debugger:native -d:useMalloc -d:noseccomp -o:bin/inosync src/inosync.nim"

task futhark, "Build/rebuild futhark wrappers":
  exec "mkdir -p bin"
  exec "nim c -d:useFuthark -d:futharkRebuild --maxLoopIterationsVM:50000000 --cc:clang -o:bin/inosync src/inosync.nim"

task build, "Create a development build":
  exec "mkdir -p bin"
  exec "nim c -d:noseccomp -o:bin/inosync src/inosync.nim"

task release, "Build for release":
  exec "mkdir -p bin"
  exec "nim c -d:release -d:danger --opt:speed -d:useMalloc -o:bin/inosync src/inosync.nim"
