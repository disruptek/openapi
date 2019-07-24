#? replace(sub = "\t", by = " ")
import tables
import npeg
import strutils

type
	TemplateParse* = object
		constants*: seq[string]
		variables*: seq[string]
		path*: string
		ok*: bool

proc isTemplate*(path: string): bool =
	## quickly test to see if the path may be templated
	let
		a = path.find('{')
		b = path.find('}')
	return a < b and a > -1

proc parseTemplate*(path: string): TemplateParse =
	## parse a path and pull out the variable names and constants
	if not path.isTemplate:
		return TemplateParse(ok: false, path: path)
	result = TemplateParse(ok: true, path: path)
	let variables = peg "path":
		noncurly <- Print - '{' - '}'
		text <- +noncurly
		variable <- '{' * >text * '}'
		segment <- text | variable
		path <- +segment
	var parsed = variables.match(path)
	if not parsed.ok:
		return TemplateParse(ok: false, path: path)
	result.variables = parsed.captures
	let constants = peg "path":
		noncurly <- Print - '{' - '}'
		text <- +noncurly
		variable <- '{' * text * '}'
		segment <- >text | variable
		path <- +segment
	parsed = constants.match(path)
	if not parsed.ok:
		return TemplateParse(ok: false, path: path)
	result.constants = parsed.captures

proc headrest(list: seq[string]):
	tuple[head: string, tail: seq[string]] {.inline.} =
	assert list.len >= 1, "list empty; ran outta items?"
	result = (head: list[0], tail: list[1..^1])

proc match*(source: string; path: string;
	constants: seq[string]; variables: seq[string]): bool =
	## unsatisfied path variables/constants are an error
	var
		head: string
		tail: seq[string]
		index: int

	# if we have empty source
	if source.len == 0:
		# we're done one way or another
		return path.len == 0

	# if we're looking at a constant segment
	if source[0] != '{':
		(head, tail) = constants.headrest
		assert source.find(head) == 0, "source doesn't match parse"
		assert path.find(head) == 0, "path doesn't match source variable"
		return match(source[head.len..^1], path[head.len..^1], tail, variables)

	# source holds a variable
	(head, tail) = variables.headrest
	head = '{' & head & '}'
	assert source.find(head) == 0, "source doesn't match parse"
	if constants.len == 0:
		# we cannot disambiguate two adjacent variables,
		# but make sure we can associate variable->value
		assert tail.len == 0, "cannot disambiguate multiple variables"
		# it seems that the variable be empty in some inputs
		#assert path.len > 0, "insufficient input to fill variable"
		# any remaining input is part of the sole remaining variable
		return true
	let (fhead, ftail) = constants.headrest
	discard ftail # noqa
	index = path.find(fhead)
	assert index != -1, "path doesn't match source variable"
	return match(source[head.len..^1], path[index..^1], constants, tail)

proc match*(tp: TemplateParse; input: string): bool =
	## unsatisfied path variables/constants are an error
	result = tp.path.match(input, tp.constants, tp.variables)

proc composePath*(path: string; variables: Table[string, string]): string =
	## create a path with variable substitution per the template, variables
	result = path
	for key, value in variables.pairs:
		var token = '{' & key & '}'
		result = result.replace(token, value)
		assert token notin result, "replace didn't replace all instances"
