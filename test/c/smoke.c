/* Smoke test of the experimental C interface: parse, render, free, errors. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "md.h"

static int fails = 0;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int contains(const uint8_t *s, size_t n, const char *needle) {
    size_t m = strlen(needle);
    for (size_t i = 0; i + m <= n; i++) if (memcmp(s + i, needle, m) == 0) return 1;
    return 0;
}

int main(void) {
    const char *src = "# Hi\n\nterm\n: def\n\n| a |\n| - |\n| 1 |\n";
    md_document *doc = NULL;
    CHECK(md_parse((const uint8_t *)src, strlen(src), MD_EXT_ALL, &doc) == MD_OK);
    CHECK(doc != NULL);

    uint8_t *html = NULL; size_t html_len = 0;
    CHECK(md_to_html(doc, &html, &html_len) == MD_OK);
    CHECK(contains(html, html_len, "<h1>Hi</h1>"));
    CHECK(contains(html, html_len, "<dl>"));
    CHECK(contains(html, html_len, "<table>"));
    md_free_string(html, html_len);

    uint8_t *text = NULL; size_t text_len = 0;
    CHECK(md_to_text(doc, 40, 0, &text, &text_len) == MD_OK);
    CHECK(contains(text, text_len, "Hi"));
    md_free_string(text, text_len);

    /* Without extensions the table is plain text. */
    md_document *plain = NULL;
    CHECK(md_parse((const uint8_t *)src, strlen(src), 0, &plain) == MD_OK);
    CHECK(md_to_html(plain, &html, &html_len) == MD_OK);
    CHECK(!contains(html, html_len, "<table>"));
    md_free_string(html, html_len);
    md_free(plain);

    /* Empty input and error paths. */
    md_document *empty = NULL;
    CHECK(md_parse(NULL, 0, 0, &empty) == MD_OK);
    md_free(empty);
    CHECK(md_parse(NULL, 5, 0, &empty) == MD_ERR_INVALID_ARGUMENT);
    CHECK(empty == NULL);
    CHECK(md_parse((const uint8_t *)"x", 1, 0, NULL) == MD_ERR_INVALID_ARGUMENT);
    CHECK(md_to_html(NULL, &html, &html_len) == MD_ERR_INVALID_ARGUMENT);
    md_free(NULL);
    md_free_string(NULL, 0);

    md_free(doc);

    /* What each extension flag does, seen from C. */
    static const struct { uint32_t flag; const char *src; const char *wants; } flags[] = {
        {MD_EXT_TABLES, "|a|\n|-|\n", "<table>"},
        {MD_EXT_STRIKETHROUGH, "~~a~~\n", "<del>"},
        {MD_EXT_TASK_LISTS, "- [x] a\n", "checkbox"},
        {MD_EXT_AUTOLINKS, "www.a.com\n", "<a href"},
        {MD_EXT_TAGFILTER, "<xmp>\n", "&lt;xmp>"},
        {MD_EXT_FOOTNOTES, "a[^1]\n\n[^1]: n\n", "footnote"},
        {MD_EXT_FRONT_MATTER, "---\nk: v\n---\nz\n", "<p>z</p>"},
        {MD_EXT_DEFINITION_LISTS, "t\n: d\n", "<dl>"},
    };
    for (size_t i = 0; i < sizeof flags / sizeof flags[0]; i++) {
        for (int on = 0; on < 2; on++) {
            md_document *d = NULL;
            CHECK(md_parse((const uint8_t *)flags[i].src, strlen(flags[i].src), on ? flags[i].flag : 0, &d) == MD_OK);
            CHECK(md_to_html(d, &html, &html_len) == MD_OK);
            /* Without front matter the block renders as a rule and a heading. */
            if (flags[i].flag == MD_EXT_FRONT_MATTER) CHECK(contains(html, html_len, "<hr />") == !on);
            else CHECK(contains(html, html_len, flags[i].wants) == on);
            md_free_string(html, html_len);
            md_free(d);
        }
    }

    /* Width and colour reach the terminal renderer; safe HTML is safe. */
    const char *words = "one two three four five six [x](javascript:a)\n";
    md_document *w = NULL;
    CHECK(md_parse((const uint8_t *)words, strlen(words), 0, &w) == MD_OK);
    CHECK(md_to_text(w, 0, 0, &text, &text_len) == MD_OK);
    CHECK(!contains(text, text_len, "one two\n"));
    CHECK(!contains(text, text_len, "\x1b["));
    md_free_string(text, text_len);
    CHECK(md_to_text(w, 8, 1, &text, &text_len) == MD_OK);
    CHECK(contains(text, text_len, "\x1b["));
    CHECK(contains(text, text_len, "two\x1b[0m\n"));
    md_free_string(text, text_len);
    CHECK(md_to_safe_html(w, &html, &html_len) == MD_OK);
    CHECK(contains(html, html_len, "href=\"\""));
    CHECK(!contains(html, html_len, "javascript"));
    md_free_string(html, html_len);
    CHECK(md_to_safe_html(NULL, &html, &html_len) == MD_ERR_INVALID_ARGUMENT);
    md_free(w);

    /* The default limits come back as their own status codes. */
    size_t line_len = 4u * 1024 * 1024 + 1;
    size_t big_len = 64u * 1024 * 1024 + 1;
    uint8_t *big = malloc(big_len);
    CHECK(big != NULL);
    if (big != NULL) {
        md_document *none = NULL;
        memset(big, 'a', line_len);
        CHECK(md_parse(big, line_len, 0, &none) == MD_ERR_LINE_TOO_LONG);
        CHECK(none == NULL);
        memset(big, '\n', big_len);
        CHECK(md_parse(big, big_len, 0, &none) == MD_ERR_INPUT_TOO_LARGE);
        CHECK(none == NULL);
        free(big);
    }

    CHECK(strcmp(md_version(), EXPECTED_VERSION) == 0); /* build.zig.zon */
    if (fails == 0) printf("c api ok\n");
    return fails ? 1 : 0;
}
