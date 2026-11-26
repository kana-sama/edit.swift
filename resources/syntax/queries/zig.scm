; Types
(builtin_type) @type.builtin

; The grammar parses these primitives as identifiers in expression positions.
((primary_type_expression/identifier) @type.builtin
  (#match? @type.builtin "^(f80|c_char|[iu]0[0-9]*)$"))

(anyframe_type "anyframe" @keyword "->")
(("anyframe" @type.builtin)
  (#not-followed-by? @type.builtin "->"))

(parameter "..." @type.builtin)

; Built-in function names use the same color as ZLS builtin tokens.
(builtin_identifier) @function.builtin

; Color a single const binding whose initializer has a syntactically known type role.
((variable_declaration
   . "const" . (identifier) @type type: (_)?
   . "=" . [
     (struct_declaration)
     (enum_declaration)
     (union_declaration)
     (opaque_declaration)
     (error_set_declaration)
     (function_signature)
     (anyframe_type)
     (slice_type (builtin_type) .)
     (pointer_type (builtin_type) .)
     (nullable_type (builtin_type) .)
     (array_type (integer) (builtin_type) .)
     (error_union_type error: (error_set_declaration) ok: (builtin_type))
   ] @_initializer . ";")
  (#zig-type-binding? @type @_initializer))

((variable_declaration
   . "const" . (identifier) @type type: (_)?
   . "=" . (builtin_type) @_type . ";")
  (#not-eq? @_type "anytype")
  (#zig-type-binding? @type @_type))

((variable_declaration
   . "const" . (identifier) @type type: (_)?
   . "=" . (primary_type_expression/identifier) @_type . ";")
  (#match? @_type "^(f80|c_char|[iu]0[0-9]*)$")
  (#zig-type-binding? @type @_type))

; ZLS classifies parameter declarations by the direct type spelling.
((parameter name: (identifier) @type type: (builtin_type) @_type)
  (#eq? @_type "type"))

((parameter name: (identifier) @property type: (builtin_type) @_type)
  (#not-eq? @_type "type"))

((parameter name: (identifier) @property type: (identifier) @_type)
  (#match? @_type "^(f80|c_char|[iu]0[0-9]*)$"))

(parameter name: (identifier) @property type: "anyframe")

; Labels and explicit error tags
[
  (block_label (identifier) @keyword.control.label)
  (break_label (identifier) @keyword.control.label)
  (error_type (identifier) @type)
  (error_set_declaration (identifier) @type)
]

; A colon distinguishes a named field from an element of a tuple struct.
(struct_declaration
  (container_field name: [(identifier) "null" "undefined" "true" "false"] @property ":" type: (_)))

[
  (enum_declaration
    (container_field name: [(identifier) (builtin_type) (boolean) "null" "undefined" "true" "false"] @property))
  (union_declaration
    (container_field name: [(identifier) (builtin_type) (boolean) "null" "undefined" "true" "false"] @property))
]

(initializer_list
  (assignment_expression
    left: (field_expression !object member: (identifier) @property)
    "="))

(field_initializer (identifier) @property)

; Keyword literals use the same color as ZLS keywordLiteral tokens.
([
  "null"
  "unreachable"
  "undefined"
  (boolean)
] @keyword.control
  (#not-field? @keyword.control "name"))

; Keywords
[
  "asm"
  "defer"
  "errdefer"
  "test"
  "error"
  "const"
  "var"
] @keyword

[
  "struct"
  "union"
  "enum"
  "opaque"
] @keyword.type

[
  "suspend"
  "nosuspend"
  "resume"
] @keyword.coroutine

"fn" @keyword.function

[
  "and"
  "or"
  "orelse"
] @keyword.operator

"return" @keyword.return

[
  "if"
  "else"
  "switch"
] @keyword.conditional

[
  "for"
  "while"
  "break"
  "continue"
] @keyword.repeat

"export" @keyword.import

[
  "try"
  "catch"
] @keyword.exception

[
  "volatile"
  "allowzero"
  "noalias"
  "addrspace"
  "align"
  "callconv"
  "linksection"
  "pub"
  "inline"
  "noinline"
  "extern"
  "comptime"
  "packed"
  "threadlocal"
] @keyword.modifier

; Operator
[
  "="
  "*="
  "*%="
  "*|="
  "/="
  "%="
  "+="
  "+%="
  "+|="
  "-="
  "-%="
  "-|="
  "<<="
  "<<|="
  ">>="
  "&="
  "^="
  "|="
  "!"
  "~"
  "-"
  "-%"
  "&"
  "=="
  "!="
  ">"
  ">="
  "<="
  "<"
  "&"
  "^"
  "|"
  "<<"
  ">>"
  "<<|"
  "+"
  "++"
  "+%"
  "-%"
  "+|"
  "-|"
  "*"
  "/"
  "%"
  "**"
  "*%"
  "*|"
  "||"
  ".*"
  ".?"
  "?"
  ".."
] @operator

; Literals
(character) @string

([
  (string)
  (multiline_string)
] @string
  (#set! "priority" 95))

; Recovery can leave the opening quote and string pieces directly under ERROR.
(ERROR ["\"" (string_content)] @string.incomplete)

((ERROR
  ["\"" (string_content) (escape_sequence)] @_string_piece
  . (ERROR) @string.incomplete.escape)
 (#eq? @string.incomplete.escape "\\"))

(integer) @number

(float) @number.float

(escape_sequence) @string.escape

; Punctuation
[
  "["
  "]"
  "("
  ")"
  "{"
  "}"
] @punctuation.bracket

[
  ";"
  "."
  ","
  ":"
  "=>"
  "->"
] @punctuation.delimiter

(payload
  "|" @punctuation.bracket)

; Comments
(comment) @comment
