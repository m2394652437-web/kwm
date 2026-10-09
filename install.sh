#!/bin/bash

zig build \
    -Doptimize=ReleaseSafe \
    -Dconfig=config.def.zon \
    --search-prefix /usr \
    --fork=../deps/zig-xkbcommon-0.3.0 \
    --fork=../deps/mvzr-0.3.10 \
    --fork=../deps/zig-fcft-2.0.0 \
    --fork=../deps/zig-pixman-0.3.0 \
    --fork=../deps/zig-wayland-0.6.0 \
    --summary all


install -m 755 \
        ~/Documents/My_files/Programming/zig/mykwm/kwm/zig-out/bin/kwm \
        ~/.local/bin/kwm

echo "mykwm is successfully installed!"
