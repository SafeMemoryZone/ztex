# ztex
A very simple nano-like text editor in zig.

## Quickstart

1. Make sure you have the [zig compiler](https://ziglang.org/download/) and [ncurses](https://invisible-island.net/ncurses/) installed.

2. Compile and run the project with (pass any arguments to the text editor after '--'):

```console
$ zig build run -- ...
```

## Usage

```console
$ ./ztex [<file_to_edit>]
```

## Controls

- Use the arrow keys to move
- Use '<ctrl> + q' to quit the editor (a prompt will appear asking for the filename - press '<ctrl> + q' again to quit)

## Note

This project is unfinished and has currently not support for windows. Keep your expectations low!
