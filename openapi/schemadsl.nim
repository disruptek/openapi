## shared templates for the schema definition DSL used by schema2 and schema3
import spec

template `<~`*(name: untyped; fields: openArray[(FieldName, FieldTypeDef)]) =
  # it's a var because we sometimes need to mutate it
  var name {.compileTime.} = `fields`.newSchema

template `<~`*(name: untyped; ftype: FieldTypeDef) =
  # it's a var because we sometimes need to mutate it
  var name {.compileTime.} = ftype
