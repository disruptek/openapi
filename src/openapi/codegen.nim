import macros
import tables
import json
import strutils
import options
import hashes
import strtabs

import spec
import parser
import paths

from schema2 import OpenApi2

const MAKETYPES = false
when MAKETYPES:
  import typewrap
  import wrapped
  import sequtils

type
  PathItem = object of ConsumeResult
    path*: string
    parsed*: ParserResult
    basePath*: string
    host*: string
    operations*: Table[string, Operation]
    parameters*: Parameters
    generator*: Generator

  ParameterIn* = enum
    InPath = "path"
    InQuery = "query"
    InHeader = "header"
    InData = "formData"
    InBody = "body"

  DocType = enum Json, Native

  Parameter = object of ConsumeResult
    name*: string
    description*: string
    required*: bool
    location*: ParameterIn
    default*: JsonNode
    source*: JsonNode
    kind*: Option[GuessTypeResult]

  Parameters = object
    sane: StringTableRef
    tab: Table[Hash, Parameter]
    forms: set[ParameterIn]

  Response = object of ConsumeResult
    status: string
    description: string

  Operation = object of ConsumeResult
    meth*: HttpOpName
    path*: PathItem
    description*: string
    operationId*: string
    parameters*: Parameters
    responses*: seq[Response]
    deprecated*: bool
    typename*: NimNode
    prepname*: NimNode
    urlname*: NimNode

  Generator* = object of ConsumeResult
    schemes*: set[Scheme]
    roottype*: NimNode
    inputfn*: string
    outputfn*: string
    imports*: NimNode
    types*: NimNode
    recallable*: NimNode
    hydratePath*: NimNode
    queryString*: NimNode
    makeTypes: NimNode
    forms*: set[ParameterIn]

proc guessDefault(kind: GuessTypeResult; root: JsonNode; input: JsonNode): JsonNode =
  assert input != nil, "unable to guess type for nil json node"
  result = input.getOrDefault("default")
  if result == nil:
    if kind.minor == "enum" and "enum" in input:
      assert input["enum"].kind == JArray and input["enum"].len > 0
      result = input["enum"][0]
  if result != nil:
    var target = root.pluckRefJson(result)
    if target != nil:
      result = target

proc requiresPassedInput(param: Parameter): bool =
  ## determine if the parameter may will require passed input
  result = param.required and param.default == nil

proc shortRepr(js: JsonNode): string =
  ## render a JInt(3) as "JInt(3)"; will puke on arrays/objects/null
  assert js.kind in {JNull, JBool, JInt, JFloat, JString}
  result = $js.kind & "(" & $js & ")"

proc newParameter(root: JsonNode; input: JsonNode): Parameter =
  ## instantiate a new parameter from a JsonNode schema
  assert input != nil and input.kind == JObject, "bizarre input: " &
    input.pretty
  var
    js = root.pluckRefJson(input)
    documentation = input.pluckString("description")
  if js == nil:
    js = input
  elif documentation.isNone:
    documentation = js.pluckString("description")
  var kind = js.guessType(root)
  if kind.isNone:
    error "unable to guess type:\n" & js.pretty
  result = Parameter(ok: false, kind: kind, js: js)
  result.name = js["name"].getStr
  result.location = parseEnum[ParameterIn](js["in"].getStr)
  result.required = js.getOrDefault("required").getBool
  if documentation.isSome:
    result.description = documentation.get
  result.default = kind.get.guessDefault(root, js)

  if result.default != nil:
    var defkind = result.default.guessType(root)
    if defkind.isNone:
      warning "unknown type for default value of " & $result
      result.default = nil
    elif defkind.get.major != kind.get.major:
      warning $kind.get.major & " parameter `" & $result & "` has default of " &
        result.default.shortRepr & "; omitting code to supply the default"
      result.default = nil

  # `source` is a pointer to the JsonNode that defines the
  # format for the parameter; it can be overridden with `schema`
  if result.location == InBody and "schema" notin js:
    error "schema is required for " & $result & "\n" & js.pretty
  elif result.location != InBody and "schema" in js:
    error "schema is inappropriate for " & $result & "\n" & js.pretty
  while "schema" in js:
    js = js["schema"]
    var source = root.pluckRefJson(js)
    if source == nil:
      break
    js = source
  if result.source == nil:
    result.source = js

  result.ok = true

template cappableAdd(s: var string; c: char) =
  ## add a char to a string, perhaps capitalizing it
  if s.len > 0 and s[^1] == '_':
    s.add c.toUpperAscii()
  else:
    s.add c

proc sanitizeIdentifier(name: string; capsOkay=false): Option[string] =
  ## convert any string to a valid nim identifier in camel_Case
  const elideUnder = true
  var id = ""
  if name.len == 0:
    return
  for c in name:
    if id.len == 0:
      if c in IdentStartChars:
        id.cappableAdd c
        continue
    elif c in IdentChars:
      id.cappableAdd c
      continue
    # help differentiate words case-insensitively
    id.add '_'
  when not elideUnder:
    while "__" in id:
      id = id.replace("__", "_")
  if id.len > 1:
    id.removeSuffix {'_'}
    id.removePrefix {'_'}
  # if we need to lowercase the first letter, we'll lowercase
  # until we hit a word boundary (_, digit, or lowercase char)
  if not capsOkay and id[0].isUpperAscii:
    for i in id.low..id.high:
      if id[i] in ['_', id[i].toLowerAscii]:
        break
      id[i] = id[i].toLowerAscii
  # ensure we're not, for example, starting with a digit
  if id[0] notin IdentStartChars:
    warning "identifiers cannot start with `" & id[0] & "`"
    return
  when elideUnder:
    if id.len > 1:
      while "_" in id:
        id = id.replace("_", "")
  if not id.isValidNimIdentifier:
    warning "bad identifier: " & id
    return
  result = some(id)

proc saneName(param: Parameter): string =
  ## produce a safe identifier for the given parameter
  let id = sanitizeIdentifier(param.name, capsOkay=true)
  if id.isNone:
    error "unable to compose valid identifier for parameter `" & param.name & "`"
  result = id.get

proc saneName(op: Operation): string =
  ## produce a safe identifier for the given operation
  var attempt: seq[string]
  if op.operationId != "":
    attempt.add op.operationId
    attempt.add $op.meth & "_" & op.operationId
  # TODO: turn path /some/{var_name}/foo_bar into some_varName_fooBar?
  attempt.add $op.meth & "_" & op.path.path
  for name in attempt:
    var id = sanitizeIdentifier(name, capsOkay=false)
    if id.isSome:
      return id.get
  error "unable to compose valid identifier; attempted these: " & attempt.repr

proc `$`*(path: PathItem): string =
  ## render a path item for error message purposes
  if path.host != "":
    result = path.host
  if path.basePath != "/":
    result.add path.basePath
  result.add path.path

proc `$`*(op: Operation): string =
  ## render an operation for error message purposes
  result = op.saneName

proc `$`*(param: Parameter): string =
  result = $param.saneName & "(" & $param.location & "-`" & param.name & "`)"

proc hash(p: Parameter): Hash =
  ## parameter cardinality is a function of name and location
  result = p.location.hash !& p.name.hash
  result = !$result

when false:
  proc len(parameters: Parameters): int =
    ## the number of items in the container
    result = parameters.tab.len

iterator items(parameters: Parameters): Parameter =
  ## helper for iterating over parameters
  for p in parameters.tab.values:
    yield p

iterator forLocation(parameters: Parameters; loc: ParameterIn): Parameter =
  ## iterate over parameters with the given location
  if loc in parameters.forms:
    for p in parameters:
      if p.location == loc:
        yield p

iterator nameClashes(parameters: Parameters; p: Parameter): Parameter =
  ## yield clashes that don't produce parameter "overrides" (identity)
  let name = p.saneName
  if name in parameters.sane:
    for existing in parameters:
      # identical parameter names can be ignored
      if existing.name == p.name:
        if existing.location == p.location:
          continue
      # yield only identifier collisions
      if name.eqIdent(existing.saneName):
        warning "name `" & p.name & "` versus `" & existing.name & "`"
        warning "sane `" & name & "` matches `" & existing.saneName & "`"
        yield existing

proc add(parameters: var Parameters; p: Parameter) =
  ## simpler add explicitly using hash
  let
    location = $p.location
    name = p.saneName

  parameters.sane[name] = location
  parameters.tab[p.hash] = p
  parameters.forms.incl p.location

proc safeAdd(parameters: var Parameters; p: Parameter; prefix=""): Option[string] =
  ## attempt to add a parameter to the container, erroring if it clashes
  for clash in parameters.nameClashes(p):
    # this could be a replacement/override of an existing parameter
    if clash.location == p.location:
      # the names have to match, not just their identifier versions
      if clash.name == p.name:
        continue
    # otherwise, we should probably figure out alternative logic
    var msg = "parameter " & $clash & " and " & $p &
      " yield the same Nim identifier"
    if prefix != "":
      msg = prefix & ": " & msg
    return some(msg)
  parameters.add p

proc init(parameters: var Parameters) =
  ## prepare a parameter container to accept parameters
  parameters.sane = newStringTable(modeStyleInsensitive)
  parameters.tab = initTable[Hash, Parameter]()
  parameters.forms = {}

proc readParameters(root: JsonNode; js: JsonNode): Parameters =
  ## parse parameters out of an arbitrary JsonNode
  result.init()
  for param in js:
    var parameter = root.newParameter(param)
    if not parameter.ok:
      error "bad parameter:\n" & param.pretty
      continue
    result.add parameter

proc newResponse(root: JsonNode; status: string; input: JsonNode): Response =
  ## create a new Response
  var js = root.pluckRefJson(input)
  if js == nil:
    js = input
  result = Response(ok: false, status: status, js: js)
  result.description = js.getOrDefault("description").getStr
  # TODO: save the schema
  result.ok = true

proc toJsonParameter(name: NimNode; required: bool): NimNode =
  ## create the right-hand side of a JsonNode typedef for the given parameter
  if required:
    result = newIdentDefs(name, ident"JsonNode")
  else:
    result = newIdentDefs(name, ident"JsonNode", newNilLit())

proc toNativeParameter(name: NimNode; kind: JsonNodeKind; required: bool; default: JsonNode = nil): NimNode =
  ## create the right-hand side of a native typedef for the given parameter

  # if we've previously established a default, ie. because one was
  # supplied as such or we've inferred the default value for a param,
  # eg. because it's the first value of an enum...
  if default != nil:
    # make sure that we don't have an obvious type clash
    if default.kind == kind:
      return newIdentDefs(name, kind.toNimNode, default.getLiteral)
    warning $kind & " parameter `" & $name & "` has default of " &
      default.shortRepr & "; omitting code to supply the default"
  # if it's required or the default was of the wrong kind, then err
  # on the side of requiring a value to be passed to the argument.
  if required or default != nil:
    return newIdentDefs(name, kind.toNimNode)
  # otherwise, default it to a default value for the native type
  result = newIdentDefs(name, kind.toNimNode, kind.getLiteral)

proc toNewJsonNimNode(js: JsonNode): NimNode =
  ## take a JsonNode value and produce Nim that instantiates it
  case js.kind:
  of JNull:
    result = quote do: newJNull()
  of JInt:
    let i = js.getInt
    result = quote do: newJInt(`i`)
  of JString:
    let s = js.getStr
    result = quote do: newJString(`s`)
  of JFloat:
    let f = js.getFloat
    result = quote do: newJFloat(`f`)
  of JBool:
    let b = newIdentNode($js.getBool)
    result = quote do: newJBool(`b`)
  of JArray:
    var
      a = newNimNode(nnkBracket)
      t: JsonNodeKind
    for i, j in js.getElems:
      if i == 0:
        t = j.kind
      elif t != j.kind:
        warning "disparate JArray element kinds are discouraged"
      else:
        a.add j.toNewJsonNimNode
    var
      c = newStmtList()
      i = ident"jarray"
    c.add quote do:
      var `i` = newJarray()
    for j in a:
      c.add quote do:
        `i`.add `j`
    c.add quote do:
      `i`
    result = newBlockStmt(c)
  else:
    raise newException(ValueError, "unsupported input: " & $js.kind)

proc defaultNode(op: Operation; param: Parameter; root: JsonNode): NimNode =
  ## generate nim to instantiate the default value for the parameter
  var useDefault = false
  if param.default != nil:
    let
      sane = param.saneName
    if param.kind.isNone:
      warning "unable to parse default value for parameter `" & sane &
      "`:\n" & param.js.pretty
    elif param.kind.get.major == param.default.kind:
      useDefault = true
    else:
      # provide a warning if the default type doesn't match the input
      warning "`" & sane & "` parameter in `" & $op &
        "` is " & $param.kind.get.major & " but the default is " &
        param.default.shortRepr & "; omitting code to supply the default"

  if useDefault:
    # set default value for input
    try:
      result = param.default.toNewJsonNimNode
    except ValueError as e:
      error e.msg & ":\n" & param.default.pretty
    assert result != nil
  else:
    result = newNilLit()

proc documentation(p: Parameter; form: DocType; root: JsonNode; name=""): NimNode =
  ## document the given parameter
  var
    label = if name == "": p.name else: name
    docs = "  " & label & ": "
  if p.kind.isNone:
    docs &= "{unknown type}"
  else:
    case form:
    of Json:
      docs &= $p.kind.get.major
    of Native:
      docs &= $p.kind.get.major.toNimNode
  if p.required:
    docs &= " (required)"
  if p.description != "":
    docs &= "\n" & spaces(2 + label.len) & ": "
    docs &= p.description
  result = newCommentStmtNode(docs)

proc sectionParameter(param: Parameter; kind: JsonNodeKind; section: NimNode; default: NimNode = nil): NimNode =
  ## pluck value out of location input, validate it, store it in section ident
  result = newStmtList([])
  var
    name = param.name
    reqIdent = newIdentNode($param.required)
    locIdent = newIdentNode($param.location)
    validIdent = genSym(ident="valid")
    defNode = if default == nil: newNilLit() else: default
    kindIdent = newIdentNode($kind)
  # you might think `locIdent`.getOrDefault() would be a good place to simply
  # instantiate our default JsonNode, but the validateParameter() is a more
  # central place to validate/log both the input and the default value,
  # particularly since we aren't going to unwrap the 'body' parameter

  # "there can be one 'body' parameter at most."
  if param.location == InBody:
    result.add quote do:
      `section` = validateParameter(`locIdent`, `kindIdent`,
        required= `reqIdent`, default= `defNode`)
  else:
    result.add quote do:
      var `validIdent` = `locIdent`.getOrDefault(`name`)
      `validIdent` = validateParameter(`validIdent`, `kindIdent`,
        required= `reqIdent`, default= `defNode`)
      if `validIdent` != nil:
        `section`.add `name`, `validIdent`

proc maybeAddExternalDocs(node: var NimNode; js: JsonNode) =
  ## add external docs comments to the given node if appropriate
  if js == nil or "externalDocs" notin js:
    return
  for field in ["description", "url"]:
    var comment = js["externalDocs"].pluckString(field)
    if comment.isSome:
      node.add newCommentStmtNode(comment.get)

proc maybeDeprecate(name: NimNode; params: seq[NimNode]; body: NimNode;
                    deprecate: bool): NimNode =
  ## make a proc and maybe deprecate it
  if deprecate:
    var pragmas = newNimNode(nnkPragma)
    pragmas.add ident"deprecated"
    result = newProc(name, params, body, pragmas = pragmas)
  else:
    result = newProc(name, params, body)

proc get(parameters: Parameters; location: ParameterIn; name: string; mode: StringTableMode): Option[Parameter] =
  ## get a parameter from a parameter list using location and string;
  ## the mode parameter is identical to that for strtabs, allowing you to
  ## specify the type of identifier comparison to use for detecting equality
  var sane: string
  if mode == modeStyleInsensitive:
    let sanitized = name.sanitizeIdentifier
    if sanitized.isSome:
      sane = sanitized.get
    else:
      warning "unable to sanitize parameter name `" & name & "`"
      return
  for param in parameters.forLocation(location):
    case mode
    of modeCaseSensitive:
      if param.name == name:
        return some(param)
    of modeCaseInsensitive:
      if param.name.toLowerAscii == name.toLowerAscii:
        return some(param)
    of modeStyleInsensitive:
      var saneparam = param.name.sanitizeIdentifier
      if saneparam.isSome and saneparam.get == sane:
        return some(param)

proc makeUrl(path: PathItem; op: Operation): NimNode =
  ## make a proc that composes a url for the call given a json path object
  let
    name = op.urlname
    pathObj = ident"path"
    queryObj = ident"query"
    hydrated = ident"hydrated"
    hydrateProc = path.generator.hydratePath
    route = ident"route"
    base = ident"base"
    host = ident"host"
    protocol = ident"protocol"
    bracket = newNimNode(nnkBracket)
    inputs = newCall(path.generator.queryString, queryObj)
  var
    body = newStmtList()

  body.add quote do:
    result.scheme = $`protocol`
    result.hostname = `host`
    result.query = $`inputs`

  if not path.path.isTemplate:
    # the path doesn't take take any variables; warn if the schema does
    for param in op.parameters.forLocation(InPath):
      assert false, $op & " has param " & $param & " but path isn't a template"
    body.add quote do:
      result.path = `base` & `route`
  else:
    let
      parsed = path.path.parseTemplate
      segments = ident"segments"
    if path.path.isTemplate:
      body.add quote do:
        assert `pathObj` != nil, "path is required to populate template"

    # add some assertions
    for segment in parsed.segments:
      if segment.kind != VariableSegment:
        continue
      var
        gotParam = op.parameters.get(InPath, $segment, modeStyleInsensitive)
        varname = newStrLitNode($segment)
        msg = newStrLitNode("`" & $segment & "` is a required path parameter")
      if gotParam.isNone:
        warning "path template references an unknown parameter `" & $segment & "`"
        continue
      body.add quote do:
        assert `varname` in `pathObj`, `msg`

    # construct a list of segments we'll use to hydrate the path
    for segment in parsed.segments:
      var par = newPar([newColonExpr(ident"kind", newIdentNode($segment.kind)),
                        newColonExpr(ident"value", newStrLitNode(segment.value))])
      bracket.add par
    body.add newConstStmt(segments, bracket.prefix("@"))

    # invoke the hydration and bomb if it failed
    body.add newVarStmt(hydrated, newCall(hydrateProc, pathObj, segments))
    body.add quote do:
      if `hydrated`.isNone:
        raise newException(ValueError, "unable to fully hydrate path")
      result.path = `base` & `hydrated`.get

  var params = @[ident"Uri"]
  params.add newIdentDefs(protocol, ident"Scheme")
  params.add newIdentDefs(host, ident"string")
  params.add newIdentDefs(base, ident"string")
  params.add newIdentDefs(route, ident"string")
  params.add newIdentDefs(pathObj, ident"JsonNode")
  params.add newIdentDefs(queryObj, ident"JsonNode")
  result = newProc(name, params, body)

proc locationParamDefs(op: Operation; nillable: bool): seq[NimNode] =
  ## produce a list of name/value parameters for each location
  for location in ParameterIn.low..ParameterIn.high:
    var locIdent = newIdentNode($location)
    # we require all locations for signature reasons
    result.add locIdent.toJsonParameter(required=not nillable)

proc makeCallWithLocationInputs(generator: var Generator; op: Operation): Option[NimNode] =
  ## a call that gets passed JsonNodes for each parameter section
  let
    name = newExportedIdentNode("call")
    validIdent = ident"valid"
    callName = genSym(ident="call")
    output = ident"result"
  var
    content: NimNode
    validatorParams: seq[NimNode]
    validatorProc = newDotExpr(callName, ident"validator")
    body = newStmtList()

  # add documentation if available
  if op.description != "":
    body.add newCommentStmtNode(op.description & "\n")
  body.maybeAddExternalDocs(op.js)

  for location in ParameterIn.low..ParameterIn.high:
    validatorParams.add newIdentNode($location)

  var validatorCall = validatorProc.newCall(validatorParams)
  body.add newLetStmt(validIdent, validatorCall)
  var
    urlProc = newDotExpr(callName, ident"url")
    urlHost = newDotExpr(callName, ident"host")
    urlBase = newDotExpr(callName, ident"base")
    urlRoute = newDotExpr(callName, ident"route")
    scheme = ident"scheme"
    protocol = newDotExpr(scheme, ident"get")
    path = newCall(newDotExpr(validIdent, ident"getOrDefault"),
                   newStrLitNode("path"))
    query = newCall(newDotExpr(validIdent, ident"getOrDefault"),
                   newStrLitNode("query"))
  if InBody in op.parameters.forms:
    content = newCall(newDotExpr(validIdent, ident"getOrDefault"),
                                 newStrLitNode("body"))
  else:
    content = newNilLit()

  body.add newLetStmt(scheme, newDotExpr(callName, ident"pickScheme"))
  body.add quote do:
    if `scheme`.isNone:
      raise newException(IOError, "unable to find a supported scheme")
  body.add newLetStmt(ident"url", newCall(urlProc, protocol, urlHost,
                                          urlBase, urlRoute, path, query))
  let heads = newCall(newDotExpr(validIdent,
                                 ident"getOrDefault"),
                      newStrLitNode("header"))
  if generator.recallable == nil:
    body.add newAssignment(output, newCall(ident"newRecallable", callName,
                                           ident"url", heads, content))
  else:
    body.add newAssignment(output, newCall(generator.recallable, callName,
                                           ident"url", validIdent))

  var params = @[ident"Recallable"]
  params.add newIdentDefs(callName, op.typename)
  params &= op.locationParamDefs(nillable=false)
  result = some(maybeDeprecate(name, params, body, deprecate=op.deprecated))

proc makeValidator(op: Operation; name: NimNode; root: JsonNode): Option[NimNode] =
  ## create a proc to validate and compose inputs for a given call
  let
    output = ident"result"
    section = ident"section"
  var
    body = newStmtList()

  # add documentation if available
  if op.description != "":
    body.add newCommentStmtNode(op.description & "\n")
  body.maybeAddExternalDocs(op.js)

  # all of these procs need all sections for consistency
  body.add quote do:
    var `section`: JsonNode

  body.add quote do:
    `output` = newJObject()

  for location in ParameterIn.low..ParameterIn.high:
    var
      required: bool
      loco = $location
      locIdent = newIdentNode(loco)
    required = false
    if location in op.parameters.forms:
      body.add newCommentStmtNode("parameters in `" & loco & "` object:")
      for param in op.parameters.forLocation(location):
        body.add param.documentation(Json, root)

    # the body IS the section, so don't bother creating a JObject for it
    if location != InBody:
      body.add quote do:
        `section` = newJObject()

    for param in op.parameters.forLocation(location):
      var
        default = op.defaultNode(param, root)
      if param.kind.isNone:
        warning "failure to infer type for parameter " & $param
        return
      if not required:
        required = required or param.required
        if required:
          var msg = loco & " argument is necessary"
          if location != InBody:
            msg &= " due to required `" & param.name & "` field"
          body.add quote do:
            assert `locIdent` != nil, `msg`
      body.add param.sectionParameter(param.kind.get.major, section, default=default)

    if location == InBody:
      # just leave the body out if it's undefined (as a signal)
      body.add quote do:
        if `locIdent` != nil:
          `output`.add `loco`, `locIdent`
    else:
      # if it's not a body, we don't need to check if it's nil
      body.add quote do:
        `output`.add `loco`, `section`

  var params = @[ident"JsonNode"]
  #params.add newIdentDefs(callName, callType)
  params &= op.locationParamDefs(nillable=false)
  result = some(maybeDeprecate(name, params, body, deprecate=op.deprecated))

proc usesJsonWhenNative(param: Parameter): bool =
  ## simple test to see if a parameter should use a json type
  if param.location == InBody:
    result = true
  elif param.kind.get.major notin {JBool, JInt, JFloat, JString}:
    result = true

proc namedParamDefs(op: Operation; forms: set[ParameterIn]): seq[NimNode] =
  ## produce a list of name/value parameters per each operation input
  # add required params first,
  for param in op.parameters:
    # the user may want to skip this section
    if param.location notin forms:
      continue
    if param.requiresPassedInput:
      var
        sane = param.saneName
        saneIdent = sane.stropIfNecessary
        major = param.kind.get.major
      if param.usesJsonWhenNative:
        if major == JNull:
          warning $param & " is a required JNull; we'll insert it later..."
          continue
        result.add saneIdent.toJsonParameter(param.required)
      else:
        result.add saneIdent.toNativeParameter(major, param.required,
                                               default=param.default)
  # then add optional params
  for param in op.parameters:
    # the user may want to skip this section
    if param.location notin forms:
      continue
    if not param.requiresPassedInput:
      var
        sane = param.saneName
        saneIdent = sane.stropIfNecessary
        major = param.kind.get.major
      if param.usesJsonWhenNative:
        result.add saneIdent.toJsonParameter(param.required)
      else:
        result.add saneIdent.toNativeParameter(major, param.required,
                                               default=param.default)

proc makeCallWithNamedArguments(generator: var Generator; op: Operation): Option[NimNode] =
  ## create a proc to validate and compose inputs for a given call
  let
    name = newExportedIdentNode("call")
    callName = genSym(ident="call")
    callType = op.typename
    output = ident"result"
  var
    validatorParams: seq[NimNode]
    sectionedProc = newDotExpr(callName, ident"call")
    body = newStmtList()
    sections = newTable[ParameterIn, NimNode]()

  # add documentation if available
  body.add newCommentStmtNode(op.saneName)
  if op.description != "":
    body.add newCommentStmtNode(op.description)
  body.maybeAddExternalDocs(op.js)

  # document the parameters
  for param in op.parameters:
    # the user may want to skip this section
    if param.location notin generator.forms:
      continue
    if param.usesJsonWhenNative:
      body.add param.documentation(Json, generator.js, name=param.saneName)
    else:
      body.add param.documentation(Native, generator.js, name=param.saneName)
  for location in ParameterIn.low..ParameterIn.high:
    # we may just be skipping all of this section...
    if location notin generator.forms:
      validatorParams.add newNilLit()
      continue

    # look for the parameters in order to setup new JObjects
    block found:
      for param in op.parameters.forLocation(location):
        var section = genSym(ident= $location)
        sections[location] = section
        validatorParams.add section
        body.add newVarStmt(section, newCall(ident"newJObject"))
        break found
      validatorParams.add newNilLit()
  var validatorCall = sectionedProc.newCall(validatorParams)

  # assert proper parameter types and/or set defaults
  for param in op.parameters:
    # the user may want to skip this section
    if param.location notin generator.forms:
      continue
    var
      insane = param.name
      sane = param.saneName
      saneIdent = sane.stropIfNecessary
      section = sections[param.location]
      #sectionadd = newDotExpr(section, ident"add")
      errmsg: string
    if param.kind.isNone:
      warning "failure to infer type for parameter " & $param
      return
    errmsg = "expected " & $param.kind.get.major & " for `" & sane & "` but received "
    for clash in op.parameters.nameClashes(param):
      warning "identifier clash in proc arguments: " & $clash.location &
        "-`" & clash.name & "` versus " & $param.location & "-`" &
        param.name & "`"
      return
    if param.usesJsonWhenNative:
      if param.location == InBody:
        body.add quote do:
          if `saneIdent` != nil:
            `section` = `saneIdent`
      else:
        body.add quote do:
          if `saneIdent` != nil:
            `section`.add `insane`, `saneIdent`
    else:
      var rhs = param.kind.get.major.instantiateWithDefault(saneIdent)
      body.add newCall(ident"add", section, newStrLitNode(insane), rhs)

  body.add newAssignment(output, validatorCall)

  var
    params = @[ident"Recallable"]
  params.add newIdentDefs(callName, callType)
  params &= op.namedParamDefs(generator.forms)
  result = some(maybeDeprecate(name, params, body, deprecate=op.deprecated))

proc makeCallType(generator: Generator; path: PathItem; op: Operation): NimNode =
  let
    saneType = op.typename
    oac = generator.roottype
  result = quote do:
    type
      `saneType` = ref object of `oac`

proc makeCallVar(generator: Generator; path: PathItem; op: Operation): NimNode =
  ## produce an instantiated call object for export
  let
    sane = op.saneName
    meth = $op.meth
    methId = newIdentNode("HttpMethod.Http" & meth.capitalizeAscii)
    saneCall = newExportedIdentNode(sane)
    saneType = op.typename
    validId = op.prepname
    urlId = op.urlname
    base = path.basePath
    host = path.host
    route = path.path
    schemes = generator.schemes.toNimNode

  result = quote do:
    var `saneCall` = `saneType`(name: `sane`, meth: `methId`, host: `host`,
                                route: `route`, validator: `validId`,
                                base: `base`, url: `urlId`, schemes: `schemes`)

proc newOperation(path: PathItem; meth: HttpOpName; root: JsonNode; input: JsonNode): Operation =
  ## create a new operation for a given http method on a given path
  var
    response: Response
    js = root.pluckRefJson(input)
    documentation = input.pluckString("description")
  if js == nil:
    js = input
  # if the ref has a description, use that if needed
  elif documentation.isNone:
    documentation = input.pluckString("description")
  result = Operation(ok: false, meth: meth, path: path, js: js)
  if documentation.isSome:
    result.description = documentation.get
  result.operationId = js.getOrDefault("operationId").getStr
  if result.operationId == "":
    var msg = "operationId not defined for " & toUpperAscii($meth)
    if path.path == "":
      msg = "empty path and " & msg
      error msg
      return
    else:
      msg = msg & " on `" & path.path & "`"
      warning msg
      let sane = result.saneName
      warning "invented operation name `" & sane & "`"
      result.operationId = sane
  let sane = result.saneName
  result.typename = genSym(ident="Call_" & sane.capitalizeAscii)
  result.prepname = genSym(ident="validate_" & sane.capitalizeAscii)
  result.urlname = genSym(ident="url_" & sane.capitalizeAscii)
  if "responses" in js:
    for status, resp in js["responses"].pairs:
      response = root.newResponse(status, resp)
      if response.ok:
        result.responses.add response
      else:
        warning "bad response:\n" & resp.pretty

  result.parameters.init()
  # inherited parameters from the PathItem
  for parameter in path.parameters:
    var badadd = result.parameters.safeAdd(parameter, sane)
    if badadd.isSome:
      warning badadd.get
      result.parameters.add parameter
  # parameters for this particular http method
  if "parameters" in js:
    for parameter in root.readParameters(js["parameters"]):
      var badadd = result.parameters.safeAdd(parameter, sane)
      if badadd.isSome:
        warning badadd.get
        result.parameters.add parameter

  result.ast = newStmtList()

  var generator = path.generator

  # start with the call type
  result.ast.add generator.makeCallType(path, result)

  # add a routine to convert a path object into a url
  result.ast.add path.makeUrl(result)

  # if we don't have a validator, we cannot support the operation at all
  let validator = result.makeValidator(result.prepname, root)
  if validator.isNone:
    warning "unable to compose validator for `" & sane & "`"
    return
  result.ast.add validator.get

  # if we don't have locations, we cannot support the operation at all
  let locations = generator.makeCallWithLocationInputs(result)
  if locations.isNone:
    warning "unable to compose call for `" & sane & "`"
    return
  result.ast.add locations.get

  # we use the call type to make our call() operation with named args
  let namedArgs = generator.makeCallWithNamedArguments(result)
  if namedArgs.isSome:
    result.ast.add namedArgs.get

  # finally, add the call variable that the user hooks to
  result.ast.add path.generator.makeCallVar(path, result)
  result.ok = true

proc newPathItem(gen: Generator; path: string; input: JsonNode): PathItem =
  ## create a PathItem result for a parsed node
  let root = gen.js
  var op: Operation
  result = PathItem(ok: false, generator: gen, path: path, js: input)
  if root != nil and root.kind == JObject and "basePath" in root:
    if root["basePath"].kind == JString:
      result.basePath = root["basePath"].getStr
  if root != nil and root.kind == JObject and "host" in root:
    if root["host"].kind == JString:
      result.host = root["host"].getStr
  if input == nil or input.kind != JObject:
    error "unimplemented path item input:\n" & input.pretty
    return
  if "$ref" in input:
    error "path item $ref is unimplemented:\n" & input.pretty
    return

  # record default parameters for the path
  if "parameters" in input:
    result.parameters = root.readParameters(input["parameters"])

  # look for operation names in the input
  for opName in HttpOpName:
    if $opName notin input:
      continue
    op = result.newOperation(opName, root, input[$opName])
    if not op.ok:
      warning "unable to parse " & $opName & " on " & path
      continue
    result.operations[$opName] = op
  result.ok = true

iterator paths(generator: Generator; ftype: FieldTypeDef): PathItem =
  ## yield path items found in the given node
  let root = generator.js
  var
    schema: Schema
    pschema: Schema = nil

  assert ftype.kind == Complex, "malformed schema: " & $ftype.schema

  while "paths" in ftype.schema:
    # make sure our schema is sane
    if ftype.schema["paths"].kind == Complex:
      pschema = ftype.schema["paths"].schema
    else:
      error "malformed paths schema: " & $ftype.schema["paths"]
      break

    # make sure our input is sane
    if root == nil or root.kind != JObject:
      warning "missing or invalid json input: " & $root
      break
    if "paths" notin root or root["paths"].kind != JObject:
      warning "missing or invalid paths in input: " & $root["paths"]
      break

    # find a good schema definition for ie. /{name}
    for k, v in pschema.pairs:
      if not k.startsWith("/"):
        warning "skipped invalid path: `" & k & "`"
        continue
      schema = v.schema
      break

    # iterate over input and yield PathItems per each node
    for k, v in root["paths"].pairs:
      # spec says valid paths should start with /
      if not k.startsWith("/"):
        if not k.toLower.startsWith("x-"):
          warning "unrecognized path: " & k
        continue
      yield generator.newPathItem(k, v)
    break

proc prefixedPluck(js: JsonNode; field: string; indent=0): string =
  result = indent.spaces & field & ": "
  result &= js.pluckString(field).get("(not provided)") & "\n"

proc renderLicense(js: JsonNode): string =
  ## render a license section for the preamble
  result = "license:"
  if js == nil:
    return result & " (not provided)\n"
  result &= "\n"
  for field in ["name", "url"]:
    result &= js.prefixedPluck(field, 4)

proc renderPreface(js: JsonNode): string =
  ## produce a preamble suitable for documentation
  result = "auto-generated via openapi macro\n"
  if "info" in js:
    let
      info = js["info"]
    for field in ["title", "version", "termsOfService"]:
      result &= info.prefixedPluck(field)
    result &= info.getOrDefault("license").renderLicense
    result &= "\n" & info.pluckString("description").get("") & "\n"

proc preamble(oac: NimNode): NimNode =
  ## code common to all apis
  result = newStmtList([])

  let
    jsP = ident"js"
    kindP = ident"kind"
    requiredP = ident"required"
    defaultP = ident"default"
    queryP = ident"query"
    bodyP = ident"body"
    pathP = ident"path"
    headerP = ident"header"
    formP = ident"formData"
    vsP = ident"ValidatorSignature"
    tP = ident"t"
    createP = ident"clone"
    T = ident"T"
    #dollP = ident"`$`"
    protoP = ident"protocol"
    hostP = ident"host"
    baseP = ident"base"
    routeP = ident"route"
    SchemeP = ident"Scheme"
    schemeP = ident"scheme"
    hashP = ident"hash"
    oarcP = ident"OpenApiRestCall"

  result.add quote do:
    type
      `SchemeP` {.pure.} = enum
        Https = "https",
        Http = "http",
        Wss = "wss"
        Ws = "ws",

      `vsP` = proc (`queryP`: JsonNode = nil; `bodyP`: JsonNode = nil;
         `headerP`: JsonNode = nil; `pathP`: JsonNode = nil;
         `formP`: JsonNode = nil): JsonNode
      `oarcP` = ref object of RestCall
        validator*: `vsP`
        route*: string
        base*: string
        host*: string
        schemes*: set[Scheme]
        url*: proc (`protoP`: Scheme; `hostP`: string; `baseP`: string;
                    `routeP`: string; `pathP`: JsonNode; `queryP`: JsonNode): Uri

      # this gives the user a type to hook into for code in their macro
      `oac` = ref object of `oarcP`

    proc `hashP`(`schemeP`: Scheme): Hash {.used.} = result = hash(ord(`schemeP`))

    #proc `dollP`*(`bodyP`: `oac`): string = rest.`dollP`(`bodyP`)

    proc `createP`[`T`: `oac`](`tP`: `T`): `T` {.used.} =
      result = T(name: `tP`.name, meth: `tP`.meth, host: `tP`.host,
                 base: `tP`.base, route: `tP`.route, schemes: `tP`.schemes,
                 validator: `tP`.validator, url: `tP`.url)

    proc pickScheme(`tP`: `oac`): Option[Scheme] {.used.} =
      ## select a supported scheme from a set of candidates
      for `schemeP` in Scheme.low..Scheme.high:
        if `schemeP` notin `tP`.schemes:
          continue
        if `schemeP` in [Scheme.Https, Scheme.Wss]:
          when defined(ssl):
            return some(`schemeP`)
          else:
            continue
        return some(`schemeP`)

    proc validateParameter(`jsP`: JsonNode; `kindP`: JsonNodeKind;
      `requiredP`: bool; `defaultP`: JsonNode = nil): JsonNode =
      ## ensure an input is of the correct json type and yield
      ## a suitable default value when appropriate
      if `jsP` == nil:
        if `defaultP` != nil:
          return validateParameter(`defaultP`, `kindP`,
            required=`requiredP`)
      result = `jsP`
      if result == nil:
        assert not `requiredP`, $`kindP` & " expected; received nil"
        if `requiredP`:
          result = newJNull()
      else:
        assert `jsP`.kind == `kindP`,
          $`kindP` & " expected; received " & $`jsP`.kind

  # i'm getting lazy
  result.add parseStmt """
type
  KeyVal {.used.} = tuple[key: string; val: string]
  PathTokenKind = enum ConstantSegment, VariableSegment
  PathToken = tuple
    kind: PathTokenKind
    value: string
  """
  result.add parseStmt """
proc queryString(query: JsonNode): string =
  var qs: seq[KeyVal]
  if query == nil:
    return ""
  for k, v in query.pairs:
    qs.add (key: k, val: v.getStr)
  result = encodeQuery(qs)

proc hydratePath(input: JsonNode; segments: seq[PathToken]): Option[string] =
  ## reconstitute a path with constants and variable values taken from json
  var head: string
  if segments.len == 0:
    return some("")
  head = segments[0].value
  case segments[0].kind:
  of ConstantSegment: discard
  of VariableSegment:
    if head notin input:
      return
    let js = input[head]
    if js.kind notin {JString, JInt, JFloat, JNull, JBool}:
      return
    head = $js
  var remainder = input.hydratePath(segments[1..^1])
  if remainder.isNone:
    return
  result = some(head & remainder.get)
  """

proc newGenerator*(inputfn: string; outputfn: string): Generator {.compileTime.} =
  ## create a new generator
  result = Generator(ok: false, inputfn: inputfn, outputfn: outputfn)
  result.ast = newStmtList()
  result.imports = newNimNode(nnkImportStmt)
  result.hydratePath = ident"hydratePath"
  result.queryString = ident"queryString"
  for location in ParameterIn.low .. ParameterIn.high:
    result.forms.incl location

proc init*(generator: var Generator; content: string) =
  ## initialize a generator with a string holding the json api input
  try:
    if generator.js == nil:
      generator.js = content.parseJson()
    if generator.js.kind != JObject:
      error "i was expecting a json object, but i got " &
        $generator.js.kind
  except JsonParsingError as e:
    error "error parsing the input as json: " & e.msg
  except ValueError:
    error "json parsing failed, probably due to an overlarge number"

  if "swagger" in generator.js:
    if generator.js["swagger"].getStr != "2.0":
      error "we only know how to parse openapi-2.0 atm"
    generator.schema = OpenApi2
  else:
    error "no swagger version found in the input"

  let pr = generator.schema.parseSchema(generator.js)
  if not pr.ok:
    error "schema parse error: " & pr.msg

  # setup some imports we'll want so the user doesn't need to add them
  for module in ["json", "options", "hashes", "uri"]:
    # FIXME: check to prevent dupes
    generator.imports.add newIdentNode(module)

  # add the preface so we're ready for the user to add code
  generator.ast.add newCommentStmtNode(generator.js.renderPreface)
  generator.ast.maybeAddExternalDocs(generator.js)

  # add common code
  if generator.roottype == nil:
    generator.roottype = genSym(ident="OpenApiRestCall")
  generator.ast.add generator.roottype.preamble

proc consume*(generator: var Generator; content: string) {.compileTime.} =
  ## parse a string which might hold an openapi definition

  when MAKETYPES:
    var
      parsed: ParserResult
      schema: FieldTypeDef
      typedefs: seq[FieldTypeDef]
      tree: WrappedField

  # set the default recallable factory
  if generator.recallable == nil:
    generator.imports.add ident"rest"
    generator.recallable = ident"newRecallable"
  else:
    # build the declaration for the recallable method
    let hookP = generator.recallable
    var params = @[ident"Recallable"]
    params.add newIdentDefs(ident"call", ident"OpenApiRestCall")
    params.add newIdentDefs(ident"url", ident"Uri")
    params.add newIdentDefs(ident"input", ident"JsonNode")
    var pragmas = newNimNode(nnkPragma)
    pragmas.add ident"base"
    generator.ast.add newProc(hookP, params,
      body = newEmptyNode(), procType = nnkMethodDef, pragmas = pragmas)

  while true:
    when MAKETYPES:
      tree = newBranch[FieldTypeDef, WrappedItem](anything({}), "tree")
      tree["definitions"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "definitions")
      tree["parameters"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "parameters")
      if "definitions" in generator.js:
        let
          definitions = generator.schema["definitions"]
        typedefs = toSeq(definitions.schema.values)
        assert typedefs.len == 1, "dunno what to do with " &
          $typedefs.len & " definitions schemas"
        schema = typedefs[0]
        var
          typeSection = newNimNode(nnkTypeSection)
          deftree = tree["definitions"]
        for k, v in generator.js["definitions"]:
          parsed = v.parsePair(k, schema)
          if not parsed.ok:
            error "parse error on definition for " & k
            break
          for wrapped in parsed.ftype.wrapOneType(k, v):
            if wrapped.name in deftree:
              warning "not redefining " & wrapped.name
              continue
            case wrapped.kind:
            of Primitive:
              deftree[k] = newLeaf(parsed.ftype, k, wrapped)
            of Complex:
              deftree[k] = newBranch[FieldTypeDef, WrappedItem](parsed.ftype, k)
            else:
              error "can't grok " & k & " of type " & $wrapped
          var onedef = schema.makeTypeDef(k, input=v)
          if onedef.ok:
            typeSection.add onedef.ast
          else:
            warning "unable to make typedef for " & k
          generator.ast.add typeSection

    # determine which schemes we'll support
    if "schemes" notin generator.js or generator.js["schemes"].kind != JArray:
      error "no schemes defined"
      return
    for s in generator.js["schemes"]:
      if s.kind != JString:
        error "wrong type for scheme: " & $s.kind
        return
      generator.schemes.incl parseEnum[Scheme](s.getStr)

    # add whatever we can for each operation
    for path in generator.paths(generator.schema):
      for meth, op in path.operations.pairs:
        generator.ast.add op.ast

    generator.ok = true
    break

template generate*(name: untyped; input: string; output: string; body: untyped): untyped {.dirty.} =
  ## parse input json filename and output nim target library
  import macros

  macro name(embody: untyped): untyped =
    var generator = newGenerator(inputfn= input, outputfn= output)
    let content = staticRead(generator.inputfn)
    generator.init(content)

    # the user's code runs here to tweak the generator
    body

    generator.consume(content)
    if generator.ok == false:
      error "parse error"

    if not generator.outputfn.endsWith(".nim"):
      error "i'm afraid to overwrite " & generator.outputfn
    hint "writing " & generator.outputfn
    when true:
      generator.ast.add embody
      var ast = newStmtList(generator.imports, generator.ast)
      writeFile(generator.outputfn, ast.repr)
      result = newNimNode(nnkImportStmt)
      result.add newStrLitNode(generator.outputfn)
    else:
      var ast = newStmtList(generator.imports, generator.ast)
      writeFile(generator.outputfn, ast.repr)
      var imports = newNimNode(nnkImportStmt)
      imports.add newStrLitNode(generator.outputfn)
      result = newStmtList()
      result.add imports
      result.add embody

template render*(name: typed; arbody: untyped): untyped =
  # run the macro and add the user's code to the api we output
  name(arbody)
