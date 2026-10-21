#ifndef HARPER_FFI_H
#define HARPER_FFI_H
#include <stdint.h>
// Returns a JSON array of lints (char offsets). Free with harper_free. dialect: 0 American, 1 British, 2 Canadian, 3 Australian.
char *harper_lint(const char *text, uint32_t dialect);
// Returns the text with only high-confidence fixes applied (a/an, sentence capitals, "i", spacing, its/it's, a few
// contractions), or NULL on failure. Free with harper_free.
char *harper_fix(const char *text, uint32_t dialect);
void harper_free(char *p);
uint32_t harper_version(void);
#endif
