#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "../EditSyntaxABI/EditSyntaxABI.h"
#include "tree_sitter/api.h"

#define EDIT_VISIBLE __attribute__((visibility("default")))

typedef struct {
    uint32_t startByte;
    uint32_t endByte;
    EditSyntaxPreview publish;
} Preview;

#define DECLARE(name) extern const TSLanguage *tree_sitter_##name(void)
DECLARE(c);
DECLARE(cpp);
DECLARE(clojure);
DECLARE(css);
DECLARE(erlang);
DECLARE(go);
DECLARE(html);
DECLARE(json);
DECLARE(lua);
DECLARE(markdown);
DECLARE(markdown_inline);
DECLARE(objcpp);
DECLARE(odin);
DECLARE(python);
DECLARE(ruby);
DECLARE(rust);
DECLARE(bash);
DECLARE(solidity);
DECLARE(swift);
DECLARE(toml);
DECLARE(typescript);
DECLARE(tsx);
DECLARE(yaml);
DECLARE(zig);
#undef DECLARE

typedef const TSLanguage *(*LanguageFactory)(void);
struct Grammar {
    const char *name;
    LanguageFactory make;
};

static const struct Grammar grammars[] = {
    {"c", tree_sitter_c}, {"cpp", tree_sitter_cpp}, {"clojure", tree_sitter_clojure},
    {"css", tree_sitter_css}, {"erlang", tree_sitter_erlang}, {"go", tree_sitter_go},
    {"html", tree_sitter_html}, {"javascript", tree_sitter_tsx}, {"javascript-jsx", tree_sitter_tsx},
    {"json", tree_sitter_json}, {"lua", tree_sitter_lua}, {"markdown", tree_sitter_markdown},
    {"markdown-inline", tree_sitter_markdown_inline}, {"objective-c", tree_sitter_objcpp},
    {"objective-cpp", tree_sitter_objcpp}, {"odin", tree_sitter_odin}, {"python", tree_sitter_python},
    {"ruby", tree_sitter_ruby}, {"rust", tree_sitter_rust}, {"shell", tree_sitter_bash},
    {"solidity", tree_sitter_solidity}, {"swift", tree_sitter_swift}, {"toml", tree_sitter_toml},
    {"typescript", tree_sitter_typescript}, {"tsx", tree_sitter_tsx}, {"yaml", tree_sitter_yaml},
    {"zig", tree_sitter_zig}
};

static const char *grammarName(NSString *name) {
    if (!name) return NULL;
    NSString *key = name.lowercaseString;
    for (size_t i = 0; i < sizeof(grammars) / sizeof(grammars[0]); ++i) {
        if ([key isEqualToString:@(grammars[i].name)]) return grammars[i].name;
    }
    NSDictionary<NSString *, NSString *> *aliases = @{
        @"js": @"javascript", @"cjs": @"javascript", @"mjs": @"javascript", @"jsx": @"javascript-jsx",
        @"cpp": @"cpp", @"c++": @"cpp", @"cc": @"cpp", @"cxx": @"cpp",
        @"objc": @"objective-c", @"m": @"objective-c", @"objective-c++": @"objective-cpp",
        @"objcpp": @"objective-cpp", @"mm": @"objective-cpp",
        @"rs": @"rust", @"py": @"python", @"rb": @"ruby", @"md": @"markdown",
        @"sh": @"shell", @"bash": @"shell", @"zsh": @"shell", @"shell-script": @"shell",
        @"ts": @"typescript", @"cts": @"typescript", @"mts": @"typescript", @"yml": @"yaml",
        @"clj": @"clojure", @"cljs": @"clojure", @"edn": @"clojure", @"erl": @"erlang",
        @"sol": @"solidity", @"zon": @"zig", @"jsonc": @"json", @"htm": @"html"
    };
    NSString *canonical = aliases[key];
    if (canonical) return grammarName(canonical);
    return NULL;
}

static const TSLanguage *languageForName(const char *name) {
    for (size_t i = 0; i < sizeof(grammars) / sizeof(grammars[0]); ++i) {
        if (strcmp(grammars[i].name, name) == 0) return grammars[i].make();
    }
    return NULL;
}

typedef struct {
    const uint16_t *units;
    uint32_t bytes;
    EditSyntaxCapture highlight;
    EditSyntaxCapture bracket;
    EditSyntaxCancelled cancelled;
    void *context;
    // A viewport query can visit an injection before the complete query visits it.
    __unsafe_unretained NSMutableDictionary<NSString *, NSValue *> *trees;
    bool previewPass;
    uint32_t highlightLimit;
} Input;

static bool cancelled(Input *input) {
    return input->cancelled && input->cancelled(input->context);
}

static bool parseProgress(TSParseState *state) {
    return cancelled(state->payload);
}

static bool queryProgress(TSQueryCursorState *state) {
    return cancelled(state->payload);
}

static const char *readInput(void *payload, uint32_t index, TSPoint point, uint32_t *bytes) {
    Input *input = payload;
    (void) point;
    if (index >= input->bytes) {
        *bytes = 0;
        return NULL;
    }
    *bytes = input->bytes - index;
    return (const char *) input->units + index;
}

static NSString *stringForNode(Input *input, TSNode node) {
    uint32_t start = ts_node_start_byte(node);
    uint32_t end = ts_node_end_byte(node);
    if (start > end || end > input->bytes) return nil;
    return [[NSString alloc] initWithBytes:(const char *) input->units + start
                                   length:end - start encoding:NSUTF16LittleEndianStringEncoding];
}

static NSString *queryValue(const TSQuery *query, uint32_t id) {
    uint32_t length = 0;
    const char *value = ts_query_string_value_for_id(query, id, &length);
    return [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding];
}

static TSNode captureNode(TSQueryMatch match, uint32_t id) {
    for (uint16_t i = 0; i < match.capture_count; ++i) {
        if (match.captures[i].index == id) return match.captures[i].node;
    }
    return (TSNode){0};
}

static NSString *captureValue(Input *input, TSQueryMatch match, uint32_t id) {
    TSNode node = captureNode(match, id);
    return ts_node_is_null(node) ? nil : stringForNode(input, node);
}

static bool zigStructTypeIsKnown(Input *input, TSNode node) {
    uint32_t count = ts_node_child_count(node);
    if (!count) return false;
    TSNode closer = ts_node_child(node, count - 1);
    if (ts_node_is_missing(closer) || strcmp(ts_node_type(closer), "}") != 0) return false;

    // An ordinary struct is a type even when ZLS cannot resolve one of its field types.
    // For tuple structs, ZLS needs the element types before it colors the binding.
    bool inBody = false;
    bool hasUnresolvedTupleField = false;
    for (uint32_t i = 0; i + 1 < count; ++i) {
        TSNode child = ts_node_child(node, i);
        const char *type = ts_node_type(child);
        if (strcmp(type, "{") == 0) inBody = true;
        if (!inBody || !ts_node_is_named(child) || ts_node_is_extra(child) ||
            ts_node_start_byte(child) == ts_node_end_byte(child)) continue;
        if (strcmp(type, "container_field") == 0) {
            if (!ts_node_is_null(ts_node_child_by_field_name(child, "type", 4))) return true;
            TSNode element = ts_node_child_by_field_name(child, "name", 4);
            if (ts_node_is_null(element) || strcmp(ts_node_type(element), "builtin_type") != 0 ||
                [stringForNode(input, element) isEqualToString:@"anytype"]) hasUnresolvedTupleField = true;
        } else if (strcmp(type, "ERROR") != 0) {
            return true;
        }
    }
    return inBody && !hasUnresolvedTupleField;
}

// Tree-sitter returns predicate expressions for its consumer to evaluate.
static bool matchesPredicates(Input *input, const TSQuery *query, TSQueryMatch match,
                              NSMutableDictionary<NSString *, id> *regexes) {
    uint32_t count = 0;
    const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(query, match.pattern_index, &count);
    for (uint32_t start = 0; start < count;) {
        uint32_t end = start;
        while (end < count && steps[end].type != TSQueryPredicateStepTypeDone) ++end;
        if (end >= start + 3 && steps[start + 1].type == TSQueryPredicateStepTypeCapture) {
            NSString *name = queryValue(query, steps[start].value_id);
            TSNode node = captureNode(match, steps[start + 1].value_id);
            if ([name isEqualToString:@"zig-type-binding?"]) {
                if (steps[start + 2].type != TSQueryPredicateStepTypeCapture || ts_node_is_null(node)) return false;
                TSNode initializer = captureNode(match, steps[start + 2].value_id);
                if (ts_node_is_null(initializer)) return false;
                TSNode annotation = ts_node_child_by_field_name(ts_node_parent(node), "type", 4);
                if (!ts_node_is_null(annotation) && ![stringForNode(input, annotation) isEqualToString:@"type"]) return false;
                if (strcmp(ts_node_type(initializer), "struct_declaration") == 0 && !zigStructTypeIsKnown(input, initializer)) return false;
                start = end + 1;
                continue;
            }
            NSString *argument = steps[start + 2].type == TSQueryPredicateStepTypeCapture
                ? captureValue(input, match, steps[start + 2].value_id)
                : queryValue(query, steps[start + 2].value_id);
            if ([name isEqualToString:@"not-followed-by?"]) {
                if (ts_node_is_null(node)) return false;
                TSNode sibling = ts_node_next_sibling(node);
                while (!ts_node_is_null(sibling) && ts_node_is_extra(sibling)) sibling = ts_node_next_sibling(sibling);
                if (!ts_node_is_null(sibling) && [argument isEqualToString:@(ts_node_type(sibling))]) return false;
                start = end + 1;
                continue;
            }
            if ([name isEqualToString:@"not-field?"]) {
                if (ts_node_is_null(node)) return false;
                const char *field = argument.UTF8String;
                TSNode parent = ts_node_parent(node);
                if (field && !ts_node_is_null(parent) &&
                    ts_node_eq(node, ts_node_child_by_field_name(parent, field, (uint32_t)strlen(field)))) return false;
                start = end + 1;
                continue;
            }
            NSString *value = ts_node_is_null(node) ? nil : stringForNode(input, node);
            if ([name isEqualToString:@"eq?"] || [name isEqualToString:@"not-eq?"]) {
                if ([value isEqualToString:argument] == [name hasPrefix:@"not-"]) return false;
            } else if ([name isEqualToString:@"match?"] || [name isEqualToString:@"not-match?"]) {
                if (!value || !argument) return false;
                id regex = regexes[argument];
                if (!regex) {
                    regex = [NSRegularExpression regularExpressionWithPattern:argument options:0 error:NULL] ?: NSNull.null;
                    regexes[argument] = regex;
                }
                bool matched = regex != NSNull.null && [regex firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
                if (matched == [name hasPrefix:@"not-"]) return false;
            } else if ([name isEqualToString:@"any-of?"] || [name isEqualToString:@"not-any-of?"]) {
                bool matched = false;
                for (uint32_t i = start + 2; i < end; ++i) {
                    if ([value isEqualToString:queryValue(query, steps[i].value_id)]) {
                        matched = true;
                        break;
                    }
                }
                if (matched == [name hasPrefix:@"not-"]) return false;
            }
        }
        start = end + 1;
    }
    return true;
}

static NSString *injectedLanguage(Input *input, const TSQuery *query, TSQueryMatch match) {
    for (uint16_t i = 0; i < match.capture_count; ++i) {
        uint32_t length = 0;
        const char *capture = ts_query_capture_name_for_id(query, match.captures[i].index, &length);
        if (strcmp(capture, "injection.language") == 0) return stringForNode(input, match.captures[i].node);
    }
    uint32_t count = 0;
    const TSQueryPredicateStep *steps = ts_query_predicates_for_pattern(query, match.pattern_index, &count);
    for (uint32_t i = 0; i + 2 < count; ++i) {
        if (steps[i].type == TSQueryPredicateStepTypeString &&
            steps[i + 1].type == TSQueryPredicateStepTypeString &&
            steps[i + 2].type == TSQueryPredicateStepTypeString &&
            [queryValue(query, steps[i].value_id) isEqualToString:@"set!"] &&
            [queryValue(query, steps[i + 1].value_id) isEqualToString:@"injection.language"]) {
            return queryValue(query, steps[i + 2].value_id);
        }
    }
    return nil;
}

static bool runGrammar(Input input, const char *name, NSString *directory, uint32_t offset, int depth, const Preview *preview);

static const TSQuery *loadQuery(const TSLanguage *language, NSString *path, NSArray<NSString *> *basePaths) {
    static NSMutableDictionary<NSString *, id> *queries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queries = [NSMutableDictionary dictionary]; });
    @synchronized (queries) {
        id cached = queries[path];
        if (cached) return cached == NSNull.null ? NULL : [cached pointerValue];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data && basePaths.count) {
            NSMutableData *combined = [NSMutableData data];
            for (NSString *basePath in basePaths) {
                NSData *base = [NSData dataWithContentsOfFile:basePath];
                if (!base) { combined = nil; break; }
                [combined appendData:base];
                [combined appendBytes:"\n" length:1];
            }
            [combined appendData:data];
            data = combined;
        }
        TSQuery *query = NULL;
        if (data && data.length <= UINT32_MAX) {
            uint32_t errorOffset;
            TSQueryError error;
            query = ts_query_new(language, data.bytes, (uint32_t) data.length, &errorOffset, &error);
        }
        // Queries are immutable and shared by the cursors for open documents. Keep
        // this fixed set of bundled queries (and their capture names) available.
        queries[path] = query ? [NSValue valueWithPointer:query] : NSNull.null;
        return query;
    }
}

static bool bracketTextNode(const char *type, bool interpolation) {
    // An interpolated wrapper stays traversable so its expression tokens remain visible.
    if (strcmp(type, "string") == 0) return !interpolation;
    static const char *const ignored[] = {
        "comment", "line_comment", "block_comment", "multiline_comment", "js_comment", "html_comment", "shebang",
        "string_literal", "objc_string_literal", "interpreted_string_literal", "raw_string_literal", "char_literal", "rune_literal",
        "char_lit", "character", "calling_convention", "system_lib_string", "hex_string_literal", "unicode_string_literal",
        "yul_string_literal", "yul_hex_string_literal", "string_value", "single_quote_scalar", "double_quote_scalar",
        "block_scalar", "multi_string", "raw_string", "ansi_c_string", "multiline_string",
        "char", "str_lit", "regex_lit", "regex", "regex_literal", "regex_pattern",
        "string_content", "string_fragment", "line_str_text", "multi_line_str_text", "raw_str_part",
        "raw_str_end_part", "heredoc_content", "escape_sequence", "str_escaped_char"
    };
    for (size_t index = 0; index < sizeof(ignored) / sizeof(*ignored); ++index) {
        if (strcmp(type, ignored[index]) == 0) return true;
    }
    return false;
}

static bool angleOperator(TSNode node, const char *type) {
    if (!strchr(type, '<') && !strchr(type, '>')) return false;
    if (type[strspn(type, "<>=!")] != '\0') return false;
    if (type[1] != '\0') return true; // Shifts, comparisons, and arrows are single operator tokens.
    TSNode parent = ts_node_parent(node);
    return !ts_node_is_null(parent) && strcmp(ts_node_type(parent), "binary_expression") == 0;
}

static bool tagAngle(TSNode node, const char *type) {
    if (strcmp(type, "<") != 0 && strcmp(type, "</") != 0 && strcmp(type, ">") != 0 && strcmp(type, "/>") != 0) return false;
    TSNode parent = ts_node_parent(node);
    return !ts_node_is_null(parent) && strncmp(ts_node_type(parent), "jsx_", 4) == 0;
}

static bool templateDelimiter(TSNode node, const char *type) {
    if (strcmp(type, "${") == 0) return true;
    if (strcmp(type, "}") != 0) return false;
    TSNode parent = ts_node_parent(node);
    return !ts_node_is_null(parent) && strcmp(ts_node_type(parent), "template_substitution") == 0;
}

// A grammar can recover a not-yet-closed C-style comment as ordinary operators.
// Find its opener only in the code gaps between ranges already classified by the grammar.
static uint32_t recoverBlockComments(Input *input, uint32_t start, uint32_t limit, uint32_t offset, bool nested) {
    uint32_t length = input->bytes / 2u;
    uint32_t steps = 0;
    const uint16_t *units = input->units;
    while (start < limit && start + 1 < length) {
        if ((++steps & 4095u) == 0 && cancelled(input)) return length;
        if (units[start] != '/' || units[start + 1] != '*') {
            ++start;
            continue;
        }
        uint32_t end = start + 2;
        uint32_t nesting = 1;
        while (end + 1 < length && nesting > 0) {
            if ((++steps & 4095u) == 0 && cancelled(input)) return length;
            if (units[end] == '*' && units[end + 1] == '/') {
                --nesting;
                end += 2;
            } else if (nested && units[end] == '/' && units[end + 1] == '*') {
                ++nesting;
                end += 2;
            } else {
                ++end;
            }
        }
        if (nesting > 0) end = length;
        input->bracket(input->context, offset + start, offset + end, NULL);
        start = end;
    }
    return start;
}

static void readBracketContext(Input *input, TSNode root, const TSLanguage *language, const char *name,
                               uint32_t offset, int depth) {
    bool interpolation = strcmp(name, "python") == 0 || strcmp(name, "ruby") == 0 || strcmp(name, "shell") == 0;
    bool swift = strcmp(name, "swift") == 0;
    bool tsx = strcmp(name, "tsx") == 0;
    bool angleTokens = strcmp(name, "typescript") == 0 || tsx;
    bool js = strcmp(name, "javascript") == 0 || strcmp(name, "javascript-jsx") == 0;
    bool nestedComments = swift || strcmp(name, "rust") == 0;
    bool cStyleComments = nestedComments || angleTokens || js || strcmp(name, "c") == 0 || strcmp(name, "cpp") == 0 ||
        strcmp(name, "go") == 0 || strcmp(name, "css") == 0 || strcmp(name, "solidity") == 0 || strcmp(name, "json") == 0;
    // Tree-sitter symbols are grammar-local. Classify the small symbol table once per parse.
    uint32_t symbols = ts_language_symbol_count(language);
    bool *ignored = calloc(symbols, sizeof(*ignored));
    if (!ignored) return;
    for (uint32_t symbol = 0; symbol < symbols; ++symbol) {
        const char *type = ts_language_symbol_name(language, (TSSymbol) symbol);
        if (!type) continue;
        ignored[symbol] = bracketTextNode(type, interpolation) && !(swift && strcmp(type, "raw_string_literal") == 0);
    }

    TSTreeCursor cursor = ts_tree_cursor_new(root);
    uint32_t visited = 0;
    uint32_t codeStart = 0;
    for (;;) {
        if ((++visited & 255u) == 0 && cancelled(input)) goto done;
        TSNode node = ts_tree_cursor_current_node(&cursor);
        TSSymbol symbol = ts_node_symbol(node);
        const char *type = ts_node_type(node);
        bool delimiter = !ts_node_is_named(node);
        bool skip = (symbol < symbols && ignored[symbol]) ||
            (delimiter && ((angleTokens && angleOperator(node, type)) || (tsx && tagAngle(node, type)) ||
                           (depth > 0 && (angleTokens || js) && templateDelimiter(node, type))));
        if (skip) {
            uint32_t start = ts_node_start_byte(node) / 2u;
            uint32_t end = ts_node_end_byte(node) / 2u;
            if (start < end) {
                if (cStyleComments && codeStart < start) {
                    codeStart = recoverBlockComments(input, codeStart, start, offset, nestedComments);
                }
                if (end > codeStart) codeStart = end;
                input->bracket(input->context, offset + start, offset + end, NULL);
            }
        } else if (ts_tree_cursor_goto_first_child(&cursor)) {
            continue;
        }
        while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts_tree_cursor_goto_parent(&cursor)) {
                if (cStyleComments && !cancelled(input)) recoverBlockComments(input, codeStart, input->bytes / 2u, offset, nestedComments);
                goto done;
            }
        }
    }
done:
    ts_tree_cursor_delete(&cursor);
    free(ignored);
}

typedef struct {
    TSNode content;
    TSTree *tree;
} MarkdownInlineParse;

static bool markdownLiteralAt(Input *input, TSNode root, uint32_t start, MarkdownInlineParse *cached) {
    TSNode node = ts_node_named_descendant_for_byte_range(root, start * 2u, (start + 4u) * 2u);
    TSNode inlineContent = {0};
    for (; !ts_node_is_null(node); node = ts_node_parent(node)) {
        const char *type = ts_node_type(node);
        if (strcmp(type, "fenced_code_block") == 0 || strcmp(type, "indented_code_block") == 0 ||
            strcmp(type, "link_destination") == 0 || strcmp(type, "link_title") == 0 ||
            strcmp(type, "minus_metadata") == 0 || strcmp(type, "plus_metadata") == 0) return true;
        if (strcmp(type, "inline") == 0 || strcmp(type, "pipe_table_cell") == 0) inlineContent = node;
    }
    if (ts_node_is_null(inlineContent)) return false;

    const uint32_t from = ts_node_start_byte(inlineContent);
    if (!ts_node_eq(cached->content, inlineContent)) {
        if (cached->tree) ts_tree_delete(cached->tree);
        cached->content = inlineContent;
        cached->tree = NULL;
        Input section = *input;
        section.units += from / 2u;
        section.bytes = ts_node_end_byte(inlineContent) - from;
        TSParser *parser = ts_parser_new();
        if (!parser) return false;
        ts_parser_set_language(parser, tree_sitter_markdown_inline());
        TSInput text = {.payload = &section, .read = readInput, .encoding = TSInputEncodingUTF16LE};
        TSParseOptions options = {.payload = &section, .progress_callback = parseProgress};
        cached->tree = ts_parser_parse_with_options(parser, NULL, text, options);
        ts_parser_delete(parser);
    }
    if (!cached->tree) return false;
    const uint32_t local = start * 2u - from;
    node = ts_node_named_descendant_for_byte_range(ts_tree_root_node(cached->tree), local, local + 8u);
    bool literal = false;
    for (; !ts_node_is_null(node) && !literal; node = ts_node_parent(node)) {
        const char *type = ts_node_type(node);
        literal = strcmp(type, "code_span") == 0 || strcmp(type, "link_destination") == 0 ||
            strcmp(type, "link_title") == 0 || strcmp(type, "html_tag") == 0;
    }
    return literal;
}

static uint32_t unclosedMarkdownComment(Input *input, TSNode root) {
    const uint16_t *units = input->units;
    const uint32_t length = input->bytes / 2u;
    uint32_t suffix = length;
    // Only an opener after the final raw terminator can run to the end of the buffer.
    while (suffix >= 3u) {
        if ((suffix & 4095u) == 0 && cancelled(input)) return length;
        if (units[suffix - 1] == '>' && units[suffix - 2] == '-' && units[suffix - 3] == '-') break;
        --suffix;
    }
    MarkdownInlineParse cached = {0};
    uint32_t opener = length;
    for (uint32_t start = suffix >= 3u ? suffix : 0; start + 4u <= length; ++start) {
        if ((start & 4095u) == 0 && cancelled(input)) break;
        if (units[start] != '<' || units[start + 1] != '!' || units[start + 2] != '-' || units[start + 3] != '-') continue;
        uint32_t escape = start;
        while (escape > 0 && units[escape - 1] == '\\') --escape;
        if ((start - escape) % 2u == 0 && !markdownLiteralAt(input, root, start, &cached)) {
            opener = start;
            break;
        }
    }
    if (cached.tree) ts_tree_delete(cached.tree);
    return opener;
}

static bool zigQuotedIdentifierString(TSNode node, const char *capture) {
    // The Zig grammar represents @"name" as an identifier containing a string.
    bool escape = strcmp(capture, "string.escape") == 0;
    bool incomplete = strncmp(capture, "string.incomplete", sizeof("string.incomplete") - 1) == 0;
    if (!escape && !incomplete && strcmp(capture, "string") != 0) return false;
    TSNode parent = ts_node_parent(node);
    if (incomplete || (escape && !ts_node_is_null(parent) && ts_node_is_error(parent))) {
        // Recovery can flatten a quoted identifier's @, quote, and body into siblings.
        while (!ts_node_is_null(node)) {
            const char *type = ts_node_type(node);
            if (strcmp(type, "\"") == 0) {
                TSNode prefix = ts_node_prev_sibling(node);
                return !ts_node_is_null(prefix) && strcmp(ts_node_type(prefix), "@") == 0 &&
                    ts_node_end_byte(prefix) == ts_node_start_byte(node);
            }
            if (strcmp(type, "string_content") != 0 && strcmp(type, "escape_sequence") != 0 &&
                !ts_node_is_error(node)) break;
            TSNode previous = ts_node_prev_sibling(node);
            if (ts_node_is_null(previous) || ts_node_end_byte(previous) != ts_node_start_byte(node)) break;
            node = previous;
        }
        // Incomplete escapes belong to this string only when adjacent to its quote or body.
        return strcmp(capture, "string.incomplete.escape") == 0;
    }
    if (escape) node = parent;
    if (ts_node_is_null(node) || strcmp(ts_node_type(node), "string") != 0) return false;
    parent = ts_node_parent(node);
    return !ts_node_is_null(parent) && strcmp(ts_node_type(parent), "identifier") == 0;
}

static void runQuery(Input *input, const TSQuery *query, TSNode root, NSString *directory,
                     uint32_t offset, int depth, bool injection, const Preview *preview) {
    TSQueryCursor *cursor = ts_query_cursor_new();
    if (preview) ts_query_cursor_set_byte_range(cursor, preview->startByte, preview->endByte);
    const TSQueryCursorOptions options = {.payload = input, .progress_callback = queryProgress};
    ts_query_cursor_exec_with_options(cursor, query, root, &options);
    const bool zig = !injection && ts_node_language(root) == tree_sitter_zig();
    NSMutableDictionary<NSString *, id> *regexes = [NSMutableDictionary dictionary];
    TSQueryMatch match;
    uint32_t count = 0;
    while (ts_query_cursor_next_match(cursor, &match)) {
        if ((++count & 255u) == 0 && cancelled(input)) break;
        @autoreleasepool {
            if (!matchesPredicates(input, query, match, regexes)) continue;
            const char *nestedName = NULL;
            if (injection && depth < 4) {
                NSString *nested = injectedLanguage(input, query, match);
                if ([nested isEqualToString:@"markdown_inline"]) nested = @"markdown-inline";
                nestedName = grammarName(nested);
            }
            for (uint16_t i = 0; i < match.capture_count; ++i) {
                const TSQueryCapture capture = match.captures[i];
                uint32_t length = 0;
                const char *name = ts_query_capture_name_for_id(query, capture.index, &length);
                uint32_t from = ts_node_start_byte(capture.node);
                uint32_t to = ts_node_end_byte(capture.node);
                if (from >= to || to > input->bytes) continue;
                const uint32_t start = offset + from / 2u;
                const uint32_t end = offset + to / 2u;
                if (!injection) {
                    if (start < input->highlightLimit && !(zig && zigQuotedIdentifierString(capture.node, name))) {
                        input->highlight(input->context, start, MIN(end, input->highlightLimit), name);
                    }
                } else if (nestedName && strcmp(name, "injection.content") == 0 && !cancelled(input)) {
                    if (start >= input->highlightLimit && !input->bracket) continue;
                    Input section = *input;
                    section.units += from / 2u;
                    section.bytes = to - from;
                    if (input->bracket) {
                        input->bracket(input->context, offset + from / 2u, offset + to / 2u, nestedName);
                    }
                    runGrammar(section, nestedName, directory, offset + from / 2u, depth + 1, NULL);
                }
            }
        }
    }
    ts_query_cursor_delete(cursor);
}

static bool runGrammar(Input input, const char *name, NSString *directory, uint32_t offset, int depth, const Preview *preview) {
    const TSLanguage *language = languageForName(name);
    if (!language || cancelled(&input)) return false;
    const TSQuery *query = NULL;
    if (input.highlight) {
        bool isObjectiveC = language == tree_sitter_objcpp();
        NSString *filename = isObjectiveC ? @"objective-c.scm" : [@(name) stringByAppendingString:@".scm"];
        NSString *queryPath = [directory stringByAppendingPathComponent:filename];
        NSArray<NSString *> *basePaths = nil;
        if (isObjectiveC || strcmp(name, "cpp") == 0) {
            basePaths = @[[directory stringByAppendingPathComponent:@"c.scm"],
                          [directory stringByAppendingPathComponent:@"cpp-common.scm"]];
        }
        query = loadQuery(language, queryPath, basePaths);
        if (!query && !input.bracket) return false;
    }
    // Only preview and full highlighting can revisit the same injection within an analysis.
    NSString *key = depth > 0 && input.trees ? [NSString stringWithFormat:@"%u:%u:%s", offset, input.bytes, name] : nil;
    TSTree *tree = key ? [input.trees[key] pointerValue] : NULL;
    if (tree) {
        if (!input.previewPass) [input.trees removeObjectForKey:key];
    } else {
        TSParser *parser = ts_parser_new();
        if (!parser) return false;
        bool ready = ts_parser_set_language(parser, language);
        TSInput text = {.payload = &input, .read = readInput, .encoding = TSInputEncodingUTF16LE};
        TSParseOptions options = {.payload = &input, .progress_callback = parseProgress};
        tree = ready ? ts_parser_parse_with_options(parser, NULL, text, options) : NULL;
        ts_parser_delete(parser);
        if (tree && key && input.previewPass) input.trees[key] = [NSValue valueWithPointer:tree];
    }
    const bool parsed = tree != NULL;
    if (parsed) {
        TSNode root = ts_tree_root_node(tree);
        const uint32_t commentEnd = MIN(input.highlightLimit, offset + input.bytes / 2u);
        if (strcmp(name, "markdown") == 0 && !cancelled(&input)) {
            uint32_t markdownComment = unclosedMarkdownComment(&input, root);
            if (markdownComment < input.bytes / 2u) {
                input.highlightLimit = MIN(input.highlightLimit, offset + markdownComment);
                if (input.bracket) input.bracket(input.context, offset + markdownComment, offset + input.bytes / 2u, NULL);
            }
        }
        const TSQuery *injections = NULL;
        if (depth < 4 && !cancelled(&input) &&
            (strcmp(name, "markdown") == 0 || strcmp(name, "markdown-inline") == 0 || strcmp(name, "html") == 0)) {
            NSString *injectionPath = [directory stringByAppendingPathComponent:[@(name) stringByAppendingString:@"-injections.scm"]];
            injections = loadQuery(language, injectionPath, nil);
        }
        if (query) {
            if (preview && !cancelled(&input)) {
                Input visible = input;
                visible.bracket = NULL;
                visible.previewPass = true;
                if (input.highlightLimit < commentEnd) input.highlight(input.context, input.highlightLimit, commentEnd, "comment");
                runQuery(&visible, query, root, directory, offset, depth, false, preview);
                if (injections) runQuery(&visible, injections, root, directory, offset, depth, true, preview);
                if (!cancelled(&input)) preview->publish(input.context);
            }
            if (input.highlightLimit < commentEnd) input.highlight(input.context, input.highlightLimit, commentEnd, "comment");
            if (!cancelled(&input)) runQuery(&input, query, root, directory, offset, depth, false, NULL);
        }
        if (input.bracket && !cancelled(&input)) readBracketContext(&input, root, language, name, offset, depth);
        if (injections && !cancelled(&input)) runQuery(&input, injections, root, directory, offset, depth, true, NULL);
        if (!key || !input.previewPass) ts_tree_delete(tree);
    }
    return parsed && !cancelled(&input);
}

EDIT_VISIBLE bool edit_syntax_analyze_v1(const char *language, const char *queryDirectory,
                                        const uint16_t *units, uint32_t count,
                                        uint32_t previewStart, uint32_t previewEnd, EditSyntaxPreview publishPreview,
                                        EditSyntaxCapture highlight, EditSyntaxCapture bracket,
                                        EditSyntaxCancelled check, void *context) {
    if ((!highlight && !bracket) || count > UINT32_MAX / 2u) return false;
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:queryDirectory];
        if (!directory) return false;
        const bool canPreview = highlight && publishPreview && previewStart < previewEnd && previewEnd <= count;
        NSMutableDictionary<NSString *, NSValue *> *trees = canPreview ? [NSMutableDictionary dictionary] : nil;
        Input input = {units, count * 2u, highlight, bracket, check, context, trees, false, count};
        Preview preview = {previewStart * 2u, previewEnd * 2u, publishPreview};
        const bool result = runGrammar(input, language, directory, 0, 0, canPreview ? &preview : NULL);
        for (NSValue *tree in trees.allValues) ts_tree_delete(tree.pointerValue);
        return result;
    }
}

static TSPoint advancePoint(TSPoint point, const uint16_t *units, uint32_t start, uint32_t end, Input *input) {
    for (uint32_t i = start; i < end; ++i) {
        if ((i & 1023u) == 0 && cancelled(input)) break;
        if (units[i] == '\n') {
            ++point.row;
            point.column = 0;
        } else {
            point.column += 2;
        }
    }
    return point;
}

EDIT_VISIBLE EditSyntaxTreeProjectFunction edit_syntax_tree_project_v1;
void *edit_syntax_tree_project_v1(const void *previous, const uint16_t *previousUnits, uint32_t previousCount,
                                  const uint16_t *units, uint32_t count, uint32_t prefix, uint32_t suffix,
                                  EditSyntaxCancelled check, void *context) {
    if (count > UINT32_MAX / 2u || previousCount > UINT32_MAX / 2u || prefix > count || prefix > previousCount ||
        suffix > count - prefix || suffix > previousCount - prefix) return NULL;
    Input input = {.units = units, .bytes = count * 2u, .cancelled = check, .context = context};
    uint32_t oldEnd = previousCount - suffix;
    uint32_t newEnd = count - suffix;
    TSPoint start = advancePoint((TSPoint){0, 0}, previousUnits, 0, prefix, &input);
    TSPoint oldPoint = advancePoint(start, previousUnits, prefix, oldEnd, &input);
    TSPoint newPoint = advancePoint(start, units, prefix, newEnd, &input);
    if (cancelled(&input)) return NULL;
    TSTree *tree = ts_tree_copy(previous);
    if (!tree) return NULL;
    TSInputEdit edit = {prefix * 2u, oldEnd * 2u, newEnd * 2u, start, oldPoint, newPoint};
    ts_tree_edit(tree, &edit);
    return tree;
}

EDIT_VISIBLE EditSyntaxTreeParseFunction edit_syntax_tree_parse_v2;
void *edit_syntax_tree_parse_v2(const char *name, const uint16_t *units, uint32_t count, const void *previous,
                               EditSyntaxCancelled check, void *context) {
    const TSLanguage *language = languageForName(name);
    if (!language || count > UINT32_MAX / 2u || (previous && ts_tree_language(previous) != language)) return NULL;
    Input input = {.units = units, .bytes = count * 2u, .cancelled = check, .context = context};
    TSTree *old = previous ? ts_tree_copy(previous) : NULL;
    if (previous && !old) return NULL;

    TSParser *parser = ts_parser_new();
    TSTree *tree = NULL;
    if (parser && !cancelled(&input) && ts_parser_set_language(parser, language)) {
        TSInput text = {.payload = &input, .read = readInput, .encoding = TSInputEncodingUTF16LE};
        TSParseOptions options = {.payload = &input, .progress_callback = parseProgress};
        tree = ts_parser_parse_with_options(parser, old, text, options);
    }
    if (parser) ts_parser_delete(parser);
    if (old) ts_tree_delete(old);
    if (tree && cancelled(&input)) {
        ts_tree_delete(tree);
        return NULL;
    }
    return tree;
}

EDIT_VISIBLE EditSyntaxTreeQueryFunction edit_syntax_tree_query_v1;
bool edit_syntax_tree_query_v1(const void *tree, const char *name, const char *queryDirectory, const uint16_t *units, uint32_t count,
                       uint32_t start, uint32_t end, EditSyntaxCapture highlight, EditSyntaxCapture bracket,
                       EditSyntaxCancelled check, void *context) {
    if (start > end || end > count || count > UINT32_MAX / 2u) return false;
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:queryDirectory];
        const TSLanguage *language = ts_tree_language(tree);
        if (!directory || languageForName(name) != language) return false;
        Input input = {.units = units, .bytes = count * 2u, .highlight = highlight, .bracket = bracket,
                       .cancelled = check, .context = context, .highlightLimit = count};
        TSTree *snapshot = ts_tree_copy(tree);
        if (!snapshot) return false;
        TSNode root = ts_tree_root_node(snapshot);
        if (highlight && start < end && !cancelled(&input)) {
            NSString *filename = [@(name) stringByAppendingString:@".scm"];
            const TSQuery *query = loadQuery(language, [directory stringByAppendingPathComponent:filename], nil);
            if (!query) {
                ts_tree_delete(snapshot);
                return false;
            }
            Preview range = {start * 2u, end * 2u, NULL};
            runQuery(&input, query, root, directory, 0, 0, false, &range);
        }
        if (bracket && !cancelled(&input)) readBracketContext(&input, root, language, name, 0, 0);
        ts_tree_delete(snapshot);
        return !cancelled(&input);
    }
}

static void releaseSyntaxTree(void *tree) { ts_tree_delete(tree); }

EDIT_VISIBLE EditSyntaxTreeReleaseFunction edit_syntax_tree_release_v1;
void edit_syntax_tree_release_v1(void *tree) {
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), tree, releaseSyntaxTree);
}

static bool solidityNameMatches(Input *input, TSNode name, uint32_t start, uint32_t end) {
    if (ts_node_is_null(name)) return false;
    uint32_t nameStart = ts_node_start_byte(name);
    uint32_t nameEnd = ts_node_end_byte(name);
    return nameEnd <= input->bytes && nameEnd - nameStart == end - start &&
        memcmp((const char *)input->units + nameStart, (const char *)input->units + start, end - start) == 0;
}

static TSNode solidityEnumInScope(Input *input, TSNode scope, uint32_t start, uint32_t end, bool *declared) {
    TSNode found = {0};
    for (uint32_t i = 0, count = ts_node_named_child_count(scope); i < count && !cancelled(input); ++i) {
        TSNode child = ts_node_named_child(scope, i);
        TSNode name = ts_node_child_by_field_name(child, "name", 4);
        if (!solidityNameMatches(input, name, start, end)) continue;
        bool duplicate = *declared;
        *declared = true;
        if (duplicate || strcmp(ts_node_type(child), "enum_declaration") != 0) return (TSNode){0};
        found = child;
    }
    return found;
}

static bool solidityHasLocalBinding(Input *input, TSNode receiver, uint32_t start, uint32_t end) {
    TSNode body = ts_node_parent(receiver);
    while (!ts_node_is_null(body) && strcmp(ts_node_type(body), "function_body") != 0) body = ts_node_parent(body);
    if (ts_node_is_null(body)) return false;

    TSTreeCursor cursor = ts_tree_cursor_new(ts_node_parent(body));
    bool found = false;
    for (bool hasNode = true; hasNode && !cancelled(input);) {
        TSNode node = ts_tree_cursor_current_node(&cursor);
        if (ts_node_start_byte(node) < start) {
            const char *type = ts_node_type(node);
            if ((strcmp(type, "variable_declaration") == 0 || strcmp(type, "parameter") == 0) &&
                solidityNameMatches(input, ts_node_child_by_field_name(node, "name", 4), start, end)) {
                found = true;
                break;
            }
            if (ts_tree_cursor_goto_first_child(&cursor)) continue;
        }
        while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts_tree_cursor_goto_parent(&cursor)) {
                hasNode = false;
                break;
            }
        }
    }
    ts_tree_cursor_delete(&cursor);
    return found;
}

// An identifier in an unfinished member expression may outlive Solar's semantic index.
// Look only at its enclosing contract and source unit for an enum with that name.
EDIT_VISIBLE EditSolidityEnumMembersFunction edit_solidity_enum_members_v1;
bool edit_solidity_enum_members_v1(const uint16_t *units, uint32_t count, uint32_t receiverStart, uint32_t receiverEnd,
                                  EditSyntaxCapture member, EditSyntaxCancelled check, void *context) {
    if (receiverStart >= receiverEnd || receiverEnd > count || count > UINT32_MAX / 2u) return false;
    TSTree *tree = edit_syntax_tree_parse_v2("solidity", units, count, NULL, check, context);
    if (!tree) return false;
    Input input = {.units = units, .bytes = count * 2u, .cancelled = check, .context = context};
    const uint32_t start = receiverStart * 2u;
    const uint32_t end = receiverEnd * 2u;
    TSNode root = ts_tree_root_node(tree);
    TSNode receiver = ts_node_named_descendant_for_byte_range(root, start, end);
    TSNode scope = receiver;
    while (!ts_node_is_null(scope) && strcmp(ts_node_type(scope), "contract_body") != 0) {
        scope = ts_node_parent(scope);
    }
    bool found = false;
    if (!ts_node_is_null(receiver) && strcmp(ts_node_type(receiver), "identifier") == 0 &&
        ts_node_start_byte(receiver) == start && ts_node_end_byte(receiver) == end &&
        !solidityHasLocalBinding(&input, receiver, start, end)) {
        bool declared = false;
        TSNode type = solidityEnumInScope(&input, ts_node_is_null(scope) ? root : scope, start, end, &declared);
        if (!declared && !ts_node_is_null(scope))
            type = solidityEnumInScope(&input, root, start, end, &declared);
        TSNode body = ts_node_is_null(type) ? (TSNode){0} : ts_node_child_by_field_name(type, "body", 4);
        if (!ts_node_is_null(body) && !ts_node_has_error(body)) {
            for (uint32_t i = 0, count = ts_node_named_child_count(body); i < count && !cancelled(&input); ++i) {
                TSNode value = ts_node_named_child(body, i);
                if (strcmp(ts_node_type(value), "enum_value") != 0 || ts_node_is_missing(value)) continue;
                member(context, ts_node_start_byte(value) / 2u, ts_node_end_byte(value) / 2u, NULL);
                found = true;
            }
        }
    }
    ts_tree_delete(tree);
    return found && !cancelled(&input);
}

EDIT_VISIBLE bool edit_markdown_table_v1(const uint16_t *units, uint32_t count, uint32_t caret,
                                         EditSyntaxCapture row, void *context) {
    if (count > UINT32_MAX / 2u || caret > count) return false;
    TSParser *parser = ts_parser_new();
    if (!parser) return false;
    Input input = {.units = units, .bytes = count * 2u};
    ts_parser_set_language(parser, tree_sitter_markdown());
    TSInput text = {.payload = &input, .read = readInput, .encoding = TSInputEncodingUTF16LE};
    TSTree *tree = ts_parser_parse(parser, NULL, text);
    ts_parser_delete(parser);
    if (!tree) return false;

    TSNode root = ts_tree_root_node(tree);
    const uint32_t comment = unclosedMarkdownComment(&input, root);
    if (comment < count && caret >= comment) {
        ts_tree_delete(tree);
        return false;
    }
    uint32_t start = caret;
    if (start > 0 && units[start - 1] != '\n' && units[start - 1] != '\r') --start;
    TSNode table = ts_node_named_descendant_for_byte_range(root, start * 2u, caret * 2u);
    while (!ts_node_is_null(table) && strcmp(ts_node_type(table), "pipe_table") != 0) {
        table = ts_node_parent(table);
    }
    const bool found = !ts_node_is_null(table);
    if (found) {
        for (uint32_t index = 0; index < ts_node_named_child_count(table); ++index) {
            TSNode child = ts_node_named_child(table, index);
            const char *type = ts_node_type(child);
            if (strcmp(type, "pipe_table_header") == 0 || strcmp(type, "pipe_table_delimiter_row") == 0 ||
                strcmp(type, "pipe_table_row") == 0) {
                row(context, ts_node_start_byte(child) / 2u, ts_node_end_byte(child) / 2u, NULL);
            }
        }
    }
    ts_tree_delete(tree);
    return found;
}

/* Running editors can load this library after a development rebuild. Keep prior entry points. */
EDIT_VISIBLE bool edit_syntax_highlight_with_viewport(const char *language, const char *queryDirectory,
                                                     const uint16_t *units, uint32_t count,
                                                     uint32_t previewStart, uint32_t previewEnd, EditSyntaxPreview publishPreview,
                                                     EditSyntaxCapture callback, EditSyntaxCancelled check, void *context) {
    if (!language || !queryDirectory || !units || !callback) return false;
    return edit_syntax_analyze_v1(language, queryDirectory, units, count, previewStart, previewEnd,
                                 publishPreview, callback, NULL, check, context);
}

// A null capture name marks text excluded from matching. A language name marks an injection.
EDIT_VISIBLE bool edit_syntax_bracket_context(const char *language, const char *queryDirectory,
                                             const uint16_t *units, uint32_t count,
                                             EditSyntaxCapture callback, EditSyntaxCancelled check, void *context) {
    if (!language || !queryDirectory || !units || !callback) return false;
    return edit_syntax_analyze_v1(language, queryDirectory, units, count, 0, 0, NULL, NULL, callback, check, context);
}

/* A running editor may first open a highlighted file after its development bundle is rebuilt. */
EDIT_VISIBLE bool edit_syntax_highlight(const char *language, const char *queryDirectory,
                                       const uint16_t *units, uint32_t count,
                                       EditSyntaxCapture callback, EditSyntaxCancelled check, void *context) {
    return edit_syntax_highlight_with_viewport(language, queryDirectory, units, count,
                                             0, 0, NULL, callback, check, context);
}
