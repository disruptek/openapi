version = "1.0.0"
author = "disruptek"
description = "OpenAPI Code Generator"
license = "MIT"
requires "nim >= 0.20.0"
requires "npeg >= 0.17.1"

task test, "Runs the test suite":
  exec "nim c -r tests.nim"
