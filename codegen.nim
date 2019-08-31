#? replace(sub = "\t", by = " ")
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
import typewrap

from schema2 import OpenApi2

type
	ConsumeResult* = object of RootObj
		ok*: bool
		schema*: Schema
		js*: JsonNode
		ast*: NimNode

	PathItem* = object of ConsumeResult
		path*: string
		parsed*: ParserResult
		basePath*: string
		host*: string
		operations*: Table[string, Operation]
		parameters*: Parameters

	ParameterIn = enum
		InQuery = "query"
		InBody = "body"
		InHeader = "header"
		InPath = "path"
		InData = "formData"

	Parameter = object of ConsumeResult
		name*: string
		description*: string
		required*: bool
		location*: ParameterIn
		default*: JsonNode
		source*: JsonNode

	Parameters = object
		sane: StringTableRef
		tab: Table[Hash, Parameter]
		forms: set[ParameterIn]

	Response = object of ConsumeResult
		status: string
		description: string

	Operation = object of ConsumeResult
		meth*: HttpOpName
		path*: string
		description*: string
		operationId*: string
		parameters*: Parameters
		responses*: seq[Response]
		# TODO: support this natively
		deprecated*: bool

	TypeDefResult* = object of ConsumeResult
		name: string
		comment: string
		ftype: FieldTypeDef
		wrapped: WrappedItem

	GuessTypeResult = tuple
		ok: bool
		major: JsonNodeKind
		minor: string

	WrappedField = WrappedType[FieldTypeDef, WrappedItem]
	WrappedItem = ref object
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

proc validNimIdentifier(s: string): bool =
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

proc makeTypeDef*(ftype: FieldTypeDef; name: string; input: JsonNode = nil): TypeDefResult
proc parseTypeDef(input: JsonNode): FieldTypeDef
proc parseTypeDefOrRef(input: JsonNode): NimNode

proc newExportedIdentNode(name: string): NimNode =
	## newIdentNode with an export annotation
	assert name.validNimIdentifier == true
	result = newNimNode(nnkPostfix)
	result.add newIdentNode("*")
	result.add newIdentNode(name)

proc isValidIdentifier(name: string): bool =
	## verify that the identifier has a reasonable name
	if name.startsWith("_") and name != "_":
		result = false
	elif "__" in name:
		result = false
	else:
		result = name.validNimIdentifier

proc toValidIdentifier(name: string; star=true): NimNode =
	## permute identifiers until they are valid
	if name.isValidIdentifier:
		if star:
			result = newExportedIdentNode(name)
		else:
			result = newIdentNode(name)
	else:
		result = toValidIdentifier("oa" & name.replace("__", "_"), star=star)

proc guessJsonNodeKind(name: string): JsonNodeKind =
	## map openapi type names to their json node types
	result = case name:
	of "integer": JInt
	of "number": JFloat
	of "string": JString
	of "file": JString
	of "boolean": JBool
	of "array": JArray
	of "object": JObject
	of "null": JNull
	else:
		raise newException(Defect, "unknown type: " & name)

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

proc conjugateFieldType(major: JsonNodeKind; format=""): FieldTypeDef =
	## makes a typedef given node kind and optional format;
	## (this should someday handle arbitrary formats)
	if not major.isKnownFormat(format):
		warning $major & " type has unknown format `" & format & "`"
	result = major.toFieldTypeDef

when false:
	proc conjugateFieldType(name: string; format=""): FieldTypeDef =
		let major = name.guessJsonNodeKind()
		result = major.conjugateFieldType(format=format)

converter toNimNode(ftype: FieldTypeDef): NimNode =
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
			return case kind:
			of JInt: newIdentNode("int")
			of JFloat: newIdentNode("float")
			of JString: newIdentNode("string")
			of JBool: newIdentNode("bool")
			of JNull: newNimNode(nnkNilLit)
			else:
				newCommentStmtNode("you can't create a Primitive from " & $kind)
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

proc pluckString(input: JsonNode; key: string): Option[string] =
	## a robust getter for string values in json
	if input == nil:
		return
	if input.kind != JObject:
		return
	if key notin input:
		return
	result = some(input[key].getStr)

proc pluckDescription(input: JsonNode): NimNode =
	## return a comment node for the given json
	let desc = input.pluckString("description")
	if desc.isSome:
		return newCommentStmtNode(desc.get())
	return newCommentStmtNode("(no description available)")

proc parseRefTarget(target: string): NimNode {.deprecated.} =
	## turn a $ref -> string into a nim ident node
	let templ = "#/definitions/{name}".parseTemplate()
	assert templ.ok, "you couldn't parse your own template, doofus"
	let caught = templ.match(target)
	assert caught, "our template didn't match the ref: " & target
	result = toValidIdentifier(target.split("/")[^1], star=false)

proc pluckRefJson(root: JsonNode; input: JsonNode): JsonNode =
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
		for k, v in input.pairs:
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

proc contains[T](t: tuple; v: T): bool =
	result = false
	for n in t.fields:
		if v == n:
			return true

proc defineMap(input: JsonNode): NimNode =
	## reference an existing map type or create a new one right here
	var
		target: NimNode
	assert input != nil
	assert input.kind == JObject

	let contents = (typed: "type" in input, refd: "$ref" in input)
	if false notin contents:
		# we'll let the $ref override...
		target = input.pluckRefNode()
	elif true notin contents:
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
	for def in input.objectProperties:
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
		for n in input["allOf"]:
			result = n.defineObjectOrMap()
			if result != nil:
				break
	else:
		error "missing properties or additionalProperties in object:\n" &
			input.pretty

proc parseTypeDef(input: JsonNode): FieldTypeDef =
	## convert a typedef from json; eg. we may expect to look
	## for a type="something" and/or format="something-else"
	result = input.kind.toFieldTypeDef()
	case input.kind:
	of JObject:
		if "type" in input:
			let
				major = input["type"].getStr
				#minor = input.getOrDefault("format").getStr
				kind = major.guessJsonNodeKind()
			result = kind.toFieldTypeDef()
	of JArray:
		if "items" in input:
			result.member = input["items"].parseTypeDef()
	else:
		discard

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
		#	warning "lacks `type` property:\n" & input.pretty
		if "type" in input:
			return input.parseTypeDef()
		elif "allOf" in input:
			warning "allOf poorly implemented!"
			assert input["allOf"].kind == JArray
			for n in input["allOf"]:
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

proc whine(input: JsonNode; why: string) =
	## merely complain about an irregular input
	warning why & ":\n" & input.pretty

proc guessType(js: JsonNode; root: JsonNode): GuessTypeResult =
	## guess the JsonNodeKind of a node/schema, perhaps dereferencing
	var
		major: string
		input = root.pluckRefJson(js)
	if input == nil:
		input = js
	
	case input.kind:
	of JObject:
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
			elif "allOf" in input:
				input.whine "allOf is poorly implemented"
				major = "object"
				assert input["allOf"].kind == JArray
				for n in input["allOf"]:
					input = n
					break
			else:
				# we'll return if we cannot recognize the type
				warning "no type discovered:\n" & input.pretty
				return (ok: false, major: JNull, minor: "")
		let
			format = input.getOrDefault("format").getStr
			kind = major.guessJsonNodeKind()
		result = (ok: true, major: kind, minor: format)
	else:
		result = (ok: true, major: input.kind, minor: "")

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
		if not k.ok:
			result.fail "unable to guess type of schema"
			return
		# do we need to define an object type here?
		if k.major == JObject:
			# name this object type and add the definition
			result.ast = input.defineObjectOrMap()

		# TODO: maybe we have some array code?
		#elif kind == JArray:

		else:
			# it's not an object; just figure out what it is and def it
			# create a new fieldtype, perhaps permuted by the format
			result.ftype = k.major.conjugateFieldType(format=k.minor)
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
		right: NimNode
		target = input.pluckRefNode()
		documentation = input.pluckDescription()

	if input.kind == JObject and input.len == 0:
		documentation = newCommentStmtNode(name & " lacks any type info")
		#documentation.strVal.warning
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

proc jsonKind(param: Parameter; root: JsonNode): JsonNodeKind =
	## determine the type of a parameter
	let kind = param.source.guessType(root)
	if not kind.ok:
		raise newException(ValueError, "unable to guess type:\n" & param.js.pretty)
	result = kind.major

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
	result = Parameter(ok: false, js: js)
	result.name = js["name"].getStr
	result.location = parseEnum[ParameterIn](js["in"].getStr)
	result.required = js.getOrDefault("required").getBool
	if documentation.isSome:
		result.description = documentation.get()
	result.default = js.getOrDefault("default")

	# `source` is a pointer to the JsonNode that defines the
	# format for the parameter; it can be overridden with `schema`
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
	if not id.validNimIdentifier:
		warning "bad identifier: " & id
		return
	result = some(id)

proc saneName(param: Parameter): string =
	## produce a safe identifier for the given parameter
	let id = sanitizeIdentifier(param.name, capsOkay=true)
	if id.isNone:
		error "unable to compose valid identifier for parameter `" & param.name & "`"
	result = id.get()

proc saneName(op: Operation): string =
	## produce a safe identifier for the given operation
	var attempt: seq[string]
	if op.operationId != "":
		attempt.add op.operationId
		attempt.add $op.meth & "_" & op.operationId
	# TODO: turn path /some/{var_name}/foo_bar into some_varName_fooBar?
	attempt.add $op.meth & "_" & op.path
	for name in attempt:
		var id = sanitizeIdentifier(name, capsOkay=false)
		if id.isSome:
			return id.get()
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

proc safeAdd(parameters: var Parameters; p: Parameter; prefix=""): bool =
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
		warning msg
		return false
	parameters.add p
	result = true

proc initParameters(parameters: var Parameters) =
	## prepare a parameter container to accept parameters
	parameters.sane = newStringTable(modeStyleInsensitive)
	parameters.tab = initTable[Hash, Parameter]()
	parameters.forms = {}

proc readParameters(root: JsonNode; js: JsonNode): Parameters =
	## parse parameters out of an arbitrary JsonNode
	result.initParameters()
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
		result = newIdentDefs(name, newIdentNode("JsonNode"))
	else:
		result = newIdentDefs(name, newIdentNode("JsonNode"), newNilLit())

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
			i = newIdentNode("jarray")
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

proc shortRepr(js: JsonNode): string =
	## render a JInt(3) as "JInt(3)"; will puke on arrays/objects/null
	result = $js.kind & "(" & $js & ")"

proc defaultNode(op: Operation; param: Parameter; root: JsonNode): NimNode =
	## generate nim to instantiate the default value for the parameter
	var useDefault = false
	let
		jsKind = param.jsonKind(root)
		sane = param.saneName
	if param.default != nil:
		if jsKind == param.default.kind:
			useDefault = true
		else:
			# provide a warning if the default type doesn't match the input
			warning "`" & sane & "` parameter in `" & $op.operationId &
				"` is " & $jsKind & " but the default is " &
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

proc documentation(p: Parameter; root: JsonNode): NimNode =
	var
		docs = "  " & p.name & ": " & $p.jsonKind(root)
	if p.required:
		docs &= " (required)"
	if p.description != "":
		docs &= "\n" & spaces(2 + p.name.len) & ": "
		docs &= p.description
	result = newCommentStmtNode(docs)

proc makeProcWithLocationInputs(op: Operation; name: string; root: JsonNode): NimNode =
	let
		opIdent = newExportedIdentNode("prepare" & name.capitalizeAscii)
		validIdent = newIdentNode("valid")
		inputsIdent = newIdentNode("result")
		sectionIdent = newIdentNode("section")
	var
		pragmas = newNimNode(nnkPragma)
		opBody = newStmtList()
		opJsParams: seq[NimNode] = @[newIdentNode("JsonNode")]
	
	if op.deprecated:
		pragmas.add newIdentNode("deprecated")

	# add documentation if available
	if op.description != "":
		opBody.add newCommentStmtNode(op.description & "\n")

	if op.parameters.len > 0:
		opBody.add quote do:
			var
				`validIdent`: JsonNode
				`sectionIdent`: JsonNode

	opBody.add quote do:
		`inputsIdent` = newJObject()

	for location in op.parameters.forms:
		var
			required: bool
			loco = $location
			locIdent = newIdentNode(loco)
		required = false
		opBody.add newCommentStmtNode("parameters in `" & loco & "` object:")
		for param in op.parameters.forLocation(location):
			opBody.add param.documentation(root)
		opJsParams.add locIdent.toJsonParameter(false)

		opBody.add quote do:
			`sectionIdent` = newJObject()
		for param in op.parameters.forLocation(location):
			var
				name = param.name
				defNode = op.defaultNode(param, root)
				jsKind = param.jsonKind(root)
				kindIdent = newIdentNode($jsKind)
				reqIdent = newIdentNode($param.required)
			if not required:
				required = required or param.required
				if required:
					let msg = loco & " argument is required due to required `" &
						param.name & "` field"
					opBody.add quote do:
						assert `locIdent` != nil, `msg`
			opBody.add quote do:
				`validIdent` = `locIdent`.getOrDefault(`name`)
				`validIdent` = validateParameter(valid, `kindIdent`,
					required= `reqIdent`, default= `defNode`)
				if `validIdent` != nil:
					`sectionIdent`.add `name`, `validIdent`
		opBody.add quote do:
			`inputsIdent`.add `loco`, `sectionIdent`

	if pragmas.len > 0:
		result = newProc(opIdent, opJsParams, opBody, pragmas = pragmas)
	else:
		result = newProc(opIdent, opJsParams, opBody)

proc makeProcWithNamedArguments(op: Operation; name: string; root: JsonNode): NimNode =
	let
		opIdent = newExportedIdentNode(name)
		validIdent = newIdentNode("valid")
	var
		pragmas = newNimNode(nnkPragma)
		opBody = newStmtList()
		opJsParams: seq[NimNode] = @[newIdentNode("JsonNode")]
	
	if op.deprecated:
		pragmas.add newIdentNode("deprecated")

	# add documentation if available
	if op.description != "":
		opBody.add newCommentStmtNode(op.description & "\n")

	# add required params first,
	for param in op.parameters:
		var
			sane = param.saneName
			saneIdent = newIdentNode(sane)
		opBody.add param.documentation(root)
		if param.required:
			opJsParams.add saneIdent.toJsonParameter(param.required)

	# then add optional params
	for param in op.parameters:
		var
			sane = param.saneName
			saneIdent = newIdentNode(sane)
		if not param.required:
			opJsParams.add saneIdent.toJsonParameter(param.required)

	let inputsIdent = newIdentNode("result")
	if op.parameters.len > 0:
		opBody.add quote do:
			var `validIdent`: JsonNode
	opBody.add quote do:
		`inputsIdent` = newJObject()

	# assert proper parameter types and/or set defaults
	for param in op.parameters:
		var
			insane = param.name
			sane = param.saneName
			saneIdent = newIdentNode(sane)
			jsKind = param.jsonKind(root)
			kindIdent = newIdentNode($jsKind)
			reqIdent = newIdentNode($param.required)
			useDefault = false
			defNode: NimNode
			errmsg: string
		errmsg = "expected " & $jsKind & " for `" & sane & "` but received "
		for clash in op.parameters.nameClashes(param):
			error "identifier clash in proc arguments: " & $clash.location & "-`" &
			clash.name & "` versus " & $param.location & "-`" & param.name & "`"

		if param.default != nil:
			if jsKind == param.default.kind:
				useDefault = true
			else:
				# provide a warning if the default type doesn't match the input
				warning "`" & sane & "` parameter in `" & $op.operationId &
					"` is " & $jsKind & " but the default is " &
					param.default.shortRepr & "; omitting code to supply the default"

		if useDefault:
			# set default value for input
			try:
				defNode = param.default.toNewJsonNimNode
			except ValueError as e:
				error e.msg & ":\n" & param.default.pretty
		else:
			defNode = newNilLit()

		opBody.add quote do:
			`validIdent` = validateParameter(`saneIdent`, `kindIdent`,
				required=`reqIdent`, default=`defNode`)
		if param.required:
			opBody.add quote do:
				`inputsIdent`.add(`insane`, `validIdent`)
		else:
			opBody.add quote do:
				if `validIdent` != nil:
					`inputsIdent`.add(`insane`, `validIdent`)

	if pragmas.len > 0:
		result = newProc(opIdent, opJsParams, opBody, pragmas = pragmas)
	else:
		result = newProc(opIdent, opJsParams, opBody)

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
	result = Operation(ok: false, meth: meth, path: path.path, js: js)
	if documentation.isSome:
		result.description = documentation.get()
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
	if "responses" in js:
		for status, resp in js["responses"].pairs:
			response = root.newResponse(status, resp)
			if response.ok:
				result.responses.add response
			else:
				warning "bad response:\n" & resp.pretty
	
	result.parameters.initParameters()
	# inherited parameters from the PathItem
	for parameter in path.parameters:
		if not result.parameters.safeAdd(parameter, sane):
			error "fatal!"
	# parameters for this particular http method
	if "parameters" in js:
		for parameter in root.readParameters(js["parameters"]):
			if not result.parameters.safeAdd(parameter, sane):
				error "fatal!"

	result.ast = newStmtList()
	result.ast.add result.makeProcWithNamedArguments(sane, root)
	result.ast.add result.makeProcWithLocationInputs(sane, root)
	result.ok = true

proc newPathItem(root: JsonNode; path: string; input: JsonNode): PathItem =
	## create a PathItem result for a parsed node
	var
		op: Operation
	result = PathItem(ok: false, path: path, js: input)
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

iterator paths(root: JsonNode; ftype: FieldTypeDef): PathItem =
	## yield path items found in the given node
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
			yield root.newPathItem(k, v)
		break

iterator wrapOneType(ftype: FieldTypeDef; name: string; input: JsonNode): WrappedItem {.deprecated.} =
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

proc consume(content: string): ConsumeResult {.compileTime.} =
	## parse a string which might hold an openapi definition
	when false:
		var
			parsed: ParserResult
			schema: FieldTypeDef
			typedefs: seq[FieldTypeDef]
			tree: WrappedField

	result = ConsumeResult(ok: false)

	while true:
		try:
			result.js = content.parseJson()
			if result.js.kind != JObject:
				error "i was expecting a json object, but i got " &
					$result.js.kind
				break
		except JsonParsingError as e:
			error "error parsing the input as json: " & e.msg
			break
		except ValueError:
			error "json parsing failed, probably due to an overlarge number"
			break

		if "swagger" in result.js:
			if result.js["swagger"].getStr != "2.0":
				error "we only know how to parse openapi-2.0 atm"
				break
			result.schema = OpenApi2
		else:
			error "no swagger version found in the input"
			break

		let pr = result.schema.parseSchema(result.js)
		if not pr.ok:
			break

		# add some imports we'll want
		# FIXME: make sure we need tables before importing it
		let imports = quote do:
			import json
			
		result.ast = newStmtList []
		result.ast.add newCommentStmtNode(result.js.renderPreface)
		result.ast.add imports

		# deprecated
		when false:
			tree = newBranch[FieldTypeDef, WrappedItem](anything({}), "tree")
			tree["definitions"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "definitions")
			tree["parameters"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "parameters")
			if "definitions" in result.js:
				let
					definitions = result.schema["definitions"]
				typedefs = toSeq(definitions.schema.values)
				assert typedefs.len == 1, "dunno what to do with " &
					$typedefs.len & " definitions schemas"
				schema = typedefs[0]
				var
					typeSection = newNimNode(nnkTypeSection)
					deftree = tree["definitions"]
				for k, v in result.js["definitions"]:
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
							error "can't grok " & k & " of type " & $wrapped.kind
					var onedef = schema.makeTypeDef(k, input=v)
					if onedef.ok:
						typeSection.add onedef.ast
					else:
						warning "unable to make typedef for " & k
					result.ast.add typeSection

		let
			jsP = newIdentNode("js")
			kindP = newIdentNode("kind")
			requiredP = newIdentNode("required")
			defaultP = newIdentNode("default")
		result.ast.add quote do:
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

		for path in result.js.paths(result.schema):
			for meth, op in path.operations.pairs:
				result.ast.add op.ast

		result.ok = true
		break

macro openapi*(inputfn: static[string]; outputfn: static[string]=""; body: typed): untyped =
	## parse input json filename and output nim target library
	# TODO: this should get renamed to openApiClient to make room for openApiServer
	let content = staticRead(`inputfn`)
	var consumed = content.consume()
	if consumed.ok == false:
		error "openapi: unable to parse " & `inputfn`
		return
	result = consumed.ast

	if `outputfn` == "":
		hint "openapi: (provide a filename to save API source)"
	else:
		hint "openapi: writing output to " & `outputfn`
		writeFile(`outputfn`, result.repr)
		result = quote do:
			import `outputfn`
			`body`
