(comment) @comment
[(string) (template_string) (regex)] @string
(number) @number
[(true) (false) (null) (undefined) (this) (super)] @constant.builtin
(function_declaration name: (identifier) @function)
(method_definition name: (property_identifier) @function.method)
(call_expression function: (identifier) @function)
(pair key: [(property_identifier) (string)] @property)
(property_identifier) @property
[
  "const" "let" "var" "function" "class" "extends" "new" "import" "export" "from" "as"
  "async" "await" "return" "yield" "if" "else" "for" "in" "of" "while" "do" "switch"
  "case" "default" "try" "catch" "finally" "throw" "break" "continue" "typeof" "instanceof"
  "void" "delete" "debugger"
] @keyword
(jsx_opening_element name: (_) @tag)
(jsx_closing_element name: (_) @tag)
(jsx_self_closing_element name: (_) @tag)
(jsx_attribute (property_identifier) @attribute)
