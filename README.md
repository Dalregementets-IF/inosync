# inosync

Inosync takes one or more sets of arguments each consisting of an `action` and a
`src`/`dest` file pair. Data is syncronized according to `action` into `dest`
dependent on `src`, writing into `dest` between the first occurence of lines
matching `<!-- INOSYNC BEGIN -->` and `<!-- INOSYNC END -->`. There are two
classes of actions: toggle-type actions will add or remove information depending
on if `src` exists, while other actions only trigger when `src` exists.

## Usage

A list of all available actions and a short description of each is available
through `--list`.

```
$ inosync --list
available actions:
  kallelse     toggle promobox with link to /kallelse.pdf
  styrelse     create table rows from tsv file
  tavlingar    create rows of divs from tsv file
  warn         toggle warning alert with text from file
  info         toggle info alert with text from file
  markdown     create html from markdown file
  plain        get plain text from file
```

Inosync takes one or more arguments as `<action>,<src>,<dest>`.

```
$ inosync markdown,path1,path2 markdown,path3,path4 plain,path5,path6
```

## All Options

```
inosync [optional-params] [action,src,dest ...]

Options(opt-arg sep :|=|spc):
  -h, --help                  print this cligen-erated help
  --help-syntax               advanced: prepend,plurals,..
  --version      bool  false  print version
  -l, --list     bool  false  list available actions
```
