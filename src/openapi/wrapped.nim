import options
import macros
import json
import strutils

import foreach
import spec
import typewrap
import paths

type
  TypeDefResult* = object of ConsumeResult
    name: string
    comment: string
    ftype: FieldTypeDef
    wrapped: WrappedItem

  WrappedField* = WrappedType[FieldTypeDef, WrappedItem]
  WrappedItem* = ref object
    name: string  ## this is necessarily the WrappedType.name
    case kind: FieldType
    of Primitive:
      primitive: JsonNode
    of List:
      list: WrappedField
    of Either:
      either: WrappedField
    of Anything:
      anything: WrappedField
    of Complex:
      complex: WrappedField

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): TypeDefResult
proc parseTypeDef(input: JsonNode): FieldTypeDef
proc parseTypeDefOrRef(input: JsonNode): NimNode

proc newWrappedPrimitive(ftype: FieldTypeDef, name: string; js: JsonNode): WrappedItem =
  ## a wrapped item that points to a primitive
  result = WrappedItem(kind: Primitive, name: name, primitive: js)
  assert ftype.kind == result.kind

proc newWrappedList(ftype: FieldTypeDef; name: string; js: JsonNode): WrappedItem =
  ## a wrapped item that holds a list of other wrapped items
  #let wrapped = newLimb(ftype, name, @[])
  #result = WrappedItem(kind: List, name: name, list: wrapped)
  assert ftype.kind == result.kind

proc newWrappedComplex(ftype: FieldTypeDef; name: string; js: JsonNode = nil): WrappedItem =
  ## a wrapped item that may contain named wrapped items
  let wrapped = newBranch[FieldTypeDef, WrappedItem](ftype, name)
  result = WrappedItem(kind: Complex, name: name, complex: wrapped)
  assert ftype.kind == result.kind

iterator wrapOneType*(ftype: FieldTypeDef; name: string; input: JsonNode): WrappedItem {.deprecated.} =
  case ftype.kind:
  of Primitive:
    yield ftype.newWrappedPrimitive(name, input)
  of List:
    error "unable to parse lists"
    yield ftype.newWrappedList(name, input)
  of Complex:
    yield ftype.newWrappedComplex(name, input)
  else:
    warning "unable to wrap " & $ftype.kind

proc toValidIdentifier(name: string; star=true): NimNode =
  ## permute identifiers until they are valid
  if name.isValidNimIdentifier:
    if star:
      result = newExportedIdentNode(name)
    else:
      result = name.stropIfNecessary
  else:
    result = toValidIdentifier("oa" & name.replace("__", "_"), star=star)

proc parseRefTarget(target: string): NimNode {.deprecated.} =
  ## turn a $ref -> string into a nim ident node
  let templ = "#/definitions/{name}".parseTemplate()
  assert templ.ok, "you couldn't parse your own template, doofus"
  let caught = templ.match(target)
  assert caught, "our template didn't match the ref: " & target
  result = toValidIdentifier(target.split("/")[^1], star=false)

proc pluckRefNode(input: JsonNode): NimNode =
  ## sniff the type name and cast it to a nim identifier
  let target = input.pluckString("$ref")
  if target.isNone:
    return
  result = target.get().parseRefTarget()

proc elementTypeDef(input: JsonNode; name="nil"): NimNode {.deprecated.} =
  result = input.parseTypeDefOrRef()
  if result != nil:
    return
  let element = input.parseTypeDef()
  result = element.makeTypeDef(name, input).ast

iterator objectProperties(input: JsonNode): NimNode =
  ## yield typedef nodes of a json object, and
  ## ignore "$ref" nodes in the input
  var onedef, typedef: NimNode
  if input != nil:
    assert input.kind == JObject, "nonsensical json type in objectProperties"
    foreach k, v in input.pairs of string and JsonNode:
      if k == "$ref":
        continue
      # a single property typedef
      onedef = newNimNode(nnkIdentDefs)
      onedef.add k.toValidIdentifier()
      typedef = v.parseTypeDefOrRef()
      assert typedef != nil, "unable to parse type: " & $v
      onedef.add typedef
      onedef.add newEmptyNode()
      yield onedef

proc defineMap(input: JsonNode): NimNode =
  ## reference an existing map type or create a new one right here
  var
    target: NimNode
  assert input != nil
  assert input.kind == JObject

  let contents = (typed: "type" in input, refd: "$ref" in input)
  if contents.typed and contents.refd:
    # we'll let the $ref override...
    target = input.pluckRefNode()
  elif not (contents.typed or contents.refd):
    # no type and no ref; use string
    target = newIdentNode("string")
  elif contents.refd:
    target = input.pluckRefNode()
  else:
    assert contents.typed == true
    let ftype = input.parseTypeDef()
    if ftype.kind == Primitive:
      target = ftype.toNimNode
    else:
      # it's a List, Complex, or worse
      # TODO: verify that this is correct!
      target = newIdentNode("string")

  return quote do:
    Table[string, `target`]

proc defineObject(input: JsonNode): NimNode =
  ## reference an existing obj type or create a new one right here
  assert input != nil, "i should be getting non-nil input, i think"
  var reclist: NimNode
  let target = input.pluckRefNode()

  # the object is composed thusly
  result = newNimNode(nnkObjectTy)
  result.add newEmptyNode()
  result.add newEmptyNode()
  reclist = newNimNode(nnkRecList)
  foreach def in input.objectProperties of NimNode:
    if target != nil:
      warning "found a properties ref and 1+ props: " & def.strVal, result
      break
    reclist.add def
  # we would have exited sooner, but i wanted to make sure we could provide
  # a decent warning message above...
  if target != nil:
    result = target
  else:
    result.add reclist

proc defineObjectOrMap(input: JsonNode): NimNode =
  ## reference an existing obj type or create a new one right here
  assert input != nil, "i should be getting non-nil input, i think"
  assert input.kind == JObject, "bizarre input: " & $input

  if "properties" in input and "additionalProperties" in input:
    error "both `properties` and `additionalProperties`" &
      " are defined:\n" & input.pretty

  # if we have a ref at this root, well, just use that
  result = input.pluckRefNode()
  if result != nil:
    return

  if input.len == 0:
    # FIXME: not sure we want to swallow objects like {}
    result = input.defineMap()
  elif "properties" in input:
    result = input["properties"].defineObject()
  elif "additionalProperties" in input:
    result = input["additionalProperties"].defineMap()
  elif "items" in input:
    assert input["items"].kind == JObject
    result = input["items"].parseTypeDefOrRef()
    assert result != nil
    return quote do:
      seq[`result`]
  elif "allOf" in input:
    warning "allOf support is terrible!"
    assert input["allOf"].kind == JArray
    foreach n in input["allOf"].items of JsonNode:
      result = n.defineObjectOrMap()
      if result != nil:
        break
  else:
    error "missing properties or additionalProperties in object:\n" &
      input.pretty

proc parseTypeDef(input: JsonNode): FieldTypeDef =
  ## convert a typedef from json; eg. we may expect to look
  ## for a type="something" and/or format="something-else"
  case input.kind:
  of JObject:
    if "type" in input:
      let
        major = input["type"].getStr
        #minor = input.getOrDefault("format").getStr
        kind = major.guessJsonNodeKind()
      if kind.isSome:
        result = kind.get().toFieldTypeDef()
        return
  of JArray:
    if "items" in input:
      result = input.kind.toFieldTypeDef()
      result.member = input["items"].parseTypeDef()
      return
  else:
    discard
  result = input.kind.toFieldTypeDef()

proc parseTypeDefOrRef(input: JsonNode): NimNode =
  ## convert a typedef from json to nimnode; this one will
  ## provide the RHS of a typedef and performs a substitution
  ## of an available $ref if available
  var ftype: FieldTypeDef
  if input == nil:
    return
  result = input.pluckRefNode()
  if result != nil:
    return
  ftype = input.parseTypeDef()
  case ftype.kind:
  of List:
    assert input.kind == JObject
    if ftype.member == nil:
      if "items" in input:
        let target = input["items"].pluckRefNode()
        if target != nil:
          return quote do:
            seq[`target`]
        else:
          ftype.member = input["items"].parseTypeDef()
          assert ftype.member != nil, "bad items: " & $input["items"]
    return ftype.toNimNode
  of Complex:
    #if "type" notin input:
    # warning "lacks `type` property:\n" & input.pretty
    if "type" in input:
      return input.parseTypeDef()
    elif "allOf" in input:
      warning "allOf poorly implemented!"
      assert input["allOf"].kind == JArray
      foreach n in input["allOf"].items of JsonNode:
        return n.parseTypeDefOrRef()
    elif input.len == 0:
      # it's okay, it's an empty map {}
      discard
    elif "properties" in input:
      # it's okay, it's an underspecified object
      discard
    elif "additionalProperties" in input:
      # it's okay, it's an underspecified map
      discard
    else:
      # i guess we can't really tell what it is...
      warning "lacks `type` property:\n" & input.pretty
      result = newCommentStmtNode("assuming it's an optional string...!")
      result.strVal.warning result
      return JString.optional
    return input.defineObjectOrMap()
  else:
    # it's a primitive or otherwise easily converted
    return ftype.toNimNode

proc fail(rh: var TypeDefResult; why: string; silent=false) =
  ## prepare the result of a failed parse
  rh.ok = false
  rh.comment = rh.name & ": " & why
  if not silent:
    rh.ast = newCommentStmtNode(rh.comment)
    rh.ast.add newCommentStmtNode($rh.js)
  warning rh.comment, rh.ast
  warning rh.js.pretty, rh.ast

proc whine(rh: var TypeDefResult; why: string) {.deprecated.} =
  ## issue warnings but don't necessarily
  ## reset the success bool as a result
  let was = rh.ok
  rh.fail why, silent=true
  rh.ok = was or rh.ok

proc bomb(rh: var TypeDefResult; why: string) =
  ## prepare the result of a fatal parse failure
  rh.fail(why)
  error "unrecoverable error", rh.ast

proc rightHandType(ftype: FieldTypeDef; js: JsonNode; name="?"): TypeDefResult =
  ## produce the right-hand side of a typedef given a json schema
  result = TypeDefResult(ok: false, ftype: ftype, js: js, name: name)
  var input = js
  if ftype == nil:
    result.bomb "no schema provided for unpack"
    return

  if input == nil:
    result.bomb "no input for type unpack"
    return

  if ftype.kind in {List, Complex}:
    if input.kind != JObject:
      result.bomb "bad input for " & $input.kind
      return
    elif input.len == 0:
      # this is basically a "type" like {}
      result.ast = input.defineObjectOrMap()
      result.ok = true
      # skip that huge case
      return

  case ftype.kind:
  of Primitive:
    result.ast = ftype.toNimNode
  of List:
    # FIXME: clean this up
    if "items" notin input:
      result.bomb "lacks `items` property"
      return
    let member = input["items"].elementTypeDef()
    # because it's, like, what, 12 `Sym "[]"` records?
    result.ast = quote do:
      seq[`member`]
  of Complex:
    let k = input.guessType(root=nil) # no root here!
    if k.isNone:
      result.fail "unable to guess type of schema"
      return
    let (major, minor) = k.get()
    # do we need to define an object type here?
    if k.get().major == JObject:
      # name this object type and add the definition
      result.ast = input.defineObjectOrMap()

    # TODO: maybe we have some array code?
    #elif kind == JArray:

    else:
      # it's not an object; just figure out what it is and def it
      # create a new fieldtype, perhaps permuted by the format
      result.ftype = major.conjugateFieldType(format=minor)
      let
        # pass the same input through, for comment reasons
        rh = result.ftype.rightHandType(input, name=name)
      result.ast = rh.ast
      if not rh.ok:
        return
  else:
    result.fail "bad typedef kind " & $ftype.kind
    return

  # do anything else you need to do on a valid type held in result,
  # ie. if we get this far, we aren't merely commenting on bad data
  result.ok = true

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): TypeDefResult =
  ## toplevel type builder which emits symbols and associated types,
  ## of Primitive, List, Complex forms

  result = TypeDefResult(ok: false, ftype: ftype, js: input, name: name)

  # no input, no problem
  if input == nil:
    result.bomb name & " lacks any type info"
    return

  var
    documentation, right: NimNode
    target = input.pluckRefNode()
    description = input.pluckString("description")

  if input.kind == JObject and input.len == 0:
    documentation = newCommentStmtNode(name & " lacks any type info")
    #documentation.strVal.warning
  elif description.isSome:
    documentation = newCommentStmtNode(description.get())
  if documentation == nil:
    documentation = newCommentStmtNode(name & " lacks `description`")

  # if there's a ref target (a symbol), then we'll just use that
  if target != nil:
    right = target

  # else unpack the type on the right-hand side
  else:
    let rh = rightHandType(ftype, input, name=name)
    assert rh.ast != nil
    # good or bad, we always get ast
    right = rh.ast
    if not rh.ok:
      return

  # sadly, still need to figure out how to do docs
  #result = documentation
  result.ast = newNimNode(nnkTypeDef)
  result.ast.add name.toValidIdentifier
  result.ast.add newEmptyNode()
  result.ast.add right
  result.ok = true
