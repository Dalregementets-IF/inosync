import std / [inotify, intsets, paths, posix, strformat, strutils, tables]
import inosync / [misc, replacers, sc]

type
  FIndex = range[0..1]
  Watch = tuple[path: string, wd: FileHandle = -1]
  WatchPair = tuple
    ifw: Watch      ## infile
    ofw: Watch      ## outfile
    action: RepProc
  WatchIndexes = tuple
    pi: int     ## pairs index
    fi: FIndex  ## file index: ifw (0) or ofw (1)

  WatchList = object
    fd: cint                              ## inotify
    pairs: seq[WatchPair]
    map: Table[string, WatchIndexes]      ## filename to pairs indexes
    wmap: Table[FileHandle, WatchIndexes] ## wd to pairs indexes
    queue: IntSet                         ## pairs that are ready for processing
    dirs: Table[string, FileHandle]

const
  fidx0: FIndex = 0
  fidx1: FIndex = 1
  watchMaskFile = IN_MODIFY or IN_DELETE_SELF or IN_MOVE_SELF
  watchMaskDir = IN_CREATE or IN_MOVED_TO

var errno* {.importc, header: "<errno.h>".}: int

proc `$`(wl: WatchList): string =
  result = """
(
  fd: $1, queue: $2
  dirs: $3
  map: {
""" % [$wl.fd, $wl.queue, $wl.dirs]
  for k, v in wl.map.pairs:
    result.add "    " & k & ": " & $v & "\n"
  result.add "  }\n  wmap: {\n"
  for k, v in wl.wmap.pairs:
    result.add "    " & $k & ": " & $v & "\n"
  result.add "  }\n  pairs: {\n"
  for pair in wl.pairs:
    result.add "    ifw::" & $pair.ifw & " -> ofw::" & $pair.ofw & "\n"
  result.add "  }\n)"

proc parentDir(path: string): string = string(parentDir(Path(path)))
proc extractFilename(path: string): string = string(extractFilename(Path(path)))

proc getName*(evt: ptr InotifyEvent): string = $cast[cstring](evt.name.addr)

proc newWatchList(): WatchList =
  result.fd = inotify_init()
  if result.fd < 0:
    quit("inotify_init failed, errno: " & $errno, errno)

proc newWatchPair(infile, outfile: string, action: RepProc): WatchPair =
  (ifw: (path: infile, wd: -1),
   ofw: (path: outfile, wd: -1),
   action: action)

proc add(wl: var WatchList, infile, outfile: string, action: RepProc) =
  wl.pairs.add newWatchPair(infile, outfile, action)
  let
    ifshort = extractFilename(infile)
    ofshort = extractFilename(outfile)
  wl.map[ifshort] = (pi: wl.pairs.high, fi: fidx0)
  wl.map[ofshort] = (pi: wl.pairs.high, fi: fidx1)
  for fw in [wl.pairs[^1].ifw, wl.pairs[^1].ofw]:
    let dir = parentDir(fw.path)
    if not wl.dirs.hasKey(dir):
      wl.dirs[dir] = -1

proc watch(wl: var WatchList, name: string) =
  ## Attempt to add inotify watch on `name`.
  let (pi, fi) = wl.map[name]
  let fw =
    if fi == fidx0:
      addr wl.pairs[pi][fidx0]
    else:
      addr wl.pairs[pi][fidx1]
  debug "processing watch on " & $fw[].path
  if fw[].wd < 0:
    fw[].wd = inotify_add_watch(wl.fd, cstring(fw[].path), watchMaskFile)
    if fw[].wd >= 0:
      wl.wmap[fw[].wd] = (pi, fi)
      debug "new watch: " & $fw[].path & ", " & $fw[].wd
    else:
      debug "could not watch: " & $fw[].path & ", " & $fw[].wd & ", errno: " & $errno
  else:
    debug "already watching: " & $fw[].path & ", " & $fw[].wd

proc purge(wl: var WatchList, name: string) =
  ## Remove `name` from tracking. Use when `name` has been deleted or moved.
  let (pi, fi) = wl.map[name]
  let fw =
    if fi == fidx0:
      addr wl.pairs[pi][fidx0]
    else:
      addr wl.pairs[pi][fidx1]
  discard inotify_rm_watch(wl.fd, fw[].wd)
  debug "purged: " & $fw[].path & ", " & $fw[].wd
  wl.wmap.del fw[].wd
  fw[].wd = -1
  wl.queue.excl pi

proc mute(wl: var WatchList, i: int) =
  ## Remove inotify watch on wd pair `i` ofw temporarily. Does not affect queue.
  let fw = addr wl.pairs[i].ofw
  discard inotify_rm_watch(wl.fd, fw.wd)
  debug "muted: " & $fw[].path & ", " & $fw[].wd
  wl.wmap.del fw[].wd
  fw.wd = -1

proc unmute(wl: var WatchList, i: int) =
  ## Reinstate inotify watch on muted wd pair `i` ofw. Does not affect queue.
  let fw = addr wl.pairs[i].ofw
  fw[].wd = inotify_add_watch(wl.fd, cstring(fw[].path), watchMaskFile)
  if fw[].wd >= 0:
    let (pi, fi) = wl.map[extractFilename(fw[].path)]
    wl.wmap[fw[].wd] = (pi, fi)
    debug "unmuted: " & $fw[].path & ", " & $fw[].wd
  else:
    debug "failed to unmute: " & $fw[].path & ", " & $fw[].wd & ", errno: " & $errno

proc processQueue(wl: var WatchList) =
  ## Execute registered action for any pair in queue.
  for i in wl.queue:
    wl.mute i
    debug "processQueue: " & $wl.pairs[i].ifw.path & "->" & $wl.pairs[i].ofw.path
    replacer(wl.pairs[i].ifw.path, wl.pairs[i].ofw.path, wl.pairs[i].action)
    wl.unmute i
  clear wl.queue

proc run(list = false; args: seq[string]): int =
  if list:
    var x: seq[string]
    for k, v in actions.pairs:
      x.add fmt"{k:<12} {v[1]}"
    echo "available actions:\n  " & x.join("\n  ")
    return

  if args.len < 1:
    echo "nothing to do"
    return

  var wl = newWatchList()
  block process_args:
    var argsets: seq[(string, string, RepProc)]
    for arg in args:
      let x = arg.split(',')
      if x.len != 3:
        echo "arguments must be in format '<action>,<path>,<path>' with exactly two ','"
        return 100
      let act = getAction(x[0])
      argsets.add (x[1], x[2], act)
    for p in argsets.items:
      debug "adding: " & $p[0] & "->" & $p[1]
      wl.add(p[0], p[1], p[2])
    debug $wl

  lockdown()

  for k in wl.dirs.keys:
    wl.dirs[k] = inotify_add_watch(wl.fd, cstring(k), watchMaskDir)
    if wl.dirs[k] >= 0:
      debug "new watch: " & k & ", " & $wl.dirs[k]
    else:
      stderr.writeLine "could not watch: " & $k & ", " & $wl.dirs[k]
      return errno

  for name in wl.map.keys:
    wl.watch(name)

  for i in 0..wl.pairs.high:
    if (wl.pairs[i].ifw.wd >= 0 and wl.pairs[i].ofw.wd >= 0) or
        (wl.pairs[i].ofw.wd >= 0 and wl.pairs[i].action in toggles):
      wl.queue.incl i
  processQueue wl

  debug $wl

  var evs = newSeq[byte](8192)
  while (let n = read(wl.fd, evs[0].addr, 8192); n) > 0:
    var printList: bool
    for e in inotify_events(evs[0].addr, n):
      let evname = e.getName
      if inmask(e[].mask, IN_IGNORED) or evname[^1] == '~' or evname[0] == '.':
        continue
      debug "file: $1[$2]<cookie:$3>, event: $4" % [evname, $e[].wd, $e[].cookie, e[].mask.toString]
      if wl.wmap.hasKey(e[].wd) or wl.map.hasKey(evname):
        printList = true
        var pi, fi: int
        if wl.wmap.hasKey(e[].wd):
          debug "using wmap"
          (pi, fi) = wl.wmap[e[].wd]
        else:
          debug "using map"
          (pi, fi) = wl.map[evname]

        let
          fw =
            if fi == fidx0:
              addr wl.pairs[pi][fidx0]
            else:
              addr wl.pairs[pi][fidx1]
          fname = extractFilename(fw[].path)

        if inmask(e[].mask, IN_MODIFY):
          if (wl.pairs[pi].ifw.wd >= 0 and wl.pairs[pi].ofw.wd >= 0) or
              (wl.pairs[pi].ofw.wd >= 0 and wl.pairs[pi].action in toggles):
            wl.queue.incl pi
        elif inmask(e[].mask, IN_CREATE, IN_MOVED_TO):
          if fw[].wd >= 0:
            wl.purge(fname)
          wl.watch(fname)
          if (wl.pairs[pi].ifw.wd >= 0 and wl.pairs[pi].ofw.wd >= 0) or
              (wl.pairs[pi].ofw.wd >= 0 and wl.pairs[pi].action in toggles):
            wl.queue.incl pi
        elif inmask(e[].mask, IN_DELETE_SELF, IN_MOVE_SELF):
          wl.purge(fname)
          if wl.pairs[pi].ofw.wd >= 0 and wl.pairs[pi].action in toggles:
            wl.queue.incl pi
    if printList:
      debug $wl
    processQueue wl

when isMainModule:
  import cligen

  const
    progName = "inosync"
    progUse = progName & " [optional-params] [action,src,dest ...]"
    progVer {.strdefine.} = strip(gorge("git tag -l --sort=version:refname '*.*.*' | tail -n1"))
    gitHash {.strdefine.} = strip(gorge("git log -n 1 --format=%H"))
    gitDirty {.strdefine.} = gorge("git status --porcelain --untracked-files=no")

  let dirty =
    if gitDirty != "":
      " (dirty)\n" & gitDirty
    else:
      ""
  clCfg.version = """$1 $2
Compiled at $3 $4
Written by Tobias Dély

git hash: $5$6""" % [progName, progVer, CompileDate, CompileTime, gitHash, dirty]

  dispatchCf run, cmdName = progName, cf = clCfg, noHdr = true,
    usage = progUse & "\n\nOptions(opt-arg sep :|=|spc):\n$options",
    help = {
      "list": "list available actions"
    }
