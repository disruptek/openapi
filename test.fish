#!/bin/fish

nim c --out:./unit-tests tests.nim ; and ./unit-tests $argv
