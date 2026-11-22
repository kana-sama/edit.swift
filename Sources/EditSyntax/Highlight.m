#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "tree_sitter/api.h"

#define EDIT_VISIBLE __attribute__((visibility("default")))

typedef void (*EditCapture)(void *context, uint32_t start, uint32_t end, const char *name);
typedef bool (*EditCancelled)(void *context);
typedef void (*EditPreview)(void *context);

typedef struct {
    uint32_t startByte;
    uint32_t endByte;
    EditPreview publish;
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
    {"markdown-inline", tree_sitter_markdown_inline}, {"python", tree_sitter_python},
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
    EditCapture capture;
    EditCancelled cancelled;
    void *context;
    bool bracketContext;
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

static NSString *captureValue(Input *input, TSQueryMatch match, uint32_t id) {
    for (uint16_t i = 0; i < match.capture_count; ++i) {
        if (match.captures[i].index == id) return stringForNode(input, match.captures[i].node);
    }
    return nil;
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
            NSString *value = captureValue(input, match, steps[start + 1].value_id);
            NSString *argument = steps[start + 2].type == TSQueryPredicateStepTypeCapture
                ? captureValue(input, match, steps[start + 2].value_id)
                : queryValue(query, steps[start + 2].value_id);
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

static const TSQuery *loadQuery(const TSLanguage *language, NSString *path) {
    static NSMutableDictionary<NSString *, id> *queries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queries = [NSMutableDictionary dictionary]; });
    @synchronized (queries) {
        id cached = queries[path];
        if (cached) return cached == NSNull.null ? NULL : [cached pointerValue];
        NSData *data = [NSData dataWithContentsOfFile:path];
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
        "string_literal", "interpreted_string_literal", "raw_string_literal", "char_literal", "rune_literal",
        "char_lit", "character", "system_lib_string", "hex_string_literal", "unicode_string_literal",
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
        input->capture(input->context, offset + start, offset + end, NULL);
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
                input->capture(input->context, offset + start, offset + end, NULL);
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

static void runQuery(Input *input, const TSQuery *query, TSNode root, NSString *directory,
                     uint32_t offset, int depth, bool injection, const Preview *preview) {
    TSQueryCursor *cursor = ts_query_cursor_new();
    if (preview) ts_query_cursor_set_byte_range(cursor, preview->startByte, preview->endByte);
    const TSQueryCursorOptions options = {.payload = input, .progress_callback = queryProgress};
    ts_query_cursor_exec_with_options(cursor, query, root, &options);
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
                if (!injection) {
                    input->capture(input->context, offset + from / 2u, offset + to / 2u, name);
                } else if (nestedName && strcmp(name, "injection.content") == 0 && !cancelled(input)) {
                    Input section = *input;
                    section.units += from / 2u;
                    section.bytes = to - from;
                    if (input->bracketContext) {
                        input->capture(input->context, offset + from / 2u, offset + to / 2u, nestedName);
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
    if (!input.bracketContext) {
        NSString *queryPath = [directory stringByAppendingPathComponent:[@(name) stringByAppendingString:@".scm"]];
        query = loadQuery(language, queryPath);
        if (!query) return false;
    }
    TSParser *parser = ts_parser_new();
    bool ready = ts_parser_set_language(parser, language);
    TSInput text = {.payload = &input, .read = readInput, .encoding = TSInputEncodingUTF16LE};
    TSParseOptions options = {.payload = &input, .progress_callback = parseProgress};
    TSTree *tree = ready ? ts_parser_parse_with_options(parser, NULL, text, options) : NULL;
    const bool parsed = tree != NULL;
    if (parsed) {
        TSNode root = ts_tree_root_node(tree);
        const TSQuery *injections = NULL;
        if (depth < 4 && !cancelled(&input) &&
            (strcmp(name, "markdown") == 0 || strcmp(name, "markdown-inline") == 0 || strcmp(name, "html") == 0)) {
            NSString *injectionPath = [directory stringByAppendingPathComponent:[@(name) stringByAppendingString:@"-injections.scm"]];
            injections = loadQuery(language, injectionPath);
        }
        if (input.bracketContext) {
            readBracketContext(&input, root, language, name, offset, depth);
        } else {
            if (preview && !cancelled(&input)) {
                runQuery(&input, query, root, directory, offset, depth, false, preview);
                if (injections) runQuery(&input, injections, root, directory, offset, depth, true, preview);
                if (!cancelled(&input)) preview->publish(input.context);
            }
            if (!cancelled(&input)) runQuery(&input, query, root, directory, offset, depth, false, NULL);
        }
        if (injections && !cancelled(&input)) runQuery(&input, injections, root, directory, offset, depth, true, NULL);
        ts_tree_delete(tree);
    }
    ts_parser_delete(parser);
    return parsed && !cancelled(&input);
}

EDIT_VISIBLE bool edit_syntax_highlight_with_viewport(const char *language, const char *queryDirectory,
                                                     const uint16_t *units, uint32_t count,
                                                     uint32_t previewStart, uint32_t previewEnd, EditPreview publishPreview,
                                                     EditCapture callback, EditCancelled check, void *context) {
    if (!language || !queryDirectory || !units || !callback || count > UINT32_MAX / 2u) return false;
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:queryDirectory];
        if (!directory) return false;
        Input input = {units, count * 2u, callback, check, context, false};
        Preview preview = {previewStart * 2u, previewEnd * 2u, publishPreview};
        const bool canPreview = publishPreview && previewStart < previewEnd && previewEnd <= count;
        return runGrammar(input, language, directory, 0, 0, canPreview ? &preview : NULL);
    }
}

// A null capture name marks text excluded from matching. A language name marks an injection.
EDIT_VISIBLE bool edit_syntax_bracket_context(const char *language, const char *queryDirectory,
                                             const uint16_t *units, uint32_t count,
                                             EditCapture callback, EditCancelled check, void *context) {
    if (!language || !queryDirectory || !units || !callback || count > UINT32_MAX / 2u) return false;
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:queryDirectory];
        if (!directory) return false;
        Input input = {units, count * 2u, callback, check, context, true};
        return runGrammar(input, language, directory, 0, 0, NULL);
    }
}

/* A running editor may first open a highlighted file after its development bundle is rebuilt. */
EDIT_VISIBLE bool edit_syntax_highlight(const char *language, const char *queryDirectory,
                                       const uint16_t *units, uint32_t count,
                                       EditCapture callback, EditCancelled check, void *context) {
    return edit_syntax_highlight_with_viewport(language, queryDirectory, units, count,
                                             0, 0, NULL, callback, check, context);
}
