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
    NSString *queryPath = [directory stringByAppendingPathComponent:[@(name) stringByAppendingString:@".scm"]];
    const TSQuery *query = loadQuery(language, queryPath);
    if (!query) return false;
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
        if (preview && !cancelled(&input)) {
            runQuery(&input, query, root, directory, offset, depth, false, preview);
            if (injections) runQuery(&input, injections, root, directory, offset, depth, true, preview);
            if (!cancelled(&input)) preview->publish(input.context);
        }
        if (!cancelled(&input)) runQuery(&input, query, root, directory, offset, depth, false, NULL);
        if (injections && !cancelled(&input)) runQuery(&input, injections, root, directory, offset, depth, true, NULL);
        ts_tree_delete(tree);
    }
    ts_parser_delete(parser);
    return parsed && !cancelled(&input);
}

EDIT_VISIBLE bool edit_syntax_highlight(const char *language, const char *queryDirectory,
                                       const uint16_t *units, uint32_t count,
                                       uint32_t previewStart, uint32_t previewEnd, EditPreview publishPreview,
                                       EditCapture callback, EditCancelled check, void *context) {
    if (!language || !queryDirectory || !units || !callback || count > UINT32_MAX / 2u) return false;
    @autoreleasepool {
        NSString *directory = [NSString stringWithUTF8String:queryDirectory];
        if (!directory) return false;
        Input input = {units, count * 2u, callback, check, context};
        Preview preview = {previewStart * 2u, previewEnd * 2u, publishPreview};
        const bool canPreview = publishPreview && previewStart < previewEnd && previewEnd <= count;
        return runGrammar(input, language, directory, 0, 0, canPreview ? &preview : NULL);
    }
}
