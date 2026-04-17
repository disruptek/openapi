version = "5.0.0"
author = "disruptek"
description = "OpenAPI Code Generator"
license = "MIT"
requires "nim >= 2.0.0"
requires "npeg < 2.0.0"
requires "foreach >= 1.0.1 & < 2.0.0"
requires "https://github.com/disruptek/rest.git >= 1.0.5 & < 2.0.0"

proc execCmd(cmd: string) =
  echo "execCmd:" & cmd
  exec cmd

proc execTest(test: string) =
  execCmd "nim c           -f -r " & test
  execCmd "nim c   -d:release -r " & test
  execCmd "nim c   -d:danger  -r " & test
  execCmd "nim cpp            -r " & test
  execCmd "nim cpp -d:danger  -r " & test
  execCmd "nim c   --mm:arc -r " & test
  execCmd "nim cpp --mm:arc -r " & test

task test, "run tests":
  execTest("tests/test.nim")
  execTest("tests/test3.nim")
