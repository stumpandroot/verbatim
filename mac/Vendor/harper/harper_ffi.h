#ifndef HARPER_FFI_H
#define HARPER_FFI_H
#include <stdint.h>
// Returns a JSON array of lints (char offsets). Free with harper_free. dialect: 0 American, 1 British, 2 Canadian, 3 Australian.
char *harper_lint(const char *text, uint32_t dialect);
void harper_free(char *p);
uint32_t harper_version(void);
#endif
