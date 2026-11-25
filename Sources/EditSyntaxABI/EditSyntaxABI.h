#ifndef EDIT_SYNTAX_ABI_H
#define EDIT_SYNTAX_ABI_H

#include <stdbool.h>
#include <stdint.h>

typedef void (*EditSyntaxCapture)(void * _Null_unspecified context, uint32_t start, uint32_t end,
                                  const char * _Nullable name);
typedef bool (*EditSyntaxCancelled)(void * _Null_unspecified context);
typedef void (*EditSyntaxPreview)(void * _Null_unspecified context);

typedef bool EditSyntaxAnalysisFunction(const char * _Nonnull language, const char * _Nonnull queryDirectory,
                                        const uint16_t * _Nonnull units, uint32_t count,
                                        uint32_t previewStart, uint32_t previewEnd,
                                        EditSyntaxPreview _Nullable publishPreview,
                                        EditSyntaxCapture _Nullable highlight, EditSyntaxCapture _Nullable bracket,
                                        EditSyntaxCancelled _Nullable cancelled, void * _Null_unspecified context);

typedef EditSyntaxAnalysisFunction *EditSyntaxAnalyze;
extern EditSyntaxAnalysisFunction edit_syntax_analyze_v1;

typedef bool EditMarkdownTableFunction(const uint16_t * _Nonnull units, uint32_t count, uint32_t caret,
                                       EditSyntaxCapture _Nonnull row, void * _Null_unspecified context);

typedef EditMarkdownTableFunction *EditMarkdownTable;
extern EditMarkdownTableFunction edit_markdown_table_v1;

#endif
