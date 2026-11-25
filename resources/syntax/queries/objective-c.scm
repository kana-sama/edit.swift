; Additional Objective-C captures for both .m and .mm.

[
  "@interface" "@implementation" "@protocol" "@end" "@class"
  "@compatibility_alias" "@property" "@synthesize" "@dynamic"
  "@selector" "@encode" "@available" "__builtin_available"
  "@required" "@optional" "@private" "@protected" "@public" "@package"
] @keyword

[
  "@import" "@try" "@catch" "@finally" "@throw" "@autoreleasepool" "@synchronized"
] @keyword.control

(objc_for_in_statement "in" @keyword.control)
(objc_module_import module: (identifier) @module)
(objc_builtin_type) @type
(objc_category name: (identifier) @type)
(objc_macro_invocation name: (objc_macro_name) @function.macro)
(objc_enum_specifier macro: (objc_enum_macro_name) @function.macro)

(objc_method_scope) @keyword
(objc_method_selector name: (identifier) @method)
(objc_method_parameter keyword: (identifier) @method)
(objc_message_selector name: (identifier) @method)
(objc_message_argument keyword: (identifier) @method)
(objc_selector_name (identifier) @method)

(objc_property_attribute) @attribute
(objc_property_synthesize property: (identifier) @property)
(objc_property_synthesize ivar: (identifier) @property)
(objc_property_dynamic property: (identifier) @property)
(objc_method_type_qualifier) @keyword

((type_qualifier) @keyword
  (#match? @keyword "^(__|_N)"))

((identifier) @constant.builtin
  (#any-of? @constant.builtin "nil" "Nil" "YES" "NO"))

(objc_string_literal) @string
