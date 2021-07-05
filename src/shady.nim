## Shader macro, converts nim code into GLSL

import chroma, macros, pixie, strutils, tables, vmath, chroma

var useResult {.compiletime.}: bool

proc show(n: NimNode): string =
  result.add $n.kind
  case n.kind
  of nnkStrLit..nnkTripleStrLit, nnkCommentStmt, nnkSym, nnkIdent:
    result.add "\""
    result.add n.strVal
    result.add "\""
  else:
    discard
  result.add "("
  for i, c in n:
    if i > 0: result.add ","
    result.add $i
    result.add ":"
    result.add show(c)
  result.add ")"

proc typeRename(t: string): string =
  ## Some GLSL type names don't match nim names, rename here.
  case t
  of "Mat2": "mat2"
  of "Mat3": "mat3"
  of "Mat4": "mat4"
  of "Color": "vec4"
  of "Vec4": "vec4"
  of "Vec3": "vec3"
  of "Vec2": "vec2"

  of "UVec3": "uvec3"
  of "IVec3": "ivec3"
  of "UVec4": "uvec4"
  of "IVec4": "ivec4"

  of "int32": "int"
  of "uint32": "uint"

  of "float32": "float"
  of "float64": "float"
  of "Uniform": "uniform"
  of "UniformWriteOnly": "writeonly uniform"
  of "Attribute": "attribute"

  of "SamplerBuffer": "samplerBuffer"
  of "Sampler2d": "sampler2D"
  of "UImageBuffer": "uimageBuffer"
  else: t

## Default constructor for different GLSL types.
proc typeDefault(t: string): string =
  case t
  of "mat2": "mat2(0.0)"
  of "mat3": "mat3(0.0)"
  of "mat4": "mat4(0.0)"
  of "vec4": "vec4(0.0)"
  of "vec3": "vec3(0.0)"
  of "vec2": "vec2(0.0)"

  of "uvec2": "uvec2(0)"
  of "uvec3": "uvec3(0)"
  of "uvec4": "uvec4(0)"
  of "ivec2": "ivec2(0)"
  of "ivec3": "ivec3(0)"
  of "ivec4": "ivec4(0)"

  of "float": "0.0"
  of "int": "0"
  else: quit("no typeDefault " & t)

const glslGlobals = [
  "gl_Position", "gl_FragCoord", "gl_GlobalInvocationID",
]

## List of function that GLSL provides, don't include their NIM src.
const glslFunctions = [
  "rgb=", "rgb", "xyz", "xyz=", "xy", "xy=",
  "bool", "array",
  "vec2", "vec3", "vec4", "mat2", "mat3", "mat4", "color",
  "Vec2", "Vec3", "Vec4", "mat2", "Mat3", "Mat4", "Color",
  "uvec2", "uvec3", "uvec4",
  "UVec2", "UVec3", "UVec4",
  "ivec2", "ivec3", "ivec4",
  "IVec2", "IVec3", "IVec4",

  "abs", "clamp", "min", "max", "dot", "sqrt", "mix", "length",
  "texelFetch", "imageStore", "texture",
  "normalize",
  "floor", "ceil", "round", "exp",
  "[]", "[]=",
  "inverse"
]

## Simply SKIP these functions.
const ignoreFunctions = [
  "echo", "print", "debugEcho"
]

proc procRename(t: string): string =
  ## Some GLSL proc names don't match nim names, rename here.
  case t
  of "color": "vec4"
  of "not": "!"
  of "and": "&&"
  of "or": "||"
  of "mod": "%"
  else: t

proc opPrecedence(op: string): int =
  ## Given an operator return its precedence.
  ## Used to decide if () are needed.
  ## See: https://learnwebgl.brown37.net/12_shader_language/glsl_mathematical_operations.html
  case op:
  of "*", "/": 4
  of "+", "-": 5
  of "<", ">", "<=", ">=": 7
  of "==", "!=": 8
  of "&&": 12
  of "^^": 13
  of "||": 14
  of "=", "+=", "-=", "*=", "/=": 16
  else: -1

proc getPrecedence(n: NimNode): int =
  ## Return the opPrecedence of the node operator or -1.
  if n.kind == nnkInfix:
    n[0].strVal.opPrecedence()
  else:
    -1

proc addIndent(res: var string, level: int) =
  ## Add indent (only if its needed).
  var
    idx = res.len - 1
    spaces = 0
  while res[idx] == ' ':
    dec idx
    inc spaces
  if spaces == 0 and res[idx] != '\n':
    res.add '\n'
  let level = level - spaces div 2
  for i in 0 ..< level:
    res.add "  "

proc addSmart(res: var string, c: char, others = {'}'}) =
  ## Ads a char but first checks if its already here.
  var idx = res.len - 1
  while res[idx] in Whitespace:
    dec idx
  if res[idx] != c and res[idx] notin others:
    res.add c

proc toCodeStmts(n: NimNode, res: var string, level = 0)

proc toCode(n: NimNode, res: var string, level = 0) =
  ## Inner code block.

  case n.kind

  of nnkAsgn:
    res.addIndent level
    n[0].toCode(res)
    res.add " = "
    n[1].toCode(res)
    res.addSmart ';'

  of nnkInfix:
    if n[0].repr in ["mod"] and n[1].getType().repr != "int":
      # In nim float mod and integer made are same thing.
      # In GLSL mod(float, float) is a function while % is for integers.
      res.add n[0].repr
      res.add "("
      n[1].toCode(res)
      res.add ", "
      n[2].toCode(res)
      res.add ")"

    elif n[0].repr in ["+=", "-=", "*=", "/="]:
      res.addIndent level
      n[1].toCode(res)
      res.add " "
      n[0].toCode(res)
      res.add " "
      n[2].toCode(res)
      res.addSmart ';'

    else:
      let
        a = n.getPrecedence()
        l = n[1].getPrecedence()
        r = n[2].getPrecedence()
      if l > a or r > a:
        res.add "("
        n[1].toCode(res)
        res.add ") "
        n[0].toCode(res)
        res.add " ("
        n[2].toCode(res)
        res.add ")"
      else:
        n[1].toCode(res)
        res.add " "
        n[0].toCode(res)
        res.add " "
        n[2].toCode(res)

  of nnkHiddenDeref, nnkHiddenAddr:
    n[0].toCode(res)

  of nnkCall, nnkCommand:
    var procName = procRename(n[0].strVal)
    if procName in ignoreFunctions:
      return
    if procName == "[]=":
      n[1].toCode(res)
      for i in 2 ..< n.len - 1:
        res.add "["
        n[i].toCode(res)
        res.add "]"
      res.add " = "
      n[n.len - 1].toCode(res)
      res.addSmart ';'

    elif procName == "[]":
      n[1].toCode(res)
      for i in 2 ..< n.len:
        res.add "["
        n[i].toCode(res)
        res.add "]"

    elif procName in ["rgb=", "rgb", "xyz", "xy", "xy="]:
      if n[1].kind == nnkSym:
        n[1].toCode(res)
      else:
        res.add "("
        n[1].toCode(res)
        res.add ")"
      res.add "."
      res.add procName.replace("=", " = ")
      if n.len == 3:
        n[2].toCode(res)
    else:
      res.add procName
      res.add "("
      for j in 1 ..< n.len:
        if j != 1: res.add ", "
        n[j].toCode(res)
      res.add ")"

  of nnkDotExpr:
    n[0].toCode(res)
    res.add "."
    n[1].toCode(res)

  of nnkBracketExpr:
    n[0].toCode(res)
    res.add "["
    n[1].toCode(res)
    res.add "]"

  of nnkIdent, nnkSym:
    res.add procRename(n.strVal)

  of nnkStmtListExpr:
    for j in 0 ..< n.len:
      n[j].toCode(res, level)

  of nnkStmtList:
    for j in 0 ..< n.len:
      if n[j].kind in [nnkCall]:
        res.addIndent level
      n[j].toCode(res, level)
      if n[j].kind notin [nnkLetSection, nnkVarSection, nnkCommentStmt]:
        res.addSmart ';'
        res.add "\n"

  of nnkIfStmt:
    res.addIndent level
    res.add "if ("
    n[0][0].toCode(res)
    res.add ") {\n"
    n[0][1].toCodeStmts(res, level + 1)
    res.addIndent level
    res.add "}"
    var i = 1
    while n.len > i:
      if n[i].kind == nnkElse:
        res.add " else {\n"
        n[i][0].toCodeStmts(res, level + 1)
        res.addIndent level
        res.add "}"
      elif n[i].kind == nnkElifBranch:
        res.add " else if ("
        n[i][0].toCode(res)
        res.add ") {\n"
        n[i][1].toCodeStmts(res, level + 1)
        res.addIndent level
        res.add "}"
      else:
        quit("Not supported if branch")
      inc i

  # of nnkIfExpr:
  #   res.add "("
  #   n[0][0].toCode(res)
  #   res.add ") ? ("
  #   n[1][0].toCode(res)
  #   res.add ") : ("
  #   n[2][0].toCode(res)
  #   res.add ")"

  of nnkConv:
    res.add typeRename(n[0].strVal)
    res.add "("
    n[1].toCode(res)
    res.add ")"

  of nnkHiddenStdConv:
    var typeStr = typeRename(n.getType.repr)
    if typeStr.startsWith("range["):
      n[1].toCode(res)
    elif typeStr == "float" and n[1].kind == nnkIntLit:
      res.add $n[1].intVal.float64
    elif typeStr == "float" and n[1].kind == nnkFloatLit:
      res.add $n[1].floatVal.float64
    else:
      for j in 1 .. n.len-1:
        res.add typeStr
        res.add "("
        n[j].toCode(res)
        res.add ")"

  of nnkNone:
    assert false

  of nnkEmpty, nnkNilLit, nnkDiscardStmt, nnkPragma:
    # Skip all nil, empty and discard statements.
    discard

  of nnkIntLit .. nnkInt64Lit:
    var iv = $n.intVal
    res.add iv

  of nnkFloatLit .. nnkFloat64Lit:
    var fv = $n.floatVal
    res.add fv

  of nnkStrLit .. nnkTripleStrLit:
    res.add $n.strVal.newLit.repr

  of nnkCommentStmt:
    for line in n.strVal.split("\n"):
      res.addIndent level
      res.add "// "
      res.add line
      res.add "\n"

  of nnkVarSection, nnkLetSection:
    for j in 0 ..< n.len:
      res.addIndent level
      n[j].toCode(res, level)
      res.addSmart ';'
      res.add "\n"

  of nnkIdentDefs:
    for j in countup(0, n.len - 1, 3):
      var typeStr = ""
      if n[1].kind == nnkBracketExpr and
        n[1][0].kind == nnkSym and
        n[1][0].strVal == "array":
        typeStr = typeRename(n[1][2].strVal)
        typeStr.add "["
        typeStr.add n[1][1].repr
        typeStr.add "]"

        res.add typeStr
        res.add " "
        n[0].toCode(res)
      else:
        typeStr = typeRename(n[j].getTypeInst().strVal)
        res.add typeStr
        res.add " "
        n[j].toCode(res)
        if n[j + 2].kind != nnkEmpty:
          res.add " = "
          n[j + 2].toCode(res)
        else:
          res.add " = "
          res.add typeDefault(typeStr)

  of nnkReturnStmt:
    res.addIndent level
    if n[0].kind == nnkAsgn:
      n[0].toCode(res)
      res.add "\n"
      res.addIndent level
      res.add "return result"
    elif n[0].kind != nnkEmpty:
      res.add "return "
      n[0][1].toCode(res)
    elif useResult:
      res.add "return result"
    else:
      res.add "return"

  of nnkPrefix:
    res.add procRename(n[0].strVal) & " ("
    n[1].toCode(res)
    res.add ")"

  of nnkWhileStmt:
    res.addIndent level
    res.add "while("
    n[0].toCode(res)
    res.add ") {\n"
    n[1].toCode(res, level + 1)
    res.addIndent level
    res.add "}"

  of nnkForStmt:
    res.addIndent level
    res.add "for("
    res.add "int "
    res.add n[0].strVal
    res.add " = "
    n[1][1].toCode(res)
    res.add "; "
    res.add n[0].strVal
    if n[1][0].strVal == "..<":
      res.add " < "
    elif n[1][0].strVal == "..":
      res.add " <= "
    else:
      quit "For loop only supports integer .. or ..<."
    n[1][2].toCode(res)
    res.add "; "
    res.add n[0].strVal
    res.add "++"
    res.add ") {\n"
    n[2].toCode(res, level + 1)
    res.addIndent level
    res.add "}"

  of nnkBreakStmt:
    res.addIndent level
    res.add "break"

  of nnkProcDef:
    quit "Nested proc definitions are not allowed."

  of nnkCaseStmt:
    res.addIndent level
    res.add "switch("
    n[0].toCode(res)
    res.add ") {\n"
    for branch in n[1 .. ^1]:
      if branch.kind == nnkOfBranch:
        res.addIndent level
        res.add "case "
        branch[0].toCode(res)
        res.add ":{\n"
        branch[1].toCodeStmts(res, level + 1)
        res.addIndent level
        if branch[1].kind == nnkReturnStmt or branch[1].kind == nnkBreakStmt:
          res.add "};\n"
        else:
          res.add "}; break;\n"
      elif branch.kind == nnkElse:
        res.addIndent level
        res.add "default: {\n"
        branch[0].toCodeStmts(res, level + 1)
        res.addIndent level
        if branch[0].kind == nnkReturnStmt or branch[0].kind == nnkBreakStmt:
          res.add "};\n"
        else:
          res.add "}; break;\n"
      else:
        quit "^ can't compile branch"
    res.addIndent level
    res.add "}"

  of nnkBracket:
    echo "here?"

  else:
    echo n.treeRepr
    quit "^ can't compile"
    # res.add ($n.kind)
    # res.add "{{"
    # for j in 0 .. n.len-1:
    #   n[j].toCode(res)
    # res.add "}}"

proc toCodeStmts(n: NimNode, res: var string, level = 0) =
  if n.kind != nnkStmtList:
    res.addIndent level
    n.toCode(res, level)
    res.addSmart ';'
    res.add "\n"
  else:
    n.toCode(res, level)

proc toCodeTopLevel(topLevelNode: NimNode, res: var string, level = 0) =
  ## Top level block such as in and out params.
  ## Generates the main function (which is not like all the other functions)
  assert topLevelNode.kind == nnkProcDef
  for n in topLevelNode:
    case n.kind
    of nnkEmpty:
      discard
    of nnkSym:
      discard
    of nnkFormalParams:
      ## Main function parameters are different in they they go in as globals.
      for param in n:
        if param.kind != nnkEmpty:
          if param[0].strVal in ["gl_FragColor", "gl_Position"]:
            continue
          if param[1].kind == nnkVarTy:
            #if param[0].strVal == "fragColor":
            #  res.add "layout(location = 0) "
            if param[1][0].strVal == "int":
              res.add "flat "
            res.add "out "
            res.add typeRename(param[1][0].strVal)
          else:
            if param[1].kind == nnkBracketExpr:
              res.add typeRename(param[1][0].strVal)
              res.add " "
              res.add typeRename(param[1][1].strVal)
            else:
              if param[0].strVal == "gl_FragCoord":
                res.add "layout(origin_upper_left) "
              if param[1].strVal == "int":
                res.add "flat "
              res.add "in "
              res.add typeRename(param[1].strVal)
          res.add " "
          res.add param[0].strVal
          res.addSmart ';'
          res.add "\n"
    else:
      res.add "\n"
      res.add "void main() {\n"
      n.toCodeStmts(res, level+1)
      res.add "}\n"

proc hasResult(node: NimNode): bool =
  if node.kind == nnkSym and node.strVal == "result":
    return true
  for c in node.children:
    if c.hasResult():
      return true
  return false

proc procDef(topLevelNode: NimNode): string =
  ## Process whole function (that is not the main function).

  var procName = ""
  var paramsStr = ""
  var returnType = "void"

  assert topLevelNode.kind == nnkProcDef
  for n in topLevelNode:
    case n.kind
    of nnkEmpty, nnkPragma:
      discard
    of nnkSym:
      procName = $n
    of nnkFormalParams:
      # Reading parameter list `(x, y, z: float)`
      if n[0].kind != nnkEmpty:
        returnType = typeRename(n[0].strVal)
      for paramDef in n[1 .. ^1]:
        # The paramDef is like `x, y, z: float`.
        if paramDef.kind != nnkEmpty:
          for param in paramDef[0 ..< ^2]:
            # Process each `x`, `y`, `z` in a loop.
            paramsStr.add "  "
            let paramName = param.repr()
            let paramType = param.getTypeInst()
            if paramType.kind == nnkVarTy:
              # Process `x: var float`
              if paramType[0].strVal == "int":
                paramsStr.add "flat "
              paramsStr.add "inout "
              paramsStr.add typeRename(paramType[0].strVal)
            elif paramType.kind == nnkBracketExpr:
              # Process varying[uniform].
              # TODO test?
              paramsStr.add paramType[0].strVal
              paramsStr.add " "
              paramsStr.add typeRename(paramType[1].strVal)
            else:
              # Just a simple `x: float` case.
              if paramType.strVal == "int":
                paramsStr.add "flat "
              paramsStr.add typeRename(paramType.strVal)
            paramsStr.add " "
            paramsStr.add paramName
            paramsStr.add ",\n"
    else:
      result.add "\n"
      if paramsStr.len > 0:
        paramsStr = paramsStr[0 .. ^3] & "\n"
      result.add returnType & " " & procName & "(\n" & paramsStr & ") {\n"
      useResult = n.hasResult()
      if useResult:
        result.addIndent(1)
        result.add returnType
        result.add " result;"
      n.toCodeStmts(result, 1)
      if useResult:
        if "return result" notin result[^20..^1]:
          result.addIndent(1)
          result.add "return result;\n"
      result.add "}"

proc gatherFunction(
  topLevelNode: NimNode,
  functions: var Table[string, string],
  globals: var Table[string, string]
) =

  ## Looks for functions this function calls and brings them up
  for n in topLevelNode:
    if n.kind == nnkSym:
      # Looking for globals.
      let name = n.strVal
      if name notin glslGlobals and name notin glslFunctions and name notin globals:
        if n.owner().symKind == nskModule:
          let impl = n.getImpl()
          if impl.kind notin {nnkIteratorDef, nnkProcDef} and
              impl.kind != nnkNilLit:
            var defStr = ""
            let typeInst = n.getTypeInst
            if typeInst.kind == nnkBracketExpr:
              # might be a uniform
              if typeInst[0].repr in ["Uniform", "UniformWriteOnly", "Attribute"]:
                defStr.add typeRename(typeInst[0].repr)
                defStr.add " "
                defStr.add typeRename(typeInst[1].repr)
              elif typeInst[0].repr == "array":
                defStr.add typeRename(typeInst[2].repr)
                defStr.add "["
                defStr.add typeRename(typeInst[1][2].repr)
                defStr.add "]"
              else:
                quit("Invalid x[y].")
            else:
              defStr.add typeRename(typeInst.repr)
            defStr.add " " & name
            if impl[2].kind != nnkEmpty:
              defStr.add " = " & repr(impl[2])
            defStr.addSmart ';'
            if defStr notin ["uniform Uniform = T;", "attribute Attribute = T;"]:
              globals[name] = defStr

    if n.kind == nnkCall:
      # Looking for functions.
      echo n[0].treeRepr
      let procName = n[0].strVal()
      if procName in ignoreFunctions:
        continue
      if procName notin glslFunctions and procName notin functions:
        ## If its not a builtin proc, we need to bring definition.
        let impl = n[0].getImpl()
        gatherFunction(impl, functions, globals)
        functions[procName] = procDef(impl)

    gatherFunction(n, functions, globals)

macro toShader*(s: typed, version = "410", extra = "precision highp float;\n"): string =
  ## Converts proc to a glsl string.
  var code: string

  # Add GLS header stuff.
  code.add "#version " & version.strVal & "\n"
  code.add extra.strVal
  code.add "// from " & s.strVal & "\n\n"

  var n = getImpl(s)

  # Gather all globals and functions, and globals and functions they use.
  var functions: Table[string, string]
  var globals: Table[string, string]
  gatherFunction(n, functions, globals)

  # Put globals first.
  for k, v in globals:
    code.add(v)
    code.add "\n"

  # Put functions definition (just name and types part).
  code.add "\n"
  for k, v in functions:
    var funCode = v.split(" {")[0]
    funCode = funCode
      .replace("\n", "")
      .replace("  ", " ")
      .replace(",  ", ", ")
      .replace("( ", "(")
    code.add funCode
    code.addSmart ';'
    code.add "\n"

  # Put functions (with bodies) next.
  code.add "\n"
  for k, v in functions:
    code.add v
    code.add "\n"

  # Put the main function last.
  toCodeTopLevel(n, code)

  result = newLit(code)

## GLSL helper functions


# proc get[T](v: Uniform[T]): T = v

type
  Uniform*[T] = T
  UniformWriteOnly*[T] = T
  Attribute*[T] = T

  SamplerBuffer* = object
    data*: seq[float32]

  UImageBuffer* = object
    data*: seq[uint8]

  Sampler2d* = object
    image*: Image

#   Color* = object
#     r*: float32
#     g*: float32
#     b*: float32
#     a*: float32

#   IVec4* = object
#     x*: int32
#     y*: int32
#     z*: int32
#     w*: int32

#   IVec3* = object
#     x*: int32
#     y*: int32
#     z*: int32
#     w*: int32

#   UVec4* = object
#     x*: uint32
#     y*: uint32
#     z*: uint32
#     w*: uint32

#   UVec3* = object
#     x*: uint32
#     y*: uint32
#     z*: uint32

# proc color*(r, g, b: float32, a: float32 = 1.0): Color {.inline.} =
#   Color(r: r, g: g, b: b, a: a)

# proc ivec4*(x, y, z, w: int32): IVec4 =
#   IVec4(x:x, y:y, z:z, w:w)

# proc ivec3*(x, y, z: int32): IVec3 =
#   IVec3(x:x, y:y, z:z)

# proc uvec4*(x, y, z, w: uint32): UVec4 =
#   UVec4(x:x, y:y, z:z, w:w)

# proc uvec3*(x, y, z: uint32): UVec3 =
#   UVec3(x:x, y:y, z:z)

proc rgb*(c: Color): Vec3 =
  vec3(c.r, c.g, c.b)

proc `rgb=`*(c: var Color, v: Vec3) =
  c.r = v.x
  c.g = v.y
  c.b = v.z

# proc vec4*(v: Vec3, w: float32): Vec4 =
#   vec4(v.x, v.y, v.z, w)

proc vec4*(c: chroma.ColorRGBA): Vec4 =
  vec4(
    c.r.float32/255,
    c.g.float32/255,
    c.b.float32/255,
    c.a.float32/255
  )

# proc xyz*(v: Vec4): Vec3 =
#   vec3(v.x, v.y, v.z)

proc mix*(a, b: Vec2, v: float32): Vec2 =
  lerp(a, b, v)

proc mix*(a, b: Vec3, v: float32): Vec3 =
  lerp(a, b, v)

proc mix*(a, b: Vec4, v: float32): Vec4 =
  result.x = lerp(a.x, b.x, v)
  result.y = lerp(a.y, b.y, v)
  result.z = lerp(a.z, b.z, v)
  result.w = lerp(a.w, b.w, v)

proc `mod`*(a, b: Vec2): Vec2 =
  result.x = a.x mod b.x
  result.y = a.y mod b.y

proc `mod`*(a, b: Vec3): Vec3 =
  result.x = a.x mod b.x
  result.y = a.y mod b.y
  result.z = a.y mod b.z

proc `mod`*(a, b: Vec4): Vec4 =
  result.x = a.x mod b.x
  result.y = a.y mod b.y
  result.z = a.y mod b.z
  result.w = a.w mod b.w

proc `zmod`*(a, b: float32): float32 =
  return a - b * floor(a/b)

proc `zmod`*(a, b: Vec2): Vec2 =
  result.x = zmod(a.x, b.x)
  result.y = zmod(a.y, b.y)

proc `zmod`*(a, b: Vec3): Vec3 =
  result.x = zmod(a.x, b.x)
  result.y = zmod(a.y, b.y)
  result.z = zmod(a.y, b.z)

proc `zmod`*(a, b: Vec4): Vec4 =
  result.x = zmod(a.x, b.x)
  result.y = zmod(a.y, b.y)
  result.z = zmod(a.y, b.z)
  result.w = zmod(a.w, b.w)

# proc `*`*(m: Mat4, v: Vec4): Vec4 =
#   vec4(m * v.xyz, 1.0)

# proc `xy=`*(a: var Vec4, b: Vec2) =
#   a.x = b.x
#   a.y = b.y

# proc `xy`*(a: Vec4): Vec2 =
#   vec2(a.x, a.y)

# proc `xyz=`*(a: var Vec4, b: Vec3) =
#   a.x = b.x
#   a.y = b.y
#   a.z = b.z

# proc `xyz`*(a: Vec4): Vec3 =
#   vec3(a.x, a.y, a.z)

proc texelFetch*(buffer: Uniform[SamplerBuffer], index: int): Vec4 =
  vec4(buffer.data[index], 0, 0, 0)

proc texelFetch*(buffer: Uniform[SamplerBuffer], index: int32): Vec4 =
  vec4(buffer.data[index], 0, 0, 0)

proc imageStore*(buffer: var UniformWriteOnly[UImageBuffer], index: int32, color: UVec4) =
  buffer.data[index.int] = color.x.uint8

proc texture*(buffer: Uniform[Sampler2D], pos: Vec2): Color =
  let pos = pos - vec2(0.5 / buffer.image.width.float32, 0.5 /
      buffer.image.height.float32)
  buffer.image.getRgbaSmooth(
    ((pos.x mod 1.0) * buffer.image.width.float32),
    ((pos.y mod 1.0) * buffer.image.height.float32)
  ).color

# proc floor*(a: Vec2): Vec2 =
#   result.x = a.x.floor
#   result.y = a.y.floor

# proc round*(a: Vec2): Vec2 =
#   result.x = a.x.round
#   result.y = a.y.round

# proc min*(a, b: Vec2): Vec2 =
#   result.x = min(a.x, b.x)
#   result.y = min(a.y, b.y)

# proc min*(a, b: Vec3): Vec3 =
#   result.x = min(a.x, b.x)
#   result.y = min(a.y, b.y)
#   result.z = min(a.z, b.z)

# proc min*(a, b: Vec4): Vec4 =
#   result.x = min(a.x, b.x)
#   result.y = min(a.y, b.y)
#   result.z = min(a.z, b.z)
#   result.w = min(a.w, b.w)

# proc max*(a, b: Vec2): Vec2 =
#   result.x = max(a.x, b.x)
#   result.y = max(a.y, b.y)

# proc max*(a, b: Vec3): Vec3 =
#   result.x = max(a.x, b.x)
#   result.y = max(a.y, b.y)
#   result.z = max(a.z, b.z)

# proc max*(a, b: Vec4): Vec4 =
#   result.x = max(a.x, b.x)
#   result.y = max(a.y, b.y)
#   result.z = max(a.z, b.z)
#   result.w = max(a.w, b.w)

# proc `/`*(a: Vec4, b: float32): Vec4 =
#   result.x = a.x / b
#   result.y = a.y / b
#   result.z = a.z / b
#   result.w = a.w / b