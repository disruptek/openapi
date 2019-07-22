#? replace(sub = "\t", by = " ")
import tables
import npeg
import strutils

proc isTemplate*(path: string): bool =
	## quickly test to see if the path may be templated
	result = true
	if path.find('{') >= path.find('}'):
		return false
	if path.find('}') == -1:
		return false

proc parseTemplate*(path: string): seq[string] =
	## parse a path and pull out the variable names
	let parser = peg "path":
		noncurly <- Print - '{' - '}'
		text <- +noncurly
		variable <- '{' * >text * '}'
		segment <- text | variable
		path <- +segment
	let parsed = parser.match(path)
	if parsed.ok:
		return parsed.captures
	raise newException(ValueError, "invalid template: " & path)

proc composePath*(path: string; variables: Table[string, string]): string =
	## create a path with variable substitution per the template, variables
	result = path
	for key, value in variables.pairs:
		var token = '{' & key & '}'
		result = result.replace(token, value)
		assert token notin result, "replace didn't replace all instances"
