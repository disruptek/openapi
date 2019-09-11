import macros
import options
import json
import tables
import strutils

when not defined(release):
  import strformat

export JsonNodeKind

type
  # we may use the semantics of ordered tables to ensure that
  # we only iterate over patterned field names after traversing
  # the un-patterned names, so change this type at your peril
  Schema* = OrderedTableRef[FieldName, FieldTypeDef]   ## complex objects
  FieldName* = string ## the field name doubles as the pattern
  FieldType* = enum   ## variant discriminator for value types
    Anything  ## anything or nothing (nullable)
    Primitive ## a primitive value (integer, string, etc.)
    List      ## an array
    Either    ## one of 2+ possible values
    Complex   ## a map-like object
  FieldTypeDef* = ref object ## the type for any given value
    kinds*: set[JsonNodeKind]
    pattern*: bool
    required*: bool
    case kind*: FieldType
    of Anything, Primitive: discard
    of Either:
      a*: FieldTypeDef
      b*: FieldTypeDef
    of List:
      member*: FieldTypeDef
    of Complex:
      schema*: Schema
  ## string values as per the spec
  HttpOpName* = enum
    Get = "get"
    Put = "put"
    Post = "post"
    Delete = "delete"
    Options = "options"
    Head = "head"
    Patch = "patch"

  Scheme* {.pure.} = enum
    Https = "https",
    Http = "http",
    Wss = "wss"
    Ws = "ws",

  ConsumeResult* = object of RootObj
    ok*: bool
    schema*: Schema
    js*: JsonNode
    ast*: NimNode

  GuessTypeResult* = tuple
    major: JsonNodeKind
    minor: string

proc `$`*(ftype: FieldTypeDef): string =
  if ftype == nil:
    return "(nil)"
  when not defined(release):
    result = &"{ftype.kind} {ftype.kinds} req={ftype.required} pat={ftype.pattern}"
    if ftype.kind == Complex and ftype.schema != nil:
      result &= " len=" & $ftype.schema.len
  else:
    result = "(debug builds are rad)"

proc `|`*(a: FieldTypeDef; b: FieldTypeDef): FieldTypeDef =
  ## the field may be represented by either of two types
  result = FieldTypeDef(kind: Either,
    kinds: a.kinds + b.kinds,
    pattern: a.pattern or b.pattern,
    required: a.required or b.required,
    a: a, b: b)

proc newFieldTypeDef*(kind: FieldType; kinds: set[JsonNodeKind]={};
  pattern=false, required=false, member: FieldTypeDef=nil;
  schema: Schema=nil): FieldTypeDef =
  case kind:
  of Primitive:
    assert kinds != {}
    assert JObject notin kinds, "JObject is an exclusive sub-type"
    assert JArray notin kinds, "JArray is an exclusive sub-type"
    result = FieldTypeDef(kind: Primitive, kinds: kinds, pattern: pattern, required: required)
  of Complex:
    assert kinds.len == 1 and JObject in kinds
    result = FieldTypeDef(kind: Complex, kinds: {JObject}, pattern: pattern, required: required,
      schema: schema)
  of Anything:
    assert kinds.len == 0
    result = FieldTypeDef(kind: Anything, kinds: {}, pattern: pattern, required: required)
  of List:
    assert kinds.len == 1 and JArray in kinds
    result = FieldTypeDef(kind: List, kinds: {JArray}, pattern: pattern, required: required,
      member: member)
  of Either:
    # TODO: maybe perform an assertion here?
    result = FieldTypeDef(kind: Either, kinds: {}, pattern: pattern, required: required)
  #else:
  # raise newException(Defect, "unimplemented " & $kind & " field")

proc newSchema*(fields: openArray[(FieldName, FieldTypeDef)]): Schema =
  result = newOrderedTable(fields)

converter toSchema*(fields: openArray[(FieldName, FieldTypeDef)]): Schema =
  result = newSchema(fields)

converter toFieldTypeDef*(k: JsonNodeKind): FieldTypeDef =
  case k:
  of JObject:
    result = Complex.newFieldTypeDef(kinds={k})
  of JArray:
    result = List.newFieldTypeDef(kinds={k})
  of JNull:
    result = Anything.newFieldTypeDef(kinds={})
  else:
    result = Primitive.newFieldTypeDef(kinds={k})

converter toJsonNodeKind*(f: FieldTypeDef): JsonNodeKind =
  case f.kind:
  of Complex:
    result = JObject
  of List:
    result = JArray
  of Anything:
    result = JNull
  of Either:
    assert false, "nonsensical conversion of Either type"
  of Primitive:
    assert f.kinds.len == 1, "ambiguous types: " & $f.kinds
    for n in f.kinds:
      result = n

converter toFieldTypeDef*(s: set[JsonNodeKind]): FieldTypeDef =
  if JObject in s:
    assert s == {JObject}, "JObject is an exclusive sub-type"
    result = Complex.newFieldTypeDef(kinds=s)
  elif JArray in s:
    assert s == {JArray}, "JArray is an exclusive sub-type"
    result = List.newFieldTypeDef(kinds=s)
  elif s == {}:
    result = Anything.newFieldTypeDef(kinds={})
  else:
    result = Primitive.newFieldTypeDef(kinds=s)

converter toFieldTypeDef*(c: Schema): FieldTypeDef =
  result = Complex.newFieldTypeDef(kinds={JObject}, schema=c)

proc paint(src: FieldTypeDef; dst: FieldTypeDef) =
  ## copy variant values for immutable conversion reasons
  assert src.kind == dst.kind, "unable to paint fields of differing type"
  case src.kind:
  of Complex:
    dst.schema = src.schema
  of List:
    dst.member = src.member
  of Either:
    dst.a = src.a
    dst.b = src.b
  of Anything, Primitive: discard

proc arrayOf*(member: FieldTypeDef): FieldTypeDef =
  result = FieldTypeDef(kind: List, kinds: {JArray}, member: member,
    pattern: member.pattern, required: member.required)

converter toFieldTypeDef*(list: array[1, FieldTypeDef]): FieldTypeDef =
  result = list[0].arrayOf

proc required*(t: FieldTypeDef): FieldTypeDef =
  ## the field is required and must be present in the input
  result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=t.pattern,
    required=true)
  t.paint(result)

proc optional*(t: FieldTypeDef): FieldTypeDef =
  ## the field is optional and may|not appear in the input
  result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=t.pattern,
    required=false)
  t.paint(result)

proc patterned*(t: FieldTypeDef): FieldTypeDef =
  ## the field name associated with this value is a regex
  result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=true,
    required=t.required)
  t.paint(result)

proc unpatterned*(t: FieldTypeDef): FieldTypeDef =
  ## the field name associated with this value isn't a regex
  result = t.kind.newFieldTypeDef(kinds=t.kinds, pattern=false,
    required=t.required)
  t.paint(result)

proc anything*(): FieldTypeDef =
  ## any type, even null; defaults to optional
  result = Anything.newFieldTypeDef(required=false)

proc anything*(s: set[JsonNodeKind]): FieldTypeDef =
  ## any type, even null; defaults to optional
  assert s == {}
  result = Anything.newFieldTypeDef(required=false)

proc pluckString*(input: JsonNode; key: string): Option[string] =
  ## a robust getter for string values in json
  if input == nil:
    return
  if input.kind != JObject:
    return
  if key notin input:
    return
  result = some(input[key].getStr)

proc pluckRefJson*(root: JsonNode; input: JsonNode): JsonNode =
  ## find and return the content of a json ref, if possible
  let target = input.pluckString("$ref")
  if target.isNone:
    return
  if root == nil:
    warning "unable to retrieve $ref in this context"
    return
  var paths = target.get().split("/")
  while paths.len > 0 and paths[0] in ["", "#"]:
    paths = paths[1..^1]
  result = root
  for p in paths:
    if p notin result:
      warning "schema reference `" & target.get() & "` not found"
      return nil
    result = result[p]

proc whine(input: JsonNode; why: string) =
  ## merely complain about an irregular input
  warning why & ":\n" & input.pretty

proc guessJsonNodeKind*(name: string): Option[JsonNodeKind] =
  ## map openapi type names to their json node types
  case name:
  of "integer": result = some(JInt)
  of "number": result = some(JFloat)
  of "string": result = some(JString)
  of "file": result = some(JString)
  of "boolean": result = some(JBool)
  of "array": result = some(JArray)
  of "object": result = some(JObject)
  of "null": result = some(JNull)
  else: discard

proc guessType*(js: JsonNode; root: JsonNode): Option[GuessTypeResult] =
  ## guess the JsonNodeKind of a node/schema, perhaps dereferencing
  var
    major: string
    input = root.pluckRefJson(js)
  if input == nil:
    input = js

  case input.kind:
  of JObject:
    var
      format = input.getOrDefault("format").getStr
    # see if it's an untyped value
    if input.len == 0:
      # this is a map like {}
      major = "object"
    elif "type" in input:
      major = input["type"].getStr
    elif "schema" in input:
      return input["schema"].guessType(root)
    else:
      # whine about any issues
      if "properties" in input:
        input.whine "objects should have a type=object property"
        major = "object"
      elif "additionalProperties" in input:
        input.whine "maps should have a type=object property"
        major = "object"
      elif "enum" in input:
        major = "string"
        format = "enum"
      elif "allOf" in input:
        major = "object"
        assert input["allOf"].kind == JArray
        for n in input["allOf"]:
          input = n
          break
      else:
        # we'll return if we cannot recognize the type
        warning "no type discovered:\n" & input.pretty
        return some((major: JNull, minor: ""))
      if "allOf" in input:
        input.whine "allOf is poorly implemented"
    assert major != "", "logic error; ie. someone forgot to add logic"
    let
      kind = major.guessJsonNodeKind()
    if kind.isSome:
      result = some((major: kind.get(), minor: format))
  else:
    result = some((major: input.kind, minor: ""))

proc isKnownFormat(major: JsonNodeKind; format=""): bool =
  ## it is known (and appropriate to the major)
  case major:
  of JInt:
    result = case format:
    of "", "integer", "int32", "long", "int64": true
    else: false
  of JFloat:
    result = case format:
    of "", "number", "float", "double": true
    else: false
  of JString:
    result = case format:
    of "", "string", "password", "file": true
    of "byte", "binary": true
    of "date", "date-time": true
    else: false
  of JBool:
    result = case format:
    of "", "boolean": true
    else: false
  of JArray:
    result = case format:
    of "", "array": true
    else: false
  of JObject:
    result = case format:
    of "", "object": true
    else: false
  of JNull:
    result = case format:
    of "", "null": true
    else: false

proc conjugateFieldType*(major: JsonNodeKind; format=""): FieldTypeDef =
  ## makes a typedef given node kind and optional format;
  ## (this should someday handle arbitrary formats)
  if not major.isKnownFormat(format):
    warning $major & " type has unknown format `" & format & "`"
  result = major.toFieldTypeDef

converter toNimNode*(kind: JsonNodeKind): NimNode =
  result = case kind:
  of JInt: ident"int"
  of JFloat: ident"float"
  of JString: ident"string"
  of JBool: ident"bool"
  of JNull: newNilLit()
  else:
    raise newException(ValueError, "unable to cast " & $kind & " to Nim")

converter toNimNode*(ftype: FieldTypeDef): NimNode =
  ## render a fieldtypedef as nimnode
  if ftype == nil:
    return newCommentStmtNode("fieldtypedef was nil")
  case ftype.kind:
  of Primitive:
    if ftype.kinds.card == 0:
      return newCommentStmtNode("missing type specification")
    if ftype.kinds.card != 1:
      return newCommentStmtNode("multiple types is too many")
    for kind in ftype.kinds:
      return kind.toNimNode
  of List:
    assert ftype.member != nil
    let elements = ftype.member.toNimNode
    result = quote do:
      seq[`elements`]
  of Complex:
    result = newCommentStmtNode("creating a " & $ftype.kind)
    result.strVal.warning result
  else:
    result = newCommentStmtNode("you can't create a typedef for a " & $ftype.kind)
    result.strVal.error result

proc isKeyword*(identifier: string): bool =
  ## true if the given identifier is a nim keyword
  result = identifier in [
    "addr", "and", "as", "asm",
    "bind", "block", "break", "block", "break",
    "case", "cast", "concept", "const", "continue", "converter",
    "defer", "discard", "distinct", "div", "do",
    "elif", "else", "end", "enum", "except", "export",
    "finally", "for", "from", "func",
    "if", "import", "in", "include", "interface", "is", "isnot", "iterator",
    "let",
    "macro", "method", "mixin", "mod",
    "nil", "not", "notin",
    "object", "of", "or", "out",
    "proc", "ptr",
    "raise", "ref", "return",
    "shl", "shr", "static",
    "template", "try", "tuple", "type",
    "using",
    "var",
    "when", "while",
    "xor",
    "yield",
  ]

proc isValidNimIdentifier*(s: string): bool =
  ## true for strings that are valid identifier names
  if s.len > 0 and s[0] in IdentStartChars:
    if s.len > 1 and '_' in [s[0], s[^1]]:
      return false
    for i in 1..s.len-1:
      if s[i] notin IdentChars:
        return false
      if s[i] == '_' and s[i-1] == '_':
        return false
    return true

proc stropIfNecessary*(name: string): NimNode =
  ## backtick an identifier if it represents a keyword
  if name.isKeyword:
    result = newNimNode(nnkAccQuoted)
    result.add newIdentNode(name)
  else:
    result = newIdentNode(name)

proc newExportedIdentNode*(name: string): NimNode =
  ## newIdentNode with an export annotation
  assert name.isValidNimIdentifier == true
  result = newNimNode(nnkPostfix)
  result.add newIdentNode("*")
  result.add name.stropIfNecessary

proc getLiteral*(node: JsonNode = nil): NimNode =
  ## produce literal nim of the given json type, perhaps with a value
  assert node != nil
  result = case node.kind:
  of JString:
    newStrLitNode(node.getStr)
  of JBool:
    newIdentNode($node.getBool)
  of JInt:
    newIntLitNode(node.getInt)
  of JFloat:
    newFloatLitNode(node.getFloat)
  of JNull:
    newNilLit()
  else:
    raise newException(ValueError,
                       "unable to get a literal from a " & $node.kind)

proc getLiteral*(kind: JsonNodeKind): NimNode =
  ## produce literal nim of the given json type, perhaps with a value
  result = case kind:
  of JString:
    newStrLitNode("")
  of JBool:
    newIdentNode("false")
  of JInt:
    newIntLitNode(0)
  of JFloat:
    newFloatLitNode(0.0)
  of JNull:
    newNilLit()
  else:
    raise newException(ValueError,
                       "unable to get a literal from a " & $kind)

proc instantiateWithDefault*(kind: JsonNodeKind; default: NimNode): NimNode =
  assert default != nil, "nil defaults aren't supported yet"
  if kind in {JString, JInt, JBool, JFloat}:
    result = newCall(newIdentNode("new" & $kind), default)
  elif kind == JNull:
    result = newCall(newIdentNode("new" & $kind))
  else:
    raise newException(ValueError,
                       "unable to instantiate new " & $kind & " node (yet)")
