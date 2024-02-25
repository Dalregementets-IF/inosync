# Package
version       = "1.0.1"
author        = "Tobias Dély"
description   = "monitor pairs of in/out files and sync data according to given action"
license       = "MIT"
bin           = @["inosync"]

# Dependencies
requires "nim >= 2.0.2"
requires "seccomp >= 0.2.1"

# Tasks
task debug, "Create a debug build":
  exec "nim c --lineDir:on --debuginfo:on --debugger:native -d:useMalloc -d:noseccomp inosync.nim"

task futhark, "Build/rebuild futhark wrappers":
  exec "nim c -d:useFuthark -d:futharkRebuild --maxLoopIterationsVM:50000000 --cc:clang inosync.nim"

task build, "Create a development build":
  exec "nim c -d:noseccomp inosync.nim"

task release, "Build for release":
  exec "nim c -d:release -d:danger --opt:speed -d:useMalloc inosync.nim"
