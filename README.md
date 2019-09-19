# OpenAPI Code Generator for Nim

## Example

First, you need to convert your YAML swagger input into JSON:

```bash
$ yq . fungenerators.com/lottery/1.5/swagger.yaml > input.json
```

You can render the API every time you build you project, or you can build it via a separate source input.  Either way, it looks the same:

```nim
import asyncdispatch
import httpclient
import httpcore

import openapi/codegen

# 0) API handle, 1) input JSON source, 2) output Nim source
generate myAPI, "input.json", "output.nim":
  ## here you can mess with the generator directly as needed...
  
  # add a constant from the input to the API...
  let service = generator.js["info"]["x-serviceName"].getStr
  generator.ast.add newConstStmt(ident"myService", newStrLitNode(service))

render myAPI:
  ## whatever you write here will be included in your API verbatim
  echo "service " & myService & " loaded"

# use the API...
let
  request = getLotteryCountries.call()
  response = waitFor request.issueRequest()
if response.code.is2xx:
  echo waitFor response.body
else:
  echo "failure: " & $response.code
```

## Theory

### Why output Nim source at all?

1. Parsing the API schema and generating the code isn't terribly fast when performed at compile-time, so saving the source allows us to cache that work product to dramatically speed up compilation of an application which actually uses the resultant API and is likely being recompiled more often than the API schema is changing.

1. Eventually, this library will, by default, generate an API which has no third-party module requirements.  We aren't quite there yet, simply because we provide some minor quality-of-life shimming of the HTTP client.

1. Without source text, many forms of tooling (documentation, editor plug-ins, etc.) have needless hoops to jump through, if they work at all.

1. Adding generated code to source control lets us keep track of changes there which are no less critical than changes we might otherwise introduce manually elsewhere.

### Why is the resultant API so noisy?

The quality of OpenAPI definitions in the wild appears to vary, uh, wildly.  This code attempts to progressively define greater support for the API it receives as input whenever possible.  Hindrances to this goal include name clashes, invalid `$ref`erences, unspecified types, invalid identifiers, ambiguous schemas, and so on.

Our approach is to try to provide the most natural interface possible for the largest portion of the API we can.

You get a type defined per each operation defined in the API, and an exported instance of that type which is named according to the API's `operationId` specification.  These types allow you to perform trivial overrides or recomposition of generated values such as the `host` and `basePath`, or provide your own tweaks input validation and URL generation procedures.

## Requests
The `call` procedure returns a `Recallable` object which holds details associated with a request which may be reissued.  This proc comes in two flavors:

JSON objects matching the OpenAPI parameter locations:
```nim
proc call*(call_745068: Call_GetLotteryDraw_745063; query: JsonNode;
           body: JsonNode; header: JsonNode; path: JsonNode; formData: JsonNode): Recallable
```
Named arguments in native Nim types with default values if supported:
```nim
proc call*(call_745069: Call_GetLotteryDraw_745063; game: string; count: int = 0): Recallable
```
In any case, the inputs will be validated according to the API definition and only inputs which match parameters defined by the API will be sent to the server, and only if their types are correct.

## Some useful links
- APIs we consume https://github.com/APIs-guru/openapi-directory/blob/master/APIs
- Schema v2 https://swagger.io/specification/v2
- Schema v3 https://swagger.io/specification (not yet supported)
- Amazon Web Services APIs in Nim https://github.com/disruptek/atoz
