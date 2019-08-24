#? replace(sub = "\t", by = " ")
import tables
import strtabs
import strformat

type
	WrappedTypeObjKind* = enum Leaf, Limb, Branch
	WrappedTypeObj[S, V] = object
		name*: string
		schema: S
		case kind*: WrappedTypeObjKind
		of Leaf:
			value: V
		of Limb:
			elems: seq[V]
		of Branch:
			keys: StringTableRef
			values: TableRef[string, WrappedType[S, V]]
	WrappedType*[S, V] = ref WrappedTypeObj[S, V]

proc newLeaf*[S, V](schema: S; name: string; value: V): WrappedType[S, V] =
	result = WrappedType[S, V](kind: Leaf, name: name, schema: schema)
	result.value = value

proc newLimb*[S, V](schema: S; name: string; list: seq[V]= @[]): WrappedType[S, V] =
	result = WrappedType[S, V](kind: Limb, name: name, schema: schema)
	result.elems = list

proc newBranch*[S, V](schema: S; name: string): WrappedType[S, V] =
	result = WrappedType[S, V](kind: Branch, name: name, schema: schema)
	result.keys = newStringTable(modeStyleInsensitive)
	new(result.values)

iterator values*[S, V](wrapped: WrappedType[S, V]): WrappedType[S, V] =
	case wrapped.kind:
	of Branch:
		for value in wrapped.values.values:
			yield value
	else:
		raise newException(Defect, "called on " & $wrapped.kind)

proc get(branch: WrappedType; key: string): string =
	if key in branch.keys:
		let sym = branch.keys[key]
		if sym in branch.values:
			result = sym
	assert result != "", "tried to read an unassigned name: " & key

proc contains*(branch: WrappedType; key: string): bool =
	result = branch.keys.contains(key)

proc isAvailable(branch: WrappedType; key: string): bool =
	result = true
	if key in branch.keys:
		let sym = branch.keys[key]
		if sym in branch.values:
			result = (branch.values[sym].name == key)

proc assign(branch: WrappedType; key: string; leaf: WrappedType): bool =
	result = branch.isAvailable(key)
	#assert result == true, &"found prior {key} insert as " & branch.get(key)
	if result:
		branch.keys[key] = key
		branch.values[key] = leaf

proc `[]`*[S, V](branch: WrappedType[S, V]; key: string): WrappedType[S, V] =
	assert branch.kind == Branch
	let name = branch.get(key)
	result = branch.values[name]

proc `[]=`*[S, V](branch: WrappedType[S, V]; key: string; leaf: WrappedType[S, V]) =
	assert branch.kind == Branch
	let success = branch.assign(key, leaf)
	if not success:
		let
			sym = branch.get(key)
			msg = &"attempt to rename symbol {sym.repr} to {key.repr}"
		raise newException(Defect, msg)

proc add*(branch: WrappedType; leaf: WrappedType) =
	assert branch != nil
	assert leaf != nil
	branch[leaf.name] = leaf
	
when isMainModule:
	import logging
	import unittest

	let logger = newConsoleLogger(useStderr=true)
	logger.addHandler()

	type
		MyValue = int
		MySchema = object
			foo: int
		MyKind = enum One, Two
		MyComplex = object
			case kind: MyKind
			of One:
				integer: int
			of Two:
				comment: string

	converter toAny[S: auto, T: int](leaf: WrappedType[S, T]): T =
		assert leaf.kind == Leaf
		result = leaf.value


	suite "typewrap":
		setup:
			let
				sym = "gOa_Ts__"
				sim = "__Go__At_S"
				sam = "horSe"
			var
				mv: MyValue = 34
				mc1 = MyComplex(kind: One, integer: 55)
				mc2 = MyComplex(kind: Two, comment: "hello")
				ms = MySchema()
				branch = newBranch[MySchema, MyValue](ms, "test1")
				cb = newBranch[MySchema, MyComplex](ms, "test2")
				cleaf1 = ms.newLeaf("an integer", mc1)
				cleaf2 = ms.newLeaf("a string", mc2)
				leaf = ms.newLeaf(sym, mv)
				leaf2 = ms.newLeaf(sam, 44.MyValue)
			cb.add cleaf1
			cb.add cleaf2

		test "isAvailable":
			check true == branch.isAvailable "goats"
			check true == branch.isAvailable "pigs"
			check true == branch.isAvailable "goats"
			check true == branch.isAvailable sym
			check true == branch.isAvailable sim
		test "assign":
			check true == branch.assign(sym, leaf)
			check true == branch.isAvailable sym
			check true == branch.isAvailable sam
			check false == branch.isAvailable "goa_Ts__"
			check false == branch.isAvailable "goats"
			check false == branch.isAvailable sim
			check sym == branch.get(sim)
			check sym == branch[sim].name
			check branch[sim] == 34
			check branch[sim] != 35
		test "add":
			branch.add leaf2
			check true == branch.isAvailable sam
		test "[]=":
			branch[sym] = leaf
			check sym == branch.get(sym)
			check sym == branch.get(sim)
			check sym == branch[sym].name
		test "complex":
			check cb["a string"].value.comment == "hello"
			check cb["an integer"].value.integer == 55
			for n in values(cb):
				assert n.kind == Leaf
