# Prise

Prise is a terminal multiplexer targeted at modern terminals.

## Goals

1.  **Modern Terminal Features**: This is a core tenet. Terminals that do not
    provide the base level of modern features will not be supported; prise will
refuse to start in such environments.
2.  **High-Performance Community Vibe Coding**: Prise serves as an experiment in
    collaborative, high-performance software development driven by "vibe coding"
and AI assistance. Together, we can vibe code high performance software.
3.  **Extensibility**: Extensibility is at the core of the UI. The user
    interface is designed to be fully replaceable through configuration or by
using a third-party client.

## Build Instructions

To build the project:

```bash
zig build
```

To run the project:

```bash
zig build run
```

To run tests:

```bash
zig build test
```

## Requirements

The following binaries are required for development:

*   `stylua` (for Lua formatting)
*   [`zigdoc`](https://github.com/rockorager/zigdoc) (for documentation)

## Vibe Coding

Prise is a vibe coded project. Contributions are welcome, but preference is given to AI-developed code.

*   Sharing of AI conversation threads is preferred when submitting contributions, even if those threads did not directly result in the final Pull Request.
*   If you cannot afford paid AI tools, check out [Amp's free mode](https://ampcode.com).
*   There are also other free options available, such as OpenCode using compatible models.
