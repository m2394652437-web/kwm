#!/bin/bash

cd ../

 for archive in     xkb-0.3.0.tar.gz     mvzr-0.3.10.tar.gz     fcft-2.0.0.tar.gz     pixman-0.3.0.tar.gz     zigwl-0.6.0.tar.gz; do     tar -xf "$HOME/.cache/paru/clone/kwm/$archive"         -C "$HOME/Documents/My_files/Programming/zig/MyKWM/deps" || break; done
