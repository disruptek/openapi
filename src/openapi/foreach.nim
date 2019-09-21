import macros

iterator unwrapParentheses(node: NimNode): NimNode =
  if node.kind == nnkPar:
    for n in node.items:
      yield n
  else:
    yield node

proc initForLoop(loop: var NimNode; input: NimNode) =
  for i in 1 .. input.len - 1:
    if i == 1:
      for node in unwrapParentheses(input[i]):
        loop.add node
    else:
      loop.add input[i]

proc guard(name: NimNode; expect: NimNode): NimNode =
  let msg = "loop variable `" & name.repr & "` isn't a `" & expect.repr & "`"
  var pragma = newNimNode(nnkPragma)
  pragma.add newColonExpr(ident"error", newStrLitNode(msg))
  result = newNimNode(nnkElifBranch)
  result.add name.infix("is", expect).prefix("not")
  result.add pragma

macro forEach*(k: untyped; tree: untyped; body: untyped): untyped =
  ## create the following `for` loop syntax:
  ##
  ## forEach k, v in bar.pairs of MyType and HerType:
  ##   # a compile-time error if k isn't a MyType
  ##   # a compile-time error if v isn't a HerType
  ##   ...
  ##
  ## and, for convenience,
  ##
  ## forEach k, v in bar.pairs:
  ##   # no checking is performed on k|v types
  ##   ...
  ##
  var loop = tree[1]
  result = newNimNode(nnkForStmt)
  result.add k
  # if we aren't using `forEach k, v in bar of bif and baf` syntax,
  if tree[0] != ident"and":
    # then just build a normal for loop
    result.initForLoop(loop)
    result.add body
  else:
    # otherwise,
    let kt = loop[^1]
    # narrow the loop
    loop = loop[1]
    let
      v = loop[1]
      vt = tree[^1]
    # build the loop normally,
    result.initForLoop(loop)
    var
      control = newNimNode(nnkWhenStmt)
      succeed = newNimNode(nnkElse)
    # add a `when` to guard forEach var|type,
    control.add guard(k, kt)
    control.add guard(v, vt)
    # then an `else` to run the loop body normally.
    succeed.add body
    control.add succeed
    result.add newStmtList(control)

macro forEach*(loop: untyped; body: untyped): untyped =
  ## create the following `for` loop syntax:
  ##
  ## forEach foo in bar.items of MyType:
  ##   # a compile-time error if foo isn't a MyType
  ##   ...
  ##
  ## and, for convenience,
  ##
  ## forEach foo in bar.items:
  ##   # no checking is performed on foo's type
  ##   ...
  ##
  result = newNimNode(nnkForStmt)
  # see if it's a `forEach (k, v) in ...` syntax,
  if loop[0] == ident"and":
    error "don't wrap your loop variables in () as that syntax will change"
  # if we aren't using `forEach foo in bar of bif` syntax,
  if loop[0] != ident"of":
    # then just build a normal for loop
    result.initForLoop(loop)
    result.add body
  else:
    # otherwise,
    let
      meat = loop[1] # meat is the `for` part, and
      gravy = loop[2] # gravy is the `of` type
    # build the loop normally,
    result.initForLoop(meat)
    var
      control = newNimNode(nnkWhenStmt)
      succeed = newNimNode(nnkElse)
    # add a `when` to guard against a bogus type,
    control.add guard(meat[1], gravy)
    # then an `else` to run the loop body normally.
    succeed.add body
    control.add succeed
    result.add newStmtList(control)
