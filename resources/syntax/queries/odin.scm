; Structural captures adapted from tree-sitter-odin. Leave ambiguous names uncolored.

[
  "package" "import" "foreign" "using"
  "proc" "struct" "enum" "union" "bit_set" "bit_field" "map" "matrix"
  "distinct" "dynamic" "cast" "transmute" "auto_cast"
  "in" "not_in" "or_else"
] @keyword

[
  "if" "else" "when" "switch" "case" "where" "for" "do"
  "break" "continue" "defer" "return" "or_break" "or_continue" "or_return"
  (fallthrough_statement)
] @keyword.control

[(calling_convention) (tag)] @keyword.directive

(package_declaration (identifier) @namespace)
(import_declaration alias: (identifier) @namespace)

(procedure_declaration (identifier) @function (procedure [(block) (uninitialized)]))
(overloaded_procedure_declaration (identifier) @function)

; A bare proc signature can also be the recovered header of an unfinished body.
((const_declaration (identifier) @type "::" (tag) @_type (type (procedure_type)))
 (#eq? @_type "#type"))

(type (identifier) @type)
(struct_declaration (identifier) @type "::")
(enum_declaration (identifier) @type "::")
(enum_declaration ["{" ","] . (identifier) @property)
(union_declaration (identifier) @type "::")
(bit_field_declaration (identifier) @type "::")
(const_declaration (identifier) @type "::" [(array_type) (distinct_type) (bit_set_type) (pointer_type)])

; Only the implicit selector and the key of a named initializer prove a field role.
(member_expression . "." (identifier) @property)
(struct_field . (identifier) @property "=")
(field (identifier) @property)
(attribute ["@" "(" ","] . (identifier) @property)

[(string_literal) (raw_string_literal) (character)] @string
[(number) (float)] @number
[(boolean) (nil) (uninitialized)] @constant.builtin
[(comment) (block_comment)] @comment
