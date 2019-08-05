#? replace(sub = "\t", by = " ")
import json
import tables

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
		result = FieldTypeDef(kind: Complex, kinds: {JObject}, pattern: pattern, required: required,
			schema: schema)
	of Anything:
		result = FieldTypeDef(kind: Anything, kinds: {}, pattern: pattern, required: required)
	of List:
		result = FieldTypeDef(kind: List, kinds: {JArray}, pattern: pattern, required: required,
			member: member)
	of Either:
		result = FieldTypeDef(kind: Either, kinds: {}, pattern: pattern, required: required)
	#else:
	#	raise newException(Defect, "unimplemented " & $kind & " field")

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
	result = Complex.newFieldTypeDef(schema=c)

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
