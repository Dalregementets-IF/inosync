import std / [inotify, intsets, paths, posix, strformat, strutils, tables]
import inosync / [misc, replacers, sc]

const
  watchMaskFile = IN_MODIFY or IN_DELETE_SELF or IN_MOVE_SELF
  watchMaskDir = IN_CREATE or IN_MOVED_TO

type
  WatchPair = object
    ifw: tuple[name: string, wd: FileHandle = -1]
    ofw: tuple[name: string, wd: FileHandle = -1]
    action: RepProc
  WatchDir = object
    wd: FileHandle = -1
    misses: int  ## counter for unwatched files in the directory
  WatchList = object
    fd: cint                     ## inotify
    pairs: seq[WatchPair]
    map: Table[FileHandle, int]  ## wd to pairs index
    incomplete: IntSet           ## incomplete pairs (has unwatched file)
    queue: IntSet                ## pairs that are ready to receive work
    dirs: Table[string, WatchDir]

var errno* {.importc, header: "<errno.h>".}: int

proc parentDir(path: string): string = string(parentDir(Path(path)))

proc newWatchList(): WatchList =
  result.fd = inotify_init()
  if result.fd < 0:
    quit("inotify_init failed, errno: " & $errno, errno)

proc add(wl: var WatchList, infile, outfile: string, action: RepProc) =
  wl.pairs.add WatchPair(ifw: (name: infile, wd: -1),
                         ofw: (name: outfile, wd: -1),
                         action: action)
  wl.incomplete.incl wl.pairs.high
  for fw in [wl.pairs[^1].ifw, wl.pairs[^1].ofw]:
    let dir = parentDir(fw.name)
    if not wl.dirs.hasKey(dir):
      wl.dirs[dir] = WatchDir(wd: -1, misses: 0)
    inc wl.dirs[dir].misses

proc watch(wl: var WatchList) =
  ## Attempt to add inotify watch on any unwatched files and the dirs of any
  ## unwatched files. Any pair that becomes watch complete is added to queue.
  ## Watch on dir is removed if all tracked files inside are watched.
  var completed: IntSet
  for i in wl.incomplete.items:
    for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
      debug "processing watch on incomplete[" & $i & "]: " & $fw.name
      if fw.wd < 0:
        fw.wd = inotify_add_watch(wl.fd, cstring(fw.name), watchMaskFile)
        if fw.wd >= 0:
          debug "new watch: " & $fw.name & ", " & $fw.wd
          wl.map[fw.wd] = i
          dec wl.dirs[parentDir(fw.name)].misses
        else:
          debug "could not watch: " & $fw.name & ", " & $fw.wd & ", errno: " & $errno
      else:
        debug "already watching: " & $fw.name & ", " & $fw.wd
      if wl.pairs[i].ifw.wd >= 0 and wl.pairs[i].ofw.wd >= 0:
        completed.incl i
  wl.queue = union(wl.queue, completed)
  wl.incomplete = difference(wl.incomplete, completed)
  for k in wl.dirs.keys:
    if wl.dirs[k].wd < 0 and wl.dirs[k].misses > 0:
      wl.dirs[k].wd = inotify_add_watch(wl.fd, cstring(k), watchMaskDir)
      if wl.dirs[k].wd == -1:
        quit("inotify_add_watch failed on directory: " & k & ", errno: " & $errno, errno)
      debug "new watch on dir: " & k
    elif wl.dirs[k].wd >= 0 and wl.dirs[k].misses <= 0:
      if inotify_rm_watch(wl.fd, wl.dirs[k].wd) < 0:
        quit("could not remove watch on directory: " & k & ", errno: " & $errno, errno)
      else:
        debug "removed watch on directory: " & k & ", " & $wl.dirs[k].misses
        wl.dirs[k].wd = -1

proc purge(wl: var WatchList, wd: FileHandle) =
  ## Remove `wd` from tracking and start tracking dir events. Use when the file
  ## targeted by `wd` has been deleted or moved.
  var dir: string
  let i = wl.map[wd]
  for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
    if fw.wd == wd:
      fw.wd = -1
      dir = parentDir(fw.name)
      debug "purged: " & $fw.name & ", " & $wd
      break
  wl.map.del wd
  wl.incomplete.incl i
  wl.queue.excl i
  inc wl.dirs[dir].misses
  if wl.dirs[dir].wd < 0:
    wl.dirs[dir].wd = inotify_add_watch(wl.fd, cstring(dir), IN_CREATE)
    if wl.dirs[dir].wd == -1:
      quit("inotify_add_watch failed on directory: " & dir & ", errno: " & $errno, errno)
    debug "added watch on directory: " & dir

proc mute(wl: var WatchList, i: int) =
  ## Remove inotify watch on wd pair `i` temporarily. Does not affect queue.
  for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
    discard inotify_rm_watch(wl.fd, fw.wd)
    debug "muted: " & $fw.name & ", " & $fw.wd
    wl.map.del fw.wd
    fw.wd = -1
    wl.incomplete.excl i

proc unmute(wl: var WatchList, i: int) =
  ## Reinstate inotify watch on muted wd pair `i`. Does not affect queue.
  for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
    fw.wd = inotify_add_watch(wl.fd, cstring(fw.name), watchMaskFile)
    if fw.wd >= 0:
      debug "unmuted: " & $fw.name & ", " & $fw.wd
      wl.map[fw.wd] = i
    else:
      debug "failed to unmute: " & $fw.name & ", " & $fw.wd & ", errno: " & $errno
  if wl.pairs[i].ifw.wd < 0 or wl.pairs[i].ofw.wd < 0:
    wl.incomplete.incl i

proc processQueue(wl: var WatchList) =
  ## Execute registered action for any pair in queue.
  for i in wl.queue:
    wl.mute i
    debug "processQueue: " & $wl.pairs[i].ifw.name & "->" & $wl.pairs[i].ofw.name
    replacer(wl.pairs[i].ifw.name, wl.pairs[i].ofw.name, wl.pairs[i].action)
    wl.unmute i
  clear wl.queue

proc name(wl: WatchList, wd: FileHandle): string =
  ## Get filename associated with `wd`.
  if wl.map.hasKey(wd):
    let i = wl.map[wd]
    for fw in [addr wl.pairs[i].ifw, addr wl.pairs[i].ofw]:
      if fw.wd == wd:
        return $fw.name
  else:
    result = "unknown"

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
  watch wl
  for i in 0..wl.pairs.high:
    # Process toggle-types even if pair is incomplete
    if wl.pairs[i].action in toggles:
      if wl.pairs[i].ofw.wd >= 0:
        wl.queue.incl i
      break
  processQueue wl
  var evs = newSeq[byte](8192)
  while (let n = read(wl.fd, evs[0].addr, 8192); n) > 0:
    for e in inotify_events(evs[0].addr, n):
      if inmask(e[].mask, IN_IGNORED):
        debug e[].mask.toString
        continue
      debug "file: " & wl.name(e[].wd) & ", mask: " & e[].mask.toString
      if e[].wd in wl.map:
        if e[].mask == IN_MODIFY:
          let i = wl.map[e[].wd]
          if i notin wl.incomplete or
              (wl.pairs[i].ofw.wd >= 0 and wl.pairs[i].action in toggles):
            wl.queue.incl i
          processQueue wl
        elif inmask(e[].mask, IN_DELETE_SELF, IN_MOVE_SELF):
          let i = wl.map[e[].wd]
          wl.purge e[].wd
          watch wl
          if wl.pairs[i].ofw.wd >= 0 and wl.pairs[i].action in toggles:
            wl.queue.incl i
          processQueue wl
      elif inmask(e[].mask, IN_CREATE, IN_MOVED_TO, IN_MOVE_SELF):
        watch(wl)
        processQueue wl
    debug $wl

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
