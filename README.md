# OpenAPI Code Generator for Nim

## Example

First, you need to convert your YAML swagger input into JSON:

```bash
$ yq . fungenerators.com/lottery/1.5/swagger.yaml
```

You can render the API every time you build you project, or you can build it via a separate source input.  Either way, it looks the same:

```nim
import asyncdispatch
import httpclient
import httpcore

import openapi/codegen

# 1) input JSON source, 2) output Nim source
openapi "input.json", "output.nim":
  # whatever you write in this block gets appended to your output;
  # you are in the same scope as your generated API, so you can
  # perform hackery or loosen exports as you wish...
  
  # expose some useful REST methods...
  export rest

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

The quality of OpenAPI definitions in the wild appears to vary, uh, wildly.  This code attempts to progressively define greater support for the API it receives as input whenever possible.  Hindrances to this goal include name clashes, invalid `$ref`erences, unspecified types, invalid identifiers, ambiguous schemas, and so on.

You get a type defined per each operation defined in the API, and an exported instance of that type which is named according to the API's `operationId` specification.  These types allow you to perform trivial overrides or recomposition of generated values such as the `host`, `basePath`, or input validation and URL generation procedures.

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
- Amazon Web Services Signature Version 4 https://github.com/disruptek/sigv4
