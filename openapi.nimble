version = "3.1.5"
author = "disruptek"
description = "OpenAPI Code Generator"
license = "MIT"
requires "nim >= 1.0.6"
requires "npeg >= 0.23.0"
requires "foreach >= 1.0.1"
requires "https://github.com/disruptek/rest.git >= 1.0.3"

srcDir = "src"

proc execCmd(cmd: string) =
  echo "execCmd:" & cmd
  exec cmd

proc execTest(test: string) =
  execCmd "nim c           -f -r " & test
  execCmd "nim c   -d:release -r " & test
  execCmd "nim c   -d:danger  -r " & test
  execCmd "nim cpp            -r " & test
  execCmd "nim cpp -d:danger  -r " & test
  when NimMajor >= 1 and NimMinor >= 1:
    execCmd "nim c   --gc:arc --exceptions:goto -r " & test
    execCmd "nim cpp --gc:arc --exceptions:goto -r " & test

task test, "run tests for travis":
  execTest("tests/tests.nim")
