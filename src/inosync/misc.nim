import std / [bitops, inotify, intsets, tables]

type
  RepProc* = proc (ifn: string, tfile: File): bool {.gcsafe, nimcall.}
  FIndex* = range[0..1]
  Watch* = tuple[path: string, wd: FileHandle = -1]
  WatchPair* = tuple
    ifw: Watch      ## infile
    ofw: Watch      ## outfile
    action: RepProc
  WatchIndexes* = tuple
    pi: int     ## pairs index
    fi: FIndex  ## file index: ifw (0) or ofw (1)

  WatchList* = object
    fd*: cint                              ## inotify
    pairs*: seq[WatchPair]
    map*: Table[string, WatchIndexes]      ## filename to pairs indexes
    wmap*: Table[FileHandle, WatchIndexes] ## wd to pairs indexes
    queue*: IntSet                         ## pairs that are ready for processing
    dirs*: Table[string, FileHandle]

const
  fidx0*: FIndex = 0
  fidx1*: FIndex = 1

proc inmask*[T: SomeInteger](mask: T, events: varargs[T]): bool =
  for y in events:
    if bitand(mask, y) == y:
      return true

proc toString*(event: uint32): string =
  result =
    if inmask(event, IN_ACCESS): "IN_ACCESS"
    elif inmask(event, IN_MODIFY): "IN_MODIFY"
    elif inmask(event, IN_ATTRIB): "IN_ATTRIB"
    elif inmask(event, IN_CLOSE_WRITE): "IN_CLOSE_WRITE"
    elif inmask(event, IN_CLOSE_NOWRITE): "IN_CLOSE_NOWRITE"
    elif inmask(event, IN_OPEN): "IN_OPEN"
    elif inmask(event, IN_MOVED_FROM): "IN_MOVED_FROM"
    elif inmask(event, IN_MOVED_TO): "IN_MOVED_TO"
    elif inmask(event, IN_CREATE): "IN_CREATE"
    elif inmask(event, IN_DELETE): "IN_DELETE"
    elif inmask(event, IN_DELETE_SELF): "IN_DELETE_SELF"
    elif inmask(event, IN_MOVE_SELF): "IN_MOVE_SELF"
    elif inmask(event, IN_ISDIR): "IN_ISDIR"
    elif inmask(event, IN_UNMOUNT): "IN_UNMOUNT"
    elif inmask(event, IN_Q_OVERFLOW): "IN_Q_OVERFLOW"
    elif inmask(event, IN_IGNORED): "IN_IGNORED"
    else: "UNKNOWN[" & $event & "]"
  if inmask(event, IN_ISDIR):
    result.add "|IN_ISDIR"
