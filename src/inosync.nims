import std / [os]

const
  patched = "patchedinotify.nim"
  patchedPath = "src/inosync" / patched
block:
  let (stdlib, e) = gorgeEx("nim dump 2>&1|grep posix")
  if e != 0:
    raise newException(Defect, "failed to determine location of posix module")
  cpFile(stdlib / "inotify.nim", patchedPath)
block:
  {.hint: "Applying patch.."}
  let (msg, e) = gorgeEx("patch -d inosync -p1 -i ../../inotify.patch")
  if e != 0:
    raise newException(Defect, "failed to patch: " & msg)

{.hint: "Patching inotify.nim to fix `InotifyEvent.name`: char -> cstring "}
patchFile("stdlib", "inotify", "inosync" / patched)
