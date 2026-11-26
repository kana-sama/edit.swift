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

(procedure_declaration (identifier) @function (procedure (block)))
(procedure_declaration (identifier) @function (procedure (uninitialized)))
(procedure_declaration (identifier) @type)
(overloaded_procedure_declaration (identifier) @function)
(call_expression function: (identifier) @function.call)

(type (identifier) @type)
(struct_declaration (identifier) @type "::")
(enum_declaration (identifier) @type "::")
(union_declaration (identifier) @type "::")
(bit_field_declaration (identifier) @type "::")
(const_declaration (identifier) @type "::" [(array_type) (distinct_type) (bit_set_type) (pointer_type)])

(member_expression "." (identifier) @property)
(call_expression function: (member_expression "." (identifier) @function.call))
(struct_field (identifier) @property)
(field (identifier) @property)
(attribute (identifier) @attribute)

[(string_literal) (raw_string_literal) (character)] @string
[(number) (float)] @number
[(boolean) (nil) (uninitialized)] @constant.builtin
[(comment) (block_comment)] @comment
