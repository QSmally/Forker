
# Forker

Multitool (and libmultitool) for POSIX process hosting.

## Description

Forker is like [process-compose](https://github.com/F1bonacc1/process-compose),
[supervisord](https://github.com/Supervisor/supervisor)
and [launchd](https://github.com/apple-oss-distributions/launchd), but is meant to be
foreground-running, scriptable, and not requiring a configuration file at all.
Forker wants to reduce the every-day `$!`, `wait`ing and mass `kill`ing you'd have to do yourself.
Forker aims to be the swiss army knife of forking to different processes.

<!-- And don't even get Forker started on restarting (failed) processes. -->

```bash
$ zig build
$ zig-out/bin/forker --help

    Forker CLI
    forker [option ...] [definition [setting ...] ...]

process definition
    --always expr             execv path
    --once expr               execv path
    --on signal internal:fn   internal func
    --on signal expr          execv path

internal functions
    internal:restart          restart all processes

process setting
    ...

options
    --idle
    --quiet
    --doptions
    --help

```

A few examples to demonstrate the goal of Forker:

```bash
$ forker \
    --quiet \
    --once "path/to/exec" \
    --once "path/to/exec2"
```

```bash
$ forker \
    --always "path/to/exec" \
    --always "path/to/exec2"
```

```bash
$ forker \
    --always "path/to/exec" \
    --always "path/to/exec2" \
    --on HUP internal:restart
```

```bash
$ forker \
    --idle \
    --on USR1 "path/to/exec"
```

**(From here on is vaporware for now!)** Forker has a vision.

```bash
$ forker \
    --once "path/to/exec" --retry --max 5 \
    --once "path/to/exec2" --retry --max 3 --backoff 3s
```

```bash
$ generate_stdin | forker \
    --always "path/to/exec" \
    --once "path/to/exec2" --feed-stdin \
    --every 30s "path/to/exec3" --exclusive mylock1 \
    --on USR1 "path/to/exec4" --exclusive mylock1 \
    --on USR2 "path/to/exec5" \
    --on HUP internal:restart \
```

```bash
$ forker \
    --always "path/to/exec" \
    --always "path/to/exec2" --tag foo \
    --always "path/to/exec3" --tag foo \
    --on USR1 internal:restart \
    --on USR2 internal:restart:foo
```

```bash
$ generate_jobs | forker --parallelise "script/to/exec"
```

## Installation

`zig fetch --save git+https://github.com/QSmally/Forker`

```zig
const libforker = b.dependency("forker", .{ ... });
exec.root_module.addImport("forker", libforker.module("forker"));
// ...
```

```zig
const shell = Forker.Shell.init(&.{ "/bin/echo", "Hello world!" });
var execs = [_]Forker.Executable { shell.executable(.once) };
var forker = Forker { .processes = &execs };

Forker.start(&forker); // may only be called once
```

Commit HEAD compiled with Zig `0.14.1`.
